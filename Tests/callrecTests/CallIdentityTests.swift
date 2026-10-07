import Foundation
import Testing
@testable import CallrecCore

@Test func callIdentityAndLeadMatching() {

    // Numbers match on the last ten digits, however they are written.
    equal(LeadSheet.key("+91 90000 00001"), "9000000001", "identity.keySpaced")
    equal(LeadSheet.key("090000-00001"), "9000000001", "identity.keyPunctuated")
    equal(LeadSheet.key("+919000000001"), "9000000001", "identity.keyE164")
    equal(LeadSheet.key("123"), "123", "identity.keyShort")

    // Quoted fields containing commas must not shift the columns.
    let csv = """
    company,owner,phone,note
    Beta Staffing,,+91 11 4000 0000,"big, busy office"
    Acme Recruiters,Rahul Sharma,+91 90000 00001,317 reviews
    """
    let rows = LeadSheet.parse(csv)
    equal(rows.count, 3, "identity.csvRows")
    equal(rows[1].count, 4, "identity.csvColumns")
    equal(rows[1][3], "big, busy office", "identity.csvQuotedComma")

    // Swift reads "\r\n" as a single Character, so a CRLF sheet used to parse
    // as one enormous row and nothing ever matched.
    let crlf = csv.replacingOccurrences(of: "\n", with: "\r\n")
    equal(LeadSheet.parse(crlf).count, 3, "identity.csvCRLF")
    equal(LeadSheet.parse(csv.replacingOccurrences(of: "\n", with: "\r")).count, 3, "identity.csvCR")

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-leads-\(UUID()).csv")
    try? csv.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let hit = LeadSheet.lookup(number: "+919000000001", csv: tmp)
    equal(hit?.company ?? "", "Acme Recruiters", "identity.leadCompany")
    equal(hit?.owner ?? "", "Rahul Sharma", "identity.leadOwner")
    expect(LeadSheet.lookup(number: "+919999000011", csv: tmp) == nil, "identity.leadMiss", "unknown number matched")

    // Identity lines go into the header and read back cleanly.
    let base = Markdown.render(date: Date(), seconds: 30, audioName: "x.m4a",
                               segments: [Segment(start: 0, end: 2, text: "hi", speaker: .them)])
    let withID = MarkdownFields.setIdentity(md: base, CallIdentity(number: "+919000000001",
                                                                  contact: "Rahul",
                                                                  company: "Acme Recruiters",
                                                                  owner: "Rahul Sharma"))
    let read = MarkdownFields.identity(md: withID)
    equal(read.number, "+919000000001", "identity.roundTripNumber")
    equal(read.company, "Acme Recruiters", "identity.roundTripCompany")
    equal(read.owner, "Rahul Sharma", "identity.roundTripOwner")
    expect(withID.contains("- audio: x.m4a"), "identity.audioKept", "audio line lost")
    equal(MarkdownFields.segments(md: withID).count, 1, "identity.transcriptKept")

    // Writing twice must not duplicate the lines.
    let twice = MarkdownFields.setIdentity(md: withID, CallIdentity(number: "+910000000000"))
    equal(twice.components(separatedBy: "- number:").count - 1, 1, "identity.noDuplicate")
    equal(MarkdownFields.identity(md: twice).number, "+910000000000", "identity.overwritten")
    equal(MarkdownFields.identity(md: twice).company, "Acme Recruiters", "identity.otherFieldsKept")
}
