import Foundation
import Testing
@testable import CallrecCore

private let listing = [
    "09-05-07.m4a", "09-05-07.md", "09-05-07.far.wav", "09-05-07.mic.caf", "09-05-07.mix.wav",
    ".09-05-07.md.lock", "09-05-07.far.caf",
    "09-05-070.md", "10-00-00.m4a", "10-00-00.md", ".10-00-00.md.lock", "session-1.m4a", "notes.txt"
]

@Test func trashListsEveryFileOfOneCallAndNothingElse() {
    let f = CallTrash.files(forBase: "09-05-07", in: listing)
    equal(Set(f), ["09-05-07.m4a", "09-05-07.md", "09-05-07.far.wav", "09-05-07.mic.caf", "09-05-07.mix.wav",
                   ".09-05-07.md.lock", "09-05-07.far.caf"], "trash.files")
    equal(f.last ?? "", "09-05-07.md", "trash.mdLast")
    expect(!f.contains("09-05-070.md"), "trash.noPrefixCollision")
    equal(CallTrash.files(forBase: "", in: listing), [], "trash.emptyBase")
    equal(CallTrash.files(forBase: "11-11-11", in: listing), [], "trash.unknownBase")
}

private struct Boom: LocalizedError { var errorDescription: String? { "locked" } }

@Test func aFailedMoveIsReportedAndTheRestStillMove() {
    let dir = URL(fileURLWithPath: "/nonexistent-callrec-test")
    var moved: [String] = []
    let r = CallTrash.trash(base: "10-00-00", in: dir, listing: listing) { url in
        if url.lastPathComponent.hasSuffix(".m4a") { throw Boom() }
        moved.append(url.lastPathComponent)
    }
    equal(r.failed.map(\.file), ["10-00-00.m4a"], "trash.failedNamed")
    equal(Set(r.trashed), ["10-00-00.md", ".10-00-00.md.lock"], "trash.restMoved")
    expect(!r.isComplete && r.report.contains("10-00-00.m4a") && r.report.contains("locked"), "trash.reportNamesFile", r.report)
}

@Test func trashingUsesTheInjectedMoverNotDeletion() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-trash-\(UUID())")
    try Paths.ensureDir(dir)
    defer { Fs.remove(dir) }
    for n in ["01-02-03.m4a", "01-02-03.md", "04-05-06.md"] { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
    var seen: [String] = []
    let r = CallTrash.trash(base: "01-02-03", in: dir) { seen.append($0.lastPathComponent) }
    equal(r.trashed.count, 2, "trash.count")
    equal(seen.last ?? "", "01-02-03.md", "trash.order")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("04-05-06.md").path), "trash.otherCallUntouched")
}
