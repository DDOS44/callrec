import Foundation

/// Indian carriers play a spam or recording warning the moment a call connects.
/// It lands on the far-side track and whisper dutifully transcribes it, so it
/// gets stripped before anyone reads the transcript.
public enum Announcements {

    public static let defaultPhrases = [
        // Whisper spells the warning phonetically, so the variants matter more
        // than the correct spelling.
        "scammer", "scam", "skaim", "skaimar", "sakaim", "spam", "fraud call",
        "agla call", "agala call",
        "call record", "record kiya ja raha",
        "the number you have dialled", "number you have dialed",
        "is not reachable", "switched off", "currently busy",
        "please try again later", "airtel", "vodafone idea", "jio"
    ]

    /// Lowercased, stripped of punctuation and repeated spaces, so small
    /// spelling differences in the transcript still match.
    public static func normalise(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    public static func isOperator(_ text: String, phrases: [String] = defaultPhrases) -> Bool {
        let hay = normalise(text)
        guard !hay.isEmpty else { return false }
        return phrases.contains { !$0.isEmpty && hay.contains(normalise($0)) }
    }

    /// Drops operator messages heard on the far side at the start of the call.
    public static func strip(_ segments: [Segment],
                             phrases: [String] = defaultPhrases,
                             withinSeconds: Double = 15) -> [Segment] {
        segments.filter { segment in
            guard segment.speaker != .me, segment.start < withinSeconds else { return true }
            return !isOperator(segment.text, phrases: phrases)
        }
    }
}
