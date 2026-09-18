import Foundation
import CallrecCore

/// Pure-logic checks. They live in the target (not only in Tests/) because this
/// machine has Command Line Tools but no Xcode: `swift test` builds and links,
/// but the toolchain's test helper reports nothing, so `callrec selftest` is the
/// runnable source of truth. `Tests/callrecTests` wraps these same functions.
enum SelfTest {

    struct Failure: CustomStringConvertible {
        let check: String
        let detail: String
        var description: String { "FAIL \(check): \(detail)" }
    }

    static func runAll() -> [Failure] {
        var f: [Failure] = []
        f += paths()
        f += config()
        f += markdown()
        f += srtParsing()
        f += watcherStateMachine()
        f += silenceSplitter()
        f += markdownFields()
        return f
    }

    static func expect(_ ok: Bool, _ check: String, _ detail: @autoclosure () -> String) -> [Failure] {
        ok ? [] : [Failure(check: check, detail: detail())]
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ check: String) -> [Failure] {
        expect(a == b, check, "got \(a), expected \(b)")
    }

    // MARK: - Markdown fields (the app edits these)

    public static func markdownFields() -> [Failure] {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 14; c.minute = 2; c.second = 0
        guard let d = Calendar.current.date(from: c) else { return [Failure(check: "fields", detail: "bad date")] }
        let original = Markdown.render(date: d, seconds: 65.4, audioName: "14-02-00.m4a", segments: [
            Segment(start: 0, end: 2.5, text: "Haan ji, boliye."),
            Segment(start: 62, end: 65, text: "Theek hai, Thursday.")
        ])
        var f: [Failure] = []

        let updated = MarkdownFields.update(md: original, outcome: "booked",
                                            who: "Vineet", notes: "wants Thursday\nnot Friday")
        let back = MarkdownFields.read(md: updated)
        f += equal(back.outcome, "booked", "fields.outcomeRoundTrip")
        f += equal(back.who, "Vineet", "fields.whoRoundTrip")
        f += equal(back.notes, "wants Thursday not Friday", "fields.notesRoundTrip")

        // The transcript must survive editing untouched.
        f += expect(updated.contains("[00:00] Haan ji, boliye."), "fields.transcriptKept0", "first segment lost")
        f += expect(updated.contains("[01:02] Theek hai, Thursday."), "fields.transcriptKept1", "second segment lost")
        f += equal(MarkdownFields.segments(md: updated).count, 2, "fields.segmentCount")
        f += equal(MarkdownFields.segments(md: updated).first?.start ?? -1, 0, "fields.segmentStart0")
        f += equal(MarkdownFields.segments(md: updated).last?.start ?? -1, 62, "fields.segmentStart1")
        f += equal(MarkdownFields.firstTranscriptLine(md: updated), "Haan ji, boliye.", "fields.preview")
        f += equal(MarkdownFields.duration(md: updated), 65, "fields.duration")

        // Editing twice must not duplicate or drift.
        let twice = MarkdownFields.update(md: updated, outcome: "callback", who: "", notes: "")
        f += equal(MarkdownFields.read(md: twice), MarkdownFields.Fields(outcome: "callback", who: "", notes: ""), "fields.secondEdit")
        f += equal(twice.components(separatedBy: "- outcome:").count - 1, 1, "fields.noDuplicateOutcome")
        f += equal(MarkdownFields.segments(md: twice).count, 2, "fields.transcriptStillIntact")
        return f
    }

    // MARK: - Task 8: Silence splitter

    static func silenceSplitter() -> [Failure] {
        var f: [Failure] = []
        // 1 frame = 1 s. speech 0-10, silence 10-40, speech 40-55, tiny gap, speech 56-70
        var rms = [Float](repeating: 0.2, count: 10) + [Float](repeating: 0.001, count: 30)
        rms += [Float](repeating: 0.2, count: 15) + [0.001] + [Float](repeating: 0.2, count: 14)
        let s = SilenceSplitter.spans(rms: rms, frameSeconds: 1, threshold: 0.01, minGapSeconds: 20, minSpanSeconds: 8)
        f += equal(s.count, 2, "silence.count")
        if s.count == 2 {
            f += equal(s[0].start, 0, "silence.span0.start")
            f += equal(s[0].end, 10, "silence.span0.end")
            f += equal(s[1].start, 40, "silence.span1.start")
            f += equal(s[1].end, 70, "silence.span1.end")
        }
        let short = [Float](repeating: 0.2, count: 3) + [Float](repeating: 0.0, count: 30)
        f += expect(SilenceSplitter.spans(rms: short, frameSeconds: 1, threshold: 0.01,
                                          minGapSeconds: 20, minSpanSeconds: 8).isEmpty,
                    "silence.dropsShortSpans", "short span was kept")
        return f
    }

    // MARK: - Task 7: Watcher state machine

    static func watcherStateMachine() -> [Failure] {
        var f: [Failure] = []

        var m = WatcherStateMachine(stopAfterSilentPolls: 3)
        f += equal(m.poll(callActive: false), .none, "watcher.idleStaysIdle")
        f += equal(m.poll(callActive: true), .startRecording, "watcher.idleToRecording")
        f += equal(m.state, .recording, "watcher.stateAfterStart")
        f += equal(m.poll(callActive: true), .none, "watcher.stillRecording")

        // Two inactive polls are not enough; the third ends the call.
        f += equal(m.poll(callActive: false), .none, "watcher.inactive1")
        f += equal(m.poll(callActive: false), .none, "watcher.inactive2")
        f += equal(m.poll(callActive: false), .stopRecording, "watcher.inactive3Stops")
        f += equal(m.state, .idle, "watcher.stateAfterStop")

        // A blip of inactivity mid-call must not end the recording.
        var b = WatcherStateMachine(stopAfterSilentPolls: 3)
        _ = b.poll(callActive: true)
        _ = b.poll(callActive: false)
        _ = b.poll(callActive: true)
        f += equal(b.poll(callActive: false), .none, "watcher.blipDoesNotStop")
        f += equal(b.consecutiveInactivePolls, 1, "watcher.blipResetsCounter")

        // Back-to-back calls: a new call starts cleanly after a stop.
        f += equal(b.poll(callActive: false), .none, "watcher.secondCall.inactive2")
        f += equal(b.poll(callActive: false), .stopRecording, "watcher.secondCall.stops")
        f += equal(b.poll(callActive: true), .startRecording, "watcher.secondCall.starts")

        // An error resets to idle rather than exiting, and recording can resume.
        b.reset()
        f += equal(b.state, .idle, "watcher.resetGoesIdle")
        f += equal(b.poll(callActive: true), .startRecording, "watcher.resumesAfterReset")

        // Trigger matching only fires on the configured bundle IDs.
        let snap = [
            AudioProcessInfo(objectID: 1, pid: 10, bundleID: "com.spotify.client", isRunningOutput: true, isRunningInput: false),
            AudioProcessInfo(objectID: 2, pid: 11, bundleID: "com.apple.avconferenced", isRunningOutput: false, isRunningInput: false)
        ]
        f += expect(WatcherStateMachine.callActive(in: snap, triggerBundleIDs: ["com.spotify.client"]),
                    "watcher.matchesTrigger", "spotify should count as active")
        f += expect(!WatcherStateMachine.callActive(in: snap, triggerBundleIDs: ["com.apple.avconferenced"]),
                    "watcher.idleTriggerNotActive", "avconferenced is present but not running audio")
        return f
    }

    // MARK: - Task 6: Markdown

    static func markdown() -> [Failure] {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 14; c.minute = 2; c.second = 0
        guard let d = Calendar.current.date(from: c) else { return [Failure(check: "markdown", detail: "bad date")] }
        let md = Markdown.render(date: d, seconds: 65.4, audioName: "14-02-00.m4a", segments: [
            Segment(start: 0, end: 2.5, text: "Hi, is Vineet around?"),
            Segment(start: 62, end: 65, text: "Theek hai, Thursday.")
        ])
        var f: [Failure] = []
        f += expect(md.hasPrefix("# Call 2026-09-18 14:02\n"), "markdown.title", "bad title line")
        f += expect(md.contains("- duration: 1m 05s"), "markdown.duration", "bad duration")
        f += expect(md.contains("- audio: 14-02-00.m4a"), "markdown.audio", "bad audio line")
        f += expect(md.contains("[00:00] Hi, is Vineet around?"), "markdown.firstSegment", "missing first segment")
        f += expect(md.contains("[01:02] Theek hai, Thursday."), "markdown.secondSegment", "missing second segment")
        f += expect(md.contains("## Notes\n"), "markdown.notes", "missing notes section")
        return f
    }

    static func srtParsing() -> [Failure] {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        Hi, is Vineet around?

        2
        00:01:02,120 --> 00:01:05,000
        Theek hai, Thursday.

        """
        let segs = Transcriber.parseSRT(srt)
        var f: [Failure] = []
        f += equal(segs.count, 2, "srt.count")
        guard segs.count == 2 else { return f }
        f += equal(segs[0].text, "Hi, is Vineet around?", "srt.text0")
        f += equal(segs[0].start, 0.0, "srt.start0")
        f += equal(segs[1].start, 62.12, "srt.start1")
        f += equal(segs[1].text, "Theek hai, Thursday.", "srt.text1")
        return f
    }

    // MARK: - Task 2: Config

    static func config() -> [Failure] {
        let saved = Config.url
        defer { Config.url = saved }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-\(UUID()).json")
        Config.url = tmp
        var c = Config.load()
        var f: [Failure] = []
        f += equal(c.language, "hi", "config.defaultLanguage")
        f += expect(c.prompt.contains("Blaxify"), "config.prompt", "prompt missing Blaxify")
        f += expect(c.prompt.contains("Haan ji"), "config.promptHinglish", "prompt is not Roman Hinglish")
        f += equal(c.minCallSeconds, 8, "config.minCallSeconds")
        f += equal(c.triggerBundleIDs, ["com.apple.avconferenced"], "config.triggerBundleIDs")
        do {
            c.language = "auto"
            try c.save()
            f += equal(Config.load().language, "auto", "config.roundTrip")
        } catch {
            f += [Failure(check: "config.save", detail: "\(error)")]
        }
        try? FileManager.default.removeItem(at: tmp)
        return f
    }

    // MARK: - Task 1: Paths

    static func paths() -> [Failure] {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 9; c.minute = 5; c.second = 7
        guard let d = Calendar.current.date(from: c) else { return [Failure(check: "paths", detail: "bad date")] }
        let p = Paths.forCall(at: d, root: URL(fileURLWithPath: "/tmp/cr"))
        var f: [Failure] = []
        f += equal(p.dir.path, "/tmp/cr/2026-09-18", "paths.dir")
        f += equal(p.m4a.lastPathComponent, "09-05-07.m4a", "paths.m4a")
        f += equal(p.md.lastPathComponent, "09-05-07.md", "paths.md")
        f += equal(p.farWav.lastPathComponent, "09-05-07.far.wav", "paths.farWav")
        f += equal(p.micWav.lastPathComponent, "09-05-07.mic.wav", "paths.micWav")
        f += equal(p.mixWav.lastPathComponent, "09-05-07.mix.wav", "paths.mixWav")
        return f
    }
}
