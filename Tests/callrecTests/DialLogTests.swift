import Foundation
import Testing
@testable import CallrecCore

private func tempFile(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("callrec-dial-\(UUID().uuidString)").appendingPathComponent(name)
}

@Test func dialLogRoundTripsAndAppends() throws {
    let url = tempFile("dial-log.jsonl")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let a = DialLogEntry.attempt(at: DialFixture.at(7, 10), id: "A1", list: "fake", leadID: "L1", key: "9000000001")
    let r = a.finished(at: DialFixture.at(7, 10, 5), result: .connected, seconds: 42, outcome: "pitched", sim: "SIM-COLD")
    try DialLog.append(a, to: url)
    try DialLog.append(r, to: url)
    let loaded = try DialLog.load(from: url)
    equal(loaded.entries, [a, r], "dialLog.roundTrip")
    equal(loaded.skipped, 0, "dialLog.noneSkipped")
    let text = try String(contentsOf: url, encoding: .utf8)
    equal(text.split(separator: "\n").count, 2, "dialLog.oneLinePerEntry")
}

@Test func dialLogFileAndFolderArePrivate() throws {
    let url = tempFile("dial-log.jsonl")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try DialLog.append(.attempt(at: Date(timeIntervalSince1970: 0), list: "l", leadID: "i", key: "9000000001"), to: url)
    var st = stat()
    expect(stat(url.path, &st) == 0, "dialLog.stat")
    equal(st.st_mode & 0o777, 0o600, "dialLog.fileMode")
    expect(stat(url.deletingLastPathComponent().path, &st) == 0, "dialLog.dirStat")
    equal(st.st_mode & 0o777, 0o700, "dialLog.dirMode")
}

@Test func missingDialLogIsEmptyNotAnError() throws {
    let loaded = try DialLog.load(from: tempFile("nope.jsonl"))
    equal(loaded.entries.count, 0, "dialLog.missingEmpty")
    equal(loaded.skipped, 0, "dialLog.missingSkipped")
}

@Test func corruptLinesAreSkippedCountedAndKeptNeverDropped() throws {
    let url = tempFile("dial-log.jsonl")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let good = DialLogEntry.attempt(at: DialFixture.at(7, 10), id: "A", list: "l", leadID: "i", key: "9000000001")
    try DialLog.append(good, to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("this is not json\n{\"kind\":\"attempt\"}\n".utf8))
    try handle.close()
    try DialLog.append(good, to: url)
    let loaded = try DialLog.load(from: url)
    equal(loaded.entries.count, 2, "corrupt.goodKept")
    equal(loaded.skipped, 2, "corrupt.counted")
    let text = try String(contentsOf: url, encoding: .utf8)
    expect(text.contains("this is not json"), "corrupt.bytesKept", "damaged line must stay in the file")
}

@Test func partialLastLineDoesNotGlueOntoTheNextEntry() throws {
    let url = tempFile("dial-log.jsonl")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    // Simulates a crash mid-write: a half line with no newline.
    try Data(#"{"kind":"attempt","ts":"2026-10-07T04:30:"#.utf8).write(to: url)
    let entry = DialLogEntry.attempt(at: DialFixture.at(7, 11), id: "NEW", list: "l", leadID: "i", key: "9000000001")
    try DialLog.append(entry, to: url)
    let loaded = try DialLog.load(from: url)
    equal(loaded.entries, [entry], "partial.newEntryIntact")
    equal(loaded.skipped, 1, "partial.damageCounted")
}

@Test func unknownFieldsAndOldEntriesStillLoad() throws {
    let url = tempFile("dial-log.jsonl")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    let line = #"{"attemptID":"A","future":"x","key":"9000000001","kind":"attempt","leadID":"1","list":"l","ts":"2026-10-07T04:30:00Z"}"# + "\n"
    try Data(line.utf8).write(to: url)
    equal(try DialLog.load(from: url).entries.count, 1, "forward.compat")
}

// MARK: - DNC file

@Test func dncAddIsIdempotentAndNormalizes() throws {
    let url = tempFile("dnc.txt")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let t = DialFixture.at(7, 10)
    equal(try DNCList.add("+91 90000 00001", now: t, to: url), true, "dnc.firstAdd")
    equal(try DNCList.add("09000000001", now: t, to: url), false, "dnc.sameNumberNotRewritten")
    equal(try DNCList.add("9000000002", now: t, to: url), true, "dnc.second")
    let list = try DNCList.load(from: url)
    equal(list.keys, ["9000000001", "9000000002"], "dnc.keys")
    expect(list.contains("+919000000001"), "dnc.containsAnyFormat")
    equal(list.addedToday(now: DialFixture.at(7, 15), calendar: DialFixture.cal), 2, "dnc.addedToday")
    equal(list.addedToday(now: DialFixture.at(8, 15), calendar: DialFixture.cal), 0, "dnc.notTomorrow")
    let text = try String(contentsOf: url, encoding: .utf8)
    equal(text.split(separator: "\n").count, 2, "dnc.twoLines")
}

@Test func dncRejectsNonNumbersLoudly() {
    let url = tempFile("dnc.txt")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    #expect(throws: DNCList.AddError.self) { try DNCList.add("12345", to: url) }
    expect(!FileManager.default.fileExists(atPath: url.path), "dnc.nothingWritten")
}

@Test func dncReadsHandEditedFilesAndCountsGarbage() throws {
    let url = tempFile("dnc.txt")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    let text = "# my list\n9000000003\n+91 90000 00004  # 2026-10-07T04:30:00Z\n\nnot a number\n"
    try Data(text.utf8).write(to: url)
    let list = try DNCList.load(from: url)
    equal(list.keys, ["9000000003", "9000000004"], "dncFile.keys")
    equal(list.unreadable, 1, "dncFile.unreadableCounted")
    expect(list.entries.last?.addedAt != nil, "dncFile.timestampParsed")
    expect(list.entries.first?.addedAt == nil, "dncFile.bareKeyUndated")
}

@Test func dncFilePartialLineSafe() throws {
    let url = tempFile("dnc.txt")
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    try Data("9000000003".utf8).write(to: url)   // no trailing newline
    try DNCList.add("9000000004", to: url)
    equal(try DNCList.load(from: url).keys, ["9000000003", "9000000004"], "dncFile.noGlue")
}
