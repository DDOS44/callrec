import Foundation

enum SilenceSplitter {
    /// Given per-frame RMS values, returns the speech spans separated by gaps
    /// of at least `minGapSeconds`, dropping spans shorter than `minSpanSeconds`.
    static func spans(rms: [Float], frameSeconds: Double, threshold: Float,
                      minGapSeconds: Double, minSpanSeconds: Double) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        var spanStart: Int? = nil
        var lastLoud = 0
        let gapFrames = Int(minGapSeconds / frameSeconds)
        for (i, v) in rms.enumerated() {
            if v >= threshold {
                if spanStart == nil { spanStart = i }
                lastLoud = i
            } else if let s = spanStart, i - lastLoud >= gapFrames {
                out.append((Double(s) * frameSeconds, Double(lastLoud + 1) * frameSeconds))
                spanStart = nil
            }
        }
        if let s = spanStart {
            out.append((Double(s) * frameSeconds, Double(lastLoud + 1) * frameSeconds))
        }
        return out.filter { $0.1 - $0.0 >= minSpanSeconds }.map { (start: $0.0, end: $0.1) }
    }
}
