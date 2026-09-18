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

    /// Drops "me" segments that are really the other person leaking into the
    /// microphone: mostly overlapping one of their segments, and quieter on the
    /// mic than they are on the tap.
    public static func removeBleed(me: [Segment],
                                   them: [Segment],
                                   meRMS: [Float],
                                   themRMS: [Float],
                                   frameSeconds: Double,
                                   minOverlap: Double = 0.6,
                                   quietRatio: Float = 0.5) -> [Segment] {
        me.filter { mine in
            let overlapping = them.filter { overlapFraction(mine, $0) > minOverlap }
            guard !overlapping.isEmpty else { return true }
            let mineLevel = level(meRMS, from: mine.start, to: mine.end, frameSeconds: frameSeconds)
            let theirLevel = level(themRMS, from: mine.start, to: mine.end, frameSeconds: frameSeconds)
            guard theirLevel > 0 else { return true }
            return mineLevel >= theirLevel * quietRatio
        }
    }

    /// One conversation, in time order.
    public static func merge(me: [Segment],
                             them: [Segment],
                             meRMS: [Float] = [],
                             themRMS: [Float] = [],
                             frameSeconds: Double = 1) -> [Segment] {
        let keptMe = meRMS.isEmpty || themRMS.isEmpty
            ? me
            : removeBleed(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: frameSeconds)
        let tagged = keptMe.map { Segment(start: $0.start, end: $0.end, text: $0.text, speaker: .me) }
            + them.map { Segment(start: $0.start, end: $0.end, text: $0.text, speaker: .them) }
        return tagged.sorted { ($0.start, $0.speaker == .them ? 1 : 0) < ($1.start, $1.speaker == .them ? 1 : 0) }
    }
}
