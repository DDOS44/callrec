import Foundation
import Testing
@testable import CallrecCore

private func mode(_ url: URL) -> Int {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return -1 }
    return Int(st.st_mode & 0o7777)
}

private func tempRoot() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-perm-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func tightenMakesDirsOwnerOnlyAndKeepsTheExecBit() throws {
    let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2026-10-06")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let md = day.appendingPathComponent("10-00-00.md")
    let bin = root.appendingPathComponent("tool")
    let models = root.appendingPathComponent("models")
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    let model = models.appendingPathComponent("weights.bin")
    for (url, m) in [(md, 0o644), (bin, 0o755), (model, 0o644)] {
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8), attributes: [.posixPermissions: m])
    }
    for dir in [root, day, models] { chmod(dir.path, 0o755) }
    // A symlink pointing at a world-readable file elsewhere must never be chmodded through.
    let outside = root.deletingLastPathComponent().appendingPathComponent("callrec-outside-\(UUID()).txt")
    FileManager.default.createFile(atPath: outside.path, contents: Data("y".utf8), attributes: [.posixPermissions: 0o644])
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

    let changes = Permissions.tighten(root, skipping: ["models"])
    equal(mode(root), 0o700, "perm.rootDir")
    equal(mode(day), 0o700, "perm.dayDir")
    equal(mode(md), 0o600, "perm.transcript")
    equal(mode(bin), 0o700, "perm.execKeptForOwner")
    equal(mode(models), 0o700, "perm.skippedDirItselfTightened")
    equal(mode(model), 0o644, "perm.skippedContentsUntouched")
    equal(mode(outside), 0o644, "perm.symlinkTargetUntouched")
    expect(changes.count == 5, "perm.changeCount", "\(changes)")
    equal(Permissions.tighten(root, skipping: ["models"]), [], "perm.idempotent")
}

@Test func recordingsFolderIsPrivateAndHiddenFromSpotlight() throws {
    let root = try tempRoot().appendingPathComponent("CallRecordings")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try Permissions.protectRecordings(root)
    equal(mode(root), 0o700, "perm.recordingsDir")
    let marker = root.appendingPathComponent(".metadata_never_index")
    expect(FileManager.default.fileExists(atPath: marker.path), "perm.neverIndexMarker")
    equal(mode(marker), 0o600, "perm.markerMode")
    try Permissions.protectRecordings(root)   // idempotent
    let day = root.appendingPathComponent("2026-10-06")
    try Paths.ensureDir(day)
    equal(mode(day), 0o700, "perm.ensureDirIsPrivate")
}

@Test func filesWrittenUnderTheDaemonUmaskAreOwnerOnly() throws {
    let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let old = umask(0o077); defer { umask(old) }
    let md = root.appendingPathComponent("09-05-07.md")
    try MarkdownStore.writeTranscript(md, date: Date(), seconds: 5, audioName: "x.m4a", segments: [])
    try MarkdownStore.saveHumanFields(md, outcome: "booked", who: "", notes: "n")
    equal(mode(md), 0o600, "perm.atomicWriteMode")
    equal(mode(MarkdownStore.lockURL(for: md)), 0o600, "perm.lockFileMode")
}
