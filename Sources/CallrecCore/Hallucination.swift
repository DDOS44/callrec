import Foundation

/// Detects the model's real failure signature: a loop. The old model wrote
/// "हेलो" forty times over silence. Detection is by repetition only, never by
/// brevity: "haan", "ji", "hello", "achha", "theek hai" are the substance of a
/// Hindi sales call and must never be flagged.
public enum Hallucination {

    /// The same word 4 or more times in a row, ignoring case and punctuation.
    public static func hasTokenLoop(_ text: String, minRepeats: Int = 4) -> Bool {
        let tokens = SpeakerMerge.tokens(text)
        var run = 1
        for i in tokens.indices.dropFirst() {
            run = tokens[i] == tokens[i - 1] ? run + 1 : 1
            if run >= minRepeats { return true }
        }
        return false
    }

    /// Flags ("loop") lines whose text has a token loop, and every line of a run
    /// of 3 or more identical consecutive lines. `segments` must be one track
    /// in time order. Nothing is removed.
    public static func mark(_ segments: [Segment], minLineRepeats: Int = 3) -> [Segment] {
        var loop = Set<Int>()
        for (i, s) in segments.enumerated() where hasTokenLoop(s.text) { loop.insert(i) }
        let norm = segments.map { Announcements.normalise($0.text) }
        var i = 0
        while i < segments.count {
            var j = i + 1
            while j < segments.count, !norm[i].isEmpty, norm[j] == norm[i] { j += 1 }
            if j - i >= minLineRepeats { for k in i..<j { loop.insert(k) } }
            i = j
        }
        return segments.enumerated().map { loop.contains($0.offset) ? $0.element.flagged("loop") : $0.element }
    }
}
