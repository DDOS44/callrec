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
                try file.write(from: self.downmix(buf) ?? buf)
            } catch {
                FileHandle.standardError.write("mic write failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }

        engine.prepare()
        try engine.start()
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
        file = nil
        running = false
    }

    deinit { stop() }
}
