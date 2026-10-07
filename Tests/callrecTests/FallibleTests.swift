import Foundation
import Testing
@testable import CallrecCore

private struct Boom: Error {}

@Test func attemptReturnsValueOrNilNeverCrashes() {
    equal(attempt("ok") { 41 + 1 }, 42, "attempt.value")
    expect(attempt("boom") { () throws -> Int in throw Boom() } == nil, "attempt.nilOnThrow")
}

@Test func missingIsQuietButRealErrorsAreNotMissing() {
    let gone = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-gone-\(UUID())")
    equal(Fs.list(gone), [], "fs.listMissingIsEmpty")
    expect(Fs.text(gone) == nil, "fs.textMissingIsNil")
    equal(Fs.size(of: gone) == nil, true, "fs.sizeMissingIsNil")
    Fs.remove(gone)  // must not crash or throw
    expect(Fs.isMissing(CocoaError(.fileNoSuchFile)), "fs.cocoaMissing")
    expect(Fs.isMissing(CocoaError(.fileReadNoSuchFile)), "fs.cocoaReadMissing")
    expect(!Fs.isMissing(CocoaError(.fileReadNoPermission)), "fs.permissionIsNotMissing")
}

@Test func failureReporterNeverThrowsEvenWhenItCannotWrite() {
    // The reporter writes into a folder that does not exist: the write fails, and
    // the function must still return (it logs the failure) rather than crash or throw.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-nodir-\(UUID())")
    let paths = RecordingPaths(dir: dir, base: "10-00-00")
    let url = Transcriber.writeFailure(paths: paths, seconds: 12, date: Date(), error: Boom())
    equal(url, paths.md, "reporter.returnsTarget")
    expect(!FileManager.default.fileExists(atPath: paths.md.path), "reporter.nothingWritten")
}

@Test func doctorFindsCallrecCrashReportsOnly() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-diag-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["callrec-2026-10-06-101500.ips", "callrec-app-2026-10-07-090000.ips", "Safari-2026-10-06-101500.ips",
                 "callrec-notes.txt", "Callrec-old.crash"] {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }
    let found = Doctor.crashReports(in: dir).map(\.name).sorted()
    equal(found, ["Callrec-old.crash", "callrec-2026-10-06-101500.ips", "callrec-app-2026-10-07-090000.ips"], "doctor.crashReports")
    equal(Doctor.crashReports(in: dir.appendingPathComponent("missing")), [], "doctor.crashReportsMissingDir")
}
