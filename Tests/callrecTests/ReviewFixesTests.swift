import Foundation
import Testing
@testable import CallrecCore

// Regressions from the 2026-10-29 code review (/code-review high on the dialer branch).

@Test func stopWhileACallThatRangIsBeingResolvedWaitsForTheAnswer() {
    var s = DialSession()
    s.handle(.start)
    _ = s.handle(.preflightPassed(now: DialFixture.at(7, 11)))
    _ = s.handle(.dialChecked(now: DialFixture.at(7, 11), nextLeadID: "9000000001", decision: .allowed))
    _ = s.handle(.dialPlaced(now: DialFixture.at(7, 11, 0, 1)))
    _ = s.handle(.tick(now: DialFixture.at(7, 11, 1)))                     // past notPlacedTimeout: resolving
    guard case .resolvingDial = s.phase else { Issue.record("resolving: \(s.phase)"); return }
    let e = s.handle(.stop)
    #expect(!e.contains(.recordNotPlaced(leadID: "9000000001")), "a call that may have rung is not written off")
    let r = s.handle(.dialResolved(.placed(seconds: 0), now: DialFixture.at(7, 11, 1, 10)))
    #expect(!r.contains(.recordNotPlaced(leadID: "9000000001")))
    if case .stopped = s.phase {} else if case .wrapUp = s.phase {} else { Issue.record("then stops: \(s.phase)") }
}

@Test func aCallbackUnderTwentySecondsIsNotTalked() {
    let short = Callbacks.Item(leadID: "a", number: "9000000001", date: Date(), seconds: 8)
    #expect(!short.talked)
    #expect(Callbacks.Item(leadID: "a", number: "9000000001", date: Date(), seconds: 20).talked)
}

@Test func contactsPlanNeverAdoptsAnExistingCardAndSkipsRepeatsAndTestNumbers() throws {
    let leads = try LeadImporter.parse("""
    company,phone,alt_phone
    Acme Realty,9000000001,
    Fake Two,9000000002,9000000301
    Fake Two Branch,9000000301,
    Mine,9000000077,
    Mine,9000000077,
    """, repeatable: ["9000000077"]).leads
    let existing: [String: [ContactsPlan.Existing]] = [
        "9000000001": [.init(id: "own", organization: "Acme Realty")]]   // the user's own card
    let p = ContactsPlan.plan(leads: leads, existing: existing, skip: ["9000000077"])
    #expect(p.create.map(\.company) == ["Fake Two"], "one card per number, test numbers never saved")
    #expect(p.alreadySaved.map(\.company) == ["Acme Realty"], "an existing card is never touched")
}

@Test func notPlacedIDsAndLogKeyAreShared() {
    let a = DialLogEntry.attempt(at: DialFixture.at(7, 11), id: "X", list: "L", leadID: "1", key: "+91 90000 00001")
    #expect(DialPolicy.notPlacedIDs([a, a.finished(at: DialFixture.at(7, 11), result: .notPlaced)]) == ["X"])
    #expect(DialPolicy.logKey(a) == "9000000001")
}
