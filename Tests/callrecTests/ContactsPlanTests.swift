import Testing
@testable import CallrecCore

@Test func contactsPlanCreatesOnlyForNumbersWithNoContact() throws {
    let leads = try LeadImporter.parse("""
    company,phone,alt_phone
    Fake One Pvt Ltd,9000000001,9000000201
    Fake Two,9000000002,
    Fake Four,9000000004,
    """).leads
    let existing: [String: [ContactsPlan.Existing]] = [
        "9000000201": [.init(id: "c1", organization: "FAKE ONE PVT. LTD.")],
        "9000000002": [.init(id: "c2", organization: "")]]
    let p = ContactsPlan.plan(leads: leads, existing: existing)
    #expect(p.create.map(\.company) == ["Fake Four"])
    #expect(p.alreadySaved.map(\.company) == ["Fake One Pvt Ltd", "Fake Two"])
}
