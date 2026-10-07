import Foundation

/// Writes a wrap-up into the call's own .md: outcome and notes (the app's fields) plus the
/// company, owner and number from the lead row. Goes through MarkdownStore's lock like every other writer.
public enum DialMarkdown {

    /// The .md whose start time is within `tolerance` seconds of `callStart`, in the recordings root.
    /// nil when it does not exist (yet): the daemon writes it after transcription.
    public static func find(root: URL, callStart: Date, tolerance: TimeInterval = 6) -> URL? {
        let paths = Paths.forCall(at: callStart, root: root)
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        // Also look at the neighbouring day: a call within seconds of midnight.
        let dirs = [paths.dir] + [-1, 1].compactMap { off -> URL? in
            Calendar.current.date(byAdding: .day, value: off, to: callStart).map { Paths.forCall(at: $0, root: root).dir }
        }
        for dir in dirs {
            for file in Fs.list(dir).filter({ $0.hasSuffix(".md") }) {
                guard let date = stamp.date(from: "\(dir.lastPathComponent) \(file.dropLast(3))") else { continue }
                if abs(date.timeIntervalSince(callStart)) <= tolerance { return dir.appendingPathComponent(file) }
            }
        }
        return nil
    }

    /// Returns false when the call's .md does not exist yet. Notes already in the file are kept:
    /// the wrap-up notes are added after them.
    public static func apply(root: URL, callStart: Date, lead: Lead, outcome: String, notes: String) throws -> Bool {
        guard let md = find(root: root, callStart: callStart) else { return false }
        try MarkdownStore.modify(md) { existing in
            guard let existing else { return nil }
            let id = CallIdentity(number: lead.number, company: lead.company, owner: lead.owner)
            let withId = MarkdownFields.setIdentity(md: existing, id)
            let f = MarkdownFields.read(md: withId)
            let newNotes = [f.notes, notes.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " | ")
            return MarkdownFields.update(md: withId, outcome: outcome.isEmpty ? f.outcome : outcome, who: f.who, notes: newNotes)
        }
        return true
    }
}
