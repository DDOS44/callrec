import Foundation
import Testing
@testable import CallrecCore

// Alt-number fallback: when a placed call does not connect, the session's next dial is the next
// number of the SAME lead. Numbers here are fake (+91 90000 00xxx).

private let t0 = DialFixture.at(7, 11)
private func later(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let lead = "9000000001"
private let other = "9000000002"

/// Countdown reached, first check pending.
private func started() -> DialSession {
    var s = DialSession()
    s.handle(.start)
    _ = s.handle(.preflightPassed(now: t0))
    return s
}

/// Dial the lead's number `numbers` (count) wide; leaves the session waiting for the call at `since`.
private func dialed(_ s: inout DialSession, at now: Date, count: Int = 3) {
    _ = s.handle(.dialChecked(now: now, nextLeadID: lead, decision: .allowed, numberCount: count))
    _ = s.handle(.dialPlaced(now: now.addingTimeInterval(1)))
}

/// The call connects at +5 s and lasts `seconds`.
private func callLasting(_ s: inout DialSession, from now: Date, seconds: Int, gap: TimeInterval = 60) -> [DialEffect] {
    _ = s.handle(.callStarted(now: now.addingTimeInterval(5)))
    return s.handle(.callEnded(now: now.addingTimeInterval(5 + Double(seconds)), gap: gap, minGap: 45))
}

// MARK: - Sequence helper

@Test func sequenceIsMainThenAltsOnceEach() {
    equal(AltNumbers.sequence(main: "9000000001", alts: ["9000000201", "9000000001", "9000000202", "9000000201"]),
          ["9000000001", "9000000201", "9000000202"], "seq.dedupe")
    equal(AltNumbers.sequence(main: "9000000001", alts: []), ["9000000001"], "seq.noAlts")
}

@Test func sequenceLeavesOutAltsOnTheDNCListButKeepsMain() {
    let dnc = DNCList(entries: [.init(key: "9000000202", addedAt: nil), .init(key: "9000000001", addedAt: nil)])
    equal(AltNumbers.sequence(main: "9000000001", alts: ["9000000201", "9000000202"], dnc: dnc),
          ["9000000001", "9000000201"], "seq.dncAltDropped")
}

@Test func sequenceIsJustTheMainNumberWhenTheSwitchIsOff() {
    equal(AltNumbers.sequence(main: "9000000001", alts: ["9000000201"], enabled: false), ["9000000001"], "seq.off")
}

@Test func advanceStopsAtTheLastNumber() {
    equal(AltNumbers.advance(from: 0, count: 3), 1, "adv.first")
    equal(AltNumbers.advance(from: 1, count: 3), 2, "adv.second")
    expect(AltNumbers.advance(from: 2, count: 3) == nil, "adv.last")
    expect(AltNumbers.advance(from: 0, count: 1) == nil, "adv.single")
}

@Test func labelsAndNotices() {
    equal(AltNumbers.label(index: 0, count: 3), "Main", "label.main")
    equal(AltNumbers.label(index: 1, count: 3), "Alt 1 of 2", "label.alt1")
    equal(AltNumbers.label(index: 2, count: 3), "Alt 2 of 2", "label.alt2")
    equal(AltNumbers.queueBadge(altCount: 0) ?? "none", "none", "badge.none")
    equal(AltNumbers.queueBadge(altCount: 1) ?? "none", "1 alt", "badge.one")
    equal(AltNumbers.queueBadge(altCount: 2) ?? "none", "2 alts", "badge.two")
    let seq = ["9000000101", "9000000201", "9000000202"]
    equal(AltNumbers.notice(sequence: seq, nextIndex: 1, afterNoAnswer: true) ?? "",
          "No answer on +91 90000 00101. Trying alt 1 of 2 (+91 90000 00201)", "notice.afterNoAnswer")
    equal(AltNumbers.notice(sequence: seq, nextIndex: 2, afterNoAnswer: false) ?? "",
          "Next: alt 2 of 2 (+91 90000 00202)", "notice.resume")
    expect(AltNumbers.notice(sequence: seq, nextIndex: 0, afterNoAnswer: true) == nil, "notice.mainHasNone")
}

@Test func allNumbersCoversMainAndEveryAlt() throws {
    let r = try LeadImporter.parse("""
    company,phone,alt_phone
    Fake A,9000000101,9000000201 / 9000000202
    """)
    equal(AltNumbers.allNumbers(of: r.leads[0]), ["9000000101", "9000000201", "9000000202"], "all.numbers")
}

// MARK: - Session: the walk through a lead's numbers

@Test func mainConnectsSoTheLeadIsDoneAndAltsAreNeverDialled() {
    var s = started()
    dialed(&s, at: t0)
    equal(s.numberPlan, DialSession.NumberPlan(leadID: lead, count: 3, index: 0), "main.plan")
    let e = callLasting(&s, from: t0, seconds: 60)
    equal(e, [.recordCallEnded(leadID: lead, seconds: 60, connected: true)], "main.recorded")
    if case .wrapUp = s.phase {} else { Issue.record("main.wrapUp: \(s.phase)") }
    expect(s.numberPlan == nil, "main.planCleared")
    s.handle(.wrapUpSaved(now: later(100), outcome: "pitched", notes: "", doNotCall: false, gap: 60, minGap: 45))
    // The next dial is a different lead, with its own plan.
    _ = s.handle(.tick(now: later(160)))
    _ = s.handle(.dialChecked(now: later(160), nextLeadID: other, decision: .allowed, numberCount: 1))
    equal(s.numberPlan, DialSession.NumberPlan(leadID: other, count: 1, index: 0), "main.nextLeadPlan")
}

@Test func mainNoConnectThenAltOneConnects() {
    var s = started()
    dialed(&s, at: t0)
    // Rang out: no recording, history shows a placed call of 0 s.
    _ = s.handle(.tick(now: later(46)))
    let e = s.handle(.dialResolved(.placed(seconds: 0), now: later(50), gap: 60, minGap: 45))
    equal(e, [.recordUnanswered(leadID: lead, seconds: 0, connected: false, exhausted: false)], "alt1.recordedNotWrapUp")
    equal(s.phase, .countdown(.init(until: later(110), minGapUntil: later(95), blocked: nil, altFallback: true, afterNoAnswer: true)),
          "alt1.countdownForAlt")
    equal(s.numberPlan?.index, 1, "alt1.indexAdvanced")
    // The countdown asks for the next dial; the answer is the same lead, not the next one.
    equal(s.handle(.tick(now: later(110))), [.evaluateNext], "alt1.due")
    equal(s.handle(.dialChecked(now: later(110), nextLeadID: lead, decision: .allowed, numberCount: 3)),
          [.dial(leadID: lead)], "alt1.dials")
    equal(s.numberPlan, DialSession.NumberPlan(leadID: lead, count: 3, index: 1), "alt1.planKept")
    _ = s.handle(.dialPlaced(now: later(111)))
    let ended = callLasting(&s, from: later(111), seconds: 90)
    equal(ended, [.recordCallEnded(leadID: lead, seconds: 90, connected: true)], "alt1.connected")
    if case .wrapUp(let w) = s.phase { equal(w.leadID, lead, "alt1.wrapUpForTheLead") } else { Issue.record("alt1.wrapUp: \(s.phase)") }
    expect(s.numberPlan == nil, "alt1.planCleared")
    equal(s.dials, 2, "alt1.twoDials")
}

@Test func aShortConnectedCallCountsAsNotConnected() {
    var s = started()
    dialed(&s, at: t0)
    let e = callLasting(&s, from: t0, seconds: 3)   // below shortCallSeconds (5)
    equal(e, [.recordUnanswered(leadID: lead, seconds: 3, connected: true, exhausted: false)], "short.unanswered")
    equal(s.numberPlan?.index, 1, "short.nextNumber")
    // Exactly at the threshold it is a real call.
    var t = started()
    dialed(&t, at: t0)
    let ok = callLasting(&t, from: t0, seconds: 5)
    equal(ok, [.recordCallEnded(leadID: lead, seconds: 5, connected: true)], "short.thresholdIsAConnection")
}

@Test func aRingOutWithRealHistorySecondsStillGetsItsWrapUp() {
    var s = started()
    dialed(&s, at: t0)
    _ = s.handle(.tick(now: later(46)))
    let e = s.handle(.dialResolved(.placed(seconds: 40), now: later(50), gap: 60, minGap: 45))
    equal(e, [.recordCallEnded(leadID: lead, seconds: 40, connected: false)], "ring.realConversation")
    if case .wrapUp = s.phase {} else { Issue.record("ring.wrapUp: \(s.phase)") }
}

@Test func everyNumberTriedWithoutConnectingEndsTheLeadAsNoAnswerWithNoWrapUp() {
    var s = started()
    dialed(&s, at: t0, count: 3)
    var now = t0
    var recorded: [DialEffect] = []
    for i in 0..<3 {
        recorded += callLasting(&s, from: now, seconds: 1)
        now = now.addingTimeInterval(200)
        if i < 2 {
            _ = s.handle(.tick(now: now))
            _ = s.handle(.dialChecked(now: now, nextLeadID: lead, decision: .allowed, numberCount: 3))
            _ = s.handle(.dialPlaced(now: now.addingTimeInterval(1)))
        }
    }
    equal(recorded, [
        .recordUnanswered(leadID: lead, seconds: 1, connected: true, exhausted: false),
        .recordUnanswered(leadID: lead, seconds: 1, connected: true, exhausted: false),
        .recordUnanswered(leadID: lead, seconds: 1, connected: true, exhausted: true),
    ], "exhaust.threeResultsLastIsFinal")
    guard case .countdown(let c) = s.phase else { Issue.record("exhaust.countdown: \(s.phase)"); return }
    expect(!c.altFallback, "exhaust.nextIsANewLead")
    expect(s.numberPlan == nil, "exhaust.planCleared")
    equal(s.dials, 3, "exhaust.threeDials")
}

@Test func skipRemainingNumbersMovesOnWithNoAnswer() {
    var s = started()
    dialed(&s, at: t0)
    _ = callLasting(&s, from: t0, seconds: 1)
    let e = s.handle(.skipRemainingNumbers)
    equal(e, [.setLeadStatus(leadID: lead, status: .noAnswer)], "skip.noAnswer")
    expect(s.numberPlan == nil, "skip.planCleared")
    guard case .countdown(let c) = s.phase else { Issue.record("skip.countdown: \(s.phase)"); return }
    expect(!c.altFallback, "skip.nextIsANewLead")
    // Nothing to skip outside an alt countdown.
    expect(s.handle(.skipRemainingNumbers).isEmpty, "skip.onlyOnce")
    var idle = DialSession()
    expect(idle.handle(.skipRemainingNumbers).isEmpty, "skip.idle")
}

@Test func aNumberThatWasNotPlacedNeverFallsThroughToAnAlt() {
    var s = started()
    dialed(&s, at: t0)
    _ = s.handle(.tick(now: later(46)))
    let e = s.handle(.dialResolved(.notPlaced, now: later(50), gap: 60, minGap: 45))
    equal(e, [.recordNotPlaced(leadID: lead)], "np.recorded")
    equal(s.phase, .paused(.notPlaced), "np.paused")
    equal(s.numberPlan?.index, 0, "np.stillTheMainNumber")
    _ = s.handle(.resume(now: later(100), gap: 60, minGap: 45))
    guard case .countdown(let c) = s.phase else { Issue.record("np.countdown: \(s.phase)"); return }
    expect(!c.altFallback, "np.resumeIsNotAnAltCountdown")
    equal(s.handle(.dialChecked(now: later(160), nextLeadID: lead, decision: .allowed, numberCount: 3)), [.dial(leadID: lead)], "np.retriesMain")
    equal(s.numberPlan?.index, 0, "np.retryIndex")
}

@Test func anAltThatWasNotPlacedIsRetriedOnResumeNotSkipped() {
    var s = started()
    dialed(&s, at: t0)
    _ = callLasting(&s, from: t0, seconds: 1)   // main unanswered -> alt 1 due
    _ = s.handle(.dialChecked(now: later(100), nextLeadID: lead, decision: .allowed, numberCount: 3))
    _ = s.handle(.dialPlaced(now: later(101)))
    _ = s.handle(.tick(now: later(150)))
    _ = s.handle(.dialResolved(.notPlaced, now: later(160), gap: 60, minGap: 45))
    equal(s.phase, .paused(.notPlaced), "npAlt.paused")
    equal(s.numberPlan?.index, 1, "npAlt.sameAlt")
    _ = s.handle(.resume(now: later(200), gap: 60, minGap: 45))
    guard case .countdown(let c) = s.phase else { Issue.record("npAlt.countdown: \(s.phase)"); return }
    expect(c.altFallback && !c.afterNoAnswer, "npAlt.resumeCountdownIsForTheAlt")
}

@Test func anAltOnCooldownOrDNCIsSkippedAndTheNextOneTried() {
    for block in [DialBlock.cooldown(until: later(9999)), .doNotCall] {
        var s = started()
        dialed(&s, at: t0)
        _ = callLasting(&s, from: t0, seconds: 1)           // main unanswered, alt 1 due
        let e = s.handle(.dialChecked(now: later(100), nextLeadID: lead, decision: .blocked(block), numberCount: 3))
        equal(e, [.evaluateNext], "blocked.\(block).asksAgain")
        equal(s.numberPlan?.index, 2, "blocked.\(block).movedToAlt2")
        // Alt 2 is blocked too: the lead is done, and the next lead is asked for. The lead is
        // never marked skipped or do-not-call because of an alt.
        let last = s.handle(.dialChecked(now: later(100), nextLeadID: lead, decision: .blocked(block), numberCount: 3))
        equal(last, [.setLeadStatus(leadID: lead, status: .noAnswer), .evaluateNext], "blocked.\(block).exhausted")
        expect(s.numberPlan == nil, "blocked.\(block).planCleared")
    }
}

@Test func aMainNumberBlockedAtTheStartStillSkipsTheWholeLead() {
    var s = started()
    let e = s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(.cooldown(until: later(9999))), numberCount: 3))
    equal(e, [.setLeadStatus(leadID: lead, status: .skipped), .evaluateNext], "mainBlocked.skipsLead")
}

@Test func aSessionLevelBlockKeepsTheRemainingAltsQueued() {
    var s = started()
    dialed(&s, at: t0)
    _ = callLasting(&s, from: t0, seconds: 1)
    let e = s.handle(.dialChecked(now: later(100), nextLeadID: lead,
                                  decision: .blocked(.hourlyCapReached(cap: 10, freeAt: later(900))), numberCount: 3))
    expect(e.isEmpty, "session.waits")
    equal(s.numberPlan, DialSession.NumberPlan(leadID: lead, count: 3, index: 1), "session.altStillQueued")
    guard case .countdown(let c) = s.phase else { Issue.record("session.countdown: \(s.phase)"); return }
    expect(c.altFallback, "session.stillAltCountdown")
    // A pause keeps them too.
    _ = s.handle(.dialChecked(now: later(100), nextLeadID: lead, decision: .pause(.consecutiveFailures(count: 3)), numberCount: 3))
    equal(s.numberPlan?.index, 1, "session.pauseKeepsAlt")
    _ = s.handle(.resume(now: later(300), gap: 60, minGap: 45))
    guard case .countdown(let r) = s.phase else { Issue.record("session.resumed: \(s.phase)"); return }
    expect(r.altFallback, "session.resumeIsAltCountdown")
}

@Test func theGapBetweenAltAttemptsIsTheRandomGapAndHoldsTheDial() {
    var s = started()
    dialed(&s, at: t0)
    _ = callLasting(&s, from: t0, seconds: 1, gap: 77)       // ends at +6 s
    guard case .countdown(let c) = s.phase else { Issue.record("gap.countdown: \(s.phase)"); return }
    equal(c.until, later(6 + 77), "gap.randomGapApplied")
    equal(c.minGapUntil, later(6 + 45), "gap.minGapApplied")
    expect(s.handle(.tick(now: later(6 + 76))).isEmpty, "gap.noDialEarly")
    expect(s.handle(.dialNow(now: later(6 + 44))).isEmpty, "gap.noDialNowEarly")
    equal(s.handle(.tick(now: later(6 + 77))), [.evaluateNext], "gap.dialsAtTheEnd")
}

@Test func pauseAfterThisCallStillAppliesBetweenNumbers() {
    var s = started()
    dialed(&s, at: t0)
    s.handle(.pauseAfterThisCall)
    _ = callLasting(&s, from: t0, seconds: 1)
    equal(s.phase, .paused(.afterThisCall), "pauseAfter.paused")
    equal(s.numberPlan?.index, 1, "pauseAfter.altStillQueued")
}

@Test func doNotCallAgainEndsTheLeadSoNoAltIsDialled() {
    var s = started()
    dialed(&s, at: t0)
    _ = s.handle(.callStarted(now: later(5)))
    let e = s.handle(.doNotCallAgain)
    equal(e, [.addToDoNotCall(leadID: lead), .setLeadStatus(leadID: lead, status: .doNotCall)], "dnc.effects")
    // The call then ends short: wrap-up, not a fall-through to an alt.
    let ended = s.handle(.callEnded(now: later(7), gap: 60, minGap: 45))
    equal(ended, [.recordCallEnded(leadID: lead, seconds: 2, connected: true)], "dnc.noFallThrough")
    if case .wrapUp = s.phase {} else { Issue.record("dnc.wrapUp: \(s.phase)") }
}

@Test func aLeadWithOneNumberKeepsTodaysBehaviour() {
    var s = started()
    dialed(&s, at: t0, count: 1)
    let e = callLasting(&s, from: t0, seconds: 2)
    equal(e, [.recordCallEnded(leadID: lead, seconds: 2, connected: true)], "single.shortCallWrapUp")
    if case .wrapUp = s.phase {} else { Issue.record("single.wrapUp: \(s.phase)") }
    var r = started()
    dialed(&r, at: t0, count: 1)
    _ = r.handle(.tick(now: later(46)))
    let ring = r.handle(.dialResolved(.placed(seconds: 0), now: later(50), gap: 60, minGap: 45))
    equal(ring, [.recordCallEnded(leadID: lead, seconds: 0, connected: false)], "single.ringOutWrapUp")
}

// MARK: - Guardrails per number key

private func attempt(_ key: String, at ts: Date) -> DialLogEntry {
    DialLogEntry.attempt(at: ts, list: "fake", leadID: lead, key: key)
}

@Test func eachAltAttemptCountsTowardTheDailyAndHourlyCaps() {
    var rules = DialRules(); rules.dailyCap = 3; rules.hourlyCap = 3
    let now = DialFixture.at(7, 14)
    let log = [attempt("9000000001", at: now.addingTimeInterval(-600)),
               attempt("9000000201", at: now.addingTimeInterval(-300)),
               attempt("9000000202", at: now.addingTimeInterval(-100))]
    let d = DialPolicy.evaluate(number: "9000000203", now: now, rules: rules, log: log, dnc: DNCList(), history: [:],
                                session: DialFixture.session(), calendar: DialFixture.cal)
    if case .blocked(.hourlyCapReached) = d {} else if case .blocked(.dailyCapReached) = d {} else { Issue.record("caps.blocked: \(d)") }
    // Two attempts leave room for the third.
    let ok = DialPolicy.evaluate(number: "9000000202", now: now, rules: rules, log: Array(log.prefix(2)), dnc: DNCList(),
                                 history: [:], session: DialFixture.session(), calendar: DialFixture.cal)
    equal(ok, .allowed, "caps.roomLeft")
}

@Test func theSevenDayCooldownIsPerNumberKey() {
    let rules = DialRules()
    let now = DialFixture.at(7, 14)
    let log = [attempt("9000000201", at: now.addingTimeInterval(-3 * 86_400))]
    let alt = DialPolicy.evaluate(number: "9000000201", now: now, rules: rules, log: log, dnc: DNCList(), history: [:],
                                  session: DialFixture.session(), calendar: DialFixture.cal)
    if case .blocked(.cooldown) = alt {} else { Issue.record("cool.altBlocked: \(alt)") }
    let main = DialPolicy.evaluate(number: "9000000001", now: now, rules: rules, log: log, dnc: DNCList(), history: [:],
                                   session: DialFixture.session(), calendar: DialFixture.cal)
    equal(main, .allowed, "cool.otherKeyFree")
}

@Test func anAltOnTheDNCListIsBlockedByPolicyToo() {
    let dnc = DNCList(entries: [.init(key: "9000000201", addedAt: nil)])
    let d = DialPolicy.evaluate(number: "9000000201", now: DialFixture.at(7, 14), rules: DialRules(), log: [], dnc: dnc,
                                history: [:], session: DialFixture.session(), calendar: DialFixture.cal)
    equal(d, .blocked(.doNotCall), "dnc.altBlocked")
}

@Test func theMinimumGapAppliesToAnAltAndATestNumberUsesTheTestGap() {
    var rules = DialRules(); rules.testKeys = ["9000000299"]
    let now = DialFixture.at(7, 14)
    let facts = DialFixture.session(lastWrapUp: now.addingTimeInterval(-20))
    let alt = DialPolicy.evaluate(number: "9000000201", now: now, rules: rules, log: [], dnc: DNCList(), history: [:],
                                  session: facts, calendar: DialFixture.cal)
    if case .blocked(.gapNotElapsed) = alt {} else { Issue.record("gap.altBlocked: \(alt)") }
    let test = DialPolicy.evaluate(number: "9000000299", now: now, rules: rules, log: [], dnc: DNCList(), history: [:],
                                   session: facts, calendar: DialFixture.cal)
    equal(test, .allowed, "gap.testNumberUsesTestGap")
}

@Test func consecutiveFailureStreakCountsEveryUnansweredNumber() {
    let rules = DialRules()
    var log: [DialLogEntry] = []
    for (i, key) in ["9000000001", "9000000201", "9000000202"].enumerated() {
        let a = attempt(key, at: t0.addingTimeInterval(Double(i) * 100))
        log += [a, a.finished(at: a.ts.addingTimeInterval(30), result: .noConnect)]
    }
    equal(DialPolicy.trailingFailures(log: log, since: t0.addingTimeInterval(-1), rules: rules), 3, "streak.threeNumbers")
}

// MARK: - DNC list: all numbers of one lead are one addition

@Test func aLeadsAltNumbersOnTheDNCListCountAsOneAddition() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-altdnc-\(UUID())/dnc.txt")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let t = DialFixture.at(7, 10)
    _ = try DNCList.add("9000000001", now: t, to: url)
    _ = try DNCList.add("9000000201", now: t, altOf: "9000000001", to: url)
    _ = try DNCList.add("9000000202", now: t, altOf: "9000000001", to: url)
    let list = try DNCList.load(from: url)
    equal(list.keys, ["9000000001", "9000000201", "9000000202"], "dncAlt.allListed")
    equal(list.addedToday(now: DialFixture.at(7, 15), calendar: DialFixture.cal), 1, "dncAlt.oneAddition")
    _ = try DNCList.add("9000000003", now: t, to: url)
    equal(try DNCList.load(from: url).addedToday(now: DialFixture.at(7, 15), calendar: DialFixture.cal), 2, "dncAlt.nextLeadCounts")
    let text = try String(contentsOf: url, encoding: .utf8)
    expect(text.contains("alt of 9000000001"), "dncAlt.readableNote", text)
}

@Test func configKeyDefaultsOnAndReadsOff() throws {
    equal(Config().tryAltNumbers, true, "cfg.default")
    let off = try JSONDecoder().decode(Config.self, from: Data(#"{"tryAltNumbers": false}"#.utf8))
    equal(off.tryAltNumbers, false, "cfg.off")
    let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
    equal(old.tryAltNumbers, true, "cfg.oldFileDefaultsOn")
}

// MARK: - Runner with a fake dialer

private final class Box: @unchecked Sendable {
    var now = DialFixture.at(7, 12)
    var recording = false
    var since: Date?
    var mdReady = false
    var snapshot = HistorySnapshot(rows: [], detection: .unavailable(reason: "fixture"))
}

@MainActor
private struct Rig {
    let box = Box()
    let dialer = FakeDialer()
    let dir: URL
    let runner: DialRunner

    init(tryAlts: Bool = true, dncSeed: [String] = []) throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-alt-\(UUID())")
        try Paths.ensureDir(dir)
        let leads = try LeadImporter.parse("""
        company,phone,alt_phone,confidence
        Fake One,9000000001,9000000201 / 9000000202,high
        Fake Two,9000000002,,medium
        """)
        let store = try LeadStateStore(url: dir.appendingPathComponent("fake.state.json"), listName: "fake")
        let dncURL = dir.appendingPathComponent("dnc.txt")
        for n in dncSeed { _ = try DNCList.add(n, now: DialFixture.at(1, 9), to: dncURL) }
        let box = self.box
        var config = Config(); config.recordingsDir = dir.appendingPathComponent("recordings").path
        config.tryAltNumbers = tryAlts
        let services = DialRunner.Services(
            dialer: dialer, config: config, listName: "fake", leads: leads, store: store,
            dialLogURL: dir.appendingPathComponent("dial-log.jsonl"), dncURL: dncURL,
            calendar: DialFixture.cal, now: { box.now },
            callState: { .init(recording: box.recording, since: box.since) },
            loadHistory: { box.snapshot },
            applyToMarkdown: { _, _, _, _ in box.mdReady },
            saveColdSIM: { _ in }, autoTick: false)
        runner = DialRunner(services)
    }

    func settle() async { for _ in 0..<20 { await Task.yield() } }
    func advance(_ s: TimeInterval) { box.now = box.now.addingTimeInterval(s) }

    func begin() async {
        runner.start(); await settle(); runner.confirmManualSIM(true); runner.passPreflight()
    }

    /// The call connects, lasts `seconds`, then ends.
    func call(seconds: TimeInterval) async {
        runner.tick()
        box.recording = true; box.since = box.now; advance(1); runner.tick()
        advance(seconds); box.recording = false; runner.tick()
        await settle()
    }

    /// Past the gap: the next dial is due.
    func nextDial() { advance(130); runner.tick() }
}

@MainActor @Test func runnerMainNoConnectThenAltConnectsThenWrapUp() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    equal(rig.dialer.dialed, ["9000000001"], "run.mainFirst")
    equal(r.numberProgress?.label ?? "", "Main", "run.labelMain")

    // Main rings out: it shows in call history as a 0 s call, and no recording ever starts.
    rig.box.snapshot = HistorySnapshot(rows: [HistoryCall(key: "9000000001", date: rig.box.now.addingTimeInterval(3), seconds: 0)],
                                       detection: .unavailable(reason: "fixture"))
    r.tick(); rig.advance(46); r.tick(); await rig.settle()
    if case .countdown(let c) = r.session.phase {
        expect(c.altFallback, "run.altCountdown")
        let notice = r.altNotice(for: c) ?? ""
        equal(notice, "No answer on +91 90000 00001. Trying alt 1 of 2 (+91 90000 00201)", "run.notice")
    } else { Issue.record("run.countdown: \(r.session.phase)"); return }
    equal(r.focus?.id ?? "", "9000000001", "run.focusStaysOnTheLead")
    equal(r.queue.first { $0.id == "9000000001" }?.status, .pending, "run.leadStillPending")
    expect(!r.dialLog.contains { $0.kind == .result && $0.key == "9000000001" && $0.result == .notPlaced }, "run.mainNotMarkedNotPlaced")

    // Alt 1 is dialled after the gap, not before.
    rig.advance(10); r.tick()
    equal(rig.dialer.dialed, ["9000000001"], "run.waitsForTheGap")
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000201"], "run.altDialled")
    equal(r.numberProgress?.label ?? "", "Alt 1 of 2", "run.labelAlt")
    let altAttempt = r.dialLog.last { $0.kind == .attempt }
    equal(altAttempt?.key ?? "", "9000000201", "run.attemptKeyIsTheAlt")
    equal(altAttempt?.leadID ?? "", "9000000001", "run.attemptLeadIsTheLead")
    equal(r.dialsToday, 2, "run.altCountsAsADial")

    await rig.call(seconds: 60)
    if case .wrapUp(let w) = r.session.phase { equal(w.leadID, "9000000001", "run.wrapUpLead") } else { Issue.record("run.wrapUp: \(r.session.phase)"); return }
    expect(r.dialLog.contains { $0.kind == .result && $0.key == "9000000201" && $0.result == .connected && $0.seconds == 60 }, "run.altResultLogged")
    r.saveWrapUp(outcome: "pitched", notes: "", doNotCall: false)
    equal(r.queue.first { $0.id == "9000000001" }?.status, .called, "run.leadCalled")
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000201", "9000000002"], "run.alt2NeverDialled")
}

@MainActor @Test func runnerEveryNumberFailingEndsTheLeadAsNoAnswerWithoutWrapUp() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    await rig.call(seconds: 2)    // main: connected but shorter than 5 s
    equal(r.queue.first { $0.id == "9000000001" }?.status, .pending, "all.pendingBetweenNumbers")
    rig.nextDial()
    await rig.call(seconds: 2)    // alt 1
    guard case .countdown = r.session.phase else { Issue.record("all.afterAlt1: \(r.session.phase)"); return }
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000201", "9000000202"], "all.threeNumbers")
    await rig.call(seconds: 2)    // alt 2
    if case .wrapUp = r.session.phase { Issue.record("all.noWrapUpSheet") }
    equal(r.queue.first { $0.id == "9000000001" }?.status, .noAnswer, "all.noAnswer")
    equal(r.dialLog.filter { $0.kind == .result && $0.leadID == "9000000001" }.map(\.key),
          ["9000000001", "9000000201", "9000000202"], "all.everyAttemptHasAResult")
    expect(r.dialLog.filter { $0.kind == .attempt }.count == 3, "all.threeAttemptsLogged")
}

@MainActor @Test func runnerDoNotCallAgainListsTheMainAndEveryAlt() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    r.tick()
    rig.box.recording = true; rig.box.since = rig.box.now; rig.advance(1); r.tick()
    r.doNotCallAgain()
    for n in ["9000000001", "9000000201", "9000000202"] { expect(r.dnc.contains(n), "dncAll.\(n)") }
    expect(!r.dnc.contains("9000000002"), "dncAll.otherLeadUntouched")
    equal(r.queue.first { $0.id == "9000000001" }?.status, .doNotCall, "dncAll.status")
    equal(r.dnc.addedToday(now: rig.box.now, calendar: DialFixture.cal), 1, "dncAll.countsOnceTowardTheDailyPause")
}

@MainActor @Test func runnerQueueRowDoNotCallListsEveryNumberToo() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    rig.runner.markDoNotCall("9000000001")
    for n in ["9000000001", "9000000201", "9000000202"] { expect(rig.runner.dnc.contains(n), "dncRow.\(n)") }
}

@MainActor @Test func runnerSkipsAnAltThatIsOnTheDNCList() async throws {
    let rig = try Rig(dncSeed: ["9000000201"])
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    await rig.call(seconds: 2)
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000202"], "dncSkip.straightToAlt2")
    equal(r.numberProgress?.numbers ?? [], ["9000000001", "9000000202"], "dncSkip.sequenceWithoutIt")
}

@MainActor @Test func runnerSkipsAnAltOnCooldownFromAnEarlierDial() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    // Alt 1 was rung from another list two days ago.
    rig.box.snapshot = HistorySnapshot(rows: [HistoryCall(key: "9000000201", date: rig.box.now.addingTimeInterval(-2 * 86_400), seconds: 30)],
                                       detection: .unavailable(reason: "fixture"))
    await rig.call(seconds: 2)
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000202"], "coolSkip.straightToAlt2")
    equal(r.queue.first { $0.id == "9000000001" }?.status, .pending, "coolSkip.leadNotSkipped")
}

@MainActor @Test func runnerSkipRemainingNumbersMovesToTheNextLead() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    await rig.call(seconds: 2)
    r.skipRemainingNumbers()
    equal(r.queue.first { $0.id == "9000000001" }?.status, .noAnswer, "skipRun.noAnswer")
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000002"], "skipRun.nextLead")
}

@MainActor @Test func runnerWithTheSwitchOffBehavesAsBefore() async throws {
    let rig = try Rig(tryAlts: false)
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    equal(r.numberProgress?.numbers ?? [], ["9000000001"], "off.mainOnly")
    await rig.call(seconds: 2)
    if case .wrapUp(let w) = r.session.phase { expect(w.connected, "off.shortCallWrapUp") } else { Issue.record("off.wrapUp: \(r.session.phase)") }
    r.saveWrapUp(outcome: "", notes: "", doNotCall: false)
    rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000002"], "off.nextLeadNotAlt")
}

@MainActor @Test func runnerNotPlacedMainDoesNotFallThroughToTheAlt() async throws {
    let rig = try Rig()
    defer { Fs.remove(rig.dir) }
    let r = rig.runner
    await rig.begin()
    r.tick(); rig.advance(46); r.tick(); await rig.settle()
    rig.advance(80); r.tick(); await rig.settle()   // past the history grace: not placed
    equal(r.session.phase, .paused(.notPlaced), "npRun.paused")
    equal(rig.dialer.dialed, ["9000000001"], "npRun.noAltDialled")
    expect(r.dialLog.contains { $0.kind == .result && $0.result == .notPlaced && $0.key == "9000000001" }, "npRun.loggedNotPlaced")
    r.resume(); rig.nextDial()
    equal(rig.dialer.dialed, ["9000000001", "9000000001"], "npRun.retriesTheSameNumber")
}
