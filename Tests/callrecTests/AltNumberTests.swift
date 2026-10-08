import Testing
@testable import CallrecCore

// Regression (2026-10-08): sheet cells hold several alt numbers separated by " / ", the
// last often truncated ("+91 99"). The importer treated the whole cell as one number and
// discarded every alt number with a warning per row.

@Test func altCellWithSeveralNumbersKeepsAllValidOnes() {
    let r = PhoneNumber.list("+91 90000 00201 / +91 90000 00202 / +91 99")
    #expect(r.valid == ["9000000201", "9000000202"])
    #expect(r.dropped == ["+91 99"])
}

@Test func altCellSeparatorsAndDuplicates() {
    #expect(PhoneNumber.list("9000000201, 09000000202; +919000000201 | 9000000203 or 9000000204").valid
            == ["9000000201", "9000000202", "9000000203", "9000000204"])
    #expect(PhoneNumber.list("").valid.isEmpty)
    #expect(PhoneNumber.list("n/a").dropped.isEmpty, "text without digits is not a dropped number")
}

@Test func importKeepsAltNumbersAndSummarisesFragments() throws {
    let csv = """
    call_name,phone,alt_phone
    Fake A,+91 90000 00101,+91 90000 00201 / +91 90000 00202 / +91 99
    Fake B,+91 90000 00102,+91 90000 00102 / +91 90000 00203
    Fake C,+91 90000 00103,12345
    """
    let r = try LeadImporter.parse(csv)
    #expect(r.leads.map(\.altNumbers) == [["9000000201", "9000000202"], ["9000000203"], []])
    #expect(r.leads[0].altNumber == "9000000201")
    #expect(r.warnings.count == 2, "one summary for fragments, one for the unreadable cell: \(r.warnings)")
}
