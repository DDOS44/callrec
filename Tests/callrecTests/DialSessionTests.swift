import Foundation
import Testing
@testable import CallrecCore

private let t0 = DialFixture.at(7, 11)
private func later(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let lead = "9000000001"

/// A session driven to the countdown with the first lead ready to be checked.
private func started() -> DialSession {
    var s = DialSession()
    s.handle(.start)
    _ = s.handle(.preflightPassed(now: t0))
    return s
}

/// Through dial -> placed -> call started: on the call at `later(10)`.
private func onCall() -> DialSession {
    var s = started()
    _ = s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    _ = s.handle(.dialPlaced(now: later(1)))
    _ = s.handle(.callStarted(now: later(10)))
    return s
}

private func wrapUp() -> DialSession {
    var s = onCall()
    _ = s.handle(.callEnded(now: later(70)))
    return s
}

@Test func happyPathWalksEveryPhaseInOrder() {
    var s = DialSession()
    equal(s.phase, .idle, "phase.idle")
    s.handle(.start)
    equal(s.phase, .preflight, "phase.preflight")
    equal(s.handle(.preflightPassed(now: t0)), [.evaluateNext], "phase.firstEvaluate")
    equal(s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed)), [.dial(leadID: lead)], "phase.dialEffect")
    equal(s.phase, .dialing(leadID: lead), "phase.dialing")
    s.handle(.dialPlaced(now: later(1)))
    equal(s.phase, .waitingForCall(leadID: lead, since: later(1)), "phase.waiting")
    s.handle(.callStarted(now: later(10)))
    equal(s.phase, .onCall(leadID: lead, startedAt: later(10)), "phase.onCall")
    let ended = s.handle(.callEnded(now: later(70)))
    equal(ended, [.recordCallEnded(leadID: lead, seconds: 60, connected: true)], "phase.recordCallEnded")
    equal(s.phase, .wrapUp(.init(leadID: lead, seconds: 60, connected: true)), "phase.wrapUp")
    let saved = s.handle(.wrapUpSaved(now: later(100), outcome: "pitched", notes: "n", doNotCall: false, gap: 60, minGap: 45))
    equal(saved, [.saveWrapUp(leadID: lead, outcome: "pitched", notes: "n")], "phase.saveEffect")
    equal(s.phase, .countdown(.init(until: later(160), minGapUntil: later(145), blocked: nil)), "phase.countdown")
    equal(s.dials, 1, "phase.dialsCounted")
    equal(s.calls, 1, "phase.callsCounted")
}

@Test func countdownDoesNotStartUntilWrapUpIsSaved() {
    var s = wrapUp()
    // Time passing while the user is still typing never triggers a dial.
    for i in 0..<500 { expect(s.handle(.tick(now: later(100 + Double(i)))).isEmpty, "wrap.tickIgnored \(i)") }
    expect(s.handle(.dialNow(now: later(700))).isEmpty, "wrap.dialNowIgnored")
    if case .wrapUp = s.phase {} else { Issue.record("wrap.stillWrapUp: \(s.phase)") }
}

@Test func countdownAsksForTheNextDialOnlyAfterItsTime() {
    var s = wrapUp()
    s.handle(.wrapUpSaved(now: later(100), outcome: "", notes: "", doNotCall: false, gap: 60, minGap: 45))
    expect(s.handle(.tick(now: later(159))).isEmpty, "countdown.early")
    equal(s.handle(.tick(now: later(160))), [.evaluateNext], "countdown.due")
    equal(s.handle(.dialChecked(now: later(160), nextLeadID: "9000000002", decision: .allowed)),
          [.dial(leadID: "9000000002")], "countdown.dials")
}

@Test func dialNowOnlyAfterTheMinimumGap() {
    var s = wrapUp()
    s.handle(.wrapUpSaved(now: later(100), outcome: "", notes: "", doNotCall: false, gap: 90, minGap: 45))
    equal(s.canDialNow(at: later(144)), false, "dialNow.tooEarlyFlag")
    expect(s.handle(.dialNow(now: later(144))).isEmpty, "dialNow.tooEarlyIgnored")
    equal(s.canDialNow(at: later(145)), true, "dialNow.okFlag")
    equal(s.handle(.dialNow(now: later(145))), [.evaluateNext], "dialNow.ok")
}

@Test func notPlacedAfterTimeoutResolvesThenPauses() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    s.handle(.dialPlaced(now: later(0)))
    expect(s.handle(.tick(now: later(44))).isEmpty, "np.before45")
    equal(s.handle(.tick(now: later(45))), [.lookUpCall(leadID: lead, dialedAt: later(0))], "np.at45Looks")
    equal(s.phase, .resolvingDial(leadID: lead, since: later(0)), "np.resolving")
    equal(s.handle(.dialResolved(.notPlaced, now: later(46))), [.recordNotPlaced(leadID: lead)], "np.recorded")
    equal(s.phase, .paused(.notPlaced), "np.paused")
    // Paused never auto-advances.
    for i in 0..<300 { expect(s.handle(.tick(now: later(50 + Double(i)))).isEmpty, "np.noAutoAdvance \(i)") }
}

@Test func aRingingCallThatShowsInHistoryIsWrappedUpNotPaused() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    s.handle(.dialPlaced(now: later(0)))
    s.handle(.tick(now: later(45)))
    let e = s.handle(.dialResolved(.placed(seconds: 0), now: later(50)))
    equal(e, [.recordCallEnded(leadID: lead, seconds: 0, connected: false)], "ring.recorded")
    equal(s.phase, .wrapUp(.init(leadID: lead, seconds: 0, connected: false)), "ring.wrapUp")
}

@Test func resolvingKeepsLookingThenGivesUpAfterTheGrace() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    s.handle(.dialPlaced(now: later(0)))
    s.handle(.tick(now: later(45)))
    equal(s.handle(.tick(now: later(60))), [.lookUpCall(leadID: lead, dialedAt: later(0))], "resolve.polls")
    equal(s.handle(.tick(now: later(120))), [.recordNotPlaced(leadID: lead)], "resolve.givesUp")
    equal(s.phase, .paused(.notPlaced), "resolve.paused")
}

@Test func aLateConnectingCallStillBecomesOnCall() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    s.handle(.dialPlaced(now: later(0)))
    s.handle(.tick(now: later(45)))
    s.handle(.callStarted(now: later(52)))
    equal(s.phase, .onCall(leadID: lead, startedAt: later(52)), "late.onCall")
}

@Test func dialerFailureRecordsNotPlacedAndPauses() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    equal(s.handle(.dialFailed(message: "macOS refused")), [.recordNotPlaced(leadID: lead)], "fail.recorded")
    equal(s.phase, .paused(.dialFailed("macOS refused")), "fail.paused")
}

@Test func policyDecisionsDriveTheSession() {
    var stopped = started()
    stopped.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .stop(.wrongSIM(expected: "A", got: "B"))))
    equal(stopped.phase, .stopped(.policy(.wrongSIM(expected: "A", got: "B"))), "policy.stop")
    expect(stopped.isRedBanner, "policy.redBanner")

    var paused = started()
    paused.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .pause(.consecutiveFailures(count: 3))))
    equal(paused.phase, .paused(.policy(.consecutiveFailures(count: 3))), "policy.pause")
    expect(paused.banner?.contains("carrier restriction") ?? false, "policy.pauseMessage", paused.banner ?? "")

    var done = started()
    done.handle(.dialChecked(now: t0, nextLeadID: nil, decision: .allowed))
    equal(done.phase, .stopped(.listExhausted), "policy.exhausted")
}

@Test func blockedByTheMomentKeepsTheCountdownWithAReason() {
    var s = started()
    let hours = DialBlock.outsideCallingHours(opensAt: DialFixture.at(8, 10))
    expect(s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(hours))).isEmpty, "blocked.noEffect")
    guard case .countdown(let c) = s.phase else { Issue.record("blocked.stillCountdown: \(s.phase)"); return }
    equal(c.blocked, hours, "blocked.reasonShown")
    // And it asks again on the next tick, so it dials as soon as the block clears.
    equal(s.handle(.tick(now: later(1))), [.evaluateNext], "blocked.asksAgain")
    s.handle(.dialChecked(now: later(1), nextLeadID: lead, decision: .allowed))
    equal(s.phase, .dialing(leadID: lead), "blocked.thenDials")
}

@Test func blockedByTheLeadMarksItAndMovesOn() {
    var s = started()
    equal(s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(.doNotCall))),
          [.setLeadStatus(leadID: lead, status: .doNotCall), .evaluateNext], "leadBlock.dnc")
    equal(s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(.cooldown(until: later(5))))),
          [.setLeadStatus(leadID: lead, status: .skipped), .evaluateNext], "leadBlock.cooldown")
    equal(s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(.invalidNumber))),
          [.setLeadStatus(leadID: lead, status: .skipped), .evaluateNext], "leadBlock.invalid")
}

@Test func missingSIMConfirmationPausesInsteadOfWaitingForever() {
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .blocked(.coldSIMNotConfirmed)))
    if case .paused = s.phase {} else { Issue.record("sim.paused: \(s.phase)") }
}

@Test func pauseAfterThisCallWaitsForWrapUpSave() {
    var s = onCall()
    s.handle(.pauseAfterThisCall)
    equal(s.phase, .onCall(leadID: lead, startedAt: later(10)), "pauseAfter.stillOnCall")
    equal(s.banner, PauseReason.afterThisCall.message, "pauseAfter.bannerShown")
    s.handle(.callEnded(now: later(70)))
    if case .wrapUp = s.phase {} else { Issue.record("pauseAfter.wrapUpFirst: \(s.phase)") }
    s.handle(.wrapUpSaved(now: later(90), outcome: "booked", notes: "", doNotCall: false, gap: 60, minGap: 45))
    equal(s.phase, .paused(.afterThisCall), "pauseAfter.pausesAfterSave")
    s.handle(.resume(now: later(100), gap: 50, minGap: 45))
    equal(s.phase, .countdown(.init(until: later(150), minGapUntil: later(145), blocked: nil)), "pauseAfter.resumeCountsDown")
}

@Test func stopDuringACallStillLetsTheWrapUpBeSaved() {
    var s = onCall()
    s.handle(.stop)
    s.handle(.callEnded(now: later(70)))
    if case .wrapUp = s.phase {} else { Issue.record("stop.wrapUpKept: \(s.phase)"); return }
    s.handle(.wrapUpSaved(now: later(80), outcome: "", notes: "notes kept", doNotCall: false, gap: 60, minGap: 45))
    equal(s.phase, .stopped(.user), "stop.afterSave")
}

@Test func wrongSIMStopsAtOnceButNeverEatsTheWrapUp() {
    var s = wrapUp()
    s.handle(.policyHalt(.stop(.policy(.wrongSIM(expected: "A", got: "B")))))
    if case .wrapUp = s.phase {} else { Issue.record("halt.wrapUpStays: \(s.phase)"); return }
    expect(s.isRedBanner, "halt.redBannerNow")
    equal(s.banner, DialStop.wrongSIM(expected: "A", got: "B").message, "halt.bannerText")
    let e = s.handle(.wrapUpSaved(now: later(90), outcome: "x", notes: "y", doNotCall: false, gap: 60, minGap: 45))
    equal(e, [.saveWrapUp(leadID: lead, outcome: "x", notes: "y")], "halt.notesSaved")
    equal(s.phase, .stopped(.policy(.wrongSIM(expected: "A", got: "B"))), "halt.stoppedAfterSave")
}

@Test func aStopOutranksAPendingPauseButNotTheOtherWayAround() {
    var s = wrapUp()
    s.handle(.pause)
    s.handle(.stop)
    s.handle(.wrapUpSaved(now: later(90), outcome: "", notes: "", doNotCall: false, gap: 60, minGap: 45))
    equal(s.phase, .stopped(.user), "halt.stopWins")
    var t = wrapUp()
    t.handle(.stop)
    t.handle(.pause)
    t.handle(.wrapUpSaved(now: later(90), outcome: "", notes: "", doNotCall: false, gap: 60, minGap: 45))
    equal(t.phase, .stopped(.user), "halt.pauseDoesNotDowngradeStop")
}

@Test func doNotCallAgainDuringCallAndWrapUp() {
    var s = onCall()
    equal(s.handle(.doNotCallAgain), [.addToDoNotCall(leadID: lead), .setLeadStatus(leadID: lead, status: .doNotCall)], "dnc.onCall")
    var w = wrapUp()
    let e = w.handle(.wrapUpSaved(now: later(90), outcome: "not interested", notes: "", doNotCall: true, gap: 60, minGap: 45))
    equal(e, [.saveWrapUp(leadID: lead, outcome: "not interested", notes: ""),
              .addToDoNotCall(leadID: lead), .setLeadStatus(leadID: lead, status: .doNotCall)], "dnc.fromWrapUp")
    var idle = DialSession()
    expect(idle.handle(.doNotCallAgain).isEmpty, "dnc.nothingToAdd")
}

@Test func userPauseStopAndResumeFromCountdown() {
    var s = started()
    s.handle(.pause)
    equal(s.phase, .paused(.user), "user.pause")
    expect(s.handle(.tick(now: later(500))).isEmpty, "user.pausedIgnoresTicks")
    s.handle(.resume(now: later(10), gap: 5, minGap: 0))
    equal(s.phase, .countdown(.init(until: later(15), minGapUntil: later(10), blocked: nil)), "user.resume")
    s.handle(.stop)
    equal(s.phase, .stopped(.user), "user.stop")
    s.handle(.stop)
    equal(s.phase, .stopped(.user), "user.stopTwice")
    // A new session can start after a stop, with fresh counters.
    s.handle(.start)
    equal(s.phase, .preflight, "user.restart")
    equal(s.dials, 0, "user.freshCounters")
}

@Test func stopWhilePausedBecomesStopped() {
    var s = started()
    s.handle(.pause)
    s.handle(.stop)
    equal(s.phase, .stopped(.user), "pausedStop")
}

@Test func skipNextMarksTheLeadOnlyDuringCountdown() {
    var s = wrapUp()
    expect(s.handle(.skipNext(leadID: "9000000002")).isEmpty, "skip.notInWrapUp")
    s.handle(.wrapUpSaved(now: later(90), outcome: "", notes: "", doNotCall: false, gap: 60, minGap: 45))
    equal(s.handle(.skipNext(leadID: "9000000002")), [.setLeadStatus(leadID: "9000000002", status: .skipped)], "skip.countdown")
}

@Test func nonsenseEventsAreIgnoredNotCrashes() {
    var s = DialSession()
    for e: DialEvent in [.callStarted(now: t0), .callEnded(now: t0), .dialPlaced(now: t0), .wrapUpSaved(now: t0, outcome: "", notes: "", doNotCall: false, gap: 1, minGap: 1),
                         .dialResolved(.notPlaced, now: t0), .tick(now: t0), .dialNow(now: t0), .pause, .stop, .preflightPassed(now: t0),
                         .dialChecked(now: t0, nextLeadID: lead, decision: .allowed), .resume(now: t0, gap: 1, minGap: 1)] {
        expect(s.handle(e).isEmpty, "nonsense.\(e)")
    }
    equal(s.phase, .idle, "nonsense.stillIdle")
    var busy = onCall()
    expect(busy.handle(.dialChecked(now: t0, nextLeadID: "9000000002", decision: .allowed)).isEmpty, "nonsense.staleCheckWhileOnCall")
    expect(busy.handle(.start).isEmpty, "nonsense.startWhileRunning")
    equal(busy.phase, .onCall(leadID: lead, startedAt: later(10)), "nonsense.stillOnCall")
}

@Test func preflightCancelReturnsToIdle() {
    var s = DialSession()
    s.handle(.start)
    s.handle(.preflightCancelled)
    equal(s.phase, .idle, "preflight.cancel")
}

@Test func aSecondDialNeverStartsWhileOneIsInProgress() {
    // The machine only ever holds one lead; a second "allowed" check mid-dial is ignored.
    var s = started()
    s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    expect(s.handle(.dialChecked(now: t0, nextLeadID: "9000000002", decision: .allowed)).isEmpty, "single.ignoredWhileDialing")
    equal(s.phase, .dialing(leadID: lead), "single.stillFirst")
    s.handle(.dialPlaced(now: later(1)))
    expect(s.handle(.dialChecked(now: t0, nextLeadID: "9000000002", decision: .allowed)).isEmpty, "single.ignoredWhileWaiting")
}

// MARK: - Dialer doubles

@MainActor @Test func fakeDialerRecordsAndCanFail() throws {
    let d = FakeDialer()
    try d.dial(number: "9000000001")
    equal(d.dialed, ["9000000001"], "fake.records")
    d.failWith = DialerError.refused
    #expect(throws: DialerError.self) { try d.dial(number: "9000000002") }
    equal(d.dialed.count, 1, "fake.failedNotRecorded")
}

@Test func telURLIsBuiltFromNormalizedNumbersOnly() {
    equal(TelURL.url(for: "9000000001")?.absoluteString, "tel:+919000000001", "tel.plain")
    equal(TelURL.url(for: "+91 90000 00001")?.absoluteString, "tel:+919000000001", "tel.formatted")
    expect(TelURL.url(for: "12345") == nil, "tel.invalid")
    expect(TelURL.url(for: "") == nil, "tel.empty")
}

// Regression (2026-10-07): Stop while waiting for the call to start showed "Stopped"
// over a still-spinning "Dialing…" for up to ~2 minutes.
@Test func stopBeforeTheCallConnectsAppliesImmediately() {
    var s = started()
    _ = s.handle(.dialChecked(now: t0, nextLeadID: lead, decision: .allowed))
    _ = s.handle(.dialPlaced(now: later(1)))
    s.handle(.stop)
    equal(s.phase, .stopped(.user), "stop.immediateWhileWaiting")
    expect(s.pendingHalt == nil, "stop.noPending", "pending halt left behind")
    expect(!s.isRunning, "stop.notRunning", "still running after stop")
}

@Test func pendingStopBannerSaysWillStop() {
    var s = onCall()
    s.handle(.stop)
    expect(s.banner == "Will stop after this call.", "stop.bannerHonest", "banner: \(s.banner ?? "nil")")
}
