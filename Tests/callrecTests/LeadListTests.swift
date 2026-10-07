import Foundation
import Testing
@testable import CallrecCore

private let header = "company,phone,city,owner,what_they_do,angle,confidence,alt_number,caller"

private func csv(_ rows: [String], header h: String = header) -> String { ([h] + rows).joined(separator: "\n") + "\n" }

@Test func importReadsEveryFieldAndOrdersByConfidence() throws {
    let text = csv([
        "Fake Staffing A,+91 90000 00001,Delhi,Asha Test,IT hiring,Ask about volume,low,,Devansh",
        "Fake Staffing B,9000000002,Noida,Ravi Test,Blue collar,Referral angle,HIGH,9000000012,Devansh",
        "Fake Staffing C,09000000003,Gurgaon,,Exec search,,medium,,Devansh",
        "Fake Staffing D,9000000004,,,,,high,,Devansh"
    ])
    let r = try LeadImporter.parse(text)
    equal(r.leads.count, 4, "import.count")
    equal(r.ordered.map(\.company), ["Fake Staffing B", "Fake Staffing D", "Fake Staffing C", "Fake Staffing A"], "import.order")
    let b = try #require(r.leads.first { $0.company == "Fake Staffing B" })
    equal(b.number, "9000000002", "import.normalized")
    equal(b.id, "9000000002", "import.idIsNumber")
    equal(b.altNumber, "9000000012", "import.alt")
    equal(b.confidence, .high, "import.confidence")
    equal(b.city, "Noida", "import.city")
    equal(b.owner, "Ravi Test", "import.owner")
    equal(b.angle, "Referral angle", "import.angle")
    equal(b.whatTheyDo, "Blue collar", "import.whatTheyDo")
    equal(r.accountedRows, 4, "import.accounted")
}

@Test func importMatchesHeadersTolerantly() throws {
    let text = "\u{FEFF}Company Name,Mobile Number,Owner Name,What They Do,Alt-Number\nFake Co,9000000001,Sam Test,Recruiting,9000000002\n"
    let r = try LeadImporter.parse(text)
    equal(r.leads.count, 1, "headers.count")
    equal(r.leads[0].company, "Fake Co", "headers.company")
    equal(r.leads[0].owner, "Sam Test", "headers.owner")
    equal(r.leads[0].whatTheyDo, "Recruiting", "headers.whatTheyDo")
    equal(r.leads[0].altNumber, "9000000002", "headers.alt")
    equal(r.leads[0].confidence, .unknown, "headers.noConfidence")
}

@Test func rowsWithoutAValidNumberAreRejectedWithReasonsNeverDropped() throws {
    let text = csv([
        "Good Co,9000000001,,,,,high,,",
        "No Phone Co,,,,,,high,,",
        "Short Co,12345,,,,,high,,",
        "Two Numbers Co,9000000002 / 9000000003,,,,,high,,",
        "Foreign Co,+1 555 555 0123,,,,,high,,",
        "Dup Co,+91 90000 00001,,,,,high,,",
        ",,,,,,,,"
    ])
    let r = try LeadImporter.parse(text)
    equal(r.leads.map(\.company), ["Good Co"], "reject.goodKept")
    equal(r.rejected.map(\.line), [3, 4, 5, 6, 7], "reject.lines")
    expect(r.rejected[0].reason.contains("no phone"), "reject.noPhoneReason", r.rejected[0].reason)
    expect(r.rejected[1].reason.contains("valid 10-digit"), "reject.shortReason", r.rejected[1].reason)
    expect(r.rejected[4].reason.contains("duplicate"), "reject.dupReason", r.rejected[4].reason)
    equal(r.blankRows, 1, "reject.blankCounted")
    equal(r.accountedRows, 7, "reject.everyRowAccountedFor")
    let report = r.rejectedReport
    expect(report.contains("line 4:") && report.contains("Short Co") && report.contains("12345"), "reject.report", report)
}

@Test func missingRequiredColumnsFailLoudlyAndImportNothing() {
    #expect(throws: LeadImportError.missingColumns(["phone"])) { try LeadImporter.parse("company,city\nFake,Delhi\n") }
    #expect(throws: LeadImportError.missingColumns(["company", "phone"])) { try LeadImporter.parse("a,b\n1,2\n") }
    #expect(throws: LeadImportError.empty) { try LeadImporter.parse("") }
}

@Test func callerFilterKeepsOnlyMatchingRowsAndCountsTheRest() throws {
    let text = csv([
        "A,9000000001,,,,,high,,Devansh",
        "B,9000000002,,,,,high,,Anurag",
        "C,9000000003,,,,,high,,devansh ",
        "D,9000000004,,,,,high,,",
        "Bad,12,,,,,high,,Anurag"
    ])
    let r = try LeadImporter.parse(text, caller: "Devansh")
    equal(r.leads.map(\.company), ["A", "C"], "caller.kept")
    // Someone else's row is not this caller's problem, even when its number is bad.
    equal(r.filteredOut, 3, "caller.filtered")
    equal(r.rejected.count, 0, "caller.noRejects")
    equal(r.accountedRows, 5, "caller.accounted")
    // No caller column: nothing can be filtered, every row stays.
    let noCol = try LeadImporter.parse("company,phone\nA,9000000001\n", caller: "Devansh")
    equal(noCol.leads.count, 1, "caller.noColumnKeepsAll")
}

@Test func quotedFieldsAndCRLFParse() throws {
    let text = "company,phone,angle\r\n\"Fake, Inc.\",9000000001,\"says \"\"hi\"\"\r\nand more\"\r\n"
    let r = try LeadImporter.parse(text)
    equal(r.leads.count, 1, "csv.rows")
    equal(r.leads[0].company, "Fake, Inc.", "csv.comma")
    equal(r.leads[0].angle, "says \"hi\"\nand more", "csv.quotesAndNewline")
}

@Test func badAltNumberIsAWarningNotARejection() throws {
    let r = try LeadImporter.parse(csv(["A,9000000001,,,,,high,12345,"]))
    equal(r.leads.count, 1, "alt.rowKept")
    equal(r.leads[0].altNumber, nil, "alt.dropped")
    equal(r.warnings.count, 1, "alt.warned")
    let same = try LeadImporter.parse(csv(["A,9000000001,,,,,high,+91 9000000001,"]))
    equal(same.leads[0].altNumber, nil, "alt.sameAsPrimaryIgnored")
}

@Test func stableOrderWithinATier() throws {
    let rows = (1...6).map { "Co\($0),900000000\($0),,,,,medium,," }
    equal(try LeadImporter.parse(csv(rows)).ordered.map(\.company), (1...6).map { "Co\($0)" }, "order.stable")
}

@Test func importerReadsAFileAndLeavesItUntouched() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-leads-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { Fs.remove(dir) }
    let file = dir.appendingPathComponent("fake.csv")
    let text = csv(["A,9000000001,,,,,high,,", "bad,1,,,,,,,"])
    try Data(text.utf8).write(to: file)
    let r = try LeadImporter.load(file)
    equal(r.leads.count, 1, "file.leads")
    equal(try String(contentsOf: file, encoding: .utf8), text, "file.sourceUnchanged")
    #expect(throws: (any Error).self) { try LeadImporter.load(dir.appendingPathComponent("missing.csv")) }
}

// MARK: - State store

private func stateURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-state-\(UUID())").appendingPathComponent("fake.state.json")
}

@Test func stateStoreRoundTripsAndIsPrivate() throws {
    let url = stateURL()
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let store = try LeadStateStore(url: url, listName: "fake")
    let t = Date(timeIntervalSince1970: 1_790_000_000)
    try store.update("9000000001", now: t) {
        $0.status = .called; $0.attempts = 1; $0.outcome = "pitched"; $0.notes = "call back Tuesday"
        $0.lastDialedAt = t; $0.callID = "2026-10-07/10-30-00"
    }
    let reopened = try LeadStateStore(url: url, listName: "fake")
    let rec = reopened.record("9000000001")
    equal(rec.status, .called, "state.status")
    equal(rec.notes, "call back Tuesday", "state.notes")
    equal(rec.callID, "2026-10-07/10-30-00", "state.callID")
    equal(rec.lastDialedAt, t, "state.lastDialedAt")
    equal(reopened.record("9000000099").status, .pending, "state.unknownIsPending")
    var st = stat()
    expect(stat(url.path, &st) == 0, "state.stat")
    equal(st.st_mode & 0o777, 0o600, "state.fileMode")
}

@Test func corruptStateFileIsNeverOverwritten() throws {
    let url = stateURL()
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    let junk = "{ this is half a file"
    try Data(junk.utf8).write(to: url)
    #expect(throws: LeadStateError.self) { try LeadStateStore(url: url, listName: "fake") }
    equal(try String(contentsOf: url, encoding: .utf8), junk, "corrupt.bytesUntouched")
}

@Test func newerStateFormatIsRefusedUntouched() throws {
    let url = stateURL()
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    let future = #"{"version": 99, "list": "fake", "leads": {}}"#
    try Data(future.utf8).write(to: url)
    #expect(throws: LeadStateError.self) { try LeadStateStore(url: url, listName: "fake") }
    equal(try String(contentsOf: url, encoding: .utf8), future, "newer.untouched")
}

@Test func failedSaveLeavesMemoryUnchanged() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-state-\(UUID())")
    defer { Fs.remove(dir) }
    try Paths.ensureDir(dir)
    let store = try LeadStateStore(url: dir.appendingPathComponent("fake.state.json"), listName: "fake")
    try store.update("9000000001") { $0.status = .skipped }
    // Make the folder unusable: replace it with a plain file.
    Fs.remove(dir)
    try Data("in the way".utf8).write(to: dir)
    #expect(throws: (any Error).self) { try store.update("9000000001") { $0.status = .called } }
    equal(store.record("9000000001").status, .skipped, "failedSave.memoryUnchanged")
}

@Test func stateOlderFilesMissingFieldsStillLoad() throws {
    let url = stateURL()
    defer { Fs.remove(url.deletingLastPathComponent()) }
    try Paths.ensureDir(url.deletingLastPathComponent())
    try Data(#"{"version": 1, "list": "fake", "leads": {"9000000001": {"status": "called"}}}"#.utf8).write(to: url)
    let store = try LeadStateStore(url: url, listName: "fake")
    equal(store.record("9000000001").status, .called, "oldState.status")
    equal(store.record("9000000001").attempts, 0, "oldState.default")
}

@Test func queueShowsStatusesAndPicksNextPending() throws {
    let r = try LeadImporter.parse(csv([
        "Low,9000000001,,,,,low,,", "High,9000000002,,,,,high,,", "Med,9000000003,,,,,medium,,", "High2,9000000004,,,,,high,,"
    ]))
    var state: [String: LeadRecord] = [:]
    var done = LeadRecord(); done.status = .called
    state["9000000002"] = done
    var dnc = LeadRecord(); dnc.status = .doNotCall
    state["9000000004"] = dnc
    let q = LeadQueue.build(r, state: state)
    equal(q.map(\.lead.company), ["High", "High2", "Med", "Low"], "queue.order")
    equal(LeadQueue.nextUp(q)?.lead.company, "Med", "queue.nextPending")
    equal(LeadQueue.nextUp(q, excluding: ["9000000003"])?.lead.company, "Low", "queue.excluding")
    equal(LeadQueue.counts(q)[.pending], 2, "queue.counts")
}

@Test func resetSkippedOnlyTouchesSkipped() throws {
    let url = stateURL()
    defer { Fs.remove(url.deletingLastPathComponent()) }
    let store = try LeadStateStore(url: url, listName: "fake")
    try store.update("9000000001") { $0.status = .skipped }
    try store.update("9000000002") { $0.status = .doNotCall }
    try store.resetSkipped()
    equal(store.record("9000000001").status, .pending, "reset.skippedBack")
    equal(store.record("9000000002").status, .doNotCall, "reset.dncStays")
}
