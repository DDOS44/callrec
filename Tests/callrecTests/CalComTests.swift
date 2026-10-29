import Foundation
import Testing
@testable import CallrecCore

private let ist = TimeZone(identifier: "Asia/Kolkata")!

private func client(status: Int = 200, body: String, seen: SeenBox = SeenBox()) -> CalCom {
    CalCom(apiKey: "test-key", eventTypeId: 42, timeZone: ist) { req in
        seen.set(req)
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    }
}

final class SeenBox: @unchecked Sendable {
    private let lock = NSLock(); private var _req: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); _req = r; lock.unlock() }
    var req: URLRequest? { lock.lock(); defer { lock.unlock() }; return _req }
}

@Test func slotsAskForTheDayInTheBookingTimeZoneAndParseEveryStart() async throws {
    let seen = SeenBox()
    let c = client(body: #"{"status":"success","data":{"2026-10-30":[{"start":"2026-10-30T09:30:00.000+05:30"},{"start":"2026-10-30T09:00:00.000+05:30"}]}}"#, seen: seen)
    let day = DialFixture.at(30, 15)
    let slots = try await c.slots(on: day)
    #expect(slots == [DialFixture.at(30, 9), DialFixture.at(30, 9, 30)])
    let q = URLComponents(url: try #require(seen.req?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(q.first { $0.name == "start" }?.value == "2026-10-30")
    #expect(q.first { $0.name == "end" }?.value == "2026-10-31")
    #expect(q.first { $0.name == "eventTypeId" }?.value == "42")
    #expect(q.first { $0.name == "timeZone" }?.value == "Asia/Kolkata")
    #expect(seen.req?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
}

@Test func bookingSendsTheSlotInUTCWithTheAttendeeAndReadsTheLink() async throws {
    let seen = SeenBox()
    let c = client(status: 201, body: #"{"status":"success","data":{"uid":"bk_1","start":"2026-10-30T04:00:00.000Z","location":"https://meet.google.com/abc-defg-hij"}}"#, seen: seen)
    let b = try await c.book(start: DialFixture.at(30, 9, 30), name: " Rahul ", email: "rahul@fakeagency.in ")
    #expect(b == CalCom.Booking(uid: "bk_1", start: DialFixture.at(30, 9, 30), meetingURL: "https://meet.google.com/abc-defg-hij"))
    let req = try #require(seen.req)
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "cal-api-version") == "2024-08-13")
    let json = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
    #expect(json["start"] as? String == "2026-10-30T04:00:00Z")
    #expect(json["eventTypeId"] as? Int == 42)
    let attendee = try #require(json["attendee"] as? [String: Any])
    #expect(attendee["name"] as? String == "Rahul")
    #expect(attendee["email"] as? String == "rahul@fakeagency.in")
    #expect(attendee["timeZone"] as? String == "Asia/Kolkata")
}

@Test func calComErrorsComeBackInPlainWords() async {
    let taken = client(status: 400, body: #"{"status":"error","error":{"code":"BadRequestException","message":"User either already has booking at this time or is not available"}}"#)
    do { _ = try await taken.book(start: DialFixture.at(30, 9), name: "A", email: "a@fake.in"); Issue.record("should throw") } catch {
        #expect(error.localizedDescription == "Cal.com: User either already has booking at this time or is not available")
    }
    let badKey = client(status: 401, body: "{}")
    do { _ = try await badKey.slots(on: DialFixture.at(30, 9)); Issue.record("should throw") } catch {
        #expect(error.localizedDescription.contains("Keychain"))
    }
}

// 2026-10-29: a Keychain prompt on every launch. The key is now read only when booking, from an
// owner-only file first; a file others can read is refused.
@Test func keyFileMustBeOwnerOnlyAndWinsOverTheKeychain() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calkey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { Fs.remove(dir) }
    let f = dir.appendingPathComponent("calcom.key")
    #expect(throws: CalCom.Failure.self) { try CalCom.loadKey(file: f, keychain: { nil }) }
    #expect(try CalCom.loadKey(file: f, keychain: { "from-keychain" }) == "from-keychain")
    try Data("file-key\n".utf8).write(to: f)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
    #expect(throws: CalCom.Failure.self) { try CalCom.loadKey(file: f, keychain: { "from-keychain" }) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
    #expect(try CalCom.loadKey(file: f, keychain: { "from-keychain" }) == "file-key")
}

@Test func theKeyIsNotReadUntilARequestIsMade() async throws {
    let reads = SeenBox()
    let c = CalCom(key: { reads.set(URLRequest(url: URL(string: "https://read")!)); return "k" }, eventTypeId: 1,
                   timeZone: TimeZone(identifier: "Asia/Kolkata")!) { req in
        (Data(#"{"data":{}}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(reads.req == nil, "creating the client reads nothing")
    _ = try await c.slots(on: DialFixture.at(30, 9))
    #expect(reads.req != nil)
}
