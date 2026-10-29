import Foundation
import Testing
@testable import CallrecCore

@Test func pickupRateCountsPickedUpLeadsOverRealDialsOfThisList() {
    let t = DialFixture.at(29, 12)
    func rec(_ outcome: String) -> LeadRecord { var r = LeadRecord(); r.outcome = outcome; return r }
    let ghost = DialLogEntry.attempt(at: t, id: "G", list: "L", leadID: "9000000005", key: "9000000005")
    let log: [DialLogEntry] = [
        .attempt(at: t, list: "L", leadID: "9000000001", key: "9000000001"),
        .attempt(at: t, list: "L", leadID: "9000000001", key: "9000000201"),   // alt dial counts
        .attempt(at: t, list: "L", leadID: "9000000002", key: "+91 90000 00002"),
        .attempt(at: t, list: "L", leadID: "9000000077", key: "9000000077"),   // test number
        .attempt(at: t, list: "OTHER", leadID: "9000000003", key: "9000000003"),
        ghost, ghost.finished(at: t, result: .notPlaced)]
    let records = ["9000000001": rec("pitched"), "9000000002": rec("no connect"), "9000000004": rec("Gatekeeper"),
                   "9000000006": rec(""), "9000000077": rec("test")]
    let v = PickupRate.compute(log: log, list: "L", records: records, testKeys: ["9000000077"])
    #expect(v == PickupRate.Value(pickedUp: 2, dials: 3))
    #expect(v.text == "2 of 3 dials · 67%")
    #expect(PickupRate.Value(pickedUp: 0, dials: 0).text == "0 of 0 dials")
}
