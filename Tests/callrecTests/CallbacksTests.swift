import Foundation
import Testing
@testable import CallrecCore

@Test func callbacksAreIncomingCallsFromAnyLeadNumber() throws {
    let leads = try LeadImporter.parse("""
    company,phone,alt_phone
    Fake One,9000000001,9000000201
    Fake Two,9000000002,
    """).leads
    let t = DialFixture.at(29, 15)
    let ourDial = DialLogEntry.attempt(at: t, list: "L", leadID: "9000000002", key: "9000000002")
    let history = [
        HistoryCall(key: "9000000201", date: t.addingTimeInterval(600), seconds: 95, originated: false),   // alt rang us back
        HistoryCall(key: "9000000001", date: t.addingTimeInterval(900), seconds: 0, originated: false),    // missed callback
        HistoryCall(key: "9000000001", date: t.addingTimeInterval(1000), seconds: 40, originated: true),   // we called: not one
        HistoryCall(key: "9000000002", date: t.addingTimeInterval(20), seconds: 30, originated: nil),      // unknown dir, our dial
        HistoryCall(key: "9000000002", date: t.addingTimeInterval(3600), seconds: 25, originated: nil),    // unknown dir, not ours
        HistoryCall(key: "9000000099", date: t, seconds: 50, originated: false),                           // not a lead
        HistoryCall(key: "9000000001", date: t.addingTimeInterval(-9 * 86_400), seconds: 60, originated: false)]  // too old
    let found = Callbacks.find(history: history, leads: leads, log: [ourDial], since: t.addingTimeInterval(-7 * 86_400))
    #expect(found.map(\.leadID) == ["9000000002", "9000000001", "9000000001"])
    #expect(found.map(\.missed) == [false, true, false])
    #expect(found.last?.number == "9000000201")
}
