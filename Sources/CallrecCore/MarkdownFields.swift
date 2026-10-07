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

    static let numberPrefix = "- number:"
    static let contactPrefix = "- contact:"
    static let companyPrefix = "- company:"
    static let ownerPrefix = "- owner:"
    static let outcomePrefix = "- outcome:"
    static let whoPrefix = "- who picked up:"
    static let notesPrefix = "- what they said that wasn't in the flow:"

    static let errorPrefix = "- error:"
    static let warningPrefix = "- warning:"

    /// The `- warning:` lines in the header (a silent track, for example).
    public static func warnings(md: String) -> [String] {
        md.components(separatedBy: "\n").filter { $0.hasPrefix(warningPrefix) }
            .map { value(of: $0, after: warningPrefix) }
    }

    /// Replaces every `- warning:` line with exactly `warnings` (none clears them),
    /// placed after the audio line. The rest of the file is untouched.
    public static func setWarnings(md: String, _ warnings: [String]) -> String {
        var lines = md.components(separatedBy: "\n").filter { !$0.hasPrefix(warningPrefix) }
        guard !warnings.isEmpty else { return lines.joined(separator: "\n") }
        let new = warnings.map { "\(warningPrefix) \(oneLine($0))" }
        if let anchor = lines.firstIndex(where: { $0.hasPrefix(errorPrefix) }) ?? lines.firstIndex(where: { $0.hasPrefix("- audio:") }) {
            lines.insert(contentsOf: new, at: anchor + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Errors live on one line in the header.
    public static func oneLine(_ message: String) -> String {
        let flat = message.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "..." : flat
    }

    /// The message on the "- error:" line, if the call failed.
    public static func error(md: String) -> String? {
        for line in md.components(separatedBy: "\n") where line.hasPrefix(errorPrefix) {
            return value(of: line, after: errorPrefix)
        }
        return nil
    }

    /// Records a failure in the header of an existing transcript.
    public static func setError(md: String, message: String) -> String {
        var lines = md.components(separatedBy: "\n")
        let line = "\(errorPrefix) \(oneLine(message))"
        if let i = lines.firstIndex(where: { $0.hasPrefix(errorPrefix) }) {
            lines[i] = line
        } else if let anchor = lines.firstIndex(where: { $0.hasPrefix("- audio:") }) {
            lines.insert(line, at: anchor + 1)
        }
        return lines.joined(separator: "\n")
    }

    public static func clearError(md: String) -> String {
        md.components(separatedBy: "\n").filter { !$0.hasPrefix(errorPrefix) }.joined(separator: "\n")
    }

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

    public static func identity(md: String) -> CallIdentity {
        var id = CallIdentity()
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix(numberPrefix) { id.number = value(of: line, after: numberPrefix) }
            else if line.hasPrefix(contactPrefix) { id.contact = value(of: line, after: contactPrefix) }
            else if line.hasPrefix(companyPrefix) { id.company = value(of: line, after: companyPrefix) }
            else if line.hasPrefix(ownerPrefix) { id.owner = value(of: line, after: ownerPrefix) }
        }
        return id
    }

    /// Writes the identity lines into the header, replacing any that exist and
    /// inserting the rest just above "- outcome:".
    public static func setIdentity(md: String, _ id: CallIdentity) -> String {
        var lines = md.components(separatedBy: "\n")
        let wanted: [(String, String)] = [
            (numberPrefix, id.number), (contactPrefix, id.contact),
            (companyPrefix, id.company), (ownerPrefix, id.owner)
        ].filter { !$0.1.isEmpty }

        for (prefix, value) in wanted {
            if let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
                lines[i] = "\(prefix) \(value)"
            } else if let anchor = lines.firstIndex(where: { $0.hasPrefix(outcomePrefix) }) {
                lines.insert("\(prefix) \(value)", at: anchor)
            } else if let anchor = lines.firstIndex(where: { $0.hasPrefix("- audio:") }) {
                lines.insert("\(prefix) \(value)", at: anchor + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the daemon writes when it (re)transcribes a call. The human fields
    /// (outcome, who, notes) and anything else a person typed outside
    /// `## Transcript` stay exactly as they were; only the transcript lines are
    /// replaced and a stale error marker is cleared. A file with no
    /// `## Transcript` heading (damaged or hand-edited) cannot be edited in
    /// place, so the fresh render is used with the human fields carried over.
    public static func daemonMerge(existing: String?, fresh: String, segments: [Segment]) -> String {
        guard let existing else { return fresh }
        if existing.contains("## Transcript") {
            return replaceTranscript(md: clearError(md: existing), with: segments)
        }
        let human = read(md: existing)
        let carried = update(md: fresh, outcome: human.outcome, who: human.who, notes: human.notes)
        return setIdentity(md: carried, identity(md: existing))
    }

    /// Replaces only the lines under "## Transcript", leaving the header
    /// fields and the notes exactly as they are.
    public static func replaceTranscript(md: String, with segments: [Segment]) -> String {
        var lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Transcript") }) else { return md }
        let after = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count

        var body = [""]
        for seg in segments { body.append(Markdown.line(for: seg)) }
        if segments.isEmpty { body.append(Markdown.noSpeechLine) }
        body.append("")
        lines.replaceSubrange((start + 1)..<after, with: body)
        return lines.joined(separator: "\n")
    }

    /// True for a finished transcript with no spoken lines and no error: a
    /// silent or unanswered recording rather than a failed one.
    public static func hasNoSpeech(md: String) -> Bool {
        guard error(md: md) == nil, md.contains("## Transcript") else { return false }
        return segments(md: md).isEmpty && !md.contains("_Transcription failed")
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
                return Markdown.splitFlags(text).text
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
            let split = Markdown.splitFlags(text)
            out.append(Segment(start: m * 60 + s, end: m * 60 + s, text: split.text, speaker: speaker, flags: split.flags))
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
