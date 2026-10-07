import Foundation
import Testing
@testable import CallrecCore

private let sep = "\u{1}"
private func at(_ h: Int, _ m: Int = 0, day: Int = 7) -> Date { DialFixture.at(day, h, m) }

private func call(_ key: String, _ date: Date, values: [String: String], seconds: Int = 30, originated: Bool? = true) -> HistoryCall {
    HistoryCall(key: key, date: date, seconds: seconds, originated: originated, values: values)
}

/// Eight outgoing calls on two fake SIMs; the per-call id never repeats.
private func fixtureRows(simColumn: String = "ZSIM_ID") -> [HistoryCall] {
    (0..<8).map { i in
        call("900000000\(i)", at(10, i), values: [
            simColumn: i % 3 == 0 ? "SIM-A" : "SIM-B",
            "ZUNIQUE_ID": "uuid-\(i)",
            "ZSERVICE_PROVIDER": i % 2 == 0 ? "com.apple.Telephony" : "com.apple.FaceTime",
            "ZLOCATION": i % 2 == 0 ? "Delhi" : "Mumbai"
        ])
    }
}

@Test func tableInfoOutputParsesIntoColumns() {
    let out = "0\(sep)Z_PK\(sep)INTEGER\(sep)0\(sep)\(sep)1\n1\(sep)ZADDRESS\(sep)BLOB\(sep)0\(sep)\(sep)0\n2\(sep)ZSIM_ID\(sep)VARCHAR\(sep)0\(sep)\(sep)0\n"
    let cols = CallHistory.parseTableInfo(out)
    equal(cols.map(\.name), ["Z_PK", "ZADDRESS", "ZSIM_ID"], "schema.names")
    equal(cols[1].type, "BLOB", "schema.type")
    equal(CallHistory.parseTableInfo("").count, 0, "schema.empty")
}

@Test func candidateColumnsMatchTheHintsOnly() {
    let names = ["Z_PK", "ZADDRESS", "ZSIM_SLOT", "ZSERVICE_PROVIDER", "ZLOCATION", "ZUNIQUE_ID", "ZLINE_ID", "ZACCOUNT",
                 "ZHANDLE_TYPE", "ZDURATION", "ZSIM; DROP TABLE x"]
    let cols = names.map { CallHistory.Column(name: $0, type: "TEXT") }
    equal(SIMDetector.candidateColumns(cols),
          ["ZSIM_SLOT", "ZSERVICE_PROVIDER", "ZLOCATION", "ZUNIQUE_ID", "ZLINE_ID", "ZACCOUNT", "ZHANDLE_TYPE"], "cand.list")
}

@Test func aRealSIMColumnIsChosenOverDecoys() {
    let cands = ["ZUNIQUE_ID", "ZSERVICE_PROVIDER", "ZLOCATION", "ZSIM_ID"]
    let d = SIMDetector.analyze(candidates: cands, rows: fixtureRows())
    guard case .available(let column, let values) = d else { Issue.record("sim.available: got \(d)"); return }
    equal(column, "ZSIM_ID", "sim.column")
    equal(Set(values.map(\.value)), ["SIM-A", "SIM-B"], "sim.values")
    equal(values.map(\.count).reduce(0, +), 8, "sim.counts")
}

@Test func perCallIdsAppProvidersAndLocationsAreNeverTrusted() {
    let rows = fixtureRows()
    for decoy in ["ZUNIQUE_ID", "ZSERVICE_PROVIDER", "ZLOCATION"] {
        guard case .unavailable(let reason) = SIMDetector.analyze(candidates: [decoy], rows: rows) else {
            Issue.record("decoy.\(decoy) must not be trusted"); continue
        }
        expect(!reason.isEmpty, "decoy.reason \(decoy)")
    }
}

@Test func aConstantColumnCannotTellSIMsApart() {
    let rows = (0..<6).map { call("900000000\($0)", at(10, $0), values: ["ZSIM_ID": "SIM-A"]) }
    guard case .unavailable(let reason) = SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: rows) else {
        Issue.record("constant.unavailable"); return
    }
    expect(reason.contains("only one value"), "constant.reason", reason)
}

@Test func mostlyEmptyColumnIsRejected() {
    var rows = fixtureRows()
    for i in 2..<rows.count { rows[i].values["ZSIM_ID"] = "" }
    expect(SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: rows).column == nil, "empty.rejected")
}

@Test func tooFewCallsFallsBackToManual() {
    let rows = Array(fixtureRows().prefix(2))
    guard case .unavailable(let reason) = SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: rows) else {
        Issue.record("few.unavailable"); return
    }
    expect(reason.contains("not enough"), "few.reason", reason)
}

@Test func noCandidateColumnsFallsBackToManual() {
    guard case .unavailable(let reason) = SIMDetector.analyze(candidates: [], rows: fixtureRows()) else {
        Issue.record("none.unavailable"); return
    }
    expect(reason.contains("no column"), "none.reason", reason)
}

@Test func incomingCallsAreIgnoredWhenTheDatabaseSaysWhichAreOutgoing() {
    // Incoming calls carry a different value; only outgoing ones count towards the analysis.
    var rows = fixtureRows()
    rows += (0..<5).map { call("900000010\($0)", at(11, $0), values: ["ZSIM_ID": "SIM-INCOMING-\($0)"], originated: false) }
    let d = SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: rows)
    guard case .available(_, let values) = d else { Issue.record("incoming.available: \(d)"); return }
    equal(Set(values.map(\.value)), ["SIM-A", "SIM-B"], "incoming.excluded")
}

@Test func lineForADialIsTheNearestRowForThatNumberAfterTheDial() {
    let dialed = at(12, 0)
    let rows = [
        call("9000000001", at(11, 0), values: ["ZSIM_ID": "OLD"]),
        call("9000000001", at(12, 0).addingTimeInterval(4), values: ["ZSIM_ID": "SIM-B"]),
        call("9000000002", at(12, 0).addingTimeInterval(2), values: ["ZSIM_ID": "OTHER-NUMBER"])
    ]
    equal(SIMDetector.line(forNumber: "9000000001", dialedAt: dialed, rows: rows, column: "ZSIM_ID"), "SIM-B", "line.nearest")
    equal(SIMDetector.line(forNumber: "9000000003", dialedAt: dialed, rows: rows, column: "ZSIM_ID"), nil, "line.noRow")
    equal(SIMDetector.line(forNumber: "9000000001", dialedAt: at(14, 0), rows: rows, column: "ZSIM_ID"), nil, "line.tooOld")
    let empty = [call("9000000001", dialed, values: ["ZSIM_ID": ""])]
    equal(SIMDetector.line(forNumber: "9000000001", dialedAt: dialed, rows: empty, column: "ZSIM_ID"), nil, "line.emptyValue")
    expect(SIMDetector.call(forNumber: "9000000001", dialedAt: dialed, rows: rows)?.values["ZSIM_ID"] == "SIM-B", "line.callRow")
}

@Test func endToEndWrongSIMDecisionFromFixtureRows() {
    // The cold SIM is SIM-A. A call to a fake lead goes out on SIM-B: the session must stop.
    let dialed = at(12, 0)
    let history = fixtureRows() + [call("9000000050", dialed.addingTimeInterval(3), values: ["ZSIM_ID": "SIM-B"])]
    guard case .available(let column, _) = SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: history) else {
        Issue.record("e2e.available"); return
    }
    let line = SIMDetector.line(forNumber: "9000000050", dialedAt: dialed, rows: history, column: column)
    let attempt = DialLogEntry.attempt(at: dialed, list: "fake", leadID: "9000000050", key: "9000000050")
    let result = attempt.finished(at: dialed.addingTimeInterval(60), result: .connected, seconds: 50, sim: line)
    let session = DialFixture.session(start: at(9), expected: "SIM-A")
    let d = DialPolicy.evaluate(number: "9000000051", now: at(12, 5), rules: DialFixture.rules, log: [attempt, result],
                                dnc: DNCList(), history: [:], session: session, calendar: DialFixture.cal)
    equal(d, .stop(.wrongSIM(expected: "SIM-A", got: "SIM-B")), "e2e.stops")
    // And the same call on the cold SIM carries on.
    let good = attempt.finished(at: dialed.addingTimeInterval(60), result: .connected, seconds: 50, sim: "SIM-A")
    let ok = DialPolicy.evaluate(number: "9000000051", now: at(12, 5), rules: DialFixture.rules, log: [attempt, good],
                                 dnc: DNCList(), history: [:], session: session, calendar: DialFixture.cal)
    equal(ok, .allowed, "e2e.carriesOn")
}

@Test func detectionSummaryNeverContainsSIMValues() {
    let d = SIMDetector.analyze(candidates: ["ZSIM_ID"], rows: fixtureRows())
    let line = SIMDetector.summary(d, candidates: ["ZSIM_ID"])
    expect(line.contains("ZSIM_ID") && line.contains("2 distinct"), "summary.names", line)
    expect(!line.contains("SIM-A") && !line.contains("SIM-B"), "summary.noValues", line)
    let none = SIMDetector.summary(.unavailable(reason: "x"), candidates: [])
    expect(none.contains("manual checklist"), "summary.manual", none)
}
