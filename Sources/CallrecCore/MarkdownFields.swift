import Foundation

/// Reads and rewrites the editable fields of a transcript `.md` without ever
/// touching the transcript itself.
public enum MarkdownFields {

    public struct Fields: Equatable {
        public var outcome: String
        public var who: String
        public var notes: String

        public init(outcome: String = "", who: String = "", notes: String = "") {
            self.outcome = outcome
            self.who = who
            self.notes = notes
        }
    }

    static let outcomePrefix = "- outcome:"
    static let whoPrefix = "- who picked up:"
    static let notesPrefix = "- what they said that wasn't in the flow:"

    public static func read(md: String) -> Fields {
        var f = Fields()
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix(outcomePrefix) {
                f.outcome = value(of: line, after: outcomePrefix)
            } else if line.hasPrefix(whoPrefix) {
                f.who = value(of: line, after: whoPrefix)
            } else if line.hasPrefix(notesPrefix) {
                f.notes = value(of: line, after: notesPrefix)
            }
        }
        return f
    }

    /// Returns the markdown with only those three fields replaced.
    public static func update(md: String, outcome: String, who: String, notes: String) -> String {
        var lines = md.components(separatedBy: "\n")
        var sawNotes = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix(outcomePrefix) {
                lines[i] = "\(outcomePrefix) \(clean(outcome))"
            } else if line.hasPrefix(whoPrefix) {
                lines[i] = "\(whoPrefix) \(clean(who))"
            } else if line.hasPrefix(notesPrefix) {
                lines[i] = "\(notesPrefix) \(clean(notes))"
                sawNotes = true
            }
        }
        if !sawNotes, !clean(notes).isEmpty {
            if !lines.contains(where: { $0.hasPrefix("## Notes") }) { lines.append(contentsOf: ["", "## Notes", ""]) }
            lines.append("\(notesPrefix) \(clean(notes))")
        }
        return lines.joined(separator: "\n")
    }

    /// Notes are stored on one line, so newlines become spaces.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func value(of line: String, after prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The first transcript line, for the call list preview.
    public static func firstTranscriptLine(md: String) -> String {
        var inTranscript = false
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## Transcript") { inTranscript = true; continue }
            if line.hasPrefix("## ") { inTranscript = false }
            guard inTranscript, line.hasPrefix("[") else { continue }
            if let close = line.firstIndex(of: "]") {
                var text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                for candidate in [Speaker.me, .them] where text.hasPrefix("**\(candidate.label):**") {
                    text = String(text.dropFirst("**\(candidate.label):**".count)).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
        }
        return ""
    }

    public static func segments(md: String) -> [Segment] {
        var out: [Segment] = []
        var inTranscript = false
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## Transcript") { inTranscript = true; continue }
            if line.hasPrefix("## ") { inTranscript = false }
            guard inTranscript, line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close].components(separatedBy: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { continue }
            var text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            var speaker = Speaker.unknown
            for candidate in [Speaker.me, .them] where text.hasPrefix("**\(candidate.label):**") {
                speaker = candidate
                text = String(text.dropFirst("**\(candidate.label):**".count)).trimmingCharacters(in: .whitespaces)
            }
            out.append(Segment(start: m * 60 + s, end: m * 60 + s, text: text, speaker: speaker))
        }
        return out
    }

    /// Duration in seconds, read back from the "- duration: 4m 12s" line.
    public static func duration(md: String) -> Double {
        for line in md.components(separatedBy: "\n") where line.hasPrefix("- duration:") {
            let parts = line.dropFirst("- duration:".count).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "s", with: "")
                .components(separatedBy: "m")
            if parts.count == 2, let m = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let s = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                return m * 60 + s
            }
        }
        return 0
    }
}
