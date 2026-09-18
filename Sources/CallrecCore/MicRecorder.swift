import AVFoundation
import Foundation

/// Records the microphone (your side of the call) to a 16-bit PCM WAV.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var running = false
    private var startHost: UInt64 = 0
    private var framesWritten: Int64 = 0
    private var writeFormat: AVAudioFormat?

    public init(url: URL) throws {
        self.url = url
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            throw NSError(domain: "callrec", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No microphone input available. Check System Settings -> Privacy & Security -> Microphone."])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file

        if fmt.channelCount > 1 {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate,
                                           channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: fmt, to: mono) else {
                throw NSError(domain: "callrec", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not set up mono conversion for the microphone."])
            }
            monoFormat = mono
            converter = conv
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let file = self.file else { return }
            do {
                let out = self.downmix(buf) ?? buf
                self.framesWritten += Int64(out.frameLength)
                try file.write(from: out)
            } catch {
                FileHandle.standardError.write("mic write failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }

        engine.prepare()
        try engine.start()
        writeFormat = monoFormat ?? fmt
        startHost = Clock.nowHost
        running = true
    }

    private func downmix(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let monoFormat,
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buf.frameLength) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        return err == nil ? out : nil
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        padToWallClock()
        file = nil
        running = false
    }

    /// Matches the far-side track: fill to the stop time so both files are the
    /// same length and mix without any alignment step.
    private func padToWallClock() {
        guard let file, let format = writeFormat else { return }
        let pad = Clock.framesToPad(writtenFrames: framesWritten, startHost: startHost,
                                    bufferHost: Clock.nowHost, rate: format.sampleRate)
        guard pad > 0 else { return }
        let chunk = AVAudioFrameCount(min(pad, Int64(format.sampleRate)))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        var remaining = pad
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(chunk)))
            silence.frameLength = n
            for channel in 0..<Int(format.channelCount) {
                if let data = silence.floatChannelData?[channel] {
                    memset(data, 0, Int(n) * MemoryLayout<Float>.size)
                }
            }
            try? file.write(from: silence)
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
    }

    deinit { stop() }
}
