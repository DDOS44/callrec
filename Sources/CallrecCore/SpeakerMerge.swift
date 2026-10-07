import Foundation

/// Turns two single-track transcripts into one conversation.
///
/// There is no diarization model here: the far-side tap is by definition the
/// other person and the microphone is by definition you. The only real problem
/// is bleed - the Mac's microphone also hears the speaker, so whisper
/// transcribes their words a second time on the mic track.
public enum SpeakerMerge {

    /// Average RMS of `frames` between two times.
    public static func level(_ frames: [Float], from: Double, to: Double, frameSeconds: Double) -> Float {
        guard frameSeconds > 0, !frames.isEmpty else { return 0 }
        let first = max(0, Int(from / frameSeconds))
        let last = min(frames.count - 1, Int(to / frameSeconds))
        guard first <= last else { return 0 }
        let slice = frames[first...last]
        return slice.reduce(0, +) / Float(slice.count)
    }

    /// How much of `segment` sits inside `other`, as a fraction of `segment`.
    public static func overlapFraction(_ segment: Segment, _ other: Segment) -> Double {
        let start = max(segment.start, other.start)
        let end = min(segment.end, other.end)
        let shared = max(end - start, 0)
        guard segment.duration > 0 else { return shared > 0 ? 1 : 0 }
        return shared / segment.duration
    }

    // MARK: - Text similarity

    /// Lowercased words with punctuation stripped.
    public static func tokens(_ text: String) -> [String] {
        Announcements.normalise(text).split(separator: " ").map(String.init)
    }

    /// Token-level Jaccard: shared distinct words over all distinct words.
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let x = Set(tokens(a)), y = Set(tokens(b))
        if x.isEmpty && y.isEmpty { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// 1 - editDistance / longerLength on the normalised text. Catches the same
    /// words spelled slightly differently by the two passes ("abhee" / "abhi").
    public static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let x = Array(Announcements.normalise(a)), y = Array(Announcements.normalise(b))
        let longest = max(x.count, y.count)
        if longest == 0 { return 0 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(longest)
    }

    /// The better of the two measures.
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        max(jaccard(a, b), levenshteinRatio(a, b))
    }

    /// Text trigger: some far-side line that overlaps this mic line in time
    /// says (nearly) the same words. Independent of loudness.
    public static func isTextBleed(_ mine: Segment, them: [Segment],
                                   minSimilarity: Double = 0.7, slack: Double = 0.5) -> Bool {
        them.contains { other in
            let gap = max(mine.start, other.start) - min(mine.end, other.end)   // negative when they overlap
            return gap < slack && textSimilarity(mine.text, other.text) >= minSimilarity
        }
    }

    /// Energy trigger: mostly inside a far-side line, and quieter on the mic
    /// than on the tap.
    public static func isEnergyBleed(_ mine: Segment, them: [Segment], meRMS: [Float], themRMS: [Float],
                                     frameSeconds: Double, minOverlap: Double = 0.6, quietRatio: Float = 0.5) -> Bool {
        guard !meRMS.isEmpty, !themRMS.isEmpty else { return false }
        guard them.contains(where: { overlapFraction(mine, $0) > minOverlap }) else { return false }
        let mineLevel = level(meRMS, from: mine.start, to: mine.end, frameSeconds: frameSeconds)
        let theirLevel = level(themRMS, from: mine.start, to: mine.end, frameSeconds: frameSeconds)
        guard theirLevel > 0 else { return false }
        return mineLevel < theirLevel * quietRatio
    }

    /// Flags "me" segments that are really the other person leaking into the
    /// microphone. Two independent triggers: the words match a far-side line
    /// that overlaps in time (>= 70% similar), or the line sits mostly inside a
    /// far-side line while being much quieter on the mic. Nothing is removed.
    public static func markBleed(me: [Segment],
                                 them: [Segment],
                                 meRMS: [Float] = [],
                                 themRMS: [Float] = [],
                                 frameSeconds: Double = 1,
                                 minOverlap: Double = 0.6,
                                 quietRatio: Float = 0.5,
                                 minSimilarity: Double = 0.7) -> [Segment] {
        me.map { mine in
            if isTextBleed(mine, them: them, minSimilarity: minSimilarity)
                || isEnergyBleed(mine, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: frameSeconds,
                                 minOverlap: minOverlap, quietRatio: quietRatio) {
                return mine.flagged("bleed")
            }
            return mine
        }
    }

    /// One conversation, in time order. Every line from both tracks is kept;
    /// suspected bleed is flagged.
    public static func merge(me: [Segment],
                             them: [Segment],
                             meRMS: [Float] = [],
                             themRMS: [Float] = [],
                             frameSeconds: Double = 1) -> [Segment] {
        let marked = markBleed(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: frameSeconds)
        let tagged = marked.map { Segment(start: $0.start, end: $0.end, text: $0.text, speaker: .me, flags: $0.flags) }
            + them.map { Segment(start: $0.start, end: $0.end, text: $0.text, speaker: .them, flags: $0.flags) }
        return tagged.sorted { ($0.start, $0.speaker == .them ? 1 : 0) < ($1.start, $1.speaker == .them ? 1 : 0) }
    }
}
