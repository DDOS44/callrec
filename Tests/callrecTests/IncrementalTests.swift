import Foundation
import Testing
@testable import CallrecCore

private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-inc-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Test func parseCacheOnlyReparsesChangedFiles() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let files = (0..<50).map { dir.appendingPathComponent("call-\($0).md") }
    for f in files { try "text \(f.lastPathComponent)".write(to: f, atomically: true, encoding: .utf8) }
    let cache = ParseCache<String>()
    let parse: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) } // swiftlint:disable:this no_try_optional

    cache.beginPass()
    for f in files { _ = cache.value(for: f, parse: parse) }
    equal(cache.parsed, 50, "cache.firstPassParsesAll")

    cache.beginPass()
    for f in files { _ = cache.value(for: f, parse: parse) }
    equal(cache.parsed, 0, "cache.secondPassParsesNone")
    equal(cache.reused, 50, "cache.secondPassReusesAll")

    // One file changes: only that one is re-read, and the new content comes back.
    try "changed".write(to: files[7], atomically: true, encoding: .utf8)
    cache.beginPass()
    var values: [String] = []
    for f in files { values.append(cache.value(for: f, parse: parse) ?? "") }
    equal(cache.parsed, 1, "cache.oneChangeOneParse")
    equal(values[7], "changed", "cache.changeVisible")
    equal(values[8], "text call-8.md", "cache.othersUntouched")
}

@Test func parseCacheSeesAnAtomicSameSizeRewrite() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("a.md")
    try "AAAA".write(to: f, atomically: true, encoding: .utf8)
    let cache = ParseCache<String>()
    let parse: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) } // swiftlint:disable:this no_try_optional
    equal(cache.value(for: f, parse: parse) ?? "", "AAAA", "cache.first")
    // Same size, written via temp+rename like MarkdownStore does: the inode changes, so it must be re-read.
    try Data("BBBB".utf8).write(to: f, options: .atomic)
    equal(cache.value(for: f, parse: parse) ?? "", "BBBB", "cache.sameSizeAtomicRewriteSeen")
}

@Test func parseCacheForgetsDeletedFiles() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.md"), b = dir.appendingPathComponent("b.md")
    try "a".write(to: a, atomically: true, encoding: .utf8)
    try "b".write(to: b, atomically: true, encoding: .utf8)
    let cache = ParseCache<String>()
    let parse: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) } // swiftlint:disable:this no_try_optional
    _ = cache.value(for: a, parse: parse); _ = cache.value(for: b, parse: parse)
    equal(cache.count, 2, "cache.two")
    try FileManager.default.removeItem(at: b)
    expect(cache.value(for: b, parse: parse) == nil, "cache.deletedIsNil")
    cache.prune(keeping: [a.path])
    equal(cache.count, 1, "cache.pruned")
}

@Test func debouncerCollapsesABurstIntoOneCall() {
    let queue = DispatchQueue(label: "test.debounce")
    let counter = Counter()
    let d = Debouncer(delay: 0.15, queue: queue) { counter.bump() }
    for _ in 0..<10 { d.call(); Thread.sleep(forTimeInterval: 0.02) }
    equal(counter.value, 0, "debounce.notYet")
    Thread.sleep(forTimeInterval: 0.5)
    equal(counter.value, 1, "debounce.exactlyOnce")
    d.call(); d.cancel()
    Thread.sleep(forTimeInterval: 0.35)
    equal(counter.value, 1, "debounce.cancelled")
}

@Test func throttleAllowsOneRunPerInterval() {
    var t = Throttle(interval: 30)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    expect(t.shouldRun(now: t0), "throttle.firstRuns")
    expect(!t.shouldRun(now: t0.addingTimeInterval(2)), "throttle.twoSecondsLater")
    expect(!t.shouldRun(now: t0.addingTimeInterval(29.9)), "throttle.justBefore")
    expect(t.shouldRun(now: t0.addingTimeInterval(30)), "throttle.atInterval")
    expect(!t.shouldRun(now: t0.addingTimeInterval(31)), "throttle.restartsFromLastRun")
    t.reset()
    expect(t.shouldRun(now: t0.addingTimeInterval(32)), "throttle.resetRunsImmediately")
}
