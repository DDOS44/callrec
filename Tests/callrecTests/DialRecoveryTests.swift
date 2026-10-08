import Foundation
import Testing
@testable import CallrecCore

// Regression (2026-10-08): the app was relaunched at the end of a live call; the call
// was left with an attempt and no result, and no wrap-up was ever offered.

private func attempt(_ ts: Date, _ id: String) -> DialLogEntry {
    .attempt(at: ts, id: id, list: "fake", leadID: "9000000001", key: "9000000001")
}

@Test func unfinishedFindsAttemptsWithoutResults() {
    let t = DialFixture.at(8, 11)
    let done = attempt(t.addingTimeInterval(-600), "A")
    let log = [done, done.finished(at: t.addingTimeInterval(-500), result: .connected, seconds: 40),
               attempt(t.addingTimeInterval(-300), "B"), attempt(t.addingTimeInterval(-60), "C")]
    #expect(DialRecovery.unfinished(log: log, now: t).map(\.attemptID) == ["C", "B"])
    #expect(DialRecovery.unfinished(log: log, now: t, excluding: "C").map(\.attemptID) == ["B"],
            "the live session's own attempt is not an orphan")
}

@Test func unfinishedIgnoresOldAttempts() {
    let t = DialFixture.at(8, 18)
    let log = [attempt(t.addingTimeInterval(-7 * 3600), "OLD"), attempt(t.addingTimeInterval(-3600), "NEW")]
    #expect(DialRecovery.unfinished(log: log, now: t).map(\.attemptID) == ["NEW"])
}

@Test func recordingMatchesTheCallThatStartedAfterTheDial() {
    let dial = DialFixture.at(8, 11, 10, 24)
    let starts = [DialFixture.at(8, 10, 0), DialFixture.at(8, 11, 10, 44), DialFixture.at(8, 11, 30)]
    #expect(DialRecovery.recording(after: dial, starts: starts) == DialFixture.at(8, 11, 10, 44))
    #expect(DialRecovery.recording(after: dial, starts: [DialFixture.at(8, 11, 30)]) == nil, "too late to be this call")
}

@Test func recordingStartsReadsTheDayFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    let day = root.appendingPathComponent("2026-10-08")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for f in ["11-10-44.m4a", "11-10-44.md", "11-10-44.far.wav", "12-00-00.far.caf", "notes.txt"] {
        FileManager.default.createFile(atPath: day.appendingPathComponent(f).path, contents: Data())
    }
    let starts = DialRecovery.recordingStarts(on: DialFixture.at(8, 9), root: root, calendar: DialFixture.cal)
    #expect(Set(starts) == [DialFixture.at(8, 11, 10, 44), DialFixture.at(8, 12)])
}
