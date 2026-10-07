import Foundation
import Testing
@testable import CallrecCore

@Test func speakerAttributionAndBleedGuard() {

    // 1 frame = 1 s. They talk loudly from 0-4; I talk from 5-8.
    let themRMS: [Float] = [0.30, 0.30, 0.30, 0.30, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01]
    let meRMS: [Float]   = [0.05, 0.05, 0.05, 0.05, 0.01, 0.20, 0.20, 0.20, 0.20, 0.01]

    let them = [Segment(start: 0, end: 4, text: "Kaun bol raha hai?")]
    // The first "me" line is the speaker bleeding into the mic; the second is real.
    let me = [Segment(start: 0, end: 4, text: "Kaun bol raha hai?"),
              Segment(start: 5, end: 8, text: "Rahul baat kar raha hoon.")]

    func unflaggedCount(_ x: [Segment]) -> Int { x.filter { $0.flags.isEmpty }.count }
    let kept = SpeakerMerge.markBleed(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
    equal(kept.count, 2, "speaker.bleedStillPresent")
    equal(kept.first?.flags ?? [], ["bleed"], "speaker.bleedFlagged")
    equal(kept.last?.flags ?? ["x"], [], "speaker.realLineUnflagged")

    // Loud on the mic over the same window means I really did talk over them.
    let loudMe: [Float] = [0.40, 0.40, 0.40, 0.40, 0.01, 0.20, 0.20, 0.20, 0.20, 0.01]
    // (different words: identical words overlapping in time are dropped by the text trigger regardless of loudness)
    let talkOver = [Segment(start: 0, end: 4, text: "Nahi nahi, ruko zara."), me[1]]
    equal(unflaggedCount(SpeakerMerge.markBleed(me: talkOver, them: them, meRMS: loudMe, themRMS: themRMS, frameSeconds: 1)),
               2, "speaker.talkOverKept")

    // Overlap below the threshold is never treated as bleed.
    let brief = [Segment(start: 3, end: 8, text: "haan")]
    equal(unflaggedCount(SpeakerMerge.markBleed(me: brief, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)),
               1, "speaker.lowOverlapKept")

    equal(SpeakerMerge.overlapFraction(Segment(start: 0, end: 4, text: ""),
                                            Segment(start: 0, end: 2, text: "")), 0.5, "speaker.overlapHalf")
    equal(SpeakerMerge.overlapFraction(Segment(start: 10, end: 12, text: ""),
                                            Segment(start: 0, end: 2, text: "")), 0, "speaker.noOverlap")
    equal(SpeakerMerge.level(themRMS, from: 0, to: 3.9, frameSeconds: 1), 0.30, "speaker.level")

    // Text trigger (no RMS needed): exact duplicate, partial overlap, separate lines, no overlap.
    let themLine = [Segment(start: 5, end: 9, text: "You cannot receive incoming calls.")]
    func textKept(_ m: Segment, _ t: [Segment] = themLine) -> Bool { SpeakerMerge.markBleed(me: [m], them: t).allSatisfy { $0.flags.isEmpty } }
    expect(!textKept(Segment(start: 5, end: 9, text: "you cannot receive incoming calls")), "bleed.exactDuplicate", "duplicate kept")
    expect(!textKept(Segment(start: 7, end: 11, text: "You cannot receive incoming call!")), "bleed.partialOverlap", "partially overlapping near-duplicate kept")
    expect(!textKept(Segment(start: 4, end: 8, text: "Ye cannot recieve incoming calls")), "bleed.spellingDrift", "spelling drift kept")
    // Both genuinely say "haan ji", at different times: separate lines, both stay.
    let haanThem = [Segment(start: 10, end: 11, text: "Haan ji.")]
    expect(textKept(Segment(start: 20, end: 21, text: "haan ji"), haanThem), "bleed.separateHaanJi", "a separate 'haan ji' was dropped")
    expect(textKept(Segment(start: 20, end: 24, text: "You cannot receive incoming calls.")), "bleed.noOverlap", "identical text with no time overlap was dropped")
    expect(textKept(Segment(start: 6, end: 9, text: "Rahul baat kar raha hoon")), "bleed.overlapDifferentWords", "overlapping but different words dropped")
    expect(SpeakerMerge.jaccard("a b c d", "a b c e") == 0.6, "bleed.jaccard", "\(SpeakerMerge.jaccard("a b c d", "a b c e"))")
    expect(SpeakerMerge.levenshteinRatio("kitten", "kitten") == 1, "bleed.levIdentical", "ratio of identical != 1")
    expect(SpeakerMerge.textSimilarity("", "") == 0, "bleed.emptySimilarity", "empty text similar")
    // Energy trigger alone, different words.
    let quietBleed = [Segment(start: 0, end: 4, text: "totally different words here")]
    equal(SpeakerMerge.isEnergyBleed(quietBleed[0], them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1), true, "bleed.energyAlone")

    // Merged output is in time order and labelled.
    let merged = SpeakerMerge.merge(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
    equal(merged.count, 3, "speaker.mergedCountKeepsBleed")
    equal(merged.filter { $0.flags.isEmpty }.count, 2, "speaker.mergedUnflagged")
    equal(merged.first?.flags ?? [], ["bleed"], "speaker.firstIsFlaggedBleed")
    equal(merged.last?.speaker ?? .unknown, .me, "speaker.lastIsMe")

    // The markdown carries the labels, and reading it back recovers them.
    let md = Markdown.render(date: Date(), seconds: 10, audioName: "x.m4a", segments: merged)
    expect(md.contains("[00:00] **Them:** Kaun bol raha hai?"), "speaker.markdownThem", "them line missing")
    expect(md.contains("[00:05] **Me:** Rahul baat kar raha hoon."), "speaker.markdownMe", "me line missing")
    let parsed = MarkdownFields.segments(md: md)
    equal(parsed.count, 3, "speaker.parsedCount")
    equal(parsed.first?.flags ?? [], ["bleed"], "speaker.parsedFlag")
    equal(parsed.first?.text ?? "", "Kaun bol raha hai?", "speaker.parsedTextClean")
    equal(MarkdownFields.firstTranscriptLine(md: md), "Kaun bol raha hai?", "speaker.previewStripsLabel")
}
