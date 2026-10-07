import Foundation

/// Indian carriers play a spam or recording warning the moment a call connects.
/// It lands on the far-side track and the transcriber dutifully transcribes it, so it
/// gets stripped before anyone reads the transcript.
public enum Announcements {

    public static let defaultPhrases = [
        // The model spells the warning phonetically, so the variants matter more
        // than the correct spelling.
        "scammer", "scam", "skaim", "skaimar", "sakaim", "spam", "fraud call",
        "agla call", "agala call",
        "call record", "record kiya ja raha",
        "the number you have dialled", "number you have dialed",
        "airtel", "vodafone idea", "jio"
    ]

    /// Network-status messages. These are never part of a real conversation, so
    /// they are flagged anywhere in the call, on either track: a call can drop
    /// into one mid-way, and the mic hears the speaker too. Matching is loose
    /// (normalised, substring) and covers Roman and Devanagari spellings.
    /// A bare "busy" is deliberately not here: "main busy hoon" is real speech.
    public static let statusPhrases = [
        "the number you have dialled", "the number you have dialed", "number you have dialed",
        "the number you are trying to reach", "number you are trying to reach", "you are trying to reach",
        "is not reachable", "not reachable", "number unreachable", "number is unreachable",
        "temporarily unreachable", "unreachable",
        "switched off", "switch off", "is switched off",
        "out of coverage area", "out of the coverage area", "outside the coverage area", "coverage area",
        "number is busy", "line is busy", "currently busy", "user is busy", "subscriber is busy", "is currently busy",
        "forwarded to voicemail", "forwarded to voice mail", "call forwarded to voicemail",
        "please try again later", "please try again",
        "cannot receive incoming calls", "can not receive incoming calls", "not able to receive incoming calls",
        "incoming calls are not being received", "incoming calls not being received",
        "not being received", "incoming calls receive",
        "thodi der mein try", "thode der mein try", "thodi der baad try", "thodi der mein prayas",
        "kripaya thodi der mein try karein", "kripaya thodi der mein try karen",
        "is number par abhi incoming calls receive nahi ho rahi",
        "number par abhi incoming calls", "incoming call receive nahi",
        // Devanagari
        "आपके द्वारा डायल किया गया नंबर", "आप जिस नंबर से संपर्क करना चाहते हैं", "पहुंच से बाहर", "पहुँच से बाहर",
        "स्विच ऑफ", "स्विच्ड ऑफ", "कवरेज क्षेत्र", "फिलहाल व्यस्त", "यह नंबर व्यस्त", "नंबर व्यस्त है",
        "वॉइसमेल", "वॉयस मेल", "इनकमिंग कॉल", "रिसीव नहीं हो रही", "कृपया थोड़ी देर", "थोड़ी देर में ट्राई", "थोड़ी देर बाद"
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

    /// True for a network-status message (unreachable, switched off, busy,
    /// voicemail, "cannot receive incoming calls" ...), wherever it occurs.
    public static func isStatusMessage(_ text: String) -> Bool {
        isOperator(text, phrases: statusPhrases)
    }

    /// Flags operator messages ("operator"), on either track, and returns every
    /// segment. Status messages (unreachable, busy, voicemail ...) are flagged at
    /// any time. The carrier spam/recording warning (`phrases`) only plays as the
    /// call connects, so it is only flagged in the first `withinSeconds`; a later
    /// mention of "spam" in real talk stays unflagged. Mic-track segments are
    /// covered because the microphone hears the speaker.
    public static func mark(_ segments: [Segment],
                            phrases: [String] = defaultPhrases,
                            withinSeconds: Double = 15) -> [Segment] {
        segments.map { segment in
            if isStatusMessage(segment.text) { return segment.flagged("operator") }
            if segment.start < withinSeconds, isOperator(segment.text, phrases: phrases) { return segment.flagged("operator") }
            return segment
        }
    }
}
