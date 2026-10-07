import Foundation

/// Only the signed daemon holds Full Disk Access, so only the daemon reads call history.
/// The app asks through a mailbox of small files under `~/.callrec/`:
/// `requests/<id>.json` (app writes), `responses/<id>.json` (daemon writes). Nothing else changes
/// who may read what: no new permission is granted to the app.
public enum HistoryMailbox {

    public struct Request: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        /// Unix epoch seconds: only calls at or after this time.
        public var sinceEpoch: Double
        /// Only calls with this 10-digit number. nil = every number since `sinceEpoch` (cooldown map).
        public var numberKey: String?

        public init(id: String = UUID().uuidString, sinceEpoch: Double, numberKey: String? = nil) {
            self.id = id; self.kind = "history"; self.sinceEpoch = sinceEpoch; self.numberKey = numberKey
        }
    }

    /// A call row. No names, no other fields: just what the dialer needs.
    public struct Row: Codable, Equatable, Sendable {
        public var epoch: Double
        public var numberKey: String
        public var seconds: Int
        public init(epoch: Double, numberKey: String, seconds: Int) {
            self.epoch = epoch; self.numberKey = numberKey; self.seconds = seconds
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var id: String
        public var ok: Bool
        public var error: String?
        public var rows: [Row]
        public init(id: String, ok: Bool, error: String? = nil, rows: [Row] = []) {
            self.id = id; self.ok = ok; self.error = error; self.rows = rows
        }
    }

    public enum MailboxError: Error, LocalizedError, Equatable {
        case timeout
        case malformed(String)
        case daemonError(String)

        public var errorDescription: String? {
            switch self {
            case .timeout: return "the recorder did not answer in time (is it running?)"
            case .malformed(let m): return "the recorder's answer was unreadable (\(m))"
            case .daemonError(let m): return "the recorder could not read call history (\(m))"
            }
        }
    }

    public static let staleAfter: TimeInterval = 120
    public static var requestsDir: URL { DialerPaths.home.appendingPathComponent("requests") }
    public static var responsesDir: URL { DialerPaths.home.appendingPathComponent("responses") }

    // MARK: - Pure protocol

    public static func encode(_ r: Request) throws -> Data { try JSONEncoder().encode(r) }
    public static func encode(_ r: Response) throws -> Data { try JSONEncoder().encode(r) }

    public static func decodeRequest(_ data: Data) throws -> Request {
        do {
            let r = try JSONDecoder().decode(Request.self, from: data)
            guard r.kind == "history", isSafeID(r.id) else { throw MailboxError.malformed("bad kind or id") }
            if let k = r.numberKey, PhoneNumber.key(k) != k || k.count != 10 { throw MailboxError.malformed("bad number key") }
            return r
        } catch let e as MailboxError { throw e }
        catch { throw MailboxError.malformed(error.localizedDescription) }
    }

    public static func decodeResponse(_ data: Data, expecting id: String) throws -> Response {
        let r: Response
        do { r = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw MailboxError.malformed(error.localizedDescription) }
        guard r.id == id else { throw MailboxError.malformed("answer is for a different request") }
        if !r.ok { throw MailboxError.daemonError(r.error ?? "unknown") }
        return r
    }

    /// File names come from the id, so an id must never carry a path.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    public static func isStale(modified: Date, now: Date) -> Bool { now.timeIntervalSince(modified) > staleAfter }

    /// The rows a request asks for, from everything the daemon read.
    public static func matching(_ rows: [Row], for request: Request) -> [Row] {
        rows.filter { row in
            row.epoch >= request.sinceEpoch && (request.numberKey.map { $0 == row.numberKey } ?? true)
        }
    }

    // MARK: - File I/O

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try Paths.ensureDir(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        _ = try Permissions.tightenOne(url, isDirectory: false)
    }

    // MARK: App side

    /// Writes a request and waits for the daemon's answer. Throws `.timeout` (and withdraws the
    /// request) when there is none: the caller must treat that as "history unavailable".
    public static func ask(_ request: Request, requestsDir: URL = requestsDir, responsesDir: URL = responsesDir,
                           timeout: TimeInterval = 5, poll: TimeInterval = 0.1) async throws -> Response {
        let reqURL = requestsDir.appendingPathComponent("\(request.id).json")
        let respURL = responsesDir.appendingPathComponent("\(request.id).json")
        try Paths.ensureDir(responsesDir)
        try writeAtomically(try encode(request), to: reqURL)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let data = readIfPresent(respURL) {
                Fs.remove(respURL)
                return try decodeResponse(data, expecting: request.id)
            }
            if Date() >= deadline {
                Fs.remove(reqURL)
                throw MailboxError.timeout
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
    }

    private static func readIfPresent(_ url: URL) -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            if !Fs.isMissing(error) { logError("history mailbox: could not read \(url.lastPathComponent): \(error.localizedDescription)") }
            return nil
        }
    }

    // MARK: Daemon side

    /// Answers every pending request and cleans stale files. Returns how many were answered.
    /// `read` runs the real query (daemon: CallHistory.query); it is a parameter so tests need no database.
    @discardableResult
    public static func serve(requestsDir: URL = requestsDir, responsesDir: URL = responsesDir, now: Date = Date(),
                             read: (Request) throws -> [Row]) -> Int {
        var answered = 0
        for dir in [requestsDir, responsesDir] {
            for name in Fs.list(dir) where name.hasSuffix(".json") {
                let url = dir.appendingPathComponent(name)
                guard let modified = modificationDate(url) else { continue }
                if isStale(modified: modified, now: now) { Fs.remove(url) }
            }
        }
        for name in Fs.list(requestsDir).sorted() where name.hasSuffix(".json") {
            let url = requestsDir.appendingPathComponent(name)
            let request: Request
            do { request = try decodeRequest(try Data(contentsOf: url)) }
            catch {
                logError("history mailbox: dropped an unreadable request \(name): \(error.localizedDescription)", .watcher)
                Fs.remove(url)
                continue
            }
            let response: Response
            do { response = Response(id: request.id, ok: true, rows: matching(try read(request), for: request)) }
            catch { response = Response(id: request.id, ok: false, error: error.localizedDescription) }
            do {
                try writeAtomically(try encode(response), to: responsesDir.appendingPathComponent("\(request.id).json"))
                answered += 1
            } catch {
                logError("history mailbox: could not answer \(name): \(error.localizedDescription)", .watcher)
            }
            Fs.remove(url)
        }
        return answered
    }

    private static func modificationDate(_ url: URL) -> Date? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date }
        catch {
            if !Fs.isMissing(error) { logError("history mailbox: could not stat \(url.lastPathComponent): \(error.localizedDescription)") }
            return nil
        }
    }
}

extension CallHistory {
    /// The daemon's answer to a history request: calls since the requested time (outgoing and incoming
    /// alike), each as date, last-10-digit number and seconds. No names.
    public static func mailboxRows(since epoch: Double) throws -> [HistoryMailbox.Row] {
        let apple = epoch - 978_307_200
        let sql = "select coalesce(ZADDRESS,''), ZDATE, cast(coalesce(ZDURATION,0) as int) from ZCALLRECORD "
            + "where ZDATE >= \(apple) order by ZDATE desc limit 1000;"
        let r = try query(sql)
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: 42, userInfo: [NSLocalizedDescriptionKey:
                "call history not readable: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1}")
            guard f.count >= 3, let key = PhoneNumber.key(f[0]), let apple = Double(f[1]) else { return nil }
            return HistoryMailbox.Row(epoch: apple + 978_307_200, numberKey: key, seconds: Int(f[2]) ?? 0)
        }
    }
}
