import Foundation

/// The only way anything writes a call's `.md`.
///
/// Two programs edit the same file: the daemon and the app. Ownership:
///
/// - **Daemon** owns the header metadata (duration, audio, number, contact,
///   company, owner, error) and the `## Transcript` section.
/// - **App** owns `- outcome:`, `- who picked up:` and the notes (the human fields).
///
/// Every write is a read-modify-write under an advisory `flock` on a hidden
/// sibling lock file, with an atomic temp+rename write, and the transform only
/// replaces its own fields. A concurrent save therefore cannot erase the other
/// side's edits.
public enum MarkdownStore {

    public struct LockTimeout: Error, LocalizedError {
        public let path: String
        public var errorDescription: String? { "Could not lock \(path): another writer held it for too long." }
    }

    /// `.09-05-07.md` -> `.09-05-07.md.lock`, in the same folder, hidden.
    public static func lockURL(for md: URL) -> URL {
        md.deletingLastPathComponent().appendingPathComponent(".\(md.lastPathComponent).lock")
    }

    /// Runs `transform` on the file's current text while holding the lock.
    /// `existing` is nil when the file does not exist. Returning nil leaves the
    /// file untouched. Throws on any I/O failure; callers must not swallow it.
    public static func modify(_ md: URL, timeout: TimeInterval = 10,
                              _ transform: (_ existing: String?) throws -> String?) throws {
        let fd = open(lockURL(for: md).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Could not open lock file for \(md.path): \(String(cString: strerror(errno)))"])
        }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "flock failed for \(md.path): \(String(cString: strerror(errno)))"])
            }
            if Date() > deadline { throw LockTimeout(path: md.path) }
            usleep(25_000)
        }
        defer { flock(fd, LOCK_UN) }

        let existing: String? = FileManager.default.fileExists(atPath: md.path)
            ? try String(contentsOf: md, encoding: .utf8) : nil
        guard let updated = try transform(existing) else { return }
        try Data(updated.utf8).write(to: md, options: .atomic)
    }

    // MARK: - App side

    /// Saves the human fields only. Re-reads the file under the lock, so a
    /// transcript the daemon rewrote a second ago is kept.
    public static func saveHumanFields(_ md: URL, outcome: String, who: String, notes: String) throws {
        try modify(md) { existing in
            guard let existing else {
                throw NSError(domain: "callrec", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "\(md.lastPathComponent) no longer exists, so the edit was not saved."])
            }
            return MarkdownFields.update(md: existing, outcome: outcome, who: who, notes: notes)
        }
    }

    // MARK: - Daemon side

    /// Writes a transcript for a call. An existing file keeps every human field
    /// (and every other byte outside `## Transcript`) verbatim; a new file is
    /// rendered fresh.
    public static func writeTranscript(_ md: URL, date: Date, seconds: Double, audioName: String,
                                       segments: [Segment]) throws {
        try modify(md) { existing in
            let fresh = Markdown.render(date: date, seconds: seconds, audioName: audioName, segments: segments)
            return MarkdownFields.daemonMerge(existing: existing, fresh: fresh, segments: segments)
        }
    }

    /// Records a failure on an existing transcript, or creates the failure
    /// transcript if there is none. Human fields survive either way.
    public static func recordFailure(_ md: URL, message: String, date: Date, seconds: Double,
                                     audioName: String, id: String) throws {
        try modify(md) { existing in
            if let existing { return MarkdownFields.setError(md: existing, message: message) }
            return Markdown.renderFailure(date: date, seconds: seconds, audioName: audioName, error: message, id: id)
        }
    }

    /// Sets the header warnings (a silent track) on an existing transcript; an
    /// empty list clears them. Does nothing if the file is gone.
    public static func setWarnings(_ md: URL, _ warnings: [String]) throws {
        try modify(md) { existing in
            guard let existing else { return nil }
            let updated = MarkdownFields.setWarnings(md: existing, warnings)
            return updated == existing ? nil : updated
        }
    }

    /// Writes number / contact / company / owner into an existing transcript.
    /// Does nothing if the file is gone.
    public static func applyIdentity(_ md: URL, _ id: CallIdentity) throws {
        try modify(md) { existing in
            guard let existing else { return nil }
            return MarkdownFields.setIdentity(md: existing, id)
        }
    }
}
