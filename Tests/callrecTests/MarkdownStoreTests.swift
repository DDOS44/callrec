import Foundation
import Testing
@testable import CallrecCore

/// Two writers, one file: the daemon owns header + transcript, the app owns
/// outcome / who / notes. These tests are the regression suite for that rule.
private func tempMD() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-store-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("09-05-07.md")
}

private func segs(_ texts: [String]) -> [Segment] {
    texts.enumerated().map { Segment(start: Double($0.offset) * 2, end: Double($0.offset) * 2 + 1, text: $0.element, speaker: .them) }
}

private func daemonWrite(_ url: URL, _ texts: [String]) throws {
    try MarkdownStore.writeTranscript(url, date: Date(timeIntervalSince1970: 1_700_000_000), seconds: 65,
                                      audioName: "09-05-07.m4a", segments: segs(texts))
}

@Test func daemonRewriteKeepsHumanFields() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try daemonWrite(url, ["hello there"])
    try MarkdownStore.saveHumanFields(url, outcome: "booked", who: "owner", notes: "asked about pricing, call back Friday")

    // The daemon retranscribes, reports a failure, then labels the caller. None may touch the human fields.
    try daemonWrite(url, ["new line one", "new line two"])
    try MarkdownStore.recordFailure(url, message: "whisper timed out", date: Date(), seconds: 65, audioName: "09-05-07.m4a", id: "d/b")
    try MarkdownStore.applyIdentity(url, CallIdentity(number: "+91 90000 00001", contact: "Asha", company: "Acme", owner: "Rahul Sharma"))

    let md = try String(contentsOf: url, encoding: .utf8)
    let f = MarkdownFields.read(md: md)
    equal(f.outcome, "booked", "store.outcomeSurvivesDaemon")
    equal(f.who, "owner", "store.whoSurvivesDaemon")
    equal(f.notes, "asked about pricing, call back Friday", "store.notesSurviveDaemon")
    expect(MarkdownFields.segments(md: md).map(\.text) == ["new line one", "new line two"], "store.daemonTranscriptWritten", md)
    equal(MarkdownFields.error(md: md) ?? "", "whisper timed out", "store.failureRecorded")
    equal(MarkdownFields.identity(md: md).company, "Acme", "store.identityWritten")
}

@Test func humanSaveKeepsDaemonTranscript() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try daemonWrite(url, ["first pass"])
    // The app loaded this version and holds it in memory...
    try MarkdownStore.applyIdentity(url, CallIdentity(number: "9999999999", contact: "", company: "Beta", owner: ""))
    // ...then the daemon rewrites the transcript underneath it...
    try daemonWrite(url, ["second pass, better"])
    // ...and the app saves a stale copy of its own fields. The new transcript must survive.
    try MarkdownStore.saveHumanFields(url, outcome: "callback", who: "gatekeeper", notes: "ask for Mr Rao")

    let md = try String(contentsOf: url, encoding: .utf8)
    expect(MarkdownFields.segments(md: md).map(\.text) == ["second pass, better"], "store.transcriptSurvivesAppSave", md)
    equal(MarkdownFields.identity(md: md).company, "Beta", "store.identitySurvivesAppSave")
    let f = MarkdownFields.read(md: md)
    equal(f.outcome, "callback", "store.appOutcomeWritten")
    equal(f.notes, "ask for Mr Rao", "store.appNotesWritten")
}

@Test func daemonKeepsHandTypedNotesOutsideTheField() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try daemonWrite(url, ["one"])
    var md = try String(contentsOf: url, encoding: .utf8)
    md += "\nThey also mentioned a competitor.\n\n- follow up Monday\n"
    try md.write(to: url, atomically: true, encoding: .utf8)
    try daemonWrite(url, ["two"])
    let after = try String(contentsOf: url, encoding: .utf8)
    expect(after.contains("They also mentioned a competitor.") && after.contains("- follow up Monday"), "store.freeTextKept", after)
}

@Test func damagedFileWithoutTranscriptHeadingKeepsHumanFields() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let damaged = "# Call\n\n- outcome: booked\n- who picked up: owner\n\n## Notes\n\n- what they said that wasn't in the flow: wants a demo\n"
    try damaged.write(to: url, atomically: true, encoding: .utf8)
    try daemonWrite(url, ["a line"])
    let md = try String(contentsOf: url, encoding: .utf8)
    let f = MarkdownFields.read(md: md)
    equal(f.outcome, "booked", "store.damagedOutcome")
    equal(f.notes, "wants a demo", "store.damagedNotes")
    expect(MarkdownFields.segments(md: md).map(\.text) == ["a line"], "store.damagedGetsTranscript", md)
}

@Test func concurrentWritersNeverLoseEitherSide() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try daemonWrite(url, ["start"])
    let rounds = 60
    let errors = ErrorBox()
    DispatchQueue.concurrentPerform(iterations: 2) { who in
        for i in 0..<rounds {
            do {
                if who == 0 { try MarkdownStore.saveHumanFields(url, outcome: "pitched", who: "owner", notes: "note \(i)") }
                else { try daemonWrite(url, ["transcript \(i)"]) }
            } catch { errors.add("\(who):\(i) \(error)") }
        }
    }
    expect(errors.all.isEmpty, "store.noWriteErrors", "\(errors.all)")
    let md = try String(contentsOf: url, encoding: .utf8)
    let f = MarkdownFields.read(md: md)
    equal(f.notes, "note \(rounds - 1)", "store.lastAppWriteWins")
    equal(f.outcome, "pitched", "store.outcomeIntact")
    expect(MarkdownFields.segments(md: md).map(\.text) == ["transcript \(rounds - 1)"], "store.lastDaemonWriteWins", md)
}

@Test func lockTimeoutIsAnErrorNotASilentSkip() throws {
    let url = tempMD(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try daemonWrite(url, ["x"])
    let fd = open(MarkdownStore.lockURL(for: url).path, O_CREAT | O_RDWR, 0o600)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: MarkdownStore.LockTimeout.self) {
        try MarkdownStore.modify(url, timeout: 0.2) { $0 }
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
