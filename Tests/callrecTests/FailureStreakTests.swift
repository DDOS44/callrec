import Foundation
import Testing
@testable import CallrecCore

private func res(_ m: Int, lead: String, _ r: DialResult, seconds: Int? = nil) -> DialLogEntry {
    DialLogEntry.attempt(at: DialFixture.at(8, 12, m), id: "\(lead)-\(m)", list: "fake", leadID: lead, key: "900000\(m)000")
        .finished(at: DialFixture.at(8, 12, m), result: r, seconds: seconds)
}

// One lead with three unanswered numbers is one failure, not three.
@Test func unansweredAltsOfOneLeadCountOnce() {
    let log = [res(1, lead: "A", .noConnect), res(2, lead: "A", .noConnect), res(3, lead: "A", .noConnect)]
    #expect(DialPolicy.trailingFailures(log: log, since: DialFixture.at(8, 9), rules: DialRules()) == 1)
}

@Test func failuresAcrossLeadsStillAddUp() {
    let log = [res(1, lead: "A", .noConnect), res(2, lead: "A", .noConnect),
               res(3, lead: "B", .noConnect), res(4, lead: "C", .connected, seconds: 2)]
    #expect(DialPolicy.trailingFailures(log: log, since: DialFixture.at(8, 9), rules: DialRules()) == 3)
}

// "Barred" is the carrier-restriction signal: every one counts, even on the same lead.
@Test func barredCountsEveryDial() {
    let log = [res(1, lead: "A", .barred), res(2, lead: "A", .barred), res(3, lead: "A", .barred)]
    #expect(DialPolicy.trailingFailures(log: log, since: DialFixture.at(8, 9), rules: DialRules()) == 3)
}

@Test func aConnectionResetsTheStreak() {
    let log = [res(1, lead: "A", .noConnect), res(2, lead: "B", .connected, seconds: 60), res(3, lead: "C", .noConnect)]
    #expect(DialPolicy.trailingFailures(log: log, since: DialFixture.at(8, 9), rules: DialRules()) == 1)
}
