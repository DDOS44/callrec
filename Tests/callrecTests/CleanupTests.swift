import Foundation
import Testing
@testable import CallrecCore

@Test func operatorAnnouncementStripping() {
    expect(Announcements.isOperator("agla call scammer ho sakta hai"), "ann.scammer", "missed scammer warning")
    // Whisper writes it phonetically; that spelling must match too.
    expect(Announcements.isOperator("ki agala call skaim hai"), "ann.phoneticScam", "missed the phonetic spelling")
    expect(Announcements.isOperator("yeh call spam ho sakti hai"), "ann.spam", "missed spam warning")
    expect(Announcements.isOperator("This call may be SPAM."), "ann.caseAndPunctuation", "case or punctuation broke the match")
    expect(Announcements.isOperator("aapka call record kiya ja raha hai"), "ann.recording", "missed recording warning")
    expect(Announcements.isOperator("the number you have dialled is not reachable"), "ann.unreachable", "missed unreachable message")
    expect(!Announcements.isOperator("haan ji boliye, main Rahul bol raha hoon"), "ann.realSpeech", "dropped real speech")
    expect(!Announcements.isOperator(""), "ann.empty", "empty text matched")

    // The carrier warning only plays at the start; status messages can come any time, on either track.
    let segments = [
        Segment(start: 1, end: 4, text: "agla call scammer ho sakta hai", speaker: .them),
        Segment(start: 6, end: 9, text: "haan ji boliye", speaker: .them),
        Segment(start: 40, end: 44, text: "spam call ke baare mein baat kar rahe the", speaker: .them),
        Segment(start: 3, end: 5, text: "this call may be spam", speaker: .me)
    ]
    let marked = Announcements.mark(segments)
    func unflagged(_ s: [Segment]) -> [Segment] { s.filter { $0.flags.isEmpty } }
    equal(marked.count, 4, "ann.nothingRemoved")
    equal(unflagged(marked).count, 2, "ann.flaggedEarlyWarnings")
    expect(marked[0].flags == ["operator"], "ann.warningFlagged", "warning not flagged")
    expect(marked[2].flags.isEmpty, "ann.lateMentionUnflagged", "a later mention of spam was flagged")
    expect(marked[3].flags == ["operator"], "ann.micWarningFlagged", "warning bled into the mic track not flagged")
    expect(Announcements.mark([Segment(start: 5, end: 8, text: "haan ji bolo", speaker: .me)]).allSatisfy { $0.flags.isEmpty },
                "ann.myWordsUnflagged", "my own line was flagged")

    // Status-message family: Roman and Devanagari, loose matching, any time, both tracks.
    let status = [
        "Number unreachable.", "You cannot receive incoming calls.", "The number you are trying to reach is switched off",
        "आप जिस नंबर से संपर्क करना चाहते हैं वह पहुंच से बाहर है", "out of coverage area", "The number is busy",
        "Your call has been forwarded to voicemail", "the number you are trying to reach is currently unavailable",
        "kripaya thodi der mein try karein", "is number par abhi incoming calls receive nahi ho rahi",
        "इस नंबर पर अभी इनकमिंग कॉल्स रिसीव नहीं हो रही", "incoming calls are not being received", "Switched OFF!"
    ]
    for t in status { expect(Announcements.isStatusMessage(t), "ann.status", "missed: \(t)") }
    for t in ["main abhi busy hoon, baad mein baat karte hain", "haan ji boliye", "voice acha hai", "kal try karna"] {
        expect(!Announcements.isStatusMessage(t), "ann.statusFalsePositive", "dropped real speech: \(t)")
    }
    let mid = [Segment(start: 600, end: 604, text: "Number unreachable.", speaker: .them),
               Segment(start: 700, end: 703, text: "You cannot receive incoming calls.", speaker: .me),
               Segment(start: 800, end: 802, text: "haan bolo", speaker: .them)]
    equal(Announcements.mark(mid).map(\.flags), [["operator"], ["operator"], []], "ann.midCallBothTracks")

    // The phrase list is configurable.
    expect(Announcements.isOperator("please recharge your account", phrases: ["recharge your account"]),
                "ann.customPhrase", "custom phrase not matched")
}
