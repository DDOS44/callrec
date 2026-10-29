import Foundation

/// Calls FROM leads: a prospect ringing back after a no-connect. Found in call history by matching
/// every lead number (main + alts). A call we placed is not a callback: history says so directly
/// when it records the direction; when it does not, a call within 3 minutes of one of our dials to
/// that number is taken as ours. Talked (>= `talkedSeconds`) = a conversation happened; 0 s = missed.
public enum Callbacks {
    public struct Item: Equatable, Sendable, Identifiable {
        public var leadID: String
        public var number: String
        public var date: Date
        public var seconds: Int
        public var missed: Bool { seconds == 0 }
        /// A real conversation: 20 s or more. Shorter (voicemail, a quick hang-up) still needs a call back.
        public var talked: Bool { seconds >= 20 }
        public var id: String { "\(leadID)@\(Int(date.timeIntervalSince1970))" }
    }

    public static func find(history: [HistoryCall], leads: [Lead], log: [DialLogEntry], since: Date) -> [Item] {
        var owner: [String: String] = [:]
        for lead in leads { for n in AltNumbers.allNumbers(of: lead) where owner[n] == nil { owner[n] = lead.id } }
        let ourDials = log.filter { $0.kind == .attempt }
        return history.compactMap { row -> Item? in
            guard row.date >= since, let lead = owner[row.key] else { return nil }
            if row.originated == true { return nil }
            if row.originated == nil {
                let ours = ourDials.contains { DialPolicy.logKey($0) == row.key && abs($0.ts.timeIntervalSince(row.date)) <= 180 }
                if ours { return nil }
            }
            return Item(leadID: lead, number: row.key, date: row.date, seconds: row.seconds)
        }
        .sorted { $0.date > $1.date }
    }
}
