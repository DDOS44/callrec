import Foundation

/// Devanagari to Roman, spelled the way people actually type Hindi in chat
/// (Hinglish), not the way a library transliterates it.
///
/// Whisper transcribes Hindi in Devanagari even when asked not to. The text is
/// accurate, so rather than fight the model we convert the script afterwards.
public enum Transliterate {

    // MARK: Tables

    static let consonants: [Character: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "f", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v", "ळ": "l",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        "ड़": "d", "ढ़": "dh", "ज़": "z", "फ़": "f", "क़": "k", "ख़": "kh", "ग़": "g", "ऱ": "r"
    ]

    static let vowelSigns: [Character: String] = [
        "ा": "aa", "ि": "i", "ी": "ee", "ु": "u", "ू": "oo",
        "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ृ": "ri",
        "ॉ": "o", "ॅ": "e"
    ]

    static let independentVowels: [Character: String] = [
        "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo",
        "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऋ": "ri", "ऑ": "o", "ॲ": "a"
    ]

    static let digits: [Character: String] = [
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9"
    ]

    static let virama: Character = "्"
    static let nukta: Character = "़"
    static let anusvara: Character = "ं"
    static let chandrabindu: Character = "ँ"
    static let visarga: Character = "ः"

    /// Words whose natural Hinglish spelling is not what the rules produce.
    static let wordOverrides: [String: String] = [
        "हूँ": "hoon", "हूं": "hoon", "हुँ": "hoon",
        "है": "hai", "हैं": "hain", "था": "tha", "थी": "thi", "थे": "the",
        "नहीं": "nahi", "नही": "nahi", "ना": "na",
        "क्या": "kya", "क्यों": "kyun", "कि": "ki", "की": "ki", "को": "ko", "का": "ka", "के": "ke",
        "मैं": "main", "मुझे": "mujhe", "मुझको": "mujhko", "मेरा": "mera", "मेरी": "meri",
        "तुम्हे": "tumhe", "तुम्हें": "tumhe", "तुम्हारा": "tumhara", "तुम": "tum",
        "आप": "aap", "आपका": "aapka", "आपको": "aapko",
        "ठीक": "theek", "हाँ": "haan", "हां": "haan", "भाई": "bhai",
        "पैसा": "paisa", "पैसे": "paise", "काम": "kaam", "बात": "baat",
        "यार": "yaar", "अच्छा": "accha", "बोलिए": "boliye", "बोलो": "bolo",
        "जी": "ji", "और": "aur", "में": "mein", "से": "se", "पर": "par",
        "रहा": "raha", "रही": "rahi", "रहे": "rahe", "कर": "kar", "करो": "karo",
        "दे": "de", "देना": "dena", "ले": "le", "लो": "lo", "गया": "gaya", "गई": "gayi"
    ]

    /// English words whisper wrote out in Devanagari.
    static let loanWords: [String: String] = [
        "बैंक": "bank", "अमाउंट": "amount", "अमाउन्ट": "amount", "चेक": "check",
        "रिकॉर्डिंग": "recording", "रिकार्डिंग": "recording", "मीटिंग": "meeting",
        "क्लाइंट": "client", "क्लाइअंट": "client", "रिक्रूटमेंट": "recruitment",
        "एजेंसी": "agency", "एजेन्सी": "agency", "कॉल": "call", "फोन": "phone", "फ़ोन": "phone",
        "ईमेल": "email", "थर्सडे": "Thursday", "फ्राइडे": "Friday", "ओके": "okay",
        "स्कैमर": "scammer", "स्कामर": "scammer", "पेटीएम": "Paytm", "मम्मी": "mummy",
        "व्हाट्सएप": "WhatsApp", "गूगल": "Google", "ऑफिस": "office", "सर": "sir",
        "मैडम": "madam", "कंपनी": "company", "कम्पनी": "company", "प्रोजेक्ट": "project"
    ]

    // MARK: Entry point

    public static func devanagariToRoman(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isDevanagari) else { return text }
        var out = ""
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            out += convertWord(word)
            word = ""
        }

        for ch in text {
            if ch.unicodeScalars.allSatisfy(isDevanagari) {
                word.append(ch)
            } else {
                flush()
                out.append(ch == "।" ? "." : ch)
            }
        }
        flush()
        return out
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(Int(scalar.value))
    }

    // MARK: One word

    static func convertWord(_ word: String) -> String {
        if let loan = loanWords[word] { return loan }
        if let override = wordOverrides[word] { return override }

        // Scalars, not Characters: Swift groups a consonant and its vowel sign
        // into a single Character, which would hide the vowel entirely.
        let chars = word.unicodeScalars.map { Character($0) }
        var out = ""
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            // A nukta modifies the consonant before it: क + ़ is one letter.
            if i + 1 < chars.count, chars[i + 1] == nukta, let combined = nuktaForms[ch] {
                out += combined
                i += 2
                if i < chars.count, let sign = vowelSigns[chars[i]] {
                    out += vowelSound(chars[i], sign, isLast: i == chars.count - 1)
                    i += 1
                } else if i < chars.count, chars[i] == virama {
                    i += 1
                } else {
                    appendInherentVowel(&out, chars: chars, after: i)
                }
                continue
            }

            if let consonant = consonants[ch] {
                out += consonant
                i += 1
                // What follows decides whether the built-in "a" is spoken.
                if i < chars.count, let sign = vowelSigns[chars[i]] {
                    out += vowelSound(chars[i], sign, isLast: i == chars.count - 1)
                    i += 1
                } else if i < chars.count, chars[i] == virama {
                    i += 1                       // cluster: no vowel at all
                } else {
                    appendInherentVowel(&out, chars: chars, after: i)
                }
                continue
            }

            if let vowel = independentVowels[ch] { out += vowel; i += 1; continue }
            if let digit = digits[ch] { out += digit; i += 1; continue }

            switch ch {
            case anusvara, chandrabindu:
                // "m" before a lip consonant, "n" everywhere else.
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lip: Set<Character> = ["प", "फ", "ब", "भ", "म"]
                out += (next.map { lip.contains($0) } ?? false) ? "m" : "n"
            case visarga: out += "h"
            case "।": out += "."
            case virama, nukta: break
            default: out.append(ch)
            }
            i += 1
        }

        return out
    }

    /// A long "aa" at the very end of a word is written "a" in Hinglish:
    /// करूंगा is "karoonga", not "karoongaa".
    private static func vowelSound(_ sign: Character, _ mapped: String, isLast: Bool) -> String {
        (isLast && sign == "ा") ? "a" : mapped
    }

    /// Hindi drops the inherent "a" at the end of a word: राम is "raam", not "raama".
    private static func appendInherentVowel(_ out: inout String, chars: [Character], after index: Int) {
        guard index < chars.count else { return }     // word end: schwa deleted
        let next = chars[index]
        if next == virama { return }
        if vowelSigns[next] != nil { return }
        out += "a"
    }
}

extension Transliterate {
    /// Consonants that are written as a base letter plus a nukta.
    static let nuktaForms: [Character: String] = [
        "क": "k", "ख": "kh", "ग": "g", "ज": "z", "ड": "d", "ढ": "dh", "फ": "f", "य": "y", "र": "r"
    ]
}
