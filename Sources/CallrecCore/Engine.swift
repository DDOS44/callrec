import Foundation
import WhisperKit

/// WhisperKit plus Silero VAD, loaded once and reused across calls.
actor Engine {
    static let shared = Engine()

    static let contextPad = 0.5
    private var kit: WhisperKit?
    private var vad: SileroVAD?
    /// One load at a time: a call arriving while the start-up warm-up is still
    /// compiling joins that load instead of starting a second one.
    private var loading: Task<Void, Error>?

    func release() { kit = nil; vad = nil }

    /// Fewer than ~3 characters per second of detected speech means the model
    /// skipped most of it (Hinglish speech runs ~10-15 chars/s). Pure, for tests.
    static func looksTruncated(chars: Int, speechSeconds: Double) -> Bool {
        guard speechSeconds >= 1.5 else { return false }
        return Double(chars) < 3.0 * speechSeconds
    }

    static func text(of results: [TranscriptionResult]) -> String {
        results.flatMap(\.segments).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
    }

    /// "Devansh, Blaxify." from a vocabulary list; nil when empty. Pure, for tests.
    static func prompt(_ vocabulary: [String]) -> String? {
        let words = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: ", ") + "."
    }

    func transcribe(wav: URL, config: Config) async throws -> [Segment] {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
        let total = Double(samples.count) / Double(WhisperKit.sampleRate)
        guard total > 0 else { return [] }

        // 1. Voice activity is a gate only: it picks which stretches of audio go
        //    to the model, so silence is never transcribed (the old model looped
        //    on silence: "hello" x40). It never touches the returned text.
        if vad == nil { vad = try SileroVAD(modelURL: config.vadModelURL) }
        let detector = vad!
        let regions = try Log.interval("vad") {
            let probs = try detector.probabilities(samples: samples)
            let found = SpeechTimeline.regions(probabilities: probs, frameSeconds: SileroVAD.frameSeconds, totalSeconds: total)
            return SpeechTimeline.spans(SpeechTimeline.splitLong(found))
        }
        guard !regions.isEmpty else { return [] }
        let speechSeconds = regions.reduce(0) { $0 + $1.length }
        log(String(format: "%@: %.0fs audio, %.0fs speech (%.0f%%), %d regions", wav.lastPathComponent, total,
                   speechSeconds, 100 * speechSeconds / total, regions.count), .transcribe)

        // 2. Each region goes to the model on its own. Every block the model
        //    returns is kept exactly as written, stamped at its region's start.
        let kit = try await loadKit(config: config)
        var options = DecodingOptions()
        options.task = .transcribe
        // "en" is deliberate, not a mistake. See Config.language.
        options.language = config.language
        options.detectLanguage = false
        options.skipSpecialTokens = true
        if let prompt = Self.prompt(config.vocabulary), let tok = kit.tokenizer {
            // Bias spelling of names/brands. VAD already keeps silence away from the
            // model, which is where a prompt would otherwise get hallucinated back.
            options.promptTokens = tok.encode(text: " " + prompt)
                .filter { $0 < tok.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
        }
        var out: [Segment] = []
        let debug = ProcessInfo.processInfo.environment["CALLREC_DEBUG"] != nil
        let whisperState = Log.signposter.beginInterval("whisper", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("whisper", whisperState) }
        for r in regions {
            if debug { print(String(format: "[debug] region %.2f-%.2f", r.start, r.end)) }
            try Task.checkCancellation()
            // Half a second of real audio either side: VAD fires a beat after a word
            // starts, and a clip that begins mid-word loses it. Context only; the
            // line is still stamped at the region's own start.
            let a = min(samples.count, max(0, Int((r.start - Self.contextPad) * Double(WhisperKit.sampleRate))))
            let b = min(samples.count, max(a, Int((r.end + Self.contextPad) * Double(WhisperKit.sampleRate))))
            let clip = Array(samples[a..<b])
            var results = try await kit.transcribe(audioArray: clip, decodeOptions: options)
            // A vocabulary prompt fixes names but can make the model return nothing
            // for a whole region (2026-10-07: 17 s of speech came back empty with the
            // prompt, full text without it). Never lose a region to the prompt: if the
            // prompted pass looks too short for the speech in it, redo it unprompted
            // and keep whichever has more text.
            if options.promptTokens != nil {
                let prompted = Self.text(of: results)
                if Self.looksTruncated(chars: prompted.count, speechSeconds: r.length) {
                    // Built from scratch, not copied: a copy of the prompted options
                    // still came back empty in-process.
                    var plain = DecodingOptions()
                    plain.task = .transcribe
                    plain.language = config.language
                    plain.detectLanguage = false
                    plain.skipSpecialTokens = true
                    let retry = try await kit.transcribe(audioArray: clip, decodeOptions: plain)
                    if debug {
                        print(String(format: "[debug] retry %.1f-%.1f prompted=%d unprompted=%d", r.start, r.end,
                                     prompted.count, Self.text(of: retry).count))
                    }
                    if Self.text(of: retry).count > prompted.count {
                        log(String(format: "region %.0f-%.0fs: vocabulary prompt returned %d chars, unprompted %d; kept unprompted",
                                   r.start, r.end, prompted.count, Self.text(of: retry).count), .transcribe)
                        results = retry
                    }
                }
            }
            for seg in results.flatMap(\.segments) {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if ProcessInfo.processInfo.environment["CALLREC_DEBUG"] != nil {
                    print(String(format: "[debug] %.1f-%.1f %@", r.start, r.end, text))
                }
                guard !text.isEmpty else { continue }
                out.append(Segment(start: r.start, end: max(r.start, r.end), text: text))
            }
        }
        return Hallucination.mark(out)
    }

    /// Loads (and on the very first run compiles) the model and the VAD.
    func load(config: Config) async throws {
        _ = try await loadKit(config: config)
        if vad == nil { vad = try SileroVAD(modelURL: config.vadModelURL) }
    }

    private func loadKit(config: Config) async throws -> WhisperKit {
        if let kit { return kit }
        if loading == nil {
            // Inherits this actor's isolation, so the WhisperKit never crosses an actor boundary.
            loading = Task { try await self.finishLoad(config: config) }
        }
        let task = loading
        defer { loading = nil }
        try await task?.value
        guard let kit else {
            throw NSError(domain: "callrec", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "The speech model was released while it was loading."])
        }
        return kit
    }

    private func finishLoad(config: Config) async throws {
        kit = try await Self.buildKit(config: config)
    }

    private static func buildKit(config: Config) async throws -> WhisperKit {
        let folder = config.modelFolderURL
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path) else {
            throw NSError(domain: "callrec", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Model not found at \(folder.path). Run: ~/.callrec/download-model.sh"])
        }
        // download: false and a local tokenizer folder: nothing touches the network.
        let cfg = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                   verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        return try await WhisperKit(cfg)
    }
}
