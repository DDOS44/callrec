import Foundation
import Testing
@testable import CallrecCore

private let cal = DialFixture.cal
private let monSat: Set<Int> = [1, 2, 3, 4, 5, 6]
private func state(_ attempts: [Date], now: Date, status: LeadStatus = .noAnswer) -> RetryPlan.State {
    RetryPlan.state(attempts: attempts, status: status, now: now, calendar: cal, callingDays: monSat)
}

// Oct 2026: Thu 29, Fri 30, Sat 31, Sun 1 Nov, Mon 2.
@Test func aNoConnectIsDueAgainAfterOneCallingDayThenTwoThenFour() {
    let first = DialFixture.at(29, 11)                              // Thu morning
    if case .waiting(let until, 1, _, .midday) = state([first], now: DialFixture.at(29, 17)) {
        #expect(until == DialFixture.at(30, 0))
    } else { Issue.record("try1 waits until Friday, suggests midday: \(state([first], now: DialFixture.at(29, 17)))") }
    #expect(state([first], now: DialFixture.at(30, 10)).isDue)

    let second = DialFixture.at(30, 13)                              // Fri midday
    if case .waiting(let until, 2, _, .late) = state([first, second], now: DialFixture.at(31, 12)) {
        #expect(until == DialFixture.at(2, 0, month: 11), "2 calling days after Fri, skipping Sunday = Mon")
    } else { Issue.record("try2: \(state([first, second], now: DialFixture.at(31, 12)))") }

    let third = DialFixture.at(2, 16, month: 11)                     // Mon late
    if case .waiting(let until, 3, _, .morning) = state([first, second, third], now: DialFixture.at(3, 10, month: 11)) {
        #expect(until == DialFixture.at(6, 0, month: 11), "4 calling days after Mon = Fri")
    } else { Issue.record("try3: \(state([first, second, third], now: DialFixture.at(3, 10, month: 11)))") }

    let fourth = DialFixture.at(6, 10, month: 11)
    if case .exhausted(4, _) = state([first, second, third, fourth], now: DialFixture.at(20, 10, month: 11)) {} else {
        Issue.record("after 4 tries the lead is given up on")
    }
}

@Test func severalDialsOnOneDayAreOneTry() {
    let day = [DialFixture.at(29, 11), DialFixture.at(29, 11, 2), DialFixture.at(29, 15)]   // main + alts, and a later redial
    #expect(state(day, now: DialFixture.at(30, 10)).tries == 1)
}

@Test func onlyNoAnswerLeadsRetry() {
    for s in [LeadStatus.called, .pending, .doNotCall, .skipped] {
        #expect(state([DialFixture.at(20, 11)], now: DialFixture.at(29, 11), status: s) == .none, "\(s)")
    }
    #expect(state([], now: DialFixture.at(29, 11)) == .none)
}

@Test func suggestedWindowRotatesThroughTheDay() {
    #expect(RetryPlan.suggestedWindow(attempts: [DialFixture.at(29, 16)], calendar: cal) == .morning)
    #expect(RetryPlan.suggestedWindow(attempts: [DialFixture.at(29, 10), DialFixture.at(30, 13)], calendar: cal) == .late)
    let all = [DialFixture.at(28, 10), DialFixture.at(29, 13), DialFixture.at(30, 16), DialFixture.at(31, 11)]
    #expect(RetryPlan.suggestedWindow(attempts: all, calendar: cal) == .midday, "least tried after all three")
}
