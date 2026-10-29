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

// 2026-10-29: the 296 cards imported from callrec's own .vcf were not removable. A card is recognised
// as one ONLY if it has the .vcf's exact shape: name = organisation = the lead's company, no surname,
// and exactly the lead's numbers. Anything else (a hand-made card) is never adopted.
@Test func onlyCardsWithTheVcfShapeAreAdopted() throws {
    let lead = try LeadImporter.parse("company,phone,alt_phone\nCareer Choice Solution,9000000001,9000000201\n").leads[0]
    let vcf = ContactsPlan.Card(id: "v", organization: "Career Choice Solution", givenName: "Career Choice Solution",
                                familyName: "", numbers: ["9000000201", "9000000001"])
    #expect(ContactsPlan.isFromCallrecVcf(vcf, lead: lead))
    var handMade = vcf; handMade.givenName = "Abhishek"
    #expect(!ContactsPlan.isFromCallrecVcf(handMade, lead: lead))
    var extraNumber = vcf; extraNumber.numbers.append("9000000999")
    #expect(!ContactsPlan.isFromCallrecVcf(extraNumber, lead: lead))
    var surname = vcf; surname.familyName = "Pvt"
    #expect(!ContactsPlan.isFromCallrecVcf(surname, lead: lead))
    var otherCompany = vcf; otherCompany.organization = "Other Co"
    #expect(!ContactsPlan.isFromCallrecVcf(otherCompany, lead: lead))
}
