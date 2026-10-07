import Foundation
import Testing
@testable import CallrecCore

@Test func failureTranscriptsAndDoctor() {
    let md = Markdown.renderFailure(date: Date(), seconds: 3416, audioName: "22-28-52.m4a",
                                    error: "whisper timed out\nafter 1800s", id: "2026-09-18/22-28-52")
    expect(md.contains("- duration: 56m 56s"), "failure.header", md)
    expect(md.contains("- error: whisper timed out after 1800s\n"), "failure.errorLine", md)
    expect(md.contains("## Transcript\n\n_Transcription failed. Re-run: callrec retranscribe 2026-09-18/22-28-52_"),
                "failure.transcript", md)
    equal(MarkdownFields.error(md: md) ?? "", "whisper timed out after 1800s", "failure.readBack")
    expect(MarkdownFields.error(md: MarkdownFields.clearError(md: md)) == nil, "failure.clear", "error line survived")
    equal(MarkdownFields.read(md: md).outcome, "", "failure.fieldsStillParse")

    let ok = Markdown.render(date: Date(), seconds: 5, audioName: "x.m4a", segments: [])
    equal(MarkdownFields.error(md: MarkdownFields.setError(md: ok, message: "boom")) ?? "", "boom", "failure.setError")

    // Doctor finds a missing .md and an error .md, and leaves a healthy one alone.
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-doctor-\(UUID())")
    let day = root.appendingPathComponent("2026-09-18")
    try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["10-00-00.m4a", "10-00-00.md", "11-00-00.m4a", "12-00-00.far.wav", "12-00-00.mic.wav", "12-00-00.m4a", "12-00-00.md"] {
        FileManager.default.createFile(atPath: day.appendingPathComponent(name).path, contents: Data())
    }
    try? md.write(to: day.appendingPathComponent("12-00-00.md"), atomically: true, encoding: .utf8)
    let issues = Doctor.scan(root: root)
    equal(issues.map(\.base), ["11-00-00", "12-00-00"], "doctor.flagged")
    equal(issues.first?.fix ?? "", "callrec retranscribe 2026-09-18/11-00-00", "doctor.fix")
    equal(Doctor.bases(in: day), ["10-00-00", "11-00-00", "12-00-00"], "doctor.bases")
}

@Test func chunkBoundariesAndOffsets() {
    equal(Chunking.timeout(forAudioSeconds: 3416), 20496, "chunk.timeoutScales")
    equal(Chunking.timeout(forAudioSeconds: 30), 600, "chunk.timeoutFloor")

    equal(Chunking.chunks(totalSeconds: 600, silences: []).count, 1, "chunk.shortStaysWhole")
    // Latest silence not past the 600 s limit wins; 640 is past it.
    let c = Chunking.chunks(totalSeconds: 1300, silences: [100, 580, 595, 640, 1190])
    equal(c.map(\.start), [0, 595, 1190], "chunk.starts")
    equal(c.map(\.end), [595, 1190, 1300], "chunk.ends")
    // No silence: hard cut at 600.
    let hard = Chunking.chunks(totalSeconds: 1500, silences: [])
    equal(hard.map(\.start), [0, 600, 1200], "chunk.hardStarts")
    equal(hard.map(\.end), [600, 1200, 1500], "chunk.hardEnds")
    // A silence too early (would make a tiny chunk) is ignored.
    equal(Chunking.chunks(totalSeconds: 700, silences: [50]).map(\.end), [600, 700], "chunk.tinyIgnored")
    // Every chunk is within the limit and the chunks tile the whole file.
    let long = Chunking.chunks(totalSeconds: 3416, silences: stride(from: 37.0, to: 3416, by: 211).map { $0 })
    expect(long.allSatisfy { $0.end - $0.start <= 600 }, "chunk.allWithinLimit", "\(long)")
    expect(long.last?.end == 3416 && long.first?.start == 0 &&
                zip(long, long.dropFirst()).allSatisfy { $0.end == $1.start }, "chunk.tiles", "\(long)")

    let shifted = Chunking.offset([Segment(start: 1.5, end: 4, text: "a", speaker: .them),
                                   Segment(start: 10, end: 12.25, text: "b")], by: 595)
    equal(shifted.map(\.start), [596.5, 605], "chunk.offsetStart")
    equal(shifted.map(\.end), [599, 607.25], "chunk.offsetEnd")
    equal(shifted[0].speaker, .them, "chunk.offsetKeepsSpeaker")
    equal(shifted[1].text, "b", "chunk.offsetKeepsText")

    let log = """
    [silencedetect @ 0x1] silence_start: 10.5
    [silencedetect @ 0x1] silence_end: 12.5 | silence_duration: 2
    [silencedetect @ 0x1] silence_start: 100
    [silencedetect @ 0x1] silence_end: 101 | silence_duration: 1
    [silencedetect @ 0x1] silence_start: 200
    """
    equal(Chunking.silenceMidpoints(fromSilencedetect: log), [11.5, 100.5], "chunk.silenceParse")
}

@Test func durationGuardArithmetic() {
    equal(DurationGuard.shouldWarn(wallClockSeconds: 169.9, fileSeconds: 1.45), true, "guard.collapsedFile")
    equal(DurationGuard.shouldWarn(wallClockSeconds: 100, fileSeconds: 100), false, "guard.exact")
    equal(DurationGuard.shouldWarn(wallClockSeconds: 100, fileSeconds: 90), false, "guard.exactlyTenPercentShort")
    equal(DurationGuard.shouldWarn(wallClockSeconds: 100, fileSeconds: 89.9), true, "guard.justOverTenPercent")
    equal(DurationGuard.shouldWarn(wallClockSeconds: 100, fileSeconds: 105), false, "guard.longerIsFine")
    equal(DurationGuard.shouldWarn(wallClockSeconds: 0, fileSeconds: 0), false, "guard.zeroCall")
}

/// Config.url is process-global, so every test that repoints it lives in this
/// one serialized suite. Parallel tests repointing it corrupt each other.
@Suite(.serialized) struct ConfigFileTests {
    @Test func configDefaultsAndRoundTrip() {
        let saved = Config.url
        defer { Config.url = saved }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-\(UUID()).json")
        Config.url = tmp
        var c = Config.load()
        equal(c.language, "en", "config.defaultLanguage")
        equal(c.minCallSeconds, 8, "config.minCallSeconds")
        equal(c.triggerBundleIDs, ["com.apple.avconferenced"], "config.triggerBundleIDs")
        do {
            c.language = "auto"
            try c.save()
            equal(Config.load().language, "auto", "config.roundTrip")
        } catch {
            Issue.record(Comment(rawValue: "config.save"+": "+"\(error)"))
        }
        // Old configs still carry the removed cleanup keys; they must not break loading.
        if var legacy = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp))) as? [String: Any] {
            legacy["cleanup"] = true
            legacy["cleanupModelPath"] = "~/.callrec/models/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
            legacy["prompt"] = "old whisper.cpp prompt"
            legacy["modelPath"] = "~/.callrec/models/ggml-large-v3.bin"
            try? JSONSerialization.data(withJSONObject: legacy).write(to: tmp)
            equal(Config.load().language, "auto", "config.toleratesRemovedCleanupKeys")
        } else {
            Issue.record(Comment(rawValue: "config.legacy"+": "+"could not read saved config"))
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // A stale key from an older build is ignored; a partial config keeps defaults.
    @Test func partialConfigKeepsDefaults() {
        let saved = Config.url
        defer { Config.url = saved }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-gate-\(UUID()).json")
        Config.url = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try Data(#"{"minSpeechPeakDb": -50, "stopAfterSilentSeconds": 9}"#.utf8).write(to: tmp) }
        catch { Issue.record("could not write test config: \(error)") }
        equal(Config.load().stopAfterSilentSeconds, 9, "gate.partialConfigKeepsOtherKeys")
        equal(Config.load().language, "en", "gate.partialConfigDefaults")
    }

    @Test func corruptConfigFallsBackToDefaults() throws {
        let saved = Config.url
        defer { Config.url = saved }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-corrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{ not json".utf8).write(to: tmp)
        Config.url = tmp
        equal(Config.load().language, "en", "config.corruptFallsBack")
    }
}
