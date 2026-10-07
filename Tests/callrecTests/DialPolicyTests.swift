import Foundation
import Testing
@testable import CallrecCore

/// Fixed clock and calendar so no test depends on the machine's time zone.
enum DialFixture {
    static let ist = TimeZone(identifier: "Asia/Kolkata")!
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ist
        return c
    }

    /// Local IST time. 2026-10-07 is a Wednesday.
    static func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m, second: s))!
    }

    static let rules = DialRules()
    static let num = "9000000001"
    static let sim = "SIM-COLD"

    /// Session that has confirmed the SIM manually, started well before `now`.
    static func session(start: Date = at(7, 9), callActive: Bool = false, lastWrapUp: Date? = nil,
                        expected: String? = nil, confirmed: Bool = true) -> DialSessionFacts {
        DialSessionFacts(start: start, callActive: callActive, lastWrapUpEnd: lastWrapUp,
                         expectedSIM: expected, manualSIMConfirmed: confirmed)
    }

    static func attempt(_ ts: Date, key: String = "9000000099", id: String = UUID().uuidString) -> DialLogEntry {
        .attempt(at: ts, id: id, list: "fake", leadID: "L", key: key)
    }

    static func result(_ ts: Date, _ r: DialResult, seconds: Int? = nil, sim: String? = nil) -> DialLogEntry {
        attempt(ts).finished(at: ts, result: r, seconds: seconds, sim: sim)
    }

    static func decide(_ number: String = num, now: Date = at(7, 12), rules: DialRules = DialFixture.rules,
                       log: [DialLogEntry] = [], dnc: DNCList = DNCList(), history: [String: Date] = [:],
                       session: DialSessionFacts = DialFixture.session()) -> DialDecision {
        DialPolicy.evaluate(number: number, now: now, rules: rules, log: log, dnc: dnc, history: history,
                            session: session, calendar: cal)
    }

    static func dnc(_ entries: [(String, Date?)]) -> DNCList {
        DNCList(entries: entries.map { DNCList.Entry(key: $0.0, addedAt: $0.1) })
    }
}

private typealias F = DialFixture

// MARK: - Phone normalization

@Test func phoneNormalizationAcceptsEveryIndianFormat() {
    for raw in ["9000000001", "+91 90000 00001", "+919000000001", "09000000001", "0 9000000001",
                "91-9000000001", "091 90000 00001", "00919000000001", " 90000-00001 ", "(+91) 9000000001"] {
        equal(PhoneNumber.normalize(raw), "9000000001", "phone.normalize \(raw)")
    }
}

@Test func phoneNormalizationRejectsAnythingAmbiguous() {
    for raw in ["", "abc", "12345", "900000000", "90000000011", "9000000001 / 9000000002",
                "9000000001 ext 12", "+1 5555550123", "0000000000", "919000000", "+91 0900000001"] {
        expect(PhoneNumber.normalize(raw) == nil, "phone.reject \(raw)", "\(String(describing: PhoneNumber.normalize(raw)))")
    }
}

@Test func phoneKeyIsLenientLastTenDigits() {
    equal(PhoneNumber.key("+91 90000 00001"), "9000000001", "key.plus91")
    equal(PhoneNumber.key("+1 (555) 555-0123"), "5555550123", "key.foreign")
    equal(PhoneNumber.key("0900000"), nil, "key.tooShort")
}

// MARK: - Daily and hourly caps

@Test func dailyCapAtBoundary() {
    let day = (0..<29).map { F.attempt(F.at(7, 10, $0)) }
    equal(F.decide(now: F.at(7, 12), log: day), .allowed, "daily.29isFine")
    // Hourly cap would trip first if these were all within an hour; space them out so only the daily cap is under test.
    let spaced = (0..<30).map { F.attempt(F.at(7, 10) .addingTimeInterval(Double($0) * 700)) }
    guard case .blocked(.dailyCapReached(let cap, let resets)) = F.decide(now: F.at(7, 17, 59), log: spaced) else {
        Issue.record("daily.30blocked: got \(F.decide(now: F.at(7, 17, 59), log: spaced))"); return
    }
    equal(cap, 30, "daily.capValue")
    equal(resets, F.at(8, 0), "daily.resetsAtMidnight")
}

@Test func dailyCapCountsEveryAttemptAnyListAndNotResults() {
    var rules = DialRules(); rules.dailyCap = 3
    let first = F.attempt(F.at(7, 11))
    let a = [F.attempt(F.at(7, 10)), first, first.finished(at: F.at(7, 11, 5), result: .connected, seconds: 60)]
    // 2 attempts + 1 result line = 2 dials, not 3.
    equal(F.decide(now: F.at(7, 15), rules: rules, log: a), .allowed, "dailyCap.resultsDoNotCount")
    let other = a + [DialLogEntry.attempt(at: F.at(7, 12), list: "other-list", leadID: "x", key: "9000000077")]
    expect(F.decide(now: F.at(7, 15), rules: rules, log: other) != .allowed, "dailyCap.anyListCounts")
}

@Test func dailyCapResetsAtLocalMidnight() {
    var rules = DialRules(); rules.dailyCap = 2
    rules.days = [1, 2, 3, 4, 5, 6, 7]
    let log = [F.attempt(F.at(7, 23, 58)), F.attempt(F.at(7, 23, 59, 59))]
    // Same day: blocked by the cap (hours are also closed, so check the cap function directly).
    expect(DialPolicy.capBlock(now: F.at(7, 23, 59, 59), rules: rules, log: log, calendar: F.cal) != nil, "midnight.sameDayBlocked")
    expect(DialPolicy.capBlock(now: F.at(8, 0, 0, 0), rules: rules, log: log, calendar: F.cal) == nil, "midnight.nextDayFree")
    // And through the whole policy at 10:00 the next morning.
    equal(F.decide(now: F.at(8, 10), rules: rules, log: log, session: F.session(start: F.at(8, 9))), .allowed, "midnight.policyFree")
}

@Test func hourlyCapAtBoundaryAndRolling() {
    let now = F.at(7, 12)
    let nine = (0..<9).map { F.attempt(now.addingTimeInterval(-Double($0 + 1) * 60)) }
    equal(F.decide(now: now, log: nine), .allowed, "hourly.9fine")
    let ten = nine + [F.attempt(now.addingTimeInterval(-600))]
    guard case .blocked(.hourlyCapReached(let cap, let free)) = F.decide(now: now, log: ten) else {
        Issue.record("hourly.10blocked: got \(F.decide(now: now, log: ten))"); return
    }
    equal(cap, 10, "hourly.capValue")
    // Oldest attempt is 10 min ago; the cap frees when it ages past 60 min: 50 min from now.
    equal(free, now.addingTimeInterval(50 * 60), "hourly.freeAt")
}

@Test func hourlyWindowExcludesExactlySixtyMinutesAgo() {
    let now = F.at(7, 12)
    var rules = DialRules(); rules.hourlyCap = 1
    let exactlyHourAgo = [F.attempt(now.addingTimeInterval(-3600))]
    equal(F.decide(now: now, rules: rules, log: exactlyHourAgo), .allowed, "hourly.exactly60IsOut")
    let justInside = [F.attempt(now.addingTimeInterval(-3599))]
    expect(F.decide(now: now, rules: rules, log: justInside) != .allowed, "hourly.59m59sIsIn")
}

// MARK: - Calling hours and days

@Test func hoursEdges() {
    equal(F.decide(now: F.at(7, 9, 59, 59), session: F.session(start: F.at(7, 9))).isAllowed, false, "hours.0959")
    equal(F.decide(now: F.at(7, 10, 0, 0)), .allowed, "hours.1000start")
    equal(F.decide(now: F.at(7, 18, 29, 59)), .allowed, "hours.182959")
    guard case .blocked(.outsideCallingHours(let opens)) = F.decide(now: F.at(7, 18, 30)) else {
        Issue.record("hours.1830end: got \(F.decide(now: F.at(7, 18, 30)))"); return
    }
    equal(opens, F.at(8, 10), "hours.nextOpening")
}

@Test func hoursMidnightAndEarlyMorning() {
    expect(F.decide(now: F.at(8, 0, 0, 0)) != .allowed, "hours.midnightClosed")
    expect(F.decide(now: F.at(7, 23, 59, 59)) != .allowed, "hours.2359Closed")
    guard case .blocked(.outsideCallingHours(let opens)) = F.decide(now: F.at(8, 3, 0)) else {
        Issue.record("hours.3am"); return
    }
    equal(opens, F.at(8, 10), "hours.3amOpensToday")
}

@Test func daysMondayToSaturdayOnly() {
    // 2026-10-10 is Saturday, 2026-10-11 is Sunday, 2026-10-12 is Monday.
    equal(F.decide(now: F.at(10, 12), session: F.session(start: F.at(10, 9))), .allowed, "days.saturdayOK")
    guard case .blocked(.outsideCallingHours(let opens)) = F.decide(now: F.at(11, 12), session: F.session(start: F.at(11, 9))) else {
        Issue.record("days.sundayBlocked"); return
    }
    equal(opens, F.at(12, 10), "days.sundayOpensMonday")
    // Saturday evening after close opens Monday, skipping Sunday.
    guard case .blocked(.outsideCallingHours(let sat)) = F.decide(now: F.at(10, 19), session: F.session(start: F.at(10, 9))) else {
        Issue.record("days.satEvening"); return
    }
    equal(sat, F.at(12, 10), "days.satEveningOpensMonday")
}

@Test func noAllowedDayYieldsNoOpening() {
    var rules = DialRules(); rules.days = []
    guard case .blocked(.outsideCallingHours(let opens)) = F.decide(rules: rules) else { Issue.record("days.none"); return }
    equal(opens, nil, "days.noOpening")
}

// MARK: - Cooldown

@Test func cooldownAtExactlySevenDays() {
    let now = F.at(14, 12)
    let called = now.addingTimeInterval(-7 * 86_400)
    var key = ["9000000001": called]
    equal(F.decide(now: now, history: key, session: F.session(start: F.at(14, 9))), .allowed, "cooldown.exactly7daysFree")
    key = ["9000000001": called.addingTimeInterval(1)]
    guard case .blocked(.cooldown(let until)) = F.decide(now: now, history: key, session: F.session(start: F.at(14, 9))) else {
        Issue.record("cooldown.7daysMinus1s"); return
    }
    equal(until, now.addingTimeInterval(1), "cooldown.untilValue")
}

@Test func cooldownUsesDialLogAndHistoryAcrossLists() {
    let now = F.at(9, 12)
    let fromLog = [DialLogEntry.attempt(at: F.at(5, 11), list: "other", leadID: "z", key: "9000000001")]
    expect(F.decide(now: now, log: fromLog) != .allowed, "cooldown.dialLogOtherList")
    let fromHistory: [String: Date] = ["9000000001": F.at(4, 15)]
    expect(F.decide(now: now, history: fromHistory) != .allowed, "cooldown.callHistory")
    // A result line alone (no attempt) is not a dial.
    let resultOnly = [F.attempt(F.at(5, 11), key: "9000000002").finished(at: F.at(5, 11), result: .connected, seconds: 30)]
    equal(F.decide(now: now, log: resultOnly), .allowed, "cooldown.otherNumberFree")
    // Different formats of the same number match.
    expect(F.decide("+91 90000 00001", now: now, history: fromHistory) != .allowed, "cooldown.formatInsensitive")
}

@Test func aNotPlacedDialDoesNotStartACooldownButStillCountsAgainstTheCaps() {
    let now = F.at(9, 12)
    let a = DialLogEntry.attempt(at: F.at(8, 11), id: "NP", list: "l", leadID: "1", key: "9000000001")
    let log = [a, a.finished(at: F.at(8, 11, 50), result: .notPlaced)]
    equal(F.decide(now: now, log: log), .allowed, "notPlaced.noCooldown")
    var rules = DialRules(); rules.dailyCap = 1
    let sameDay = [DialLogEntry.attempt(at: F.at(9, 10), id: "NP2", list: "l", leadID: "1", key: "9000000001")]
    expect(F.decide(now: now, rules: rules, log: sameDay + [sameDay[0].finished(at: F.at(9, 10, 50), result: .notPlaced)]) != .allowed, "notPlaced.countsForCap")
}

@Test func cooldownTakesTheLatestOfLogAndHistory() {
    let now = F.at(14, 12)
    let old = now.addingTimeInterval(-8 * 86_400)
    let log = [DialLogEntry.attempt(at: old, list: "l", leadID: "1", key: "9000000001")]
    let history = ["9000000001": now.addingTimeInterval(-86_400)]
    expect(F.decide(now: now, log: log, history: history, session: F.session(start: F.at(14, 9))) != .allowed, "cooldown.latestWins")
}

// MARK: - Do-not-call

@Test func dncBlocksEveryFormat() {
    let dnc = F.dnc([("9000000001", nil)])
    for raw in ["9000000001", "+91 90000 00001", "09000000001", "+919000000001", "90000-00001"] {
        equal(F.decide(raw, dnc: dnc), .blocked(.doNotCall), "dnc.\(raw)")
    }
    equal(F.decide("9000000002", dnc: dnc), .allowed, "dnc.otherNumberFine")
}

@Test func invalidNumberIsBlocked() {
    equal(F.decide("12345"), .blocked(.invalidNumber), "invalid.short")
    equal(F.decide(""), .blocked(.invalidNumber), "invalid.empty")
}

// MARK: - Consecutive failures

@Test func threeConsecutiveFailuresPause() {
    let now = F.at(7, 13)
    let two = [F.result(F.at(7, 11), .noConnect), F.result(F.at(7, 12), .connected, seconds: 2)]
    equal(F.decide(now: now, log: two), .allowed, "failures.twoFine")
    let three = two + [F.result(F.at(7, 12, 30), .noConnect)]
    equal(F.decide(now: now, log: three), .pause(.consecutiveFailures(count: 3)), "failures.threePause")
}

@Test func shortCallBoundaryIsFiveSeconds() {
    let now = F.at(7, 13)
    let fourSeconds = (0..<3).map { F.result(F.at(7, 11, $0), .connected, seconds: 4) }
    equal(F.decide(now: now, log: fourSeconds), .pause(.consecutiveFailures(count: 3)), "failures.4sIsShort")
    let fiveSeconds = (0..<3).map { F.result(F.at(7, 11, $0), .connected, seconds: 5) }
    equal(F.decide(now: now, log: fiveSeconds), .allowed, "failures.5sIsNotShort")
}

@Test func aRealCallResetsTheStreak() {
    let now = F.at(7, 13)
    let log = [F.result(F.at(7, 10, 1), .noConnect), F.result(F.at(7, 10, 2), .noConnect),
               F.result(F.at(7, 10, 3), .connected, seconds: 90), F.result(F.at(7, 10, 4), .noConnect)]
    equal(F.decide(now: now, log: log), .allowed, "failures.resetByRealCall")
}

@Test func notPlacedNeitherCountsNorResetsTheStreak() {
    let now = F.at(7, 13)
    let log = [F.result(F.at(7, 10, 1), .noConnect), F.result(F.at(7, 10, 2), .notPlaced),
               F.result(F.at(7, 10, 3), .noConnect), F.result(F.at(7, 10, 4), .noConnect)]
    equal(F.decide(now: now, log: log), .pause(.consecutiveFailures(count: 3)), "failures.notPlacedIgnored")
}

@Test func failuresBeforeThisSessionDoNotCount() {
    let now = F.at(7, 13)
    let log = (0..<3).map { F.result(F.at(7, 10, $0), .noConnect) }
    equal(F.decide(now: now, log: log, session: F.session(start: F.at(7, 12))), .allowed, "failures.oldSessionIgnored")
}

@Test func barredCallStopsTheWholeDayEvenInANewSession() {
    let log = [F.result(F.at(7, 10), .barred)]
    equal(F.decide(now: F.at(7, 15), log: log, session: F.session(start: F.at(7, 14))), .pause(.possibleCarrierRestriction), "barred.sameDay")
    equal(F.decide(now: F.at(8, 11), log: log, session: F.session(start: F.at(8, 10))), .allowed, "barred.nextDayFree")
}

// MARK: - Complaint signal

@Test func threeDNCAdditionsInADayPause() {
    let now = F.at(7, 15)
    let two = F.dnc([("9000000011", F.at(7, 10)), ("9000000012", F.at(7, 11))])
    equal(F.decide(now: now, dnc: two), .allowed, "dncCount.twoFine")
    let three = F.dnc([("9000000011", F.at(7, 10)), ("9000000012", F.at(7, 11)), ("9000000013", F.at(7, 12))])
    equal(F.decide(now: now, dnc: three), .pause(.tooManyDoNotCallToday(count: 3)), "dncCount.threePause")
    // Yesterday's additions and undated (hand-edited) lines do not count.
    let old = F.dnc([("9000000011", F.at(6, 10)), ("9000000012", F.at(6, 11)), ("9000000013", nil), ("9000000014", F.at(7, 9))])
    equal(F.decide(now: now, dnc: old), .allowed, "dncCount.onlyToday")
}

// MARK: - Wrong SIM

@Test func wrongSIMStopsImmediately() {
    let now = F.at(7, 13)
    let bad = [F.result(F.at(7, 12), .connected, seconds: 30, sim: "SIM-PERSONAL")]
    equal(F.decide(now: now, log: bad, session: F.session(expected: F.sim)),
          .stop(.wrongSIM(expected: F.sim, got: "SIM-PERSONAL")), "sim.wrong")
    let good = [F.result(F.at(7, 12), .connected, seconds: 30, sim: F.sim)]
    equal(F.decide(now: now, log: good, session: F.session(expected: F.sim)), .allowed, "sim.right")
}

@Test func wrongSIMBeatsEveryOtherReasonAndIgnoresOldSessions() {
    let now = F.at(7, 13)
    let log = (0..<3).map { F.result(F.at(7, 12, $0), .noConnect, sim: "OTHER") }
    guard case .stop = F.decide(now: now, log: log, session: F.session(expected: F.sim)) else {
        Issue.record("sim.stopBeatsPause"); return
    }
    // A wrong-SIM call from before this session started is history, not a live problem.
    let old = [F.result(F.at(6, 12), .connected, seconds: 30, sim: "OTHER")]
    equal(F.decide(now: now, log: old, session: F.session(expected: F.sim)), .allowed, "sim.oldSessionIgnored")
}

@Test func unreadableLineAfterACallPausesWhenDetectionIsOn() {
    let now = F.at(7, 13)
    let log = [F.result(F.at(7, 12), .connected, seconds: 30, sim: nil)]
    equal(F.decide(now: now, log: log, session: F.session(expected: F.sim)), .pause(.simUnverified), "sim.unverified")
    // A not-placed dial never made a call, so it has no line and does not pause.
    let notPlaced = [F.result(F.at(7, 12), .notPlaced)]
    equal(F.decide(now: now, log: notPlaced, session: F.session(expected: F.sim)), .allowed, "sim.notPlacedFine")
}

@Test func manualModeNeedsTheChecklistTick() {
    equal(F.decide(session: F.session(confirmed: false)), .blocked(.coldSIMNotConfirmed), "sim.manualUnticked")
    equal(F.decide(session: F.session(confirmed: true)), .allowed, "sim.manualTicked")
    // With detection on, the tick is not required.
    equal(F.decide(session: F.session(expected: F.sim, confirmed: false)), .allowed, "sim.detectionNoTick")
}

// MARK: - Gap and active call

@Test func minimumGapSinceWrapUp() {
    let now = F.at(7, 12, 0, 44)
    let wrap = F.at(7, 12)
    guard case .blocked(.gapNotElapsed(let until)) = F.decide(now: now, session: F.session(lastWrapUp: wrap)) else {
        Issue.record("gap.44s"); return
    }
    equal(until, F.at(7, 12, 0, 45), "gap.until")
    equal(F.decide(now: F.at(7, 12, 0, 45), session: F.session(lastWrapUp: wrap)), .allowed, "gap.exact45")
}

@Test func randomGapStaysInRangeAndHonoursConfig() {
    var gen = SystemRandomNumberGenerator()
    let gaps = (0..<500).map { _ in F.rules.randomGap(using: &gen) }
    expect(gaps.allSatisfy { $0 >= 45 && $0 <= 120 }, "gap.range", "\(gaps.min() ?? 0)-\(gaps.max() ?? 0)")
    expect(Set(gaps.map { Int($0) }).count > 20, "gap.isRandom", "too few distinct values")
    var fixed = DialRules(); fixed.gapMin = 60; fixed.gapMax = 60
    equal(fixed.randomGap(using: &gen), 60, "gap.degenerate")
}

@Test func neverDialsDuringACall() {
    equal(F.decide(session: F.session(callActive: true)), .blocked(.callActive), "active.blocked")
}

@Test func pauseAndStopOutrankPerDialBlocks() {
    // DNC'd number, but the session is paused for failures: the pause is what the user must see.
    let log = (0..<3).map { F.result(F.at(7, 11, $0), .noConnect) }
    equal(F.decide(log: log, dnc: F.dnc([(F.num, nil)])), .pause(.consecutiveFailures(count: 3)), "order.pauseFirst")
}

@Test func blockedReasonsKnowWhetherToSkipOrWait() {
    expect(DialBlock.doNotCall.isLeadSpecific, "skip.dnc")
    expect(DialBlock.cooldown(until: Date()).isLeadSpecific, "skip.cooldown")
    expect(!DialBlock.dailyCapReached(cap: 1, resetsAt: Date()).isLeadSpecific, "wait.cap")
    expect(!DialBlock.outsideCallingHours(opensAt: nil).isLeadSpecific, "wait.hours")
}

// MARK: - Config

@Test func configDialerDefaultsMatchTheSpec() {
    let c = Config()
    equal(c.dailyCap, 30, "cfg.dailyCap")
    equal(c.hourlyCap, 10, "cfg.hourlyCap")
    equal(c.gapSeconds, [45, 120], "cfg.gap")
    equal(c.callingHours, ["10:00", "18:30"], "cfg.hours")
    equal(c.callingDays, [1, 2, 3, 4, 5, 6], "cfg.days")
    equal(c.cooldownDays, 7, "cfg.cooldown")
    equal(c.coldSIM, "", "cfg.coldSIM")
    let r = c.dialRules
    equal(r, DialRules(), "cfg.rulesEqualDefaults")
    equal(r.hoursStart, 36_000, "cfg.hoursStart")
    equal(r.hoursEnd, 66_600, "cfg.hoursEnd")
}

@Test func configDialerKeysAreTolerantAndBadValuesFallBack() throws {
    let partial = try JSONDecoder().decode(Config.self, from: Data(#"{"dailyCap": 12, "language": "en"}"#.utf8))
    equal(partial.dailyCap, 12, "cfg.partialKeeps")
    equal(partial.hourlyCap, 10, "cfg.partialDefaults")
    let bad = try JSONDecoder().decode(Config.self, from: Data(
        #"{"gapSeconds": [200, 10], "callingHours": ["18:30", "10:00"], "callingDays": [9, 0]}"#.utf8))
    let r = bad.dialRules
    equal(r.gapMin, 45, "cfg.badGapFallsBack")
    equal(r.gapMax, 120, "cfg.badGapFallsBackMax")
    equal(r.hoursStart, 36_000, "cfg.badHoursFallBack")
    equal(r.days, [1, 2, 3, 4, 5, 6], "cfg.badDaysFallBack")
    equal(DialRules.secondsOfDay("24:00"), nil, "cfg.hour24")
    equal(DialRules.secondsOfDay("9:05"), 9 * 3600 + 300, "cfg.hourLenient")
    equal(DialRules.secondsOfDay("nope"), nil, "cfg.hourGarbage")
}
