import Foundation

/// The do-not-call list: `~/.callrec/dnc.txt`. Append-only and never auto-removed.
/// One entry per line: `<10-digit key>  # <ISO8601 time added>`. A bare key is valid
/// (a hand-edited file); comments after `#` are optional.
public struct DNCList: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var addedAt: Date?
    }

    public private(set) var entries: [Entry]
    public private(set) var keys: Set<String>
    /// Non-blank lines that were not a number. Kept in the file; counted so the app can warn.
    public let unreadable: Int

    public init(entries: [Entry] = [], unreadable: Int = 0) {
        self.entries = entries
        self.keys = Set(entries.map(\.key))
        self.unreadable = unreadable
    }

    /// True when `number` (any format, any country code) matches a listed key.
    public func contains(_ number: String) -> Bool {
        guard let k = PhoneNumber.key(number) else { return false }
        return keys.contains(k)
    }

    /// Entries added on the same calendar day as `now`.
    public func addedToday(now: Date, calendar: Calendar) -> Int {
        entries.filter { $0.addedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }.count
    }

    // MARK: - File

    public static func load(from url: URL = DialerPaths.dnc) throws -> DNCList {
        var entries: [Entry] = []
        var bad = 0
        for raw in try AppendLog.lines(url) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = PhoneNumber.key(String(parts[0])) else {
                bad += 1
                logError("dnc: unreadable line in \(url.lastPathComponent) (kept, treated as no number)")
                continue
            }
            let when = parts.count > 1 ? ISO8601DateFormatter().date(from: parts[1].trimmingCharacters(in: .whitespaces)) : nil
            entries.append(Entry(key: key, addedAt: when))
        }
        return DNCList(entries: entries, unreadable: bad)
    }

    public enum AddError: Error, LocalizedError {
        case notANumber(String)
        public var errorDescription: String? {
            switch self {
            case .notANumber: return "That is not a phone number with at least 10 digits, so it was not added to the do-not-call list."
            }
        }
    }

    /// Adds a number to the file. Idempotent: a number already listed is not written again
    /// (returns false). Throws if it is not a number or the write fails; the caller must show that.
    @discardableResult
    public static func add(_ number: String, now: Date = Date(), to url: URL = DialerPaths.dnc) throws -> Bool {
        guard let key = PhoneNumber.key(number) else { throw AddError.notANumber(number) }
        if try load(from: url).keys.contains(key) { return false }
        try AppendLog.append("\(key)  # \(ISO8601DateFormatter().string(from: now))", to: url)
        return true
    }
}
