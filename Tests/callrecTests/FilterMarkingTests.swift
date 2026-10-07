import Foundation
import Testing
@testable import CallrecCore

@Test func noSpeechTranscript() {
    let empty = Markdown.render(date: Date(), seconds: 19, audioName: "x.m4a", segments: [])
    expect(empty.contains(Markdown.noSpeechLine), "nospeech.mdSaysSo", "no explanatory line")
    equal(MarkdownFields.hasNoSpeech(md: empty), true, "nospeech.detected")
    equal(MarkdownFields.segments(md: empty).count, 0, "nospeech.noPhantomSegments")
    // a legacy empty transcript (written before the marker existed) is recognised too
    equal(MarkdownFields.hasNoSpeech(md: empty.replacingOccurrences(of: Markdown.noSpeechLine + "\n", with: "")), true, "nospeech.legacyEmpty")
    let talk = Markdown.render(date: Date(), seconds: 9, audioName: "x.m4a", segments: [Segment(start: 1, end: 2, text: "haan", speaker: .them)])
    equal(MarkdownFields.hasNoSpeech(md: talk), false, "nospeech.realCallIsNot")
    let failed = Markdown.renderFailure(date: Date(), seconds: 9, audioName: "x.m4a", error: "boom", id: "d/b")
    equal(MarkdownFields.hasNoSpeech(md: failed), false, "nospeech.failureIsNot")
    // re-transcribing into an empty result keeps the note and the header fields
    let redone = MarkdownFields.replaceTranscript(md: talk, with: [])
    expect(redone.contains(Markdown.noSpeechLine) && MarkdownFields.hasNoSpeech(md: redone), "nospeech.replaceEmpty", "replace lost the marker")
    // and a later real transcript removes it
    let back = MarkdownFields.replaceTranscript(md: redone, with: [Segment(start: 1, end: 2, text: "haan", speaker: .them)])
    expect(!back.contains(Markdown.noSpeechLine), "nospeech.removedOnRealTranscript", "marker stuck")
}

@Test func flagsNeverDelete() {
    // The marker round-trips through the file and the parser.
    let flagged = Segment(start: 5, end: 6, text: "You cannot receive incoming calls.", speaker: .me, flags: ["bleed"])
    equal(Markdown.line(for: flagged), "[00:05] **Me:** You cannot receive incoming calls.  <!-- flagged: bleed -->", "mark.line")
    let md = Markdown.render(date: Date(), seconds: 9, audioName: "x.m4a",
                             segments: [flagged, Segment(start: 7, end: 8, text: "haan", speaker: .them, flags: ["operator", "loop"])])
    let back = MarkdownFields.segments(md: md)
    equal(back.map(\.flags), [["bleed"], ["operator", "loop"]], "mark.parseFlags")
    equal(back.map(\.text), ["You cannot receive incoming calls.", "haan"], "mark.parseTextClean")
    equal(MarkdownFields.hasNoSpeech(md: md), false, "mark.flaggedOnlyIsNotNoSpeech")
    equal(MarkdownFields.firstTranscriptLine(md: md), "You cannot receive incoming calls.", "mark.previewHasNoMarker")
    let replaced = MarkdownFields.replaceTranscript(md: md, with: [flagged])
    equal(MarkdownFields.segments(md: replaced).first?.flags ?? [], ["bleed"], "mark.replaceKeepsFlag")
    // Operator announcements are flagged and every line survives.
    let ann = Announcements.mark([Segment(start: 1, end: 3, text: "The number you are trying to reach is switched off", speaker: .them),
                                  Segment(start: 5, end: 6, text: "haan ji", speaker: .me)])
    equal(ann.count, 2, "mark.operatorKeepsAll")
    equal(ann.map(\.flags), [["operator"], []], "mark.operatorFlag")
    // Bleed is flagged, not dropped (merge keeps both tracks entirely).
    let merged = SpeakerMerge.merge(me: [Segment(start: 0, end: 4, text: "Kaun bol raha hai?")],
                                    them: [Segment(start: 0, end: 4, text: "Kaun bol raha hai?")])
    equal(merged.count, 2, "mark.bleedKeepsAll")
    equal(merged.first(where: { $0.speaker == .me })?.flags ?? [], ["bleed"], "mark.bleedFlag")
}

@Test func hallucinationMeansRepetition() {
    func seg(_ t: String, _ at: Double = 0) -> Segment { Segment(start: at, end: at + 1, text: t) }
    // Positive: the old failure signature.
    let loop = Hallucination.mark([seg(String(repeating: "हेलो ", count: 40))])
    equal(loop.first?.flags ?? [], ["loop"], "halluc.tokenLoop40")
    equal(Hallucination.hasTokenLoop("haan haan haan haan"), true, "halluc.fourInARow")
    equal(Hallucination.hasTokenLoop("Haan, haan, HAAN, haan. ji"), true, "halluc.caseAndPunctuation")
    let same = Hallucination.mark([seg("Subscribe.", 1), seg("Subscribe.", 2), seg("subscribe", 3), seg("haan", 9)])
    equal(same.map(\.flags), [["loop"], ["loop"], ["loop"], []], "halluc.identicalLines3")
    // Negative: short real utterances must never be flagged.
    let real = ["haan", "ji", "hello", "achha", "theek hai", "haan ji", "Haan hello hello.", "haan haan haan ji", "ok ok ok",
                "Haan hello hello. Aa rahi hoon aaj? Haan. Achchha.", "kar do kar do kar do"]
    equal(real.filter { Hallucination.hasTokenLoop($0) }, [], "halluc.shortRealNeverTokenLoop")
    let talk = Hallucination.mark(["haan", "ji", "hello", "achha", "theek hai", "haan", "ji", "haan", "ji", "haan"].enumerated()
        .map { seg($0.element, Double($0.offset)) })
    equal(talk.flatMap(\.flags), [], "halluc.stringOfShortUtterancesNotFlagged")
    let twice = Hallucination.mark([seg("haan", 1), seg("haan", 2), seg("ji", 3)])
    equal(twice.flatMap(\.flags), [], "halluc.twoIdenticalNotFlagged")
    equal(Hallucination.mark([seg("")]).flatMap(\.flags), [], "halluc.emptyNotFlagged")
}
