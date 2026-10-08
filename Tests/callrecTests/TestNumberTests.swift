import Foundation
import Testing
@testable import CallrecCore

// The user's own test numbers may skip cooldown, hours and caps so the dialer can be
// rehearsed safely. These tests pin that the exemption NEVER reaches a real lead.

private func testRules(_ keys: Set<String> = ["9000000077"]) -> DialRules {
    var r = DialRules(); r.testKeys = keys; return r
}

@Test func testNumberSkipsHoursCooldownAndCaps() {
    let r = testRules()
    let night = DialFixture.at(7, 1)                       // 01:00, outside hours
    #expect(DialFixture.decide("9000000077", now: night, rules: r) == .allowed)
    let called = [DialFixture.attempt(DialFixture.at(6, 12), key: "9000000077")]
    #expect(DialFixture.decide("9000000077", now: DialFixture.at(7, 12), rules: r, log: called) == .allowed)
    let capped = (0..<40).map { DialFixture.attempt(DialFixture.at(7, 11, $0), key: "9000000099") }
    #expect(DialFixture.decide("9000000077", now: DialFixture.at(7, 12), rules: r, log: capped) == .allowed)
}

@Test func realLeadStillBlockedWhileTestNumbersExist() {
    let r = testRules()
    let night = DialFixture.at(7, 1)
    if case .blocked(.outsideCallingHours) = DialFixture.decide("9000000001", now: night, rules: r) {} else {
        Issue.record("a real lead must stay blocked outside calling hours")
    }
    let called = [DialFixture.attempt(DialFixture.at(6, 12), key: "9000000001")]
    if case .blocked(.cooldown) = DialFixture.decide("9000000001", now: DialFixture.at(7, 12), rules: r, log: called) {} else {
        Issue.record("a real lead must keep its 7-day cooldown")
    }
}

@Test func testDialsDoNotCountTowardRealCaps() {
    let r = testRules()
    let tests = (0..<40).map { DialFixture.attempt(DialFixture.at(7, 11, $0), key: "9000000077") }
    #expect(DialFixture.decide("9000000001", now: DialFixture.at(7, 12), rules: r, log: tests) == .allowed)
}

@Test func testNumberStillNeedsSIMConfirmationAndNoActiveCall() {
    let r = testRules()
    let unconfirmed = DialFixture.session(confirmed: false)
    #expect(DialFixture.decide("9000000077", rules: r, session: unconfirmed) == .blocked(.coldSIMNotConfirmed))
    #expect(DialFixture.decide("9000000077", rules: r, session: DialFixture.session(callActive: true)) == .blocked(.callActive))
}

@Test func testNumberGapIsShortButNonZero() {
    let r = testRules()
    let end = DialFixture.at(7, 12)
    if case .blocked(.gapNotElapsed) = DialFixture.decide("9000000077", now: end.addingTimeInterval(5), rules: r,
                                                       session: DialFixture.session(lastWrapUp: end)) {} else {
        Issue.record("test numbers still keep a minimum gap")
    }
    #expect(DialFixture.decide("9000000077", now: end.addingTimeInterval(11), rules: r,
                               session: DialFixture.session(lastWrapUp: end)) == .allowed)
}

@Test func importAllowsRepeatsOnlyForTestNumbersWithUniqueIds() throws {
    let csv = "company,phone\nTest 1,9000000077\nTest 2,9000000077\nReal,9000000001\nReal again,9000000001\n"
    let r = try LeadImporter.parse(csv, repeatable: ["9000000077"])
    #expect(r.leads.map(\.id) == ["9000000077", "9000000077#2", "9000000001"])
    #expect(r.rejected.count == 1, "a repeated real number is still rejected")
}
