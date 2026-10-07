import Foundation

/// Who a call was with: the number from macOS call history, plus whatever the
/// Contacts database and the leads sheet can add.
public struct CallIdentity: Equatable {
    public var number: String = ""
    public var contact: String = ""
    public var company: String = ""
    public var owner: String = ""

    public var isEmpty: Bool { number.isEmpty && contact.isEmpty && company.isEmpty && owner.isEmpty }

    public init(number: String = "", contact: String = "", company: String = "", owner: String = "") {
        self.number = number
        self.contact = contact
        self.company = company
        self.owner = owner
    }
}

public enum CallHistory {

    public static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CallHistoryDB/CallHistory.storedata")
    }

    public static let noAccessMessage =
        "Call history unavailable: grant Full Disk Access to callrec in System Settings -> Privacy & Security -> Full Disk Access"

    /// Core Data stores seconds since 2001-01-01.
    static let appleEpoch = Date(timeIntervalSince1970: 978_307_200)

    /// Runs read-only SQL against a private snapshot of the store. Recent calls live
    /// in CallHistory.storedata-wal until macOS checkpoints it; the old
    /// `?immutable=1` open ignored the WAL, so the newest call it could see was
    /// days old (2026-10-07). Copying db + -wal + -shm into a 0700 temp dir and
    /// querying the copy sees everything and never touches the live database.
    static func query(_ sql: String, separator: String = "\u{1}", timeout: TimeInterval = 15)
        throws -> (status: Int32, stdout: String, stderr: String) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("callrec-history-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { Fs.remove(tmp) }
        let copy = tmp.appendingPathComponent("CallHistory.storedata")
        try fm.copyItem(at: storeURL, to: copy)
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        return try Shell.run("/usr/bin/sqlite3", ["-readonly", "-separator", separator, copy.path, sql], timeout: timeout)
    }

    /// True when the call-history database can actually be read.
    public static var readable: Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        let r: (status: Int32, stdout: String, stderr: String)
        do {
            r = try query("select count(*) from ZCALLRECORD;", timeout: 10)
        } catch {
            log("call history probe failed to run: \(error.localizedDescription)", .transcribe)
            return false
        }
        // A nonzero status here is the normal "Full Disk Access not granted" answer.
        return r.status == 0
    }

    /// Most recent call-history rows (local time, number, name, seconds) for
    /// `callrec history`: diagnosing why a recording didn't match a call.
    public static func recent(limit: Int = 10) -> [String] {
        let sql = """
        select datetime(ZDATE + 978307200, 'unixepoch', 'localtime'), coalesce(ZADDRESS,''), \
        coalesce(ZNAME,''), cast(coalesce(ZDURATION,0) as int) from ZCALLRECORD order by ZDATE desc limit \(limit);
        """
        do {
            let r = try query(sql, separator: "  |  ")
            guard r.status == 0 else { return ["call history not readable: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"] }
            return r.stdout.split(separator: "\n").map(String.init)
        } catch {
            return ["could not run sqlite3: \(error.localizedDescription)"]
        }
    }

    public struct Column: Equatable, Sendable {
        public var name: String
        public var type: String
    }

    /// Parses `PRAGMA table_info` output (cid, name, type, notnull, default, pk) split on `separator`.
    static func parseTableInfo(_ output: String, separator: String = "\u{1}") -> [Column] {
        output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: separator)
            return f.count >= 3 ? Column(name: f[1], type: f[2]) : nil
        }
    }

    /// The columns of ZCALLRECORD. Throws when the database cannot be read.
    public static func columns() throws -> [Column] {
        let r = try query("PRAGMA table_info(ZCALLRECORD);")
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: 42, userInfo: [NSLocalizedDescriptionKey:
                "call history not readable: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return parseTableInfo(r.stdout)
    }

    /// Recent call rows with the values of `candidateColumns` (names must be plain identifiers).
    /// Limited to the newest `limit` rows.
    public static func calls(candidateColumns: [String], limit: Int = 300, hasOriginated: Bool) throws -> [HistoryCall] {
        let safe = candidateColumns.filter { $0.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil }
        func text(_ c: String) -> String { "replace(replace(coalesce(cast(\"\(c)\" as text),''), char(10), ' '), char(1), ' ')" }
        let extra = safe.map { ", " + text($0) }.joined()
        let originated = hasOriginated ? ", coalesce(ZORIGINATED, -1)" : ", -1"
        let sql = "select coalesce(ZADDRESS,''), ZDATE, cast(coalesce(ZDURATION,0) as int)\(originated)\(extra) "
            + "from ZCALLRECORD order by ZDATE desc limit \(max(limit, 1));"
        let r = try query(sql)
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: 42, userInfo: [NSLocalizedDescriptionKey:
                "call history not readable: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1}")
            guard f.count >= 4 + safe.count, let key = PhoneNumber.key(f[0]), let apple = Double(f[1]) else { return nil }
            var values: [String: String] = [:]
            for (i, name) in safe.enumerated() { values[name] = f[4 + i].trimmingCharacters(in: .whitespaces) }
            let flag = Int(f[3])
            return HistoryCall(key: key, date: Date(timeInterval: apple, since: appleEpoch), seconds: Int(f[2]) ?? 0,
                               originated: flag == nil || flag == -1 ? nil : flag == 1, values: values)
        }
    }

    /// The text `callrec history --schema` prints: the column list, then what SIM
    /// detection makes of it. Meant for a human at a terminal (it prints values).
    public static func schemaReport() -> [String] {
        let cols: [Column]
        do { cols = try columns() }
        catch { return ["could not read the call history schema: \(error.localizedDescription)", noAccessMessage] }
        var out = ["ZCALLRECORD columns (name, type):"] + cols.map { "  \($0.name)  \($0.type)" }
        let candidates = SIMDetector.candidateColumns(cols)
        out.append("SIM/line candidate columns: \(candidates.isEmpty ? "none" : candidates.joined(separator: ", "))")
        do {
            let rows = try calls(candidateColumns: candidates, hasOriginated: cols.contains { $0.name == "ZORIGINATED" })
            for c in candidates {
                let counts = Dictionary(grouping: rows.map { $0.values[c] ?? "" }, by: { $0 }).mapValues(\.count)
                let shown = counts.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key.isEmpty ? "(empty)" : $0.key) x\($0.value)" }
                out.append("  \(c): \(counts.count) distinct in the last \(rows.count) calls: \(shown.joined(separator: ", "))")
            }
            let detection = SIMDetector.analyze(candidates: candidates, rows: rows)
            switch detection {
            case .available(let column, _): out.append("detection: \(column) identifies the line; the dialer will use it")
            case .unavailable(let reason): out.append("detection: none (\(reason)); the dialer uses the manual SIM checklist")
            }
        } catch {
            out.append("could not read call rows: \(error.localizedDescription)")
        }
        return out
    }

    /// The number dialled around `date`, if the history is readable.
    public static func number(near date: Date, toleranceSeconds: Double = 90) -> (number: String, name: String)? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        let target = date.timeIntervalSince(appleEpoch)
        let sql = """
        select ZADDRESS, coalesce(ZNAME, ''), ZDATE from ZCALLRECORD \
        where ZDATE between \(target - toleranceSeconds) and \(target + toleranceSeconds) \
        order by abs(ZDATE - \(target)) limit 1;
        """
        let r: (status: Int32, stdout: String, stderr: String)
        do {
            r = try query(sql)
        } catch {
            log("call history lookup failed to run: \(error.localizedDescription)", .transcribe)
            return nil
        }
        guard r.status == 0 else { return nil }
        let row = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !row.isEmpty else { return nil }
        let parts = row.components(separatedBy: "\u{1}")
        guard parts.count >= 2 else { return nil }
        let number = parts[0].trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return nil }
        return (number, parts[1].trimmingCharacters(in: .whitespaces))
    }
}

/// The leads sheet: company and owner for a number we called.
public enum LeadSheet {

    /// Numbers are written a dozen ways; the last ten digits are what match.
    public static func key(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    public static func lookup(number: String, csv: URL) -> (company: String, owner: String)? {
        let wanted = key(number)
        guard wanted.count == 10, let text = Fs.text(csv) else { return nil }
        let rows = parse(text)
        guard let header = rows.first,
              let phoneIndex = header.firstIndex(where: { $0.lowercased() == "phone" }) else { return nil }
        let companyIndex = header.firstIndex(where: { $0.lowercased() == "company" })
        let ownerIndex = header.firstIndex(where: { $0.lowercased() == "owner" })

        for row in rows.dropFirst() where row.count > phoneIndex {
            guard key(row[phoneIndex]) == wanted else { continue }
            let company = companyIndex.flatMap { row.count > $0 ? row[$0] : nil } ?? ""
            let owner = ownerIndex.flatMap { row.count > $0 ? row[$0] : nil } ?? ""
            return (company, owner)
        }
        return nil
    }

    /// Small CSV reader: handles quoted fields with commas and newlines in them.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        // Swift treats "\r\n" as one Character, so a CRLF file would never split
        // into rows unless the line endings are normalised first.
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n"))
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
