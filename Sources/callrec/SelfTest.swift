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
        return f
    }

    static func expect(_ ok: Bool, _ check: String, _ detail: @autoclosure () -> String) -> [Failure] {
        ok ? [] : [Failure(check: check, detail: detail())]
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ check: String) -> [Failure] {
        expect(a == b, check, "got \(a), expected \(b)")
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
