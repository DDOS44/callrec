import Foundation

public enum Media {
    /// Duration of any audio file in seconds, read with ffprobe.
    public static func duration(of url: URL) -> Double? {
        guard let ffprobe = Shell.which("ffprobe") else { return nil }
        let r: (status: Int32, stdout: String, stderr: String)
        do {
            r = try Shell.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                        "-of", "default=noprint_wrappers=1:nokey=1", url.path], timeout: 60)
        } catch {
            log("ffprobe failed on \(url.lastPathComponent): \(error.localizedDescription)", .transcribe)
            return nil
        }
        guard r.status == 0,
              let d = Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), d >= 0 else { return nil }
        return d
    }
}

/// Permanent guard against silently losing audio: the finished recording must
/// be about as long as the call was.
public enum DurationGuard {
    /// True when the file is shorter than the wall-clock call by more than `tolerance` (10%).
    public static func shouldWarn(wallClockSeconds: Double, fileSeconds: Double, tolerance: Double = 0.10) -> Bool {
        guard wallClockSeconds > 0 else { return false }
        return fileSeconds < wallClockSeconds * (1 - tolerance)
    }
}
