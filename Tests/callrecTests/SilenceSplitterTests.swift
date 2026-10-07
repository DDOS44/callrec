import Foundation
import Testing
@testable import CallrecCore

@Test func silenceSplitting() {
    // 1 frame = 1 s. speech 0-10, silence 10-40, speech 40-55, tiny gap, speech 56-70
    var rms = [Float](repeating: 0.2, count: 10) + [Float](repeating: 0.001, count: 30)
    rms += [Float](repeating: 0.2, count: 15) + [0.001] + [Float](repeating: 0.2, count: 14)
    let s = SilenceSplitter.spans(rms: rms, frameSeconds: 1, threshold: 0.01, minGapSeconds: 20, minSpanSeconds: 8)
    equal(s.count, 2, "silence.count")
    if s.count == 2 {
        equal(s[0].start, 0, "silence.span0.start")
        equal(s[0].end, 10, "silence.span0.end")
        equal(s[1].start, 40, "silence.span1.start")
        equal(s[1].end, 70, "silence.span1.end")
    }
    let short = [Float](repeating: 0.2, count: 3) + [Float](repeating: 0.0, count: 30)
    expect(SilenceSplitter.spans(rms: short, frameSeconds: 1, threshold: 0.01,
                                      minGapSeconds: 20, minSpanSeconds: 8).isEmpty,
                "silence.dropsShortSpans", "short span was kept")
}
