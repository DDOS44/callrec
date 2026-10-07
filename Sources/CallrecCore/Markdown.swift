import Foundation

public enum Speaker: String, Codable, Sendable {
    case me = "Me"
    case them = "Them"
    case unknown = ""

    public var label: String { rawValue }
}

public struct Segment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: Speaker
    /// Why a filter suspects this line ("bleed", "operator", "loop"). The line
    /// is kept either way: filters mark, they never delete.
    public let flags: [String]

    public init(start: Double, end: Double, text: String, speaker: Speaker = .unknown, flags: [String] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.flags = flags
    }

    public func flagged(_ flag: String) -> Segment {
        flags.contains(flag) ? self : Segment(start: start, end: end, text: text, speaker: speaker, flags: flags + [flag])
    }

    public var duration: Double { max(end - start, 0) }
}

public enum Markdown {
    /// A flagged line ends with `  <!-- flagged: bleed,loop -->`. Flags are
    /// comma-separated, lowercase, from: bleed, operator, loop.
    public static let flagPrefix = "<!-- flagged:"
    public static let flagSuffix = "-->"

    /// One transcript line, exactly as it is written to the file.
    public static func line(for seg: Segment) -> String {
        let mm = Int(seg.start) / 60, ss = Int(seg.start) % 60
        let stamp = String(format: "%02d:%02d", mm, ss)
        var text = seg.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !seg.flags.isEmpty { text += "  \(flagPrefix) \(seg.flags.joined(separator: ",")) \(flagSuffix)" }
        return seg.speaker == .unknown ? "[\(stamp)] \(text)" : "[\(stamp)] **\(seg.speaker.label):** \(text)"
    }

    /// Splits a trailing flag marker off a line's text.
    public static func splitFlags(_ text: String) -> (text: String, flags: [String]) {
        guard text.hasSuffix(flagSuffix), let r = text.range(of: flagPrefix, options: .backwards) else { return (text, []) }
        let inner = text[r.upperBound..<text.index(text.endIndex, offsetBy: -flagSuffix.count)]
        let flags = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), flags)
    }

    /// Written under "## Transcript" when a recording has no speech in it. That
    /// is a result (a silent or unanswered call), not a failure.
    public static let noSpeechLine = "_No speech detected in this recording._"

    /// The same header and sections as a normal call, but with an `- error:` line
    /// and a transcript that says how to re-run. A failed call must never be
    /// represented by a missing file.
    public static func renderFailure(date: Date, seconds: Double, audioName: String,
                                     error: String, id: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        var out = "# Call \(f.string(from: date))\n\n"
        out += "- duration: \(m)m \(String(format: "%02d", s))s\n"
        out += "- audio: \(audioName)\n"
        out += "- error: \(MarkdownFields.oneLine(error))\n"
        out += "- outcome: \n- who picked up: \n\n## Transcript\n\n"
        out += "_Transcription failed. Re-run: callrec retranscribe \(id)_\n"
        out += "\n## Notes\n\n- what they said that wasn't in the flow: \n"
        return out
    }

    public static func render(date: Date, seconds: Double, audioName: String,
                              segments: [Segment]) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        var out = "# Call \(f.string(from: date))\n\n"
        out += "- duration: \(m)m \(String(format: "%02d", s))s\n"
        out += "- audio: \(audioName)\n- outcome: \n- who picked up: \n\n## Transcript\n\n"
        if segments.isEmpty { out += noSpeechLine + "\n" }
        for seg in segments { out += line(for: seg) + "\n" }
        out += "\n## Notes\n\n- what they said that wasn't in the flow: \n"
        return out
    }
}
