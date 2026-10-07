import Foundation
import Testing
@testable import CallrecCore

@Test func transcriptMarkdown() {
    var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 14; c.minute = 2; c.second = 0
    guard let d = Calendar.current.date(from: c) else { Issue.record("markdown: bad date"); return }
    let md = Markdown.render(date: d, seconds: 65.4, audioName: "14-02-00.m4a", segments: [
        Segment(start: 0, end: 2.5, text: "Hi, is Vineet around?"),
        Segment(start: 62, end: 65, text: "Theek hai, Thursday.")
    ])
    expect(md.hasPrefix("# Call 2026-09-18 14:02\n"), "markdown.title", "bad title line")
    expect(md.contains("- duration: 1m 05s"), "markdown.duration", "bad duration")
    expect(md.contains("- audio: 14-02-00.m4a"), "markdown.audio", "bad audio line")
    expect(md.contains("[00:00] Hi, is Vineet around?"), "markdown.firstSegment", "missing first segment")
    expect(md.contains("[01:02] Theek hai, Thursday."), "markdown.secondSegment", "missing second segment")
    expect(md.contains("## Notes\n"), "markdown.notes", "missing notes section")
}

@Test func speechTimelineMapping() {
    equal(SpeechTimeline.splitLong([SpeechRegion(start: 0, end: 60)]).count, 3, "regions.splitLong")
    equal(SpeechTimeline.splitLong([SpeechRegion(start: 0, end: 20)]).count, 1, "regions.shortUntouched")
    // nearby regions share one clip so the model has a sentence of context
    let sp = SpeechTimeline.spans([SpeechRegion(start: 1.7, end: 2.4), SpeechRegion(start: 2.8, end: 3.6), SpeechRegion(start: 20, end: 21)])
    equal(sp, [SpeechRegion(start: 1.7, end: 3.6), SpeechRegion(start: 20, end: 21)], "spans.joinNearby")
    equal(SpeechTimeline.spans((0..<10).map { SpeechRegion(start: Double($0) * 4, end: Double($0) * 4 + 3) }).allSatisfy { $0.length <= 25 }, true, "spans.cap25")
    // a 0.32 s burst is a region now: VAD's own decision is the only gate
    var burst = [Float](repeating: 0, count: 100)
    for i in 10..<20 { burst[i] = 0.9 }
    equal(SpeechTimeline.regions(probabilities: burst, frameSeconds: 0.032, totalSeconds: 3.2).count, 1, "regions.shortBurstKept")
    // regions from probabilities: 32 ms frames
    var probs = [Float](repeating: 0, count: 100)
    for i in 10..<40 { probs[i] = 0.9 }     // 0.32s-1.28s speech
    for i in 50..<53 { probs[i] = 0.9 }     // 0.1s blip: below VAD's own minimum, dropped
    for i in 70..<90 { probs[i] = 0.9 }     // 2.24s-2.88s speech
    let r = SpeechTimeline.regions(probabilities: probs, frameSeconds: 0.032, totalSeconds: 3.2)
    equal(r.count, 2, "regions.count")
    equal(abs((r.first?.start ?? 0) - 0.12) < 1e-6, true, "regions.padStart")
    equal(abs((r.first?.end ?? 0) - 1.48) < 1e-6, true, "regions.padEnd")
    // two bursts 0.2 s apart merge once padded
    var close = [Float](repeating: 0, count: 60)
    for i in 5..<20 { close[i] = 0.9 }
    for i in 27..<40 { close[i] = 0.9 }
    equal(SpeechTimeline.regions(probabilities: close, frameSeconds: 0.032, totalSeconds: 2).count, 1, "regions.mergeClose")
    equal(SpeechTimeline.regions(probabilities: [], frameSeconds: 0.032, totalSeconds: 0).count, 0, "regions.empty")
    // speech running to the end of the audio is closed there
    let tail = [Float](repeating: 0.9, count: 20)
    let t = SpeechTimeline.regions(probabilities: tail, frameSeconds: 0.032, totalSeconds: 0.64)
    equal(t.count, 1, "regions.tailCount")
    equal(abs((t.first?.end ?? 0) - 0.64) < 1e-9, true, "regions.tailEnd")
}
