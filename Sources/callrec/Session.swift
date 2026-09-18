import AVFoundation
import Foundation

/// Manual fallback: record one long session, then cut it into separate calls
/// on long silences and transcribe each piece.
@available(macOS 14.2, *)
enum Session {

    static var pidURL: URL { Config.url.deletingLastPathComponent().appendingPathComponent("session.pid") }

    static func start(config: Config) throws -> Never {
        AudioRecordingPermission.request()
        let startedAt = Date()
        var sessionConfig = config
        sessionConfig.minCallSeconds = 1   // the session itself is always kept; spans are filtered later
        // The session is recorded as one long file; it is cut into calls and
        // deleted when the session stops.
        let recorder = try CallRecorder(config: sessionConfig, startedAt: startedAt, basePrefix: "session-")
        try recorder.start()

        try FileManager.default.createDirectory(at: pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(ProcessInfo.processInfo.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        print("Session recording to \(recorder.paths.dir.path). Stop with: callrec session stop")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let finish: () -> Never = {
            defer { try? FileManager.default.removeItem(at: pidURL) }
            do {
                let result = try recorder.stop()
                guard result.kept else { print("Nothing recorded."); exit(0) }
                let calls = try split(result: result, config: config, sessionStart: startedAt)
                print(calls.isEmpty ? "No calls found in the session." : calls.map(\.path).joined(separator: "\n"))
                exit(0)
            } catch {
                FileHandle.standardError.write("session failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { finish() }
            source.resume()
            sources.append(source)
        }
        dispatchMain()
    }

    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func stop() throws {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "callrec", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "No session is running. Start one with: callrec session start"])
        }
        kill(pid, SIGTERM)
        print("Stopping the session (pid \(pid)). The calls appear once transcription finishes.")
    }

    /// Cuts the session mix into one file per call and transcribes each.
    static func split(result: RecordingResult, config: Config, sessionStart: Date) throws -> [URL] {
        let rms = try frameRMS(url: result.paths.mixWav)
        // The microphone is mixed in, so "silence" still carries room noise.
        // Scale the threshold to the loudest second instead of using a fixed floor.
        let loudest = rms.max() ?? 0
        let threshold = max(0.01, loudest * 0.25)
        let spans = SilenceSplitter.spans(rms: rms, frameSeconds: 1, threshold: threshold,
                                          minGapSeconds: 20, minSpanSeconds: Double(config.minCallSeconds))
        print("Scanned \(rms.count)s, loudest second \(loudest), threshold \(threshold), found \(spans.count) call(s).")
        guard let ffmpeg = Shell.which("ffmpeg") else {
            throw NSError(domain: "callrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg not found. Run: brew install ffmpeg"])
        }

        var written: [URL] = []
        for span in spans {
            let callDate = sessionStart.addingTimeInterval(span.start)
            let callPaths = Paths.forCall(at: callDate, root: config.recordingsURL)
            try Paths.ensureDir(callPaths.dir)

            let cutWav = try Shell.run(ffmpeg, ["-y", "-i", result.paths.mixWav.path,
                                                "-ss", "\(span.start)", "-to", "\(span.end)",
                                                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", callPaths.mixWav.path])
            guard cutWav.status == 0 else {
                throw NSError(domain: "callrec", code: Int(cutWav.status), userInfo: [NSLocalizedDescriptionKey:
                    "Could not cut the session at \(span.start)s.\n\(cutWav.stderr.suffix(400))"])
            }
            let cutM4a = try Shell.run(ffmpeg, ["-y", "-i", callPaths.mixWav.path,
                                                "-c:a", "aac", "-b:a", "64k", callPaths.m4a.path])
            guard cutM4a.status == 0 else {
                throw NSError(domain: "callrec", code: Int(cutM4a.status), userInfo: [NSLocalizedDescriptionKey:
                    "Could not encode the call starting at \(span.start)s.\n\(cutM4a.stderr.suffix(400))"])
            }

            let md = try Transcriber.run(paths: callPaths, seconds: span.end - span.start,
                                         date: callDate, config: config)
            written.append(md)
        }

        try? FileManager.default.removeItem(at: result.paths.mixWav)
        try? FileManager.default.removeItem(at: result.paths.m4a)
        return written
    }

    /// One RMS value per second of the given wav.
    static func frameRMS(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate)
        var out: [Float] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            var sum: Double = 0
            var count = 0
            if let channels = buf.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buf.frameLength) {
                        let v = Double(channels[c][i]); sum += v * v; count += 1
                    }
                }
            }
            out.append(count > 0 ? Float((sum / Double(count)).squareRoot()) : 0)
        }
        return out
    }
}
