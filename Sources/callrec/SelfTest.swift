import Foundation

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
        return f
    }

    static func expect(_ ok: Bool, _ check: String, _ detail: @autoclosure () -> String) -> [Failure] {
        ok ? [] : [Failure(check: check, detail: detail())]
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ check: String) -> [Failure] {
        expect(a == b, check, "got \(a), expected \(b)")
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
        f += equal(c.language, "en", "config.defaultLanguage")
        f += expect(c.glossary.contains("Blaxify"), "config.glossary", "glossary missing Blaxify")
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
