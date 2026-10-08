import Foundation
import Testing
@testable import CallrecCore

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
    return c
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? Date()
}

@Test func calendarCountsConnectsBookedAndTalkAndExcludesTests() {
    let calls = [
        CallFacts(date: at(2026, 10, 5), seconds: 90, outcome: "booked"),
        CallFacts(date: at(2026, 10, 5), seconds: 10, outcome: "no connect"),
        CallFacts(date: at(2026, 10, 5), seconds: 300, outcome: "test"),
        CallFacts(date: at(2026, 10, 6), seconds: 20, outcome: "Booked"),
        CallFacts(date: at(2026, 9, 30, 23), seconds: 60, outcome: "booked"),   // other month
        CallFacts(date: at(2026, 11, 1, 0), seconds: 60, outcome: "booked")     // other month
    ]
    let m = CallCalendar.summarize(calls, month: at(2026, 10, 17), calendar: cal)
    equal(m.totals.calls, 3, "cal.calls")
    equal(m.totals.connects, 2, "cal.connects")
    equal(m.totals.booked, 2, "cal.booked")
    equal(m.totals.talk, 110, "cal.talk")
    equal(m.totals.tests, 1, "cal.testsSeparate")
    equal(m.days["2026-10-05"]?.calls ?? 0, 2, "cal.dayCalls")
    equal(m.days["2026-10-05"]?.tests ?? 0, 1, "cal.dayTests")
    equal(m.maxCalls, 2, "cal.max")
    equal(CallCalendar.summarize([], month: at(2026, 10, 1), calendar: cal).maxCalls, 0, "cal.empty")
}

@Test func intensityScalesToTheBusiestDay() {
    equal(CallCalendar.intensity(calls: 0, max: 10), 0, "int.zero")
    equal(CallCalendar.intensity(calls: 1, max: 10), 1, "int.low")
    equal(CallCalendar.intensity(calls: 3, max: 10), 2, "int.2")
    equal(CallCalendar.intensity(calls: 6, max: 10), 3, "int.3")
    equal(CallCalendar.intensity(calls: 10, max: 10), 4, "int.max")
    equal(CallCalendar.intensity(calls: 1, max: 1), 4, "int.single")
    equal(CallCalendar.intensity(calls: 5, max: 0), 0, "int.noScale")
}

@Test func monthGridIsMondayFirstAndPadded() {
    // October 2026 starts on a Thursday: 3 padding cells, 31 days, 5 weeks.
    let weeks = CallCalendar.weeks(month: at(2026, 10, 15), calendar: cal)
    equal(weeks.count, 5, "grid.weeks")
    expect(weeks.allSatisfy { $0.count == 7 }, "grid.sevenWide")
    equal(weeks[0].map { $0.dayNumber }, [nil, nil, nil, 1, 2, 3, 4], "grid.firstRow")
    equal(weeks[4].last?.dayNumber, nil, "grid.tailPad")
    equal(weeks.flatMap { $0 }.compactMap(\.dayNumber).count, 31, "grid.days")
    equal(weeks[0][3].key ?? "", "2026-10-01", "grid.key")
    // A month starting on Monday has no lead padding (June 2026).
    equal(CallCalendar.weeks(month: at(2026, 6, 1), calendar: cal)[0].first?.dayNumber, 1, "grid.mondayStart")
    // Ids are unique (stable ForEach identity).
    let ids = weeks.flatMap { $0 }.map(\.id)
    equal(Set(ids).count, ids.count, "grid.uniqueIds")
    equal(CallCalendar.key(CallCalendar.shift(at(2026, 12, 20), by: 1, calendar: cal), calendar: cal), "2027-01-01", "grid.shift")
}

private let known = ["no connect", "gatekeeper", "pitched", "booked", "not interested", "callback", "nurture", "test"]

@Test func everyCallLandsInExactlyOneOutcomeBucket() {
    let outcomes = ["booked", "Booked ", "", "callback", "mystery", "test", "booked", "no connect", "  "]
    let counts = OutcomeBuckets.counts(outcomes, known: known)
    equal(counts.values.reduce(0, +), outcomes.count, "bucket.sumIsTotal")
    equal(counts["booked"] ?? -1, 3, "bucket.caseAndSpaceInsensitive")
    equal(counts[OutcomeBuckets.untagged] ?? -1, 3, "bucket.untaggedCatchesBlankAndUnknown")
    equal(counts["nurture"] ?? -1, 0, "bucket.emptyKnownPresent")
    equal(OutcomeBuckets.bucket(for: "mystery", known: known), OutcomeBuckets.untagged, "bucket.unknown")
    equal(OutcomeBuckets.counts([], known: known).values.reduce(0, +), 0, "bucket.empty")
}
