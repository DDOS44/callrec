import Foundation

/// The no-connect retry cadence. A lead that rang out is not dead: most B2B prospects are reached
/// on a later attempt, at a different time of day. Researched defaults (2026-10-29):
/// - 4 tries per lead in all (HubSpot 2025: 55% of daily callers make 3-5 attempts); each try rings
///   all of the lead's numbers (alt fallback);
/// - at most one try per lead per calling day, with growing gaps: +1, +2, +4 calling days;
/// - each retry suggests a part of the day not yet tried for that lead.
/// A "try" is a calling day with at least one placed dial to the lead, read from the dial log, so
/// it needs no extra state and covers calls made before this existed.
public enum RetryPlan {

    public enum Window: Int, CaseIterable, Sendable, Comparable {
        case morning, midday, late
        public static func < (a: Window, b: Window) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .morning: return "morning (10:00–12:30)"
            case .midday: return "midday (12:30–15:30)"
            case .late: return "late (15:30–18:30)"
            }
        }
        public var short: String {
            switch self { case .morning: return "morning"; case .midday: return "midday"; case .late: return "late" }
        }
        public static func of(_ date: Date, calendar: Calendar) -> Window {
            let m = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            if m < 12 * 60 + 30 { return .morning }
            if m < 15 * 60 + 30 { return .midday }
            return .late
        }
    }

    public struct Schedule: Equatable, Sendable {
        /// Calling days to wait after try 1, 2, 3...; the last value repeats.
        public var gaps: [Int] = [1, 2, 4]
        public var maxTries = 4
        public init() {}
    }

    public enum State: Equatable, Sendable {
        /// Never dialled, or its last outcome was not a no-connect: not a retry.
        case none
        case due(tries: Int, lastCalled: Date, suggested: Window)
        case waiting(until: Date, tries: Int, lastCalled: Date, suggested: Window)
        case exhausted(tries: Int, lastCalled: Date)

        public var isDue: Bool { if case .due = self { return true } else { return false } }
        public var tries: Int {
            switch self {
            case .none: return 0
            case .due(let t, _, _), .waiting(_, let t, _, _), .exhausted(let t, _): return t
            }
        }
    }

    /// `attempts`: placed dials to the lead (any of its numbers). Only a no-answer lead retries.
    public static func state(attempts: [Date], status: LeadStatus, now: Date, calendar: Calendar,
                             callingDays: Set<Int>, schedule: Schedule = Schedule()) -> State {
        guard status == .noAnswer, let last = attempts.max() else { return .none }
        let days = Set(attempts.map { calendar.startOfDay(for: $0) })
        let tries = days.count
        let suggested = suggestedWindow(attempts: attempts, calendar: calendar)
        if tries >= schedule.maxTries { return .exhausted(tries: tries, lastCalled: last) }
        let gap = schedule.gaps.isEmpty ? 1 : schedule.gaps[min(tries - 1, schedule.gaps.count - 1)]
        let dueDay = addCallingDays(gap, to: calendar.startOfDay(for: last), calendar: calendar, callingDays: callingDays)
        if now >= dueDay { return .due(tries: tries, lastCalled: last, suggested: suggested) }
        return .waiting(until: dueDay, tries: tries, lastCalled: last, suggested: suggested)
    }

    /// The first part of the day (in order, starting after the latest one used) not yet tried.
    /// When all three were tried, the one tried least, ties going to the earliest.
    static func suggestedWindow(attempts: [Date], calendar: Calendar) -> Window {
        var firstPerDay: [Date: Date] = [:]
        for a in attempts {
            let d = calendar.startOfDay(for: a)
            if let cur = firstPerDay[d] { if a < cur { firstPerDay[d] = a } } else { firstPerDay[d] = a }
        }
        let used = firstPerDay.values.sorted().map { Window.of($0, calendar: calendar) }
        guard let lastUsed = used.last else { return .morning }
        let order = (1...3).map { Window(rawValue: (lastUsed.rawValue + $0) % 3)! }
        if let fresh = order.first(where: { !used.contains($0) }) { return fresh }
        let counts = Dictionary(grouping: used, by: { $0 }).mapValues(\.count)
        return Window.allCases.min { (counts[$0] ?? 0, $0.rawValue) < (counts[$1] ?? 0, $1.rawValue) } ?? .morning
    }

    /// `n` calling days after `day` (Sundays and other off days are skipped).
    static func addCallingDays(_ n: Int, to day: Date, calendar: Calendar, callingDays: Set<Int>) -> Date {
        var d = day, left = max(n, 0)
        var guardSteps = 0
        while left > 0 && guardSteps < 60 {
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
            if callingDays.isEmpty || callingDays.contains(DialPolicy.isoWeekday(d, calendar)) { left -= 1 }
            guardSteps += 1
        }
        return d
    }
}
