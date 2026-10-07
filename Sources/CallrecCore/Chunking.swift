import Foundation

/// Pure helpers for transcribing long audio in pieces.
public enum Chunking {
    public static let maxChunkSeconds: Double = 600

    /// Whisper runs at about 1.7x realtime on this Mac; 6x leaves a wide margin.
    public static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        max(600, 6 * seconds)
    }

    /// Splits [0, total] into chunks of at most `maxSeconds`, cutting at the
    /// latest silence that keeps the chunk above half the maximum, and
    /// hard-cutting at `maxSeconds` when there is none. `silences` are the
    /// midpoints of detected silences, in seconds.
    public static func chunks(totalSeconds: Double, silences: [Double],
                              maxSeconds: Double = maxChunkSeconds) -> [(start: Double, end: Double)] {
        guard totalSeconds > maxSeconds else { return [(0, totalSeconds)] }
        let sorted = silences.sorted()
        var out: [(start: Double, end: Double)] = []
        var start = 0.0
        while totalSeconds - start > maxSeconds {
            let limit = start + maxSeconds
            let floor = start + maxSeconds / 2
            let cut = sorted.last(where: { $0 > floor && $0 <= limit }) ?? limit
            out.append((start, cut))
            start = cut
        }
        out.append((start, totalSeconds))
        return out
    }

    /// Moves a chunk's segment timestamps onto the whole recording's timeline.
    public static func offset(_ segments: [Segment], by seconds: Double) -> [Segment] {
        segments.map { Segment(start: $0.start + seconds, end: $0.end + seconds, text: $0.text, speaker: $0.speaker, flags: $0.flags) }
    }

    /// Midpoints of the silences in ffmpeg silencedetect output.
    public static func silenceMidpoints(fromSilencedetect log: String) -> [Double] {
        var out: [Double] = []
        var pendingStart: Double?
        for line in log.components(separatedBy: "\n") {
            if let v = value(after: "silence_start:", in: line) {
                pendingStart = v
            } else if let end = value(after: "silence_end:", in: line), let s = pendingStart {
                out.append((s + end) / 2)
                pendingStart = nil
            }
        }
        return out
    }

    private static func value(after key: String, in line: String) -> Double? {
        guard let r = line.range(of: key) else { return nil }
        let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(rest.prefix(while: { "0123456789.-".contains($0) }))
    }
}
