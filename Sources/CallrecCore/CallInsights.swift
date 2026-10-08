import Foundation

/// The three facts about a call that the calendar and the outcome list need.
public struct CallFacts: Equatable, Sendable {
    public var date: Date
    public var seconds: Double
    public var outcome: String
    public init(date: Date, seconds: Double, outcome: String) {
        self.date = date; self.seconds = seconds; self.outcome = outcome
    }
    /// Test calls (the user's own numbers) never count in any statistic.
    public var isTest: Bool { OutcomeBuckets.normalize(outcome) == "test" }
}

/// Month view numbers: calls per day, scaled for a contributions-style heat map.
public enum CallCalendar {
    /// A call this long or longer counts as a connect (same bar as the stats header).
    public static let connectSeconds = 20.0

    public struct Stats: Equatable, Sendable {
        public var calls = 0
        public var connects = 0
        public var booked = 0
        public var talk = 0.0
        /// Test calls seen that day. Not part of `calls`.
        public var tests = 0
        public init() {}
    }

    public struct Month: Equatable, Sendable {
        public var days: [String: Stats] = [:]
        public var totals = Stats()
        /// Most calls on any single day this month: the top of the colour scale.
        public var maxCalls = 0
        public init() {}
    }

    public struct Cell: Equatable, Identifiable, Sendable {
        public var id: String
        /// "yyyy-MM-dd", nil for the padding cells before the 1st and after the last day.
        public var key: String?
        public var dayNumber: Int?
    }

    private static func mondayFirst(_ calendar: Calendar) -> Calendar {
        var c = calendar
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    public static func key(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// Counts the calls that fall in the month containing `month`. Test calls are
    /// counted separately and never in `calls`, `connects`, `booked` or `talk`.
    public static func summarize(_ calls: [CallFacts], month: Date, calendar: Calendar) -> Month {
        let cal = mondayFirst(calendar)
        guard let interval = cal.dateInterval(of: .month, for: month) else { return Month() }
        var out = Month()
        for call in calls where call.date >= interval.start && call.date < interval.end {
            let k = key(call.date, calendar: cal)
            var s = out.days[k] ?? Stats()
            if call.isTest {
                s.tests += 1; out.totals.tests += 1
            } else {
                s.calls += 1; out.totals.calls += 1
                if call.seconds >= connectSeconds {
                    s.connects += 1; out.totals.connects += 1
                    s.talk += call.seconds; out.totals.talk += call.seconds
                }
                if OutcomeBuckets.normalize(call.outcome) == "booked" { s.booked += 1; out.totals.booked += 1 }
            }
            out.days[k] = s
        }
        out.maxCalls = out.days.values.map(\.calls).max() ?? 0
        return out
    }

    /// 0 = no calls, otherwise 1...4 scaled to the busiest day of the month.
    public static func intensity(calls: Int, max top: Int) -> Int {
        guard calls > 0, top > 0 else { return 0 }
        return min(max(Int((Double(calls) / Double(top) * 4).rounded(.up)), 1), 4)
    }

    /// The month as Monday-first weeks of 7 cells, padded with empty cells.
    public static func weeks(month: Date, calendar: Calendar) -> [[Cell]] {
        let cal = mondayFirst(calendar)
        guard let interval = cal.dateInterval(of: .month, for: month),
              let count = cal.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (cal.component(.weekday, from: interval.start) - cal.firstWeekday + 7) % 7
        var cells: [Cell] = (0..<lead).map { Cell(id: "pad-lead-\($0)", key: nil, dayNumber: nil) }
        for d in 0..<count {
            let date = cal.date(byAdding: .day, value: d, to: interval.start) ?? interval.start
            let k = key(date, calendar: cal)
            cells.append(Cell(id: k, key: k, dayNumber: d + 1))
        }
        var tail = 0
        while cells.count % 7 != 0 { cells.append(Cell(id: "pad-tail-\(tail)", key: nil, dayNumber: nil)); tail += 1 }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// First day of the month `by` months away.
    public static func shift(_ month: Date, by months: Int, calendar: Calendar) -> Date {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        return calendar.date(byAdding: .month, value: months, to: start) ?? start
    }
}

/// Puts every call in exactly one outcome bucket.
public enum OutcomeBuckets {
    /// The bucket key of calls with no outcome, or one this build does not know.
    public static let untagged = ""

    public static func normalize(_ outcome: String) -> String {
        outcome.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `known` is the list of outcome names. Anything else (blank, a typo, an outcome from a
    /// newer build) is untagged: the call is still counted and still listed, never dropped.
    public static func bucket(for outcome: String, known: [String]) -> String {
        let n = normalize(outcome)
        return known.contains(n) ? n : untagged
    }

    /// Counts per bucket. Every known name and `untagged` is present (0 when empty), and the
    /// counts add up to `outcomes.count`.
    public static func counts(_ outcomes: [String], known: [String]) -> [String: Int] {
        var out: [String: Int] = [untagged: 0]
        for k in known { out[k] = 0 }
        for o in outcomes { out[bucket(for: o, known: known), default: 0] += 1 }
        return out
    }
}
