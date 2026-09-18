import Foundation

/// Fills in who a call was with, from call history + contacts + the leads sheet.
public enum Identify {

    public static func identity(forCallAt date: Date, config: Config) -> CallIdentity {
        guard let hit = CallHistory.number(near: date) else { return CallIdentity() }
        var id = CallIdentity(number: hit.number)
        id.contact = hit.name.isEmpty ? (ContactsLookup.name(for: hit.number) ?? "") : hit.name
        if let lead = LeadSheet.lookup(number: hit.number, csv: config.leadsURL) {
            id.company = lead.company
            id.owner = lead.owner
        }
        return id
    }

    /// Writes the identity into an existing transcript. Returns what it found.
    @discardableResult
    public static func apply(to md: URL, callDate: Date, config: Config) -> CallIdentity {
        let id = identity(forCallAt: callDate, config: config)
        guard !id.isEmpty, let text = try? String(contentsOf: md, encoding: .utf8) else { return id }
        try? MarkdownFields.setIdentity(md: text, id).write(to: md, atomically: true, encoding: .utf8)
        return id
    }

    /// `callrec relabel [yyyy-MM-dd]`: fills in identity for calls already on disk.
    public static func relabel(day: String?, config: Config) -> (updated: Int, scanned: Int) {
        let fm = FileManager.default
        let root = config.recordingsURL
        let days = day.map { [$0] } ?? ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 10 }
        var updated = 0, scanned = 0
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"

        for name in days.sorted() {
            let dir = root.appendingPathComponent(name)
            for file in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasSuffix(".md") }).sorted() {
                scanned += 1
                let time = String(file.dropLast(3))
                guard let date = stamp.date(from: "\(name) \(time)") else { continue }
                if !apply(to: dir.appendingPathComponent(file), callDate: date, config: config).isEmpty { updated += 1 }
            }
        }
        return (updated, scanned)
    }
}
