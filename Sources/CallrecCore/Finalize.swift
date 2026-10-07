import Foundation

/// Turns the raw capture into the finished files, and rescues a recording that
/// was interrupted.
///
/// Raw capture is written as CAF (`.far.caf`, `.mic.caf`) because a WAV's length is
/// only written when the file is closed: `kill -9` mid-call left a WAV whose header
/// says zero frames (`afinfo`: 0 bytes), while a CAF keeps an open-ended data chunk
/// and reads back in full (measured 2026-10-06). The finished tracks are 16 kHz
/// mono WAVs, which the transcriber and the rest of the pipeline already use.
///
/// Rule: a raw file is only deleted after the file made from it has been checked.
public enum Finalize {

    static func ffmpeg() throws -> String {
        guard let path = Shell.which("ffmpeg") else {
            throw NSError(domain: "callrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg not found. Run: brew install ffmpeg"])
        }
        return path
    }

    /// Both raw files exist or either does: this recording was not finalized.
    public static func hasRawCapture(_ paths: RecordingPaths) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.farCaf.path) || fm.fileExists(atPath: paths.micCaf.path)
    }

    /// A finished recording has an m4a. Raw capture with no m4a means an interruption.
    public static func isInterrupted(_ paths: RecordingPaths) -> Bool {
        hasRawCapture(paths) && !FileManager.default.fileExists(atPath: paths.m4a.path)
    }

    /// 16 kHz mono wav from a raw capture file. The result must be about as long
    /// as the source, or this throws and the source stays.
    static func convert(raw: URL, to wav: URL, ffmpeg: String) throws {
        let part = wav.deletingLastPathComponent().appendingPathComponent("." + wav.lastPathComponent + ".part")
        defer { Fs.remove(part) }
        let r = try Shell.run(ffmpeg, ["-y", "-i", raw.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                                       "-f", "wav", part.path])
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not convert \(raw.lastPathComponent).\n\(r.stderr.suffix(400))"])
        }
        guard let rawSeconds = Media.duration(of: raw), let outSeconds = Media.duration(of: part) else {
            throw NSError(domain: "callrec", code: 31, userInfo: [NSLocalizedDescriptionKey:
                "Could not measure \(raw.lastPathComponent) to check the conversion. The raw file was kept."])
        }
        guard !DurationGuard.shouldWarn(wallClockSeconds: rawSeconds, fileSeconds: outSeconds) else {
            throw NSError(domain: "callrec", code: 32, userInfo: [NSLocalizedDescriptionKey:
                String(format: "%@ converted to %.1fs but the raw capture is %.1fs. The raw file was kept.",
                       wav.lastPathComponent, outSeconds, rawSeconds)])
        }
        if FileManager.default.fileExists(atPath: wav.path) {
            _ = try FileManager.default.replaceItemAt(wav, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: wav)
        }
    }

    /// Raw captures to finished 16 kHz mono wav tracks. Raw files are removed only
    /// after every conversion succeeded.
    public static func tracks(paths: RecordingPaths) throws {
        let pairs = [(paths.farCaf, paths.farWav), (paths.micCaf, paths.micWav)]
            .filter { FileManager.default.fileExists(atPath: $0.0.path) }
        guard !pairs.isEmpty else { return }
        let tool = try ffmpeg()
        for (raw, wav) in pairs { try convert(raw: raw, to: wav, ffmpeg: tool) }
        for (raw, _) in pairs { Fs.remove(raw) }
    }

    /// Mixes the finished tracks into `.mix.wav` and encodes the `.m4a`. Never trims;
    /// `wallClockSeconds` (when known) is only used to warn if audio was lost.
    public static func mixAndEncode(paths: RecordingPaths, wallClockSeconds: Double?) throws {
        let tool = try ffmpeg()
        let fm = FileManager.default
        let tracks = [paths.farWav, paths.micWav].filter { fm.fileExists(atPath: $0.path) }
        guard !tracks.isEmpty else {
            throw NSError(domain: "callrec", code: 33, userInfo: [NSLocalizedDescriptionKey:
                "No finished tracks for \(paths.base) to mix."])
        }
        var args = ["-y"]
        for t in tracks { args += ["-i", t.path] }
        if tracks.count == 2 {
            // Both tracks are 16 kHz mono and already the same length.
            args += ["-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0,aresample=16000"]
        }
        args += ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", paths.mixWav.path]
        let mix = try Shell.run(tool, args)
        guard mix.status == 0 else {
            throw NSError(domain: "callrec", code: Int(mix.status), userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not merge the two recordings.\n\(mix.stderr.suffix(500))"])
        }

        // Never trim: a past silenceremove filter turned a 170 s call into 1.45 s.
        // Verify instead that the mix is about as long as the call was.
        if let wall = wallClockSeconds {
            if let fileSeconds = Media.duration(of: paths.mixWav) {
                if DurationGuard.shouldWarn(wallClockSeconds: wall, fileSeconds: fileSeconds) {
                    logError(String(format: "WARNING: final mix is %.1fs but the call lasted %.1fs wall-clock (%.0f%% of it). Audio may have been lost; keeping the untrimmed files in %@",
                                    fileSeconds, wall, fileSeconds / wall * 100, paths.dir.path), .capture)
                }
            } else {
                logError("WARNING: could not measure the final mix duration with ffprobe; duration guard skipped", .capture)
            }
        }

        let enc = try Shell.run(tool, ["-y", "-i", paths.mixWav.path, "-c:a", "aac", "-b:a", "64k", paths.m4a.path])
        guard enc.status == 0 else {
            throw NSError(domain: "callrec", code: Int(enc.status), userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not write the m4a.\n\(enc.stderr.suffix(500))"])
        }
    }

    /// Rebuilds everything an interrupted recording is missing (tracks, mix, m4a)
    /// from whatever raw capture survived. Safe to run on a healthy recording.
    public static func recover(paths: RecordingPaths) throws {
        try tracks(paths: paths)
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.m4a.path) {
            try mixAndEncode(paths: paths, wallClockSeconds: nil)
        }
        log("recovered \(paths.dir.lastPathComponent)/\(paths.base) from its raw capture", .capture)
    }
}
