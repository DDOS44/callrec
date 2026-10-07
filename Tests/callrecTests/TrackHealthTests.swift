import Foundation
import Testing
@testable import CallrecCore

@Test func silentTrackClassifier() {
    expect(TrackHealth.isSilent(samples: [Float](repeating: 0, count: 16_000)), "silence.allZeros", "digital zeros must be silent")
    expect(TrackHealth.isSilent(samples: []), "silence.empty", "no samples is not a recording")
    // 440 Hz at about -12 dBFS: ordinary speech level.
    let speech = (0..<16_000).map { 0.25 * sin(2 * Float.pi * 440 * Float($0) / 16_000) }
    expect(!TrackHealth.isSilent(samples: speech), "silence.speech", "normal audio must not be silent")
    // Very quiet but real: peak about -80 dBFS (1e-4), a dead-quiet room.
    var quiet = [Float](repeating: 0, count: 16_000)
    quiet[8_000] = 1e-4
    expect(!TrackHealth.isSilent(samples: quiet), "silence.veryQuiet", "-80 dBFS is signal, not silence")
    // Just under the threshold is silent.
    var floor = [Float](repeating: 0, count: 16_000)
    floor[1] = 1e-5   // -100 dBFS
    expect(TrackHealth.isSilent(samples: floor), "silence.belowThreshold", "-100 dBFS peak is silent")
    expect(TrackHealth.peakDBFS([0, 0]) == -Float.infinity, "silence.peakInf", "all zeros peak is -inf")
}

@Test func warningLineRoundTrip() {
    let md = Markdown.render(date: Date(timeIntervalSince1970: 0), seconds: 62, audioName: "00-16-31.m4a", segments: [])
    equal(MarkdownFields.warnings(md: md), [], "warning.none")
    let report = TrackHealth.Report(micSilent: true)
    let with = MarkdownFields.setWarnings(md: md, report.warnings)
    equal(MarkdownFields.warnings(md: with), ["your microphone was not recorded (silent track)"], "warning.set")
    expect(with.contains("- warning: your microphone was not recorded (silent track)"), "warning.line")
    equal(MarkdownFields.setWarnings(md: with, report.warnings), with, "warning.idempotent")
    equal(MarkdownFields.setWarnings(md: with, []), md, "warning.cleared")
}
