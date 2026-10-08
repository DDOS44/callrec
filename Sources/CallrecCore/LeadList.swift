import Foundation

public enum LeadConfidence: Int, Comparable, Codable, Sendable {
    case high = 0, medium = 1, low = 2, unknown = 3

    public static func < (a: LeadConfidence, b: LeadConfidence) -> Bool { a.rawValue < b.rawValue }

    init(text: String) {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "high", "h": self = .high
        case "medium", "med", "m", "mid": self = .medium
        case "low", "l": self = .low
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        case .unknown: return "unrated"
        }
    }
}

/// One callable row of an imported list. The id is the 10-digit number, so it is
/// stable across re-imports and reordering; a number appears once per list —
/// except the user's own test numbers, whose repeats get "#2", "#3"… so ids stay unique.
public struct Lead: Identifiable, Equatable, Sendable {
    public var id: String { repeatIndex <= 1 ? number : "\(number)#\(repeatIndex)" }
    /// 1 for the first occurrence of a number in the list; >1 only for test-number repeats.
    public var repeatIndex: Int = 1
    public var number: String
    public var company: String
    public var city: String
    public var owner: String
    public var whatTheyDo: String
    public var angle: String
    public var confidence: LeadConfidence
    public var altNumber: String?
    public var caller: String
    /// 1-based position among the file's data rows (header excluded), for display and stable ordering.
    public var order: Int

    /// What to show for the lead: the company, or the number when the row has none.
    public var title: String { company.isEmpty ? number : company }
}

public struct RejectedRow: Equatable, Sendable {
    /// 1-based line of the record in the file (the header is line 1).
    public var line: Int
    public var company: String
    public var phone: String
    public var reason: String
}

public struct LeadImport: Equatable, Sendable {
    /// Callable rows in file order.
    public var leads: [Lead]
    /// Rows that cannot be dialled, each with the reason. Never silently dropped.
    public var rejected: [RejectedRow]
    /// Rows that belong to another caller (the `caller` filter); counted, not an error.
    public var filteredOut: Int
    /// Things worth a look that do not stop an import (e.g. an alt number that is not a number).
    public var warnings: [String]
    /// Data rows that were entirely blank.
    public var blankRows: Int

    /// Every data row in the file lands in exactly one of these buckets.
    public var accountedRows: Int { leads.count + rejected.count + filteredOut + blankRows }

    /// Callable leads: high, then medium, then low, then unrated; list order within a tier.
    public var ordered: [Lead] {
        leads.sorted { ($0.confidence, $0.order) < ($1.confidence, $1.order) }
    }

    /// Plain-text report for the rejected rows, to show and to save next to the list.
    public var rejectedReport: String {
        guard !rejected.isEmpty else { return "" }
        return rejected.map { "line \($0.line): \($0.reason) (company: \($0.company.isEmpty ? "-" : $0.company), phone: \($0.phone.isEmpty ? "-" : $0.phone))" }
            .joined(separator: "\n") + "\n"
    }
}

public enum LeadImportError: Error, LocalizedError, Equatable {
    case empty
    case missingColumns([String])

    public var errorDescription: String? {
        switch self {
        case .empty: return "The file has no rows."
        case .missingColumns(let c): return "The file needs these columns and does not have them: \(c.joined(separator: ", ")). Nothing was imported."
        }
    }
}

public enum LeadImporter {

    private enum Field: CaseIterable {
        case company, phone, city, owner, whatTheyDo, angle, confidence, altNumber, caller

        var names: [String] {
            switch self {
            case .company: return ["company", "companyname", "business", "businessname", "agency", "agencyname", "organisation", "organization"]
            case .phone: return ["phone", "phonenumber", "mobile", "mobilenumber", "number", "contactnumber", "tel", "telephone", "primaryphone"]
            case .city: return ["city", "location", "town"]
            case .owner: return ["owner", "ownername", "founder", "decisionmaker", "contactperson", "contactname"]
            case .whatTheyDo: return ["whattheydo", "whatwedo", "description", "about", "niche", "business type", "businesstype", "specialty", "speciality"]
            case .angle: return ["angle", "pitchangle", "hook", "opener", "scriptangle"]
            case .confidence: return ["confidence", "priority", "fit", "tier"]
            case .altNumber: return ["altnumber", "altphone", "alternatenumber", "alternatephone", "secondaryphone", "phone2", "alt"]
            case .caller: return ["caller", "assignedto", "assignee", "dialer"]
            }
        }
    }

    /// "Alt Number", "alt_number", "ALT-number" -> "altnumber".
    static func canonical(_ header: String) -> String {
        var h = header
        if h.hasPrefix("\u{FEFF}") { h.removeFirst() }
        return h.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func load(_ url: URL, caller: String = "", repeatable: Set<String> = []) throws -> LeadImport {
        guard let text = Fs.text(url) else {
            throw NSError(domain: "callrec", code: 41, userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.path)."])
        }
        return try parse(text, caller: caller, repeatable: repeatable)
    }

    /// Parses CSV text. Throws only when the header lacks `company` or `phone`; a bad row is
    /// reported, never fatal. `caller` keeps only rows whose `caller` column matches
    /// (case-insensitive); with no `caller` column in the file every row is kept.
    public static func parse(_ text: String, caller: String = "", repeatable: Set<String> = []) throws -> LeadImport {
        let rows = LeadSheet.parse(text)
        guard let header = rows.first, header.contains(where: { !$0.isEmpty }) else { throw LeadImportError.empty }

        var index: [Field: Int] = [:]
        let canon = header.map(canonical)
        for field in Field.allCases {
            let wanted = Set(field.names.map(canonical))
            if let i = canon.firstIndex(where: { wanted.contains($0) }) { index[field] = i }
        }
        var missing: [String] = []
        if index[.company] == nil { missing.append("company") }
        if index[.phone] == nil { missing.append("phone") }
        guard missing.isEmpty else { throw LeadImportError.missingColumns(missing) }

        func cell(_ row: [String], _ f: Field) -> String {
            guard let i = index[f], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let wantedCaller = caller.trimmingCharacters(in: .whitespaces).lowercased()
        var out = LeadImport(leads: [], rejected: [], filteredOut: 0, warnings: [], blankRows: 0)
        var seen: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        var order = 0

        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            if row.allSatisfy({ $0.isEmpty }) { out.blankRows += 1; continue }
            let company = cell(row, .company), phone = cell(row, .phone)

            if !wantedCaller.isEmpty, index[.caller] != nil,
               cell(row, .caller).lowercased() != wantedCaller {
                out.filteredOut += 1
                continue
            }
            guard let number = PhoneNumber.normalize(phone) else {
                let why = phone.isEmpty ? "no phone number" : "not a single valid 10-digit Indian number"
                out.rejected.append(RejectedRow(line: line, company: company, phone: phone, reason: why))
                continue
            }
            if !repeatable.contains(number), let first = seen[number] {
                out.rejected.append(RejectedRow(line: line, company: company, phone: phone,
                                                reason: "duplicate of the number on line \(first)"))
                continue
            }
            if seen[number] == nil { seen[number] = line }
            occurrences[number, default: 0] += 1
            order += 1

            let altRaw = cell(row, .altNumber)
            var alt: String?
            if !altRaw.isEmpty {
                alt = PhoneNumber.normalize(altRaw)
                if alt == nil { out.warnings.append("line \(line): alt number is not a valid 10-digit number, ignored") }
                if alt == number { alt = nil }
            }
            var lead = Lead(number: number, company: company, city: cell(row, .city), owner: cell(row, .owner),
                            whatTheyDo: cell(row, .whatTheyDo), angle: cell(row, .angle),
                            confidence: LeadConfidence(text: cell(row, .confidence)), altNumber: alt,
                            caller: cell(row, .caller), order: order)
            lead.repeatIndex = occurrences[number] ?? 1
            out.leads.append(lead)
        }
        return out
    }
}
