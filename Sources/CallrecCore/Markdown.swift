import Foundation

public struct Segment {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum Markdown {
    public static func render(date: Date, seconds: Double, audioName: String, segments: [Segment]) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        var out = "# Call \(f.string(from: date))\n\n"
        out += "- duration: \(m)m \(String(format: "%02d", s))s\n"
        out += "- audio: \(audioName)\n- outcome: \n- who picked up: \n\n## Transcript\n\n"
        for seg in segments {
            let mm = Int(seg.start) / 60, ss = Int(seg.start) % 60
            out += "[\(String(format: "%02d:%02d", mm, ss))] \(seg.text.trimmingCharacters(in: .whitespaces))\n"
        }
        out += "\n## Notes\n\n- what they said that wasn't in the flow: \n"
        return out
    }
}
