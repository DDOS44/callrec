import Foundation

public enum Speaker: String, Codable, Sendable {
    case me = "Me"
    case them = "Them"
    case unknown = ""

    public var label: String { rawValue }
}

public struct Segment {
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: Speaker

    public init(start: Double, end: Double, text: String, speaker: Speaker = .unknown) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    public var duration: Double { max(end - start, 0) }
}

public enum Markdown {
    public static func render(date: Date, seconds: Double, audioName: String,
                              segments: [Segment], raw: [Segment] = []) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        var out = "# Call \(f.string(from: date))\n\n"
        out += "- duration: \(m)m \(String(format: "%02d", s))s\n"
        out += "- audio: \(audioName)\n- outcome: \n- who picked up: \n\n## Transcript\n\n"
        for seg in segments {
            let mm = Int(seg.start) / 60, ss = Int(seg.start) % 60
            let stamp = String(format: "%02d:%02d", mm, ss)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            if seg.speaker == .unknown {
                out += "[\(stamp)] \(text)\n"
            } else {
                out += "[\(stamp)] **\(seg.speaker.label):** \(text)\n"
            }
        }
        out += "\n## Notes\n\n- what they said that wasn't in the flow: \n"
        // The unedited speech-to-text is kept so the cleanup can always be checked.
        if !raw.isEmpty, raw.map(\.text) != segments.map(\.text) {
            out += "\n## Raw transcript\n\n"
            for seg in raw {
                let mm = Int(seg.start) / 60, ss = Int(seg.start) % 60
                let stamp = String(format: "%02d:%02d", mm, ss)
                let text = seg.text.trimmingCharacters(in: .whitespaces)
                out += seg.speaker == .unknown ? "[\(stamp)] \(text)\n" : "[\(stamp)] **\(seg.speaker.label):** \(text)\n"
            }
        }
        return out
    }
}
