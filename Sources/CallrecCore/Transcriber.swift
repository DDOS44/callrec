import Foundation

public enum Transcriber {

    public static func transcribe(wav: URL, config: Config) throws -> [Segment] {
        guard let cli = Shell.which("whisper-cli") else {
            throw NSError(domain: "callrec", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "whisper-cli not found. Run: brew install whisper-cpp"])
        }
        guard FileManager.default.fileExists(atPath: config.modelURL.path) else {
            throw NSError(domain: "callrec", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Model not found. Run: ~/.callrec/download-model.sh"])
        }

        let base = wav.deletingPathExtension().path
        let result = try Shell.run(cli, [
            "-m", config.modelURL.path,
            "-f", wav.path,
            "-l", config.language,
            "--prompt", config.prompt,
            "-otxt", "-osrt", "-of", base, "-nt", "-t", "4"
        ], timeout: 1800)

        guard result.status == 0 else {
            throw NSError(domain: "callrec", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey:
                "Transcription failed.\n\(result.stderr.suffix(500))"])
        }

        let srtURL = URL(fileURLWithPath: base + ".srt")
        let txtURL = URL(fileURLWithPath: base + ".txt")
        defer {
            try? FileManager.default.removeItem(at: srtURL)
            try? FileManager.default.removeItem(at: txtURL)
        }
        let srt = (try? String(contentsOf: srtURL, encoding: .utf8)) ?? ""
        return parseSRT(srt)
    }

    /// Parses whisper.cpp's .srt output into segments.
    public static func parseSRT(_ srt: String) -> [Segment] {
        var segments: [Segment] = []
        for block in srt.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 2, let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[arrow].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(from: parts[0]), let end = seconds(from: parts[1]) else { continue }
            let text = lines[(arrow + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            segments.append(Segment(start: start, end: end, text: text))
        }
        return segments
    }

    private static func seconds(from stamp: String) -> Double? {
        let s = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let bits = s.components(separatedBy: ":")
        guard bits.count == 3, let h = Double(bits[0]), let m = Double(bits[1]), let sec = Double(bits[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Transcribes a finished recording and writes the markdown next to it.
    @discardableResult
    public static func run(paths: RecordingPaths, seconds: Double, date: Date, config: Config) throws -> URL {
        let segments = try transcribe(wav: paths.mixWav, config: config)
        let md = Markdown.render(date: date, seconds: seconds,
                                 audioName: paths.m4a.lastPathComponent, segments: segments)
        try md.write(to: paths.md, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: paths.mixWav)
        return paths.md
    }

    /// Converts any audio file to the 16 kHz mono wav whisper expects.
    public static func toWhisperWav(_ input: URL) throws -> URL {
        if input.pathExtension.lowercased() == "wav" { return input }
        guard let ffmpeg = Shell.which("ffmpeg") else {
            throw NSError(domain: "callrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg not found. Run: brew install ffmpeg"])
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callrec-\(UUID().uuidString).wav")
        let r = try Shell.run(ffmpeg, ["-y", "-i", input.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out.path])
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey:
                "Could not convert \(input.lastPathComponent) for transcription.\n\(r.stderr.suffix(400))"])
        }
        return out
    }
}
