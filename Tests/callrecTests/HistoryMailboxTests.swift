import Foundation
import Testing
@testable import CallrecCore

private typealias MB = HistoryMailbox

private func dirs() throws -> (req: URL, resp: URL, root: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-mbx-\(UUID())")
    try Paths.ensureDir(root)
    return (root.appendingPathComponent("requests"), root.appendingPathComponent("responses"), root)
}

private let sampleRows = [
    MB.Row(epoch: 1_000, numberKey: "9000000001", seconds: 30),
    MB.Row(epoch: 2_000, numberKey: "9000000002", seconds: 0),
    MB.Row(epoch: 3_000, numberKey: "9000000001", seconds: 5)
]

@Test func mailboxProtocolRoundTripsAndRejectsBadInput() throws {
    let r = MB.Request(id: "abc-123", sinceEpoch: 5, numberKey: "9000000001")
    equal(try MB.decodeRequest(MB.encode(r)), r, "mbx.requestRoundTrip")
    for bad in ["not json", #"{"id":"../x","kind":"history","sinceEpoch":1}"#, #"{"id":"a","kind":"other","sinceEpoch":1}"#,
                #"{"id":"a","kind":"history","sinceEpoch":1,"numberKey":"123"}"#, #"{"id":"a"}"#] {
        #expect(throws: MB.MailboxError.self) { try MB.decodeRequest(Data(bad.utf8)) }
    }
    let resp = MB.Response(id: "abc-123", ok: true, rows: sampleRows)
    equal(try MB.decodeResponse(MB.encode(resp), expecting: "abc-123"), resp, "mbx.responseRoundTrip")
    #expect(throws: MB.MailboxError.malformed("answer is for a different request")) { try MB.decodeResponse(MB.encode(resp), expecting: "other") }
    #expect(throws: MB.MailboxError.daemonError("boom")) { try MB.decodeResponse(MB.encode(MB.Response(id: "a", ok: false, error: "boom")), expecting: "a") }
    #expect(throws: MB.MailboxError.self) { try MB.decodeResponse(Data("{".utf8), expecting: "a") }
}

@Test func mailboxMatchingAndStaleness() {
    equal(MB.matching(sampleRows, for: .init(sinceEpoch: 1_500)).map(\.epoch), [2_000, 3_000], "mbx.since")
    equal(MB.matching(sampleRows, for: .init(sinceEpoch: 0, numberKey: "9000000001")).map(\.epoch), [1_000, 3_000], "mbx.numberOnly")
    let now = Date()
    expect(!MB.isStale(modified: now.addingTimeInterval(-119), now: now), "mbx.freshAt119")
    expect(MB.isStale(modified: now.addingTimeInterval(-121), now: now), "mbx.staleAt121")
}

@Test func daemonAnswersARequestAndLeavesOnlyAPrivateResponse() throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    let req = MB.Request(id: "r1", sinceEpoch: 1_500, numberKey: "9000000001")
    try MB.writeAtomically(MB.encode(req), to: d.req.appendingPathComponent("r1.json"))
    let n = MB.serve(requestsDir: d.req, responsesDir: d.resp) { _ in sampleRows }
    equal(n, 1, "serve.answered")
    expect(Fs.list(d.req).isEmpty, "serve.requestDeleted")
    let data = try Data(contentsOf: d.resp.appendingPathComponent("r1.json"))
    let resp = try MB.decodeResponse(data, expecting: "r1")
    // Only what was asked: the one number, since the time. No names, no other numbers.
    equal(resp.rows, [MB.Row(epoch: 3_000, numberKey: "9000000001", seconds: 5)], "serve.onlyAskedRows")
    let text = String(decoding: data, as: UTF8.self)
    expect(!text.contains("9000000002"), "serve.noOtherNumbers", text)
    var st = stat()
    expect(stat(d.resp.appendingPathComponent("r1.json").path, &st) == 0, "serve.stat")
    equal(st.st_mode & 0o777, 0o600, "serve.fileMode")
    expect(stat(d.resp.path, &st) == 0, "serve.dirStat")
    equal(st.st_mode & 0o777, 0o700, "serve.dirMode")
}

@Test func daemonReportsQueryFailuresAndDropsMalformedRequests() throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    try MB.writeAtomically(MB.encode(MB.Request(id: "bad", sinceEpoch: 0)), to: d.req.appendingPathComponent("bad.json"))
    try MB.writeAtomically(Data("garbage".utf8), to: d.req.appendingPathComponent("junk.json"))
    struct NoAccess: Error, LocalizedError { var errorDescription: String? { "no access" } }
    MB.serve(requestsDir: d.req, responsesDir: d.resp) { _ in throw NoAccess() }
    expect(Fs.list(d.req).isEmpty, "fail.requestsCleared")
    #expect(throws: MB.MailboxError.daemonError("no access")) {
        try MB.decodeResponse(Data(contentsOf: d.resp.appendingPathComponent("bad.json")), expecting: "bad")
    }
    expect(!Fs.list(d.resp).contains("junk.json"), "fail.junkGetsNoAnswer")
}

@Test func staleRequestsAndResponsesAreCleanedUp() throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    try MB.writeAtomically(MB.encode(MB.Request(id: "old", sinceEpoch: 0)), to: d.req.appendingPathComponent("old.json"))
    try MB.writeAtomically(MB.encode(MB.Response(id: "old", ok: true)), to: d.resp.appendingPathComponent("old2.json"))
    var asked = 0
    // Three minutes later both files are stale: removed, and the old request is not answered.
    let n = MB.serve(requestsDir: d.req, responsesDir: d.resp, now: Date().addingTimeInterval(180)) { _ in asked += 1; return [] }
    equal(n, 0, "stale.noneAnswered")
    equal(asked, 0, "stale.queryNeverRun")
    expect(Fs.list(d.req).isEmpty && Fs.list(d.resp).isEmpty, "stale.removed")
}

@Test func appGetsTheDaemonsAnswer() async throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    let req = MB.Request(sinceEpoch: 0)
    async let answer = MB.ask(req, requestsDir: d.req, responsesDir: d.resp, timeout: 3, poll: 0.02)
    // The "daemon": waits for the request file to appear, then serves it.
    for _ in 0..<100 where Fs.list(d.req).isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    MB.serve(requestsDir: d.req, responsesDir: d.resp) { _ in sampleRows }
    let resp = try await answer
    equal(resp.rows.count, 3, "ask.rows")
    expect(Fs.list(d.resp).isEmpty, "ask.responseConsumed")
}

@Test func noAnswerIsATimeoutAndWithdrawsTheRequest() async throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    do {
        _ = try await MB.ask(.init(sinceEpoch: 0), requestsDir: d.req, responsesDir: d.resp, timeout: 0.2, poll: 0.02)
        Issue.record("timeout: expected an error")
    } catch let e as MB.MailboxError {
        equal(e, .timeout, "timeout.error")
    }
    expect(Fs.list(d.req).isEmpty, "timeout.requestWithdrawn")
}

@Test func aMalformedAnswerIsAnErrorNotEmptyHistory() async throws {
    let d = try dirs(); defer { Fs.remove(d.root) }
    let req = MB.Request(sinceEpoch: 0)
    try MB.writeAtomically(Data("{ half".utf8), to: d.resp.appendingPathComponent("\(req.id).json"))
    do {
        _ = try await MB.ask(req, requestsDir: d.req, responsesDir: d.resp, timeout: 1, poll: 0.02)
        Issue.record("malformed: expected an error")
    } catch let e as MB.MailboxError {
        if case .malformed = e {} else { Issue.record("malformed.kind: \(e)") }
    }
}
