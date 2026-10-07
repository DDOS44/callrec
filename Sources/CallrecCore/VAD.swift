import Foundation
import CoreML

/// A stretch of the original recording that contains speech, in seconds.
public struct SpeechRegion: Equatable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { end - start }
}

/// Turns per-frame speech probabilities into speech regions. VAD is a gate
/// only: it decides which audio goes to the model, and nothing else. All pure.
public enum SpeechTimeline {

    /// Same hysteresis as Silero's reference `get_speech_timestamps`: speech
    /// starts when the probability reaches `threshold` and ends once it has
    /// stayed under `threshold - 0.15` for `minSilence`. Spans shorter than
    /// `minSpeech` are dropped, the rest are padded by `pad` on both sides and
    /// merged when the padding makes them touch.
    public static func regions(probabilities: [Float], frameSeconds: Double, totalSeconds: Double,
                               threshold: Float = 0.5, minSpeech: Double = 0.1,
                               minSilence: Double = 0.3, pad: Double = 0.2) -> [SpeechRegion] {
        let negThreshold = max(threshold - 0.15, 0.01)
        var raw: [SpeechRegion] = []
        var start: Int?
        var silenceStart: Int?
        for (i, p) in probabilities.enumerated() {
            if p >= threshold {
                if start == nil { start = i }
                silenceStart = nil
            } else if p < negThreshold, let s = start {
                if silenceStart == nil { silenceStart = i }
                if Double(i - silenceStart! + 1) * frameSeconds >= minSilence {
                    raw.append(SpeechRegion(start: Double(s) * frameSeconds, end: Double(silenceStart!) * frameSeconds))
                    start = nil
                    silenceStart = nil
                }
            }
        }
        if let s = start {
            raw.append(SpeechRegion(start: Double(s) * frameSeconds, end: min(totalSeconds, Double(probabilities.count) * frameSeconds)))
        }
        var padded: [SpeechRegion] = []
        for r in raw where r.length >= minSpeech {
            let p = SpeechRegion(start: max(0, r.start - pad), end: min(totalSeconds, r.end + pad))
            if let last = padded.last, p.start <= last.end {
                padded[padded.count - 1].end = max(last.end, p.end)
            } else {
                padded.append(p)
            }
        }
        return padded
    }

    /// Joins regions separated by less than `maxGap` seconds into one span that
    /// runs from the first region's start to the last one's end, so the model
    /// hears the real audio between them and has a sentence's worth of context.
    /// A span never grows past `maxLength` (one Whisper window). Spans only choose
    /// what audio is sent: they never touch the returned text.
    public static func spans(_ regions: [SpeechRegion], maxGap: Double = 2.0, maxLength: Double = 25) -> [SpeechRegion] {
        var out: [SpeechRegion] = []
        for r in regions {
            if var last = out.last, r.start - last.end < maxGap, r.end - last.start <= maxLength {
                last.end = r.end
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Cuts any region longer than `maxLength` into equal pieces, so a pack
    /// always fits one 30 s Whisper window. Only monologues without a 0.3 s
    /// pause for that long are affected.
    public static func splitLong(_ regions: [SpeechRegion], maxLength: Double = 25) -> [SpeechRegion] {
        regions.flatMap { r -> [SpeechRegion] in
            guard r.length > maxLength else { return [r] }
            let n = Int((r.length / maxLength).rounded(.up))
            let step = r.length / Double(n)
            return (0..<n).map { SpeechRegion(start: r.start + Double($0) * step, end: r.start + Double($0 + 1) * step) }
        }
    }
}

/// Silero VAD v6 as a CoreML model (FluidInference/silero-vad-coreml). It reads
/// 512 samples at 16 kHz (32 ms) plus the last 64 samples of the previous
/// frame, and carries an LSTM state from frame to frame.
public final class SileroVAD {
    public static let frameSamples = 512
    public static let contextSamples = 64
    public static let frameSeconds = Double(frameSamples) / 16000

    private let model: MLModel

    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "callrec", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "VAD model not found at \(modelURL.path). Run: ~/.callrec/download-model.sh"])
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly   // tiny model; CPU avoids ANE round trips per 32 ms frame
        model = try MLModel(contentsOf: modelURL, configuration: cfg)
    }

    /// One speech probability per 32 ms frame of 16 kHz mono audio.
    public func probabilities(samples: [Float]) throws -> [Float] {
        let n = Self.frameSamples, c = Self.contextSamples
        var hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        var cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0..<128 { hidden[i] = 0; cell[i] = 0 }
        let input = try MLMultiArray(shape: [1, NSNumber(value: n + c)], dataType: .float32)
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: n + c)
        var context = [Float](repeating: 0, count: c)
        var out: [Float] = []
        out.reserveCapacity(samples.count / n + 1)
        var pos = 0
        while pos < samples.count {
            let end = min(pos + n, samples.count)
            for i in 0..<c { ptr[i] = context[i] }
            for i in 0..<n { ptr[c + i] = (pos + i) < end ? samples[pos + i] : 0 }
            for i in 0..<c { context[i] = ptr[n + i] }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: input),
                "hidden_state": MLFeatureValue(multiArray: hidden),
                "cell_state": MLFeatureValue(multiArray: cell)
            ])
            let result = try model.prediction(from: features)
            guard let p = result.featureValue(for: "vad_output")?.multiArrayValue,
                  let h = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let cs = result.featureValue(for: "new_cell_state")?.multiArrayValue else {
                throw NSError(domain: "callrec", code: 8, userInfo: [NSLocalizedDescriptionKey: "VAD model returned no output"])
            }
            out.append(p[0].floatValue)
            hidden = h
            cell = cs
            pos += n
        }
        return out
    }
}
