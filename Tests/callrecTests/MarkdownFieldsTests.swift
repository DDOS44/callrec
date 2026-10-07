import Foundation
import Testing
@testable import CallrecCore

@Test func markdownFieldRoundTrip() {
    var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 14; c.minute = 2; c.second = 0
    guard let d = Calendar.current.date(from: c) else { Issue.record("fields: bad date"); return }
    let original = Markdown.render(date: d, seconds: 65.4, audioName: "14-02-00.m4a", segments: [
        Segment(start: 0, end: 2.5, text: "Haan ji, boliye."),
        Segment(start: 62, end: 65, text: "Theek hai, Thursday.")
    ])

    let updated = MarkdownFields.update(md: original, outcome: "booked",
                                        who: "Vineet", notes: "wants Thursday\nnot Friday")
    let back = MarkdownFields.read(md: updated)
    equal(back.outcome, "booked", "fields.outcomeRoundTrip")
    equal(back.who, "Vineet", "fields.whoRoundTrip")
    equal(back.notes, "wants Thursday not Friday", "fields.notesRoundTrip")

    // The transcript must survive editing untouched.
    expect(updated.contains("[00:00] Haan ji, boliye."), "fields.transcriptKept0", "first segment lost")
    expect(updated.contains("[01:02] Theek hai, Thursday."), "fields.transcriptKept1", "second segment lost")
    equal(MarkdownFields.segments(md: updated).count, 2, "fields.segmentCount")
    equal(MarkdownFields.segments(md: updated).first?.start ?? -1, 0, "fields.segmentStart0")
    equal(MarkdownFields.segments(md: updated).last?.start ?? -1, 62, "fields.segmentStart1")
    equal(MarkdownFields.firstTranscriptLine(md: updated), "Haan ji, boliye.", "fields.preview")
    equal(MarkdownFields.duration(md: updated), 65, "fields.duration")

    // Editing twice must not duplicate or drift.
    let twice = MarkdownFields.update(md: updated, outcome: "callback", who: "", notes: "")
    equal(MarkdownFields.read(md: twice), MarkdownFields.Fields(outcome: "callback", who: "", notes: ""), "fields.secondEdit")
    equal(twice.components(separatedBy: "- outcome:").count - 1, 1, "fields.noDuplicateOutcome")
    equal(MarkdownFields.segments(md: twice).count, 2, "fields.transcriptStillIntact")
}
