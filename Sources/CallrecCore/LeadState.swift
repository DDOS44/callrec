import Foundation

public enum LeadStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case called
    case noAnswer = "no-answer"
    case doNotCall = "do-not-call"
    case skipped
}

extension LeadStatus {
    /// The status a lead gets when its wrap-up is saved. The person's outcome is the truth:
    /// the recorder can mark a real conversation "no answer" (the recording never started),
    /// so a wrap-up outcome must be able to correct it. A blank outcome changes nothing.
    /// Do-not-call and skipped are never overridden here.
    public static func afterWrapUp(outcome: String, current: LeadStatus) -> LeadStatus {
        if current == .doNotCall || current == .skipped { return current }
        let o = outcome.trimmingCharacters(in: .whitespaces).lowercased()
        if o.isEmpty { return current }
        return o == "no connect" ? .noAnswer : .called
    }

    /// "Move back to queue": skipped, no-answer and called leads become pending again. Do-not-call
    /// is permanent and a pending lead has nothing to undo, so both return nil. This only resets
    /// the status; the 7-day no-redial rule is enforced at dial time from the dial log and call
    /// history, so a real lead moved back still cannot be dialled inside its cooldown.
    public static func afterMoveBack(current: LeadStatus) -> LeadStatus? {
        switch current {
        case .skipped, .noAnswer, .called: return .pending
        case .pending, .doNotCall: return nil
        }
    }
}

/// What happened to one lead. Everything is optional-or-defaulted so a state file
/// written by an older build still loads.
public struct LeadRecord: Codable, Equatable, Sendable {
    public var status: LeadStatus = .pending
    public var attempts: Int = 0
    public var lastDialedAt: Date?
    public var outcome: String = ""
    public var notes: String = ""
    /// `<day>/<time>` id of the call recording this lead produced, when known.
    public var callID: String?
    public var updatedAt: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey { case status, attempts, lastDialedAt, outcome, notes, callID, updatedAt }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(LeadStatus.self, forKey: .status) ?? status
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? attempts
        lastDialedAt = try c.decodeIfPresent(Date.self, forKey: .lastDialedAt)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? outcome
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? notes
        callID = try c.decodeIfPresent(String.self, forKey: .callID)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public enum LeadStateError: Error, LocalizedError {
    case unreadable(path: String, reason: String)
    case newerVersion(path: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let p, let r):
            return "The lead state file \(p) could not be read (\(r)). It was left untouched. Fix or move it, then reopen the list."
        case .newerVersion(let p, let v):
            return "The lead state file \(p) was written by a newer callrec (format \(v)). It was left untouched."
        }
    }
}

/// `<list>.state.json`: per-lead progress for one list. The app is the only writer.
/// Never edits the CSV. A file that cannot be read is never overwritten.
public final class LeadStateStore: @unchecked Sendable {
    public static let formatVersion = 1

    private struct File: Codable {
        var version: Int = LeadStateStore.formatVersion
        var list: String
        var leads: [String: LeadRecord]
    }

    public let url: URL
    public let listName: String
    private let lock = NSLock()
    private var records: [String: LeadRecord]

    /// Loads (or starts empty when the file does not exist yet).
    public init(url: URL, listName: String) throws {
        self.url = url
        self.listName = listName
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if Fs.isMissing(error) { records = [:]; return }
            throw LeadStateError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do {
            let file = try dec.decode(File.self, from: data)
            if file.version > Self.formatVersion { throw LeadStateError.newerVersion(path: url.path, version: file.version) }
            records = file.leads
        } catch let e as LeadStateError {
            throw e
        } catch {
            throw LeadStateError.unreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    public func record(_ leadID: String) -> LeadRecord {
        lock.lock(); defer { lock.unlock() }
        return records[leadID] ?? LeadRecord()
    }

    public var all: [String: LeadRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    /// Applies `change` to one lead and saves. If the save fails the in-memory state is
    /// left as it was and the error is thrown, so memory and disk never disagree silently.
    @discardableResult
    public func update(_ leadID: String, now: Date = Date(), _ change: (inout LeadRecord) -> Void) throws -> LeadRecord {
        lock.lock(); defer { lock.unlock() }
        var next = records
        var rec = next[leadID] ?? LeadRecord()
        change(&rec)
        rec.updatedAt = now
        next[leadID] = rec
        try write(next)
        records = next
        return rec
    }

    /// Moves every skipped lead back to pending (one write).
    public func resetSkipped(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var next = records
        for (id, var rec) in next where rec.status == .skipped {
            rec.status = .pending; rec.updatedAt = now
            next[id] = rec
        }
        try write(next)
        records = next
    }

    private func write(_ leads: [String: LeadRecord]) throws {
        try Paths.ensureDir(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(File(list: listName, leads: leads))
        try data.write(to: url, options: .atomic)
        // Atomic writes keep the temp file's mode; the process umask (077) makes it 0600.
        _ = try Permissions.tightenOne(url, isDirectory: false)
    }
}

/// One row of the queue view.
public struct QueueItem: Identifiable, Equatable, Sendable {
    public var id: String { lead.id }
    public var lead: Lead
    public var record: LeadRecord
    public var status: LeadStatus { record.status }
}

public enum LeadQueue {
    /// Leads in dialing order (high, medium, low, unrated; list order within a tier), with their state.
    public static func build(_ imported: LeadImport, state: [String: LeadRecord]) -> [QueueItem] {
        imported.ordered.map { QueueItem(lead: $0, record: state[$0.id] ?? LeadRecord()) }
    }

    /// The first lead still pending whose number is not in `excluding` (numbers the policy
    /// refuses for lead-specific reasons this session).
    public static func nextUp(_ queue: [QueueItem], excluding: Set<String> = []) -> QueueItem? {
        queue.first { $0.status == .pending && !excluding.contains($0.id) }
    }

    public static func counts(_ queue: [QueueItem]) -> [LeadStatus: Int] {
        Dictionary(grouping: queue, by: \.status).mapValues(\.count)
    }
}
