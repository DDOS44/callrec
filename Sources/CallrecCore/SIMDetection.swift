import Foundation

/// One row of the macOS call history, as much as the dialer needs.
public struct HistoryCall: Equatable, Sendable {
    /// Last-10-digit key of the other party.
    public var key: String
    public var date: Date
    public var seconds: Int
    /// nil when the database has no "originated" column.
    public var originated: Bool?
    /// Values of the candidate line/SIM columns, by column name. Empty string = null.
    public var values: [String: String]

    public init(key: String, date: Date, seconds: Int, originated: Bool? = nil, values: [String: String] = [:]) {
        self.key = key; self.date = date; self.seconds = seconds
        self.originated = originated; self.values = values
    }
}

/// What the call-history database can tell us about which line (SIM) a call used.
public enum SIMDetection: Equatable, Sendable {
    /// `column` identifies the line. `values` are the distinct values seen, most recent first.
    case available(column: String, values: [LineValue])
    /// No column is trustworthy. The dialer falls back to the manual pre-flight checklist.
    case unavailable(reason: String)

    public var column: String? {
        if case .available(let c, _) = self { return c }
        return nil
    }
}

public struct LineValue: Equatable, Sendable {
    public var value: String
    public var count: Int
    public var lastSeen: Date
}

/// Finds the call-history column that says which SIM a call used, and reads it.
///
/// We cannot read the real database from a dev shell, so discovery is defensive: look at
/// every column whose name hints at a line, then trust one only if its values behave like
/// a SIM identifier (repeat across calls, more than one value, not a per-call id, not an
/// app/provider name, not a place). When nothing passes, the dialer uses the manual checklist.
public enum SIMDetector {

    /// Name fragments worth looking at.
    static let hints = ["SIM", "SERVICE_PROVIDER", "LOCATION", "UNIQUE_ID", "LINE", "ACCOUNT", "HANDLE"]
    /// Trust order among passing columns: the more SIM-like the name, the earlier.
    static let trustOrder = ["SIM", "LINE", "ACCOUNT", "SERVICE_PROVIDER", "HANDLE", "UNIQUE_ID"]
    /// How many distinct values a line column may have: nobody has dozens of SIMs.
    static let maxDistinctValues = 8

    /// Columns whose names contain a hint. Names are checked so they are safe to put in SQL.
    public static func candidateColumns(_ columns: [CallHistory.Column]) -> [String] {
        columns.map(\.name).filter { name in
            name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
                && hints.contains { name.uppercased().contains($0) }
        }
    }

    public static func analyze(candidates: [String], rows: [HistoryCall]) -> SIMDetection {
        guard !candidates.isEmpty else {
            return .unavailable(reason: "the call history has no column named like a SIM or line")
        }
        // Outgoing calls only when the database says which are outgoing.
        let outgoing = rows.contains { $0.originated != nil } ? rows.filter { $0.originated == true } : rows
        guard outgoing.count >= 3 else {
            return .unavailable(reason: "not enough recent outgoing calls (\(outgoing.count)) to tell which column identifies the SIM")
        }
        var why: [String] = []
        var passing: [(name: String, values: [LineValue])] = []
        for name in candidates {
            switch assess(name, rows: outgoing) {
            case .usable(let values): passing.append((name, values))
            case .rejected(let reason): why.append("\(name): \(reason)")
            }
        }
        let ranked = passing.sorted { rank($0.name) < rank($1.name) }
        if let best = ranked.first { return .available(column: best.name, values: best.values) }
        return .unavailable(reason: "no candidate column looks like a SIM identifier (" + why.joined(separator: "; ") + ")")
    }

    private enum Assessment { case usable([LineValue]), rejected(String) }

    private static func assess(_ name: String, rows: [HistoryCall]) -> Assessment {
        let upper = name.uppercased()
        // The callee's place, not our SIM.
        if upper.contains("LOCATION") { return .rejected("describes the other party's location, never trusted as a SIM") }
        let filled = rows.compactMap { r -> (String, Date)? in
            guard let v = r.values[name], !v.isEmpty else { return nil }
            return (v, r.date)
        }
        guard filled.count * 2 >= rows.count else { return .rejected("empty on most calls") }
        let distinct = Set(filled.map(\.0))
        guard distinct.count >= 2 else { return .rejected("only one value across all calls, cannot tell SIMs apart") }
        guard distinct.count < filled.count else { return .rejected("a different value on every call (a per-call id)") }
        guard distinct.count <= maxDistinctValues else { return .rejected("too many distinct values (\(distinct.count))") }
        // App or provider names ("com.apple.Telephony" vs "com.apple.FaceTime") say the app, not the SIM.
        if distinct.allSatisfy({ $0.lowercased().hasPrefix("com.apple.") }) {
            return .rejected("values are app/provider names, not a SIM")
        }
        var info: [String: (count: Int, last: Date)] = [:]
        for (value, date) in filled {
            let old = info[value] ?? (0, .distantPast)
            info[value] = (old.count + 1, max(old.last, date))
        }
        let values = info.map { LineValue(value: $0.key, count: $0.value.count, lastSeen: $0.value.last) }
            .sorted { $0.lastSeen > $1.lastSeen }
        return .usable(values)
    }

    private static func rank(_ name: String) -> Int {
        let upper = name.uppercased()
        return trustOrder.firstIndex { upper.contains($0) } ?? trustOrder.count
    }

    /// The line a specific call used: the row for `key` closest to `dialedAt` within a window
    /// after the dial (call history stamps the call when it starts). nil when no row matches,
    /// or the row has no value in `column`.
    public static func line(forNumber key: String, dialedAt: Date, rows: [HistoryCall], column: String,
                            window: TimeInterval = 180) -> String? {
        let match = rows
            .filter { $0.key == key && $0.date >= dialedAt.addingTimeInterval(-30) && $0.date <= dialedAt.addingTimeInterval(window) }
            .min { abs($0.date.timeIntervalSince(dialedAt)) < abs($1.date.timeIntervalSince(dialedAt)) }
        guard let value = match?.values[column], !value.isEmpty else { return nil }
        return value
    }

    /// The call-history row for a dial, whether or not it carries a line value.
    public static func call(forNumber key: String, dialedAt: Date, rows: [HistoryCall], window: TimeInterval = 180) -> HistoryCall? {
        rows.filter { $0.key == key && $0.date >= dialedAt.addingTimeInterval(-30) && $0.date <= dialedAt.addingTimeInterval(window) }
            .min { abs($0.date.timeIntervalSince(dialedAt)) < abs($1.date.timeIntervalSince(dialedAt)) }
    }

    /// Plain-language log lines about what was found. Column names and counts only: values
    /// can be identifiers of the user's SIMs and the log is public.
    public static func summary(_ detection: SIMDetection, candidates: [String]) -> String {
        let found = candidates.isEmpty ? "none" : candidates.joined(separator: ", ")
        switch detection {
        case .available(let column, let values):
            return "sim: candidate columns [\(found)]; using \(column) with \(values.count) distinct values"
        case .unavailable(let reason):
            return "sim: candidate columns [\(found)]; no usable column, manual checklist applies: \(reason)"
        }
    }
}
