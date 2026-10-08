import Foundation
import Testing
@testable import CallrecCore

private final class Box: @unchecked Sendable {
    var now = DialFixture.at(7, 12)
    var recording = false
    var since: Date?
    var mdReady = false
    var mdWrites: [(String, String)] = []
    var historyDown = false
    var snapshot = HistorySnapshot(rows: [], detection: .unavailable(reason: "fixture"))
}

@MainActor
private struct Rig {
    let box = Box()
    let dialer = FakeDialer()
    let dir: URL
    let runner: DialRunner

    init(logURL: URL? = nil, snapshot: HistorySnapshot? = nil, recordings: [(day: String, file: String)] = []) throws {
        if let snapshot { box.snapshot = snapshot }
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-runner-\(UUID())")
        try Paths.ensureDir(dir)
        for rec in recordings {
            let folder = dir.appendingPathComponent("recordings").appendingPathComponent(rec.day)
            try Paths.ensureDir(folder)
            FileManager.default.createFile(atPath: folder.appendingPathComponent(rec.file).path, contents: Data())
        }
        let leads = try LeadImporter.parse("""
        company,phone,confidence
        Fake One,9000000001,high
        Fake Two,9000000002,medium
        Fake Three,9000000003,low
        """)
        let store = try LeadStateStore(url: dir.appendingPathComponent("fake.state.json"), listName: "fake")
        let box = self.box
        // Isolated from the real ~/CallRecordings: tests must never read the user's data.
        var config = Config(); config.recordingsDir = dir.appendingPathComponent("recordings").path
        let services = DialRunner.Services(
            dialer: dialer, config: config, listName: "fake", leads: leads, store: store,
            dialLogURL: logURL ?? dir.appendingPathComponent("dial-log.jsonl"), dncURL: dir.appendingPathComponent("dnc.txt"),
            calendar: DialFixture.cal, now: { box.now },
            callState: { .init(recording: box.recording, since: box.since) },
            loadHistory: { if box.historyDown { throw HistoryMailbox.MailboxError.timeout }; return box.snapshot },
            applyToMarkdown: { _, _, outcome, notes in
                guard box.mdReady else { return false }
                box.mdWrites.append((outcome, notes)); return true
            },
            saveColdSIM: { _ in }, autoTick: false)
        runner = DialRunner(services)
    }

    func settle() async { for _ in 0..<20 { await Task.yield() } }
    func advance(_ s: TimeInterval) { box.now = box.now.addingTimeInterval(s) }
}

@MainActor @Test func aWholeSessionWithAFakeDialer() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start()
    await rig.settle()
    expect(!r.canPassPreflight, "run.manualSIMNeedsTick", "\(r.preflightItems())")
    r.confirmManualSIM(true)
    expect(r.canPassPreflight, "run.preflightOK", "\(r.preflightItems())")
    r.passPreflight()
    equal(rig.dialer.dialed, ["9000000001"], "run.firstDialHighConfidence")
    equal(r.dialsToday, 1, "run.attemptLogged")
    if case .waitingForCall = r.session.phase {} else { Issue.record("run.waiting: \(r.session.phase)") }

    // The call connects, then ends.
    r.tick()
    rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(2)
    r.tick()
    if case .onCall = r.session.phase {} else { Issue.record("run.onCall: \(r.session.phase)") }
    rig.advance(60); rig.box.recording = false
    r.tick()
    await rig.settle()
    if case .wrapUp = r.session.phase {} else { Issue.record("run.wrapUp: \(r.session.phase)"); return }
    expect(r.dialLog.contains { $0.kind == .result && $0.result == .connected && $0.seconds == 60 }, "run.resultLogged")

    // Time passes while the user types: nothing dials.
    rig.advance(600); r.tick()
    equal(rig.dialer.dialed.count, 1, "run.noDialDuringWrapUp")

    // Save: the .md does not exist yet, so the write waits and retries.
    r.saveWrapUp(outcome: "pitched", notes: "call back", doNotCall: false)
    equal(r.pendingMarkdownCount, 1, "run.mdPending")
    expect(r.saveNote?.contains("when the transcript is ready") == true, "run.saveNotePending", r.saveNote ?? "nil")
    rig.box.mdReady = true; r.tick()
    equal(r.pendingMarkdownCount, 0, "run.mdWritten")
    equal(r.saveNote ?? "", "Saved to the call's transcript", "run.saveNoteWritten")
    equal(rig.box.mdWrites.first?.0 ?? "", "pitched", "run.mdOutcome")
    equal(r.queue.first { $0.id == "9000000001" }?.record.outcome ?? "", "pitched", "run.leadState")

    // The gap passes, the next lead is dialled; the first is not redialled.
    rig.advance(130); r.tick()
    equal(rig.dialer.dialed, ["9000000001", "9000000002"], "run.secondLead")
    r.stop()
    // Changed 2026-10-07: Stop before the call connects applies at once (it used to
    // wait up to ~2 min for the not-placed timeout behind a "Dialing…" spinner).
    equal(r.session.phase, .stopped(.user), "run.stopBeforeConnectIsImmediate")
}

@MainActor @Test func doNotCallAgainWritesTheListAndNeverRedials() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true); r.passPreflight()
    r.tick()
    rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(1); r.tick()
    r.doNotCallAgain()
    expect(r.dnc.contains("9000000001"), "dnc.listed")
    equal(r.queue.first { $0.id == "9000000001" }?.status, .doNotCall, "dnc.leadStatus")
    let text = try String(contentsOf: rig.dir.appendingPathComponent("dnc.txt"), encoding: .utf8)
    expect(text.hasPrefix("9000000001"), "dnc.fileWritten", text)
}

@MainActor @Test func aDialThatCannotBeLoggedIsNeverPlaced() async throws {
    let blocker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-blocker-\(UUID())")
    try Data("a file where a folder should be".utf8).write(to: blocker)
    defer { Fs.remove(blocker) }
    let rig = try Rig(logURL: blocker.appendingPathComponent("dial-log.jsonl"))
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle()
    r.confirmManualSIM(true)
    expect(!r.canPassPreflight, "nolog.preflightBlocked")
    r.passPreflight()
    equal(rig.dialer.dialed.count, 0, "nolog.neverDialed")
    equal(r.session.phase, .preflight, "nolog.stillPreflight")
    expect(!r.alerts.isEmpty, "nolog.visibleAlert")
}

@MainActor @Test func dialerRefusalPausesAndLogsNotPlaced() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    rig.dialer.failWith = DialerError.refused
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true); r.passPreflight()
    if case .paused(.dialFailed) = r.session.phase {} else { Issue.record("refuse.paused: \(r.session.phase)") }
    expect(r.dialLog.contains { $0.result == .notPlaced }, "refuse.notPlacedLogged")
    equal(r.queue.first { $0.id == "9000000001" }?.status, .pending, "refuse.leadStaysPending")
}

@MainActor @Test func outsideCallingHoursNeverDials() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    rig.box.now = DialFixture.at(7, 22)
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true)
    expect(!r.canPassPreflight, "hours.preflightFails")
    r.passPreflight()
    equal(rig.dialer.dialed.count, 0, "hours.noDial")
}

@MainActor @Test func wrongSIMAfterACallStopsTheSession() async throws {
    // History: eight earlier calls on two fake lines make the "ZSIM" column trustworthy.
    let day = DialFixture.at(6, 11)
    var rows: [HistoryCall] = (0..<8).map {
        HistoryCall(key: "90000001\($0)0", date: day.addingTimeInterval(Double($0) * 60), seconds: 30, originated: true,
                    values: ["ZSIM": $0 % 3 == 0 ? "COLD" : "PERSONAL"])
    }
    let snap = HistorySnapshot(rows: rows, detection: SIMDetector.analyze(candidates: ["ZSIM"], rows: rows))
    let rig = try Rig(snapshot: snap)
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle()
    expect(r.simDetectionActive, "sim.detected")
    r.chooseColdSIM("COLD")
    expect(r.canPassPreflight, "sim.preflightOK", "\(r.preflightItems())")
    r.passPreflight()
    equal(rig.dialer.dialed, ["9000000001"], "sim.dialed")
    r.tick()
    rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(2); r.tick()
    // The call we placed now shows up in call history, on the wrong line.
    var after = rows
    after.append(HistoryCall(key: "9000000001", date: DialFixture.at(7, 12).addingTimeInterval(3), seconds: 50, originated: true,
                             values: ["ZSIM": "PERSONAL"]))
    rig.box.snapshot = HistorySnapshot(rows: after, detection: SIMDetector.analyze(candidates: ["ZSIM"], rows: after))
    rig.advance(50); rig.box.recording = false; r.tick()
    await rig.settle()
    expect(r.session.isRedBanner, "sim.redBanner", "\(r.session.banner ?? "nil")")
    r.saveWrapUp(outcome: "", notes: "kept", doNotCall: false)
    if case .stopped(.policy(.wrongSIM)) = r.session.phase {} else { Issue.record("sim.stopped: \(r.session.phase)") }
    rig.advance(300); r.tick()
    equal(rig.dialer.dialed.count, 1, "sim.neverDialsAgain")
}

@Test func wrapUpIsWrittenIntoTheCallsMarkdownWithoutTouchingTheTranscript() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-wrap-\(UUID())")
    defer { Fs.remove(root) }
    let start = DialFixture.at(7, 11, 30, 5)
    let paths = Paths.forCall(at: start, root: root)
    let lead = Lead(number: "9000000001", company: "Fake One", city: "", owner: "Asha Test", whatTheyDo: "", angle: "",
                    confidence: .high, altNumber: nil, caller: "", order: 1)
    equal(try DialMarkdown.apply(root: root, callStart: start, lead: lead, outcome: "pitched", notes: "n"), false, "wrap.noMdYet")
    try Paths.ensureDir(paths.dir)
    let md = Markdown.render(date: start, seconds: 60, audioName: "x.m4a",
                             segments: [Segment(start: 1, end: 3, text: "hello there", speaker: .unknown)])
    try Data(md.utf8).write(to: paths.md)
    // The daemon's clock and ours differ by a couple of seconds.
    equal(try DialMarkdown.apply(root: root, callStart: start.addingTimeInterval(2), lead: lead, outcome: "pitched", notes: "call back Tue"),
          true, "wrap.written")
    let after = try String(contentsOf: paths.md, encoding: .utf8)
    let fields = MarkdownFields.read(md: after)
    equal(fields.outcome, "pitched", "wrap.outcome")
    equal(fields.notes, "call back Tue", "wrap.notes")
    equal(MarkdownFields.identity(md: after).company, "Fake One", "wrap.company")
    equal(MarkdownFields.identity(md: after).owner, "Asha Test", "wrap.owner")
    expect(after.contains("hello there"), "wrap.transcriptIntact")
    // Saving again adds to the notes, never replaces them.
    _ = try DialMarkdown.apply(root: root, callStart: start, lead: lead, outcome: "", notes: "second")
    let again = MarkdownFields.read(md: try String(contentsOf: paths.md, encoding: .utf8))
    equal(again.notes, "call back Tue | second", "wrap.notesAppend")
    equal(again.outcome, "pitched", "wrap.emptyOutcomeKeepsOld")
    // A call 30 seconds away is a different call.
    equal(try DialMarkdown.apply(root: root, callStart: start.addingTimeInterval(30), lead: lead, outcome: "x", notes: "y"), false, "wrap.otherCall")
}

@MainActor @Test func theManualSIMTickIsRequiredEverySession() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle()
    expect(!r.canPassPreflight, "tick.neededFirstSession")
    r.passPreflight()
    equal(rig.dialer.dialed.count, 0, "tick.noDialUntilTicked")
    r.confirmManualSIM(true); r.passPreflight()
    equal(rig.dialer.dialed.count, 1, "tick.dialsOnceTicked")
    r.stop()
    // Ending the session at the first safe moment, then a brand-new session.
    r.tick(); rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(1); r.tick()
    rig.advance(30); rig.box.recording = false; r.tick(); await rig.settle()
    r.saveWrapUp(outcome: "", notes: "", doNotCall: false)
    equal(r.session.phase, .stopped(.user), "tick.sessionOneEnded")
    rig.advance(400)
    r.start(); await rig.settle()
    expect(!r.canPassPreflight, "tick.resetForNewSession", "\(r.preflightItems())")
    equal(rig.dialer.dialed.count, 1, "tick.noDialInSessionTwo")
}

@MainActor @Test func historyUnavailableBlocksTheStartAndPausesMidSession() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    rig.box.historyDown = true
    r.start(); await rig.settle(); r.confirmManualSIM(true)
    expect(!r.canPassPreflight, "histdown.preflightBlocked")
    expect(r.preflightItems().contains { $0.id == "history" && $0.state == .fail }, "histdown.itemShown")
    rig.box.historyDown = false
    r.cancelPreflight(); r.start(); await rig.settle(); r.confirmManualSIM(true); r.passPreflight()
    equal(rig.dialer.dialed.count, 1, "histdown.dialsWhenUp")
    // The recorder stops answering while the dial is waiting: the lookup fails, the session says why.
    rig.box.historyDown = true
    r.tick(); rig.advance(46); r.tick(); await rig.settle()
    expect(r.session.banner?.contains("Call history is unavailable") ?? false, "histdown.clearMessage", r.session.banner ?? "nil")
    rig.advance(100); r.tick(); await rig.settle()
    if case .paused(.policy(.historyUnavailable)) = r.session.phase {} else { Issue.record("histdown.paused: \(r.session.phase)") }
    equal(rig.dialer.dialed.count, 1, "histdown.neverContinues")
}


// Regression (2026-10-08): a relaunch mid-call left a dialled call with no wrap-up.
@MainActor @Test func anInterruptedCallIsOfferedForWrapUpOnLaunch() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-recover-\(UUID())")
    try Paths.ensureDir(dir)
    defer { Fs.remove(dir) }
    let logURL = dir.appendingPathComponent("dial-log.jsonl")
    let orphan = DialLogEntry.attempt(at: DialFixture.at(7, 11, 50), id: "ORPHAN", list: "fake",
                                      leadID: "9000000001", key: "9000000001")
    try DialLog.append(orphan, to: logURL)

    let rig = try Rig(logURL: logURL, recordings: [(day: "2026-10-07", file: "11-50-10.m4a")])
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    equal(r.unfinished.map(\.id), ["ORPHAN"], "recover.found")

    r.recover(r.unfinished[0])
    if case .wrapUp(let w) = r.session.phase { expect(w.recovered, "recover.flag", "not marked recovered") }
    else { Issue.record("recover.opensWrapUp: \(r.session.phase)") }

    r.saveWrapUp(outcome: "pitched", notes: "recovered note", doNotCall: false)
    equal(r.session.phase, .idle, "recover.backToIdleNoNextDial")
    expect(rig.dialer.dialed.isEmpty, "recover.neverDials", "dialled during recovery: \(rig.dialer.dialed)")
    expect(r.unfinished.isEmpty, "recover.closed", "still offered: \(r.unfinished.map(\.id))")
    let reloaded = try DialLog.load(from: logURL).entries
    expect(reloaded.contains { $0.kind == .result && $0.attemptID == "ORPHAN" }, "recover.resultLogged", "no result written")
}

@Test func wrapUpOutcomeSetsTheLeadStatus() {
    // Regression: a real conversation the recorder missed stayed "no answer", so the
    // list summary showed "Called 0" after a test call.
    equal(LeadStatus.afterWrapUp(outcome: "booked", current: .noAnswer), .called, "status.bookedIsCalled")
    equal(LeadStatus.afterWrapUp(outcome: "test", current: .noAnswer), .called, "status.testIsCalled")
    equal(LeadStatus.afterWrapUp(outcome: "pitched", current: .pending), .called, "status.pendingToCalled")
    equal(LeadStatus.afterWrapUp(outcome: "no connect", current: .called), .noAnswer, "status.noConnect")
    equal(LeadStatus.afterWrapUp(outcome: "", current: .called), .called, "status.blankKeeps")
    equal(LeadStatus.afterWrapUp(outcome: "booked", current: .doNotCall), .doNotCall, "status.dncSticks")
    equal(LeadStatus.afterWrapUp(outcome: "booked", current: .skipped), .skipped, "status.skippedSticks")
}

@MainActor @Test func savingAWrapUpMovesTheLeadToCalled() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    // History knows about the dial, but no recording ever started (call not seen as connected).
    r.start(); await rig.settle(); r.confirmManualSIM(true); r.passPreflight()
    // Appears only after the dial, so the cooldown check at dial time does not skip the lead.
    rig.box.snapshot = HistorySnapshot(rows: [HistoryCall(key: "9000000001", date: rig.box.now.addingTimeInterval(5), seconds: 40)],
                                       detection: .unavailable(reason: "fixture"))
    rig.advance(50); r.tick(); await rig.settle()
    if case .wrapUp(let w) = r.session.phase { expect(!w.connected, "wrap.notSeenConnected") }
    else { Issue.record("wrap.phase: \(r.session.phase)"); return }
    equal(r.queue.first { $0.id == "9000000001" }?.status, .noAnswer, "wrap.beforeSave")
    r.saveWrapUp(outcome: "booked", notes: "", doNotCall: false)
    equal(r.queue.first { $0.id == "9000000001" }?.status, .called, "wrap.afterSave")
    equal(LeadQueue.counts(r.queue)[.called] ?? 0, 1, "wrap.summaryCalledCount")
}

// Regression (2026-10-08): the user dismissed the macOS "Click to Call" prompt, then pressed
// Stop. The attempt had no result, so three identical "has no wrap-up" cards piled up.
@MainActor @Test func stopWhileWaitingForTheCallClosesTheAttemptAsNotPlaced() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true); r.passPreflight()
    if case .waitingForCall = r.session.phase {} else { Issue.record("stop.waiting: \(r.session.phase)"); return }
    r.stop()
    let results = r.dialLog.filter { $0.kind == .result }
    equal(results.count, 1, "stop.oneResult")
    equal(results.first?.result, .notPlaced, "stop.notPlaced")
    expect(DialRecovery.unfinished(log: r.dialLog, now: rig.box.now).isEmpty, "stop.noOrphan")
}

@MainActor @Test func orphansWithoutARecordingAreClosedNotShownAndDuplicatesCollapse() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-orphans-\(UUID())")
    try Paths.ensureDir(dir)
    defer { Fs.remove(dir) }
    let logURL = dir.appendingPathComponent("dial-log.jsonl")
    // Three attempts on the same lead, none with a recording (the "TEST call 2" pile-up),
    // plus a fresh one that is still inside the grace window, plus one on another lead WITH a recording.
    for (i, minute) in [10, 20, 30].enumerated() {
        try DialLog.append(.attempt(at: DialFixture.at(7, 11, minute), id: "GHOST\(i)", list: "fake",
                                    leadID: "9000000002", key: "9000000002"), to: logURL)
    }
    try DialLog.append(.attempt(at: DialFixture.at(7, 11, 59, 30), id: "FRESH", list: "fake",
                                leadID: "9000000003", key: "9000000003"), to: logURL)
    try DialLog.append(.attempt(at: DialFixture.at(7, 11, 50), id: "REAL", list: "fake",
                                leadID: "9000000001", key: "9000000001"), to: logURL)
    let rig = try Rig(logURL: logURL, recordings: [(day: "2026-10-07", file: "11-50-10.m4a")])
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    equal(r.unfinished.map(\.id), ["REAL"], "orphans.onlyTheRecordedOneIsOffered")
    let closed = r.dialLog.filter { $0.kind == .result }.map(\.attemptID).sorted()
    equal(closed, ["GHOST0", "GHOST1", "GHOST2"], "orphans.ghostsClosed")
    expect(r.dialLog.filter { $0.kind == .result }.allSatisfy { $0.result == .notPlaced }, "orphans.closedAsNotPlaced")
}

@MainActor @Test func skipCanBeUndoneAndQueueRowsCanMoveBack() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true)
    // Skip is a countdown action: pass preflight but keep the dial from happening by checking the first lead's id.
    let first = try #require(r.nextUp)
    #expect(LeadStatus.afterMoveBack(current: .skipped) == .pending)
    #expect(LeadStatus.afterMoveBack(current: .noAnswer) == .pending)
    #expect(LeadStatus.afterMoveBack(current: .called) == .pending)
    #expect(LeadStatus.afterMoveBack(current: .doNotCall) == nil, "do-not-call is permanent")
    #expect(LeadStatus.afterMoveBack(current: .pending) == nil)

    r.passPreflight()           // dials the first lead
    r.stop()
    // Mark the first lead no-answer and skip-undo a different one by hand through the queue actions.
    let second = try #require(r.queue.first { $0.id != first.id && $0.status == .pending })
    r.markDoNotCall(second.id)
    equal(r.queue.first { $0.id == second.id }?.status, .doNotCall, "dnc.rowAction")
    r.moveBackToQueue(second.id)
    equal(r.queue.first { $0.id == second.id }?.status, .doNotCall, "dnc.neverMovedBack")
}

@MainActor @Test func skippingOffersUndoAndUndoRestoresPending() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    r.start(); await rig.settle(); r.confirmManualSIM(true)
    // Put the session in the countdown with a gap so skip is allowed, via a wrap-up of a first call.
    r.passPreflight()
    r.tick()
    rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(2); r.tick()
    rig.advance(30); rig.box.recording = false; r.tick(); await rig.settle()
    r.saveWrapUp(outcome: "pitched", notes: "", doNotCall: false)
    let target = try #require(r.nextUp)
    r.skipNext()
    equal(r.queue.first { $0.id == target.id }?.status, .skipped, "skip.marked")
    equal(r.skipUndo?.leadID, target.id, "skip.undoOffered")
    r.undoSkip()
    equal(r.queue.first { $0.id == target.id }?.status, .pending, "skip.undone")
    expect(r.skipUndo == nil, "skip.undoCleared")
    // A called lead can be moved back from its row.
    let done = try #require(r.queue.first { $0.status == .called })
    r.moveBackToQueue(done.id)
    equal(r.queue.first { $0.id == done.id }?.status, .pending, "row.calledMovedBack")
}
