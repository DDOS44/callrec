import Foundation

/// Recordings and transcripts are private: directories 0700, files 0600, kept out
/// of Spotlight. FileVault and a locked-down home folder help, but they are not
/// the app's own promise to make.
public enum Permissions {

    /// Everything this process creates from here on is owner-only. Call first thing
    /// in `main` for the daemon and the app.
    public static func lockDownProcess() {
        umask(0o077)
    }

    /// Creates a directory (and parents) as 0700, and tightens it if it already exists looser.
    public static func privateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = try tightenOne(url, isDirectory: true)
    }

    /// The recordings folder: private, and tagged so Spotlight does not index transcripts.
    public static func protectRecordings(_ root: URL) throws {
        try privateDir(root)
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard FileManager.default.createFile(atPath: marker.path, contents: Data(),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "callrec", code: 30, userInfo: [NSLocalizedDescriptionKey:
                    "Could not create \(marker.path)"])
            }
        }
    }

    /// Mode this entry should have: directories 0700; files lose group and other bits
    /// (so an owner-executable binary stays executable).
    static func target(mode: mode_t, isDirectory: Bool) -> mode_t {
        isDirectory ? 0o700 : (mode & 0o700)
    }

    /// Fixes one path. Returns a description of the change, or nil if it was already fine.
    /// Symlinks are skipped: chmod would follow them to somewhere we do not own.
    static func tightenOne(_ url: URL, isDirectory: Bool) throws -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "stat \(url.path): \(String(cString: strerror(errno)))"])
        }
        if (st.st_mode & S_IFMT) == S_IFLNK { return nil }
        let current = st.st_mode & 0o7777
        let wanted = target(mode: current, isDirectory: isDirectory)
        guard current != wanted else { return nil }
        guard chmod(url.path, wanted) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "chmod \(url.path): \(String(cString: strerror(errno)))"])
        }
        return String(format: "%@: %o -> %o", url.path, current, wanted)
    }

    /// Walks `root` tightening every directory and file. `skipping` names folders
    /// whose contents are left alone (large and not private, e.g. downloaded models).
    /// Returns every change made; failures are logged, never thrown, so one bad file
    /// cannot stop the daemon from starting.
    @discardableResult
    public static func tighten(_ root: URL, skipping: Set<String> = []) -> [String] {
        var changes: [String] = []
        func visit(_ dir: URL) {
            do { if let c = try tightenOne(dir, isDirectory: true) { changes.append(c) } }
            catch { logError("permissions: \(error.localizedDescription)") }
            for name in Fs.list(dir) {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard exists else { continue }
                if isDir.boolValue {
                    if skipping.contains(name) {
                        do { if let c = try tightenOne(url, isDirectory: true) { changes.append(c) } }
                        catch { logError("permissions: \(error.localizedDescription)") }
                    } else {
                        visit(url)
                    }
                } else {
                    do { if let c = try tightenOne(url, isDirectory: false) { changes.append(c) } }
                    catch { logError("permissions: \(error.localizedDescription)") }
                }
            }
        }
        visit(root)
        return changes
    }

    /// Run at daemon start: protect the recordings folder and tighten what is already on disk.
    /// Logs what it changed (and nothing when there is nothing to change).
    public static func enforceAtStartup(config: Config) {
        let home = Config.url.deletingLastPathComponent()
        do { try protectRecordings(config.recordingsURL) }
        catch { logError("permissions: could not protect \(config.recordingsURL.path): \(error.localizedDescription)") }
        var changes = tighten(home, skipping: ["models"])
        changes += tighten(config.recordingsURL)
        if changes.isEmpty { return }
        log("permissions: tightened \(changes.count) path(s) to owner-only", .watcher)
        for c in changes.prefix(20) { log("permissions: \(c)", .watcher) }
        if changes.count > 20 { log("permissions: ... and \(changes.count - 20) more", .watcher) }
    }
}
