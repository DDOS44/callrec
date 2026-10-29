import Testing
@testable import CallrecCore

@Test func contactsPlanNeverTouchesAPersonalContact() throws {
    let leads = try LeadImporter.parse("""
    company,phone,alt_phone
    Fake One Pvt Ltd,9000000001,9000000201
    Fake Two,9000000002,
    Fake Three,9000000003,
    Fake Four,9000000004,
    """).leads
    let existing: [String: [ContactsPlan.Existing]] = [
        "9000000201": [.init(id: "c1", organization: "FAKE ONE PVT. LTD.", inGroup: false)],   // our vcf card, via its alt
        "9000000002": [.init(id: "c2", organization: "", inGroup: false)],                     // a personal contact
        "9000000003": [.init(id: "c3", organization: "Fake Three", inGroup: true)]]            // already grouped
    let p = ContactsPlan.plan(leads: leads, existing: existing)
    #expect(p.create.map(\.company) == ["Fake Four"])
    #expect(p.addToGroup == ["c1"])
    #expect(p.personal.map(\.company) == ["Fake Two"])
    #expect(p.alreadyDone == 1)
}
