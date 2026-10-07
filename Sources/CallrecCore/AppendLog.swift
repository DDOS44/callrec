import Foundation

/// Append-only line files (dial log, DNC list). One writer, a single `write` per
/// line on an O_APPEND descriptor, then a full fsync so a power cut cannot lose a
/// dial that already counted against a cap.
enum AppendLog {

    /// Appends `line` (no newline in it) as one line. Creates the file 0600 and its
    /// folder 0700. If a crash left a partial last line without a newline, a newline
    /// is written first so the new line is never glued onto the damaged one.
    static func append(_ line: String, to url: URL) throws {
        precondition(!line.contains("\n"), "AppendLog lines must be single-line")
        try Paths.ensureDir(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("open \(url.path)") }
        defer { close(fd) }

        var payload = Data()
        if try endsWithPartialLine(url) { payload.append(0x0A) }
        payload.append(Data((line + "\n").utf8))
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw posix("write \(url.path)") }
        // macOS: plain fsync does not reach the disk, F_FULLFSYNC does.
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw posix("fsync \(url.path)") }
    }

    /// True when the file exists, is non-empty and its last byte is not a newline.
    static func endsWithPartialLine(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() } catch { log("could not close \(url.path): \(error.localizedDescription)") }
        }
        let size = try handle.seekToEnd()
        guard size > 0 else { return false }
        try handle.seek(toOffset: size - 1)
        return try handle.read(upToCount: 1)?.first != 0x0A
    }

    /// File text split into lines. Missing file = no lines; other failures throw.
    static func lines(_ url: URL) throws -> [String] {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch {
            if Fs.isMissing(error) { return [] }
            throw error
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func posix(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
