import Foundation

/// The transcript as plain text for the clipboard ("Copy" next to the transcript): a one-line
/// header so it makes sense when pasted elsewhere, then one line per segment with its time and,
/// when known, who spoke.
public enum TranscriptCopy {
    public static func text(header: String, lines: [(start: Double, speaker: Speaker, text: String)]) -> String {
        let body = lines.map { line -> String in
            let stamp = String(format: "[%02d:%02d]", Int(line.start) / 60, Int(line.start) % 60)
            let who = line.speaker == .unknown ? "" : " \(line.speaker.label):"
            return "\(stamp)\(who) \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return ([header, ""] + body).joined(separator: "\n")
    }
}
