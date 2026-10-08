import Foundation

/// Calls that were dialled but never wrapped up — because the app quit, crashed or was
/// relaunched mid-session (2026-10-08: a relaunch at the end of a live test call left the
/// call with no wrap-up and the session looked like it "stopped by itself"). On launch the
/// dialer offers to finish each one, so a restart can never eat a call's notes.
public enum DialRecovery {

    public struct Unfinished: Equatable, Sendable, Identifiable {
        public var attempt: DialLogEntry
        /// Start of the recording that began just after the dial, if one exists.
        public var recordingStart: Date?
        public var id: String { attempt.attemptID }
    }

    /// Attempts with no result entry, newest first, no older than `window`.
    /// `excluding` is the attempt the live session is working on right now.
    public static func unfinished(log: [DialLogEntry], now: Date, window: TimeInterval = 6 * 3600,
                                  excluding live: String? = nil) -> [DialLogEntry] {
        let finished = Set(log.filter { $0.kind == .result }.map(\.attemptID))
        return log
            .filter { $0.kind == .attempt && !finished.contains($0.attemptID) && $0.attemptID != live }
            .filter { $0.ts <= now && now.timeIntervalSince($0.ts) <= window }
            .sorted { $0.ts > $1.ts }
    }

    /// What to do with the orphaned attempts of this list.
    public struct Triage: Equatable, Sendable {
        /// Cards to show: have a recording, at most one per lead (the newest).
        public var offer: [Unfinished]
        /// Attempts with no recording that are old enough to be certain the call never happened.
        public var close: [DialLogEntry]
    }

    /// Only an attempt with a matching recording can have a wrap-up to finish. One without a
    /// recording, older than `grace`, is closed (not placed) instead of shown; a younger one is
    /// left alone, since the call may still be about to start. One card per lead.
    public static func triage(_ items: [Unfinished], now: Date, grace: TimeInterval = 150) -> Triage {
        var offer: [Unfinished] = [], close: [DialLogEntry] = []
        var seenLeads = Set<String>()
        for item in items.sorted(by: { $0.attempt.ts > $1.attempt.ts }) {
            if item.recordingStart == nil {
                if now.timeIntervalSince(item.attempt.ts) >= grace { close.append(item.attempt) }
            } else if seenLeads.insert(item.attempt.leadID).inserted {
                offer.append(item)
            }
        }
        return Triage(offer: offer, close: close)
    }

    /// The recording that started within `maxDelay` after the dial (the user has to click
    /// Call and the other side has to answer). Earliest match wins; nil if none.
    public static func recording(after dial: Date, starts: [Date], maxDelay: TimeInterval = 300) -> Date? {
        starts.filter { $0 >= dial.addingTimeInterval(-5) && $0.timeIntervalSince(dial) <= maxDelay }.min()
    }

    /// Start times of recordings on disk for the day of `date` (file names are HH-mm-ss).
    public static func recordingStarts(on date: Date, root: URL, calendar: Calendar = .current) -> [Date] {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.calendar = calendar; day.timeZone = calendar.timeZone
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"; stamp.calendar = calendar; stamp.timeZone = calendar.timeZone
        let name = day.string(from: date)
        return Fs.list(root.appendingPathComponent(name))
            .filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".far.caf") || $0.hasSuffix(".far.wav") }
            .compactMap { file in String(file.prefix(8)) }
            .compactMap { stamp.date(from: "\(name) \($0)") }
            .reduce(into: [Date]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
