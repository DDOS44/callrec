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

    /// True when the call-history database can actually be read.
    public static var readable: Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        guard let r = try? Shell.run("/usr/bin/sqlite3",
                                     ["-readonly", "file:\(storeURL.path)?immutable=1",
                                      "select count(*) from ZCALLRECORD;"], timeout: 10) else { return false }
        return r.status == 0
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
        guard let r = try? Shell.run("/usr/bin/sqlite3",
                                     ["-readonly", "-separator", "\u{1}",
                                      "file:\(storeURL.path)?immutable=1", sql], timeout: 15),
              r.status == 0 else { return nil }
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
        guard wanted.count == 10, let text = try? String(contentsOf: csv, encoding: .utf8) else { return nil }
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
