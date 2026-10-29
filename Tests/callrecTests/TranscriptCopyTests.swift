import Testing
@testable import CallrecCore

@Test func copiedTranscriptHasAHeaderTimesAndSpeakers() {
    let t = TranscriptCopy.text(header: "Fake Co · 29 Oct 16:17 · 1m 16s", lines: [
        (start: 10, speaker: .unknown, text: " Hello. Is this Fake Co? "),
        (start: 82, speaker: .them, text: "Haan ji."),
        (start: 85, speaker: .me, text: "Thank you.")])
    #expect(t == "Fake Co · 29 Oct 16:17 · 1m 16s\n\n[00:10] Hello. Is this Fake Co?\n[01:22] Them: Haan ji.\n[01:25] Me: Thank you.")
}
