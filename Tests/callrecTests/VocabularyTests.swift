import Foundation
import Testing
@testable import CallrecCore

// Names were misheard ("Himansh" for the caller's name, "black sifai" for the company).
// A vocabulary prompt biases spelling; it must stay out of code (config only).
@Test func vocabularyPromptJoinsWordsAndSkipsBlanks() {
    #expect(Engine.prompt(["Rahul", " Acme ", ""]) == "Rahul, Acme.")
    #expect(Engine.prompt([]) == nil)
    #expect(Engine.prompt(["  "]) == nil)
}

@Test func vocabularyAndSpeakerLabelsDecodeAndDefaultSafely() throws {
    #expect(Config().vocabulary.isEmpty, "public default must carry no personal words")
    #expect(Config().speakerLabels == false, "one chronological transcript by default")
    let json = #"{"vocabulary":["Rahul","Acme"],"speakerLabels":true}"#.data(using: .utf8)!
    let c = try JSONDecoder().decode(Config.self, from: json)
    #expect(c.vocabulary == ["Rahul", "Acme"])
    #expect(c.speakerLabels == true)
    let old = try JSONDecoder().decode(Config.self, from: #"{"stopAfterSilentSeconds":6}"#.data(using: .utf8)!)
    #expect(old.vocabulary.isEmpty && old.speakerLabels == false)
}

// Regression: with the prompt, 17 s of real speech came back as "" (kept nothing).
@Test func truncationDetectorCatchesEmptyAndShortRegions() {
    #expect(Engine.looksTruncated(chars: 0, speechSeconds: 17))
    #expect(Engine.looksTruncated(chars: 20, speechSeconds: 17))
    #expect(!Engine.looksTruncated(chars: 200, speechSeconds: 17))
    #expect(!Engine.looksTruncated(chars: 0, speechSeconds: 1.0), "very short blips are not judged")
}
