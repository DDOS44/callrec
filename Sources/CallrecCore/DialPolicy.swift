import Foundation

/// Why a dial is refused right now. The lead (or the moment) is not the problem
/// for the session as a whole: the session waits or skips and asks again.
public enum DialBlock: Equatable, Sendable {
    case callActive
    case invalidNumber
    case doNotCall
    /// Dialled or called within the cooldown; `until` is when the number is free again.
    case cooldown(until: Date)
    /// Outside calling hours or days; `opensAt` is the next opening (nil if no day is allowed).
    case outsideCallingHours(opensAt: Date?)
    case dailyCapReached(cap: Int, resetsAt: Date)
    case hourlyCapReached(cap: Int, freeAt: Date)
    /// The minimum gap since wrap-up has not passed.
    case gapNotElapsed(until: Date)
    /// No SIM column on this Mac and the manual "default voice line is the cold SIM" tick is missing.
    case coldSIMNotConfirmed

    public var message: String {
        switch self {
        case .callActive: return "A call is active. The dialer never dials during a call."
        case .invalidNumber: return "This lead has no valid 10-digit number."
        case .doNotCall: return "Number is on the do-not-call list."
        case .cooldown(let until): return "Called within the cooldown window. Free again \(Self.describe(until))."
        case .outsideCallingHours(let opens):
            return opens.map { "Outside calling hours. Opens \(Self.describe($0))." } ?? "No calling day is enabled."
        case .dailyCapReached(let cap, let resets): return "Daily cap of \(cap) dials reached. Resets \(Self.describe(resets))."
        case .hourlyCapReached(let cap, let free): return "Hourly cap of \(cap) dials reached. Free \(Self.describe(free))."
        case .gapNotElapsed(let until): return "Minimum gap between calls not over. Free \(Self.describe(until))."
        case .coldSIMNotConfirmed: return "Confirm the cold SIM is the default voice line."
        }
    }

    /// When this block clears by itself, if it does.
    public var clearsAt: Date? {
        switch self {
        case .cooldown(let d), .dailyCapReached(_, let d), .hourlyCapReached(_, let d), .gapNotElapsed(let d): return d
        case .outsideCallingHours(let d): return d
        case .callActive, .invalidNumber, .doNotCall, .coldSIMNotConfirmed: return nil
        }
    }

    /// True when only this lead is the problem (skip it); false when it is the whole session's moment (wait).
    public var isLeadSpecific: Bool {
        switch self {
        case .invalidNumber, .doNotCall, .cooldown: return true
        default: return false
        }
    }

    static func describe(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The session must pause: a human has to look and press Resume.
public enum DialPause: Equatable, Sendable {
    case consecutiveFailures(count: Int)
    case tooManyDoNotCallToday(count: Int)
    /// A call today was barred / not allowed. Stop for today.
    case possibleCarrierRestriction
    /// SIM detection is on but the last call's line could not be read.
    case simUnverified
    /// The recorder (the only reader of call history) did not answer.
    case historyUnavailable

    public var message: String {
        switch self {
        case .consecutiveFailures(let n): return "\(n) dials in a row did not connect or were very short. Possible carrier restriction. Check before continuing."
        case .tooManyDoNotCallToday(let n): return "\(n) numbers were added to do-not-call today. Complaint risk. Pause and review."
        case .possibleCarrierRestriction: return "A call was barred or not allowed. Possible carrier restriction: stop for today."
        case .simUnverified: return "Could not read which line the last call used. Check the SIM before continuing."
        case .historyUnavailable: return "Call history is unavailable: the background recorder did not answer. Check that it is running (menu bar), then resume."
        }
    }
}

/// The session must stop immediately.
public enum DialStop: Equatable, Sendable {
    case wrongSIM(expected: String, got: String)

    public var message: String {
        switch self {
        case .wrongSIM: return "A call went out on the wrong line. Session stopped. Fix the default voice line before dialing again."
        }
    }
}

public enum DialDecision: Equatable, Sendable {
    case allowed
    case blocked(DialBlock)
    case pause(DialPause)
    case stop(DialStop)

    public var isAllowed: Bool { self == .allowed }
}

/// What the session knows that is not in a log or a list.
public struct DialSessionFacts: Equatable, Sendable {
    /// When this session started. Failure streaks only count results from this session.
    public var start: Date
    /// A call is live right now (state.json says recording).
    public var callActive: Bool
    /// When the last wrap-up was saved; nil before the first call of the session.
    public var lastWrapUpEnd: Date?
    /// The cold SIM's line value, or nil when the Mac gives no line column and the manual checklist applies.
    public var expectedSIM: String?
    /// In manual mode: the user ticked "default voice line = cold SIM" this session.
    public var manualSIMConfirmed: Bool

    public init(start: Date, callActive: Bool = false, lastWrapUpEnd: Date? = nil,
                expectedSIM: String? = nil, manualSIMConfirmed: Bool = false) {
        self.start = start; self.callActive = callActive; self.lastWrapUpEnd = lastWrapUpEnd
        self.expectedSIM = expectedSIM; self.manualSIMConfirmed = manualSIMConfirmed
    }
}

/// Every guardrail, in one pure function. Input: rules, the clock, the dial log, the
/// DNC list and the call-history cooldown set. Output: may we dial this number now?
/// No file, clock or UI access, so each guardrail has a unit test at its boundary.
public enum DialPolicy {

    /// Order matters. Session-level problems (stop, pause) come before per-dial blocks,
    /// because a paused session must stay paused no matter what the next lead looks like.
    public static func evaluate(number: String, now: Date, rules: DialRules, log: [DialLogEntry],
                                dnc: DNCList, history: [String: Date], session: DialSessionFacts,
                                calendar: Calendar = .current) -> DialDecision {
        if let stop = stopReason(log: log, session: session) { return .stop(stop) }
        if let pause = pauseReason(now: now, rules: rules, log: log, dnc: dnc, session: session, calendar: calendar) {
            return .pause(pause)
        }
        if session.callActive { return .blocked(.callActive) }
        guard let key = PhoneNumber.normalize(number) ?? PhoneNumber.key(number) else { return .blocked(.invalidNumber) }
        if dnc.contains(number) { return .blocked(.doNotCall) }
        // The user's own test numbers skip cooldown, hours and caps. Everything else
        // (active call, DNC, SIM confirmation, pauses, stops) still applies.
        let isTest = rules.testKeys.contains(key)
        if !isTest {
            if let until = cooldownEnd(key: key, now: now, rules: rules, log: log, history: history) { return .blocked(.cooldown(until: until)) }
            if let block = hoursBlock(now: now, rules: rules, calendar: calendar) { return .blocked(block) }
            if let block = capBlock(now: now, rules: rules, log: log, calendar: calendar) { return .blocked(block) }
        }
        if let last = session.lastWrapUpEnd {
            let until = last.addingTimeInterval(isTest ? rules.testGapMin : rules.gapMin)
            if now < until { return .blocked(.gapNotElapsed(until: until)) }
        }
        if session.expectedSIM == nil, !session.manualSIMConfirmed { return .blocked(.coldSIMNotConfirmed) }
        return .allowed
    }

    // MARK: - Stop / pause

    /// The most recent finished call of this session (not-placed excluded: no call, no line).
    static func lastRealResult(log: [DialLogEntry], since start: Date) -> DialLogEntry? {
        log.last { $0.kind == .result && $0.ts >= start && $0.result != .notPlaced && $0.result != nil }
    }

    public static func stopReason(log: [DialLogEntry], session: DialSessionFacts) -> DialStop? {
        guard let expected = session.expectedSIM, !expected.isEmpty,
              let last = lastRealResult(log: log, since: session.start),
              let got = last.sim, !got.isEmpty, got != expected else { return nil }
        return .wrongSIM(expected: expected, got: got)
    }

    public static func pauseReason(now: Date, rules: DialRules, log: [DialLogEntry], dnc: DNCList,
                                   session: DialSessionFacts, calendar: Calendar) -> DialPause? {
        // Barred / not allowed: stop for the day, whichever session saw it.
        if log.contains(where: { $0.kind == .result && $0.result == .barred && calendar.isDate($0.ts, inSameDayAs: now) }) {
            return .possibleCarrierRestriction
        }
        let streak = trailingFailures(log: log, since: session.start, rules: rules)
        if streak >= rules.failurePauseCount { return .consecutiveFailures(count: streak) }
        let dncToday = dnc.addedToday(now: now, calendar: calendar)
        if dncToday >= rules.dncPausePerDay { return .tooManyDoNotCallToday(count: dncToday) }
        if session.expectedSIM != nil, let last = lastRealResult(log: log, since: session.start),
           last.sim == nil || last.sim?.isEmpty == true {
            return .simUnverified
        }
        return nil
    }

    /// Consecutive failed results at the end of this session's log. Failed = placed but did
    /// not connect, or connected for fewer than `shortCallSeconds`. A real call resets the
    /// streak; a not-placed dial neither counts nor resets it (it is not a carrier signal).
    public static func trailingFailures(log: [DialLogEntry], since start: Date, rules: DialRules) -> Int {
        var n = 0
        for e in log.reversed() where e.kind == .result && e.ts >= start {
            guard let result = e.result, result != .notPlaced else { continue }
            let failed = result == .noConnect || result == .barred
                || (result == .connected && (e.seconds ?? 0) < rules.shortCallSeconds)
            if failed { n += 1 } else { break }
        }
        return n
    }

    // MARK: - Per-dial blocks

    /// When `key` is next free, or nil if it is free now. Uses the dial log (attempts) and
    /// the call-history map (key -> most recent call time). Free again at exactly `cooldownDays`.
    static func cooldownEnd(key: String, now: Date, rules: DialRules, log: [DialLogEntry],
                            history: [String: Date]) -> Date? {
        let window = TimeInterval(rules.cooldownDays) * 86_400
        // A dial that never placed a call (macOS did not start it) did not ring the number,
        // so it does not start a cooldown. It still counts against the caps.
        let notPlaced = Set(log.filter { $0.kind == .result && $0.result == .notPlaced }.map(\.attemptID))
        let lastDial = log.filter { $0.kind == .attempt && $0.key == key && !notPlaced.contains($0.attemptID) }.map(\.ts).max()
        let last = [lastDial, history[key]].compactMap { $0 }.max()
        guard let last else { return nil }
        let free = last.addingTimeInterval(window)
        return now < free ? free : nil
    }

    static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    static func secondsOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 3600
            + calendar.component(.minute, from: date) * 60
            + calendar.component(.second, from: date)
    }

    static func hoursBlock(now: Date, rules: DialRules, calendar: Calendar) -> DialBlock? {
        let sec = secondsOfDay(now, calendar)
        if rules.days.contains(isoWeekday(now, calendar)), sec >= rules.hoursStart, sec < rules.hoursEnd { return nil }
        return .outsideCallingHours(opensAt: nextOpening(after: now, rules: rules, calendar: calendar))
    }

    /// The next moment dialing opens: today's start if it is still ahead, else the next allowed day's start.
    static func nextOpening(after now: Date, rules: DialRules, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  rules.days.contains(isoWeekday(day, calendar)),
                  let open = calendar.date(byAdding: .second, value: rules.hoursStart, to: day),
                  open > now else { continue }
            return open
        }
        return nil
    }

    static func capBlock(now: Date, rules: DialRules, log: [DialLogEntry], calendar: Calendar) -> DialBlock? {
        // Test dials to the user's own numbers never count against the real caps.
        let attempts = log.filter { $0.kind == .attempt && !rules.testKeys.contains($0.key) }
        let today = attempts.filter { calendar.isDate($0.ts, inSameDayAs: now) }
        if today.count >= rules.dailyCap {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            return .dailyCapReached(cap: rules.dailyCap, resetsAt: tomorrow)
        }
        // Rolling hour: an attempt exactly 60 minutes ago no longer counts.
        let windowStart = now.addingTimeInterval(-3600)
        let recent = attempts.map(\.ts).filter { $0 > windowStart && $0 <= now }.sorted()
        if recent.count >= rules.hourlyCap {
            // Free when enough old attempts have aged out to get back under the cap.
            let freeing = recent.count - rules.hourlyCap
            let free = (recent.indices.contains(freeing) ? recent[freeing] : now).addingTimeInterval(3600)
            return .hourlyCapReached(cap: rules.hourlyCap, freeAt: free)
        }
        return nil
    }
}
