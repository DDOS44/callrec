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
            // -mc 0 re-applies the prompt to every 30 s window. Without it the
            // model drifts after the first window, usually into translated
            // English. The rest keeps segments to about one sentence.
            "-mc", "0", "-bs", "5", "-bo", "5", "-ml", "80", "-sow",
            "-osrt", "-of", base, "-t", "4"
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
        // Whisper writes Hindi in Devanagari whatever we ask; convert it to the
        // Roman Hinglish people actually read.
        return parseSRT(srt).map {
            Segment(start: $0.start, end: $0.end,
                    text: Transliterate.devanagariToRoman($0.text), speaker: $0.speaker)
        }
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
    ///
    /// The two tracks are transcribed separately so each line can be labelled:
    /// the tap is the other person, the microphone is you. Whisper uses Metal,
    /// so the passes run one after the other rather than in parallel.
    @discardableResult
    public static func run(paths: RecordingPaths, seconds: Double, date: Date, config: Config) throws -> URL {
        let fm = FileManager.default
        var segments: [Segment]

        if fm.fileExists(atPath: paths.farWav.path), fm.fileExists(atPath: paths.micWav.path) {
            let them = try transcribe(wav: paths.farWav, config: config)
            let me = try transcribe(wav: paths.micWav, config: config)
            let themRMS = (try? AudioLevels.perSecond(url: paths.farWav)) ?? []
            let meRMS = (try? AudioLevels.perSecond(url: paths.micWav)) ?? []
            segments = SpeakerMerge.merge(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
        } else {
            segments = try transcribe(wav: paths.mixWav, config: config)
        }
        let md = Markdown.render(date: date, seconds: seconds,
                                 audioName: paths.m4a.lastPathComponent, segments: segments)
        try md.write(to: paths.md, atomically: true, encoding: .utf8)
        let identity = Identify.apply(to: paths.md, callDate: date, config: config)
        if identity.isEmpty, !CallHistory.readable {
            print("[callrec] " + CallHistory.noAccessMessage)
        }
        // The two tracks stay: they are what makes a re-transcription possible.
        try? fm.removeItem(at: paths.mixWav)
        return paths.md
    }

    /// Re-runs transcription for calls already on disk and rewrites only the
    /// transcript, keeping outcome, notes and the identity fields.
    public static func retranscribe(target: String?, config: Config) -> (done: Int, skipped: Int) {
        let fm = FileManager.default
        let root = config.recordingsURL
        var done = 0, skipped = 0

        let days: [String]
        var onlyCall: String? = nil
        if let target, target.contains("/") {
            let parts = target.components(separatedBy: "/")
            days = [parts[0]]
            onlyCall = parts[1]
        } else if let target, target.count == 10 {
            days = [target]
        } else if let target {
            days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 10 }
            onlyCall = target
        } else {
            days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 10 }
        }

        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        for day in days.sorted() {
            let dir = root.appendingPathComponent(day)
            let mds = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.sorted()
            for file in mds {
                let base = String(file.dropLast(3))
                if let onlyCall, base != onlyCall { continue }
                let paths = RecordingPaths(dir: dir, base: base)
                guard let existing = try? String(contentsOf: paths.md, encoding: .utf8) else { skipped += 1; continue }

                var segments: [Segment] = []
                do {
                    if fm.fileExists(atPath: paths.farWav.path), fm.fileExists(atPath: paths.micWav.path) {
                        let them = try transcribe(wav: paths.farWav, config: config)
                        let me = try transcribe(wav: paths.micWav, config: config)
                        let themRMS = (try? AudioLevels.perSecond(url: paths.farWav)) ?? []
                        let meRMS = (try? AudioLevels.perSecond(url: paths.micWav)) ?? []
                        segments = SpeakerMerge.merge(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
                    } else if fm.fileExists(atPath: paths.m4a.path) {
                        // No tracks kept for this call: the mix is all there is,
                        // so the lines come back without speaker labels.
                        let wav = try toWhisperWav(paths.m4a)
                        segments = try transcribe(wav: wav, config: config)
                        try? fm.removeItem(at: wav)
                    } else {
                        skipped += 1
                        continue
                    }
                } catch {
                    print("[callrec] could not re-transcribe \(day)/\(base): \(error.localizedDescription)")
                    skipped += 1
                    continue
                }

                let updated = MarkdownFields.replaceTranscript(md: existing, with: segments)
                try? updated.write(to: paths.md, atomically: true, encoding: .utf8)
                _ = stamp.date(from: "\(day) \(base)")
                done += 1
                print("[callrec] re-transcribed \(day)/\(base) (\(segments.count) segments)")
            }
        }
        return (done, skipped)
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
