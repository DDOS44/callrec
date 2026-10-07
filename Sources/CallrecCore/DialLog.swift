import Foundation

/// How a dial ended.
public enum DialResult: String, Codable, Sendable {
    /// macOS never started the call (confirmation not clicked, no signal, ...). Not a carrier signal.
    case notPlaced = "not-placed"
    /// The call was placed but did not connect (busy, unreachable, rejected).
    case noConnect = "no-connect"
    /// The call connected; `seconds` is how long it lasted.
    case connected
    /// Call history or the operator said the call is barred / not allowed.
    case barred
}

/// One line of `~/.callrec/dial-log.jsonl`. Two kinds, because the cap must count a
/// dial the moment it is made, even if the app dies before the call ends:
/// - `attempt`: written right before the `tel:` URL is opened.
/// - `result`: written when the call ends or the dial fails; `attemptID` links it back.
public struct DialLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case attempt, result }

    public var kind: Kind
    public var ts: Date
    public var attemptID: String
    public var list: String
    public var leadID: String
    /// 10-digit number key (see PhoneNumber).
    public var key: String
    public var result: DialResult?
    public var seconds: Int?
    public var outcome: String?
    /// The line/SIM value read from call history for this call, nil when unknown.
    public var sim: String?

    public init(kind: Kind, ts: Date, attemptID: String, list: String, leadID: String, key: String,
                result: DialResult? = nil, seconds: Int? = nil, outcome: String? = nil, sim: String? = nil) {
        self.kind = kind; self.ts = ts; self.attemptID = attemptID; self.list = list
        self.leadID = leadID; self.key = key; self.result = result
        self.seconds = seconds; self.outcome = outcome; self.sim = sim
    }

    public static func attempt(at ts: Date, id: String = UUID().uuidString, list: String, leadID: String,
                               key: String) -> DialLogEntry {
        DialLogEntry(kind: .attempt, ts: ts, attemptID: id, list: list, leadID: leadID, key: key)
    }

    public func finished(at ts: Date, result: DialResult, seconds: Int? = nil, outcome: String? = nil,
                         sim: String? = nil) -> DialLogEntry {
        DialLogEntry(kind: .result, ts: ts, attemptID: attemptID, list: list, leadID: leadID, key: key,
                     result: result, seconds: seconds, outcome: outcome, sim: sim)
    }
}

/// Reader and writer for the dial log. The app is the only writer.
public enum DialLog {

    public struct Loaded: Equatable, Sendable {
        public var entries: [DialLogEntry]
        /// Lines that could not be parsed. They are kept in the file (never rewritten or
        /// deleted) and counted here so the caller can show a warning.
        public var skipped: Int
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]  // compact: one line per entry
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func append(_ entry: DialLogEntry, to url: URL = DialerPaths.dialLog) throws {
        let data = try encoder().encode(entry)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "callrec", code: 40, userInfo: [NSLocalizedDescriptionKey: "dial log entry is not UTF-8"])
        }
        try AppendLog.append(line, to: url)
    }

    /// Every parseable entry, in file order. A missing file is an empty log. An
    /// unparseable line is skipped, logged and counted, never dropped silently.
    public static func load(from url: URL = DialerPaths.dialLog) throws -> Loaded {
        var entries: [DialLogEntry] = []
        var skipped = 0
        let dec = decoder()
        for line in try AppendLog.lines(url) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            do { entries.append(try dec.decode(DialLogEntry.self, from: Data(line.utf8))) }
            catch {
                skipped += 1
                logError("dial log: skipped an unreadable line in \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return Loaded(entries: entries, skipped: skipped)
    }
}
