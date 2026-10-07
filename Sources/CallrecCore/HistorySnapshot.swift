import Foundation

/// Recent call-history rows plus what SIM detection made of them.
public struct HistorySnapshot: Equatable, Sendable {
    public var rows: [HistoryCall]
    public var detection: SIMDetection

    public init(rows: [HistoryCall], detection: SIMDetection) {
        self.rows = rows
        self.detection = detection
    }

    /// Latest outgoing call time per number key: the call-history half of the cooldown.
    public var lastCallByKey: [String: Date] {
        var out: [String: Date] = [:]
        for r in rows where r.originated != false { out[r.key] = max(out[r.key] ?? .distantPast, r.date) }
        return out
    }

    public func line(forNumber key: String, dialedAt: Date) -> String? {
        guard let column = detection.column else { return nil }
        return SIMDetector.line(forNumber: key, dialedAt: dialedAt, rows: rows, column: column)
    }
}

extension CallHistory {
    /// Reads the schema and recent rows. Throws when the database cannot be read (no Full Disk Access).
    public static func snapshot(limit: Int = 300) throws -> HistorySnapshot {
        let cols = try columns()
        let candidates = SIMDetector.candidateColumns(cols)
        let rows = try calls(candidateColumns: candidates, limit: limit, hasOriginated: cols.contains { $0.name == "ZORIGINATED" })
        return HistorySnapshot(rows: rows, detection: SIMDetector.analyze(candidates: candidates, rows: rows))
    }
}
