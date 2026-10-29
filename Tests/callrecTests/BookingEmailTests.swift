import Foundation
import Testing
@testable import CallrecCore

@Test func emailCheckCatchesWhatGetsMisheardOnACall() {
    for good in ["rahul@fakeagency.in", "a.b+c@fake.co", " hr@fake-agency.com "] { #expect(BookingEmail.isValid(good), "\(good)") }
    for bad in ["", "rahul", "rahul@", "@fake.in", "rahul@fake", "rahul fake@x.in", "a@b@c.in", "rahul@.in", "rahul@fake.c"] {
        #expect(!BookingEmail.isValid(bad), "\(bad)")
    }
}

@Test func greetingUsesAFirstNameOnlyWhenThereIsOne() {
    #expect(BookingEmail.firstName(from: "Rahul Sharma (Founder)") == "Rahul")
    #expect(BookingEmail.firstName(from: "") == "")
    #expect(BookingEmail.firstName(from: "HR-Desk") == "")
    let t = "Hi {name},\n{company} {link} {sender}"
    #expect(BookingEmail.fill(t, name: "", company: "Fake Co", link: "https://example.com/x", sender: "Me") ==
            "Hi,\nFake Co https://example.com/x Me")
    #expect(BookingEmail.fill(t, name: "Rahul", company: "", link: "", sender: "").hasPrefix("Hi Rahul,"))
}

@Test func composeURLKeepsPlusAmpersandAndNewlinesIntact() throws {
    let url = try #require(BookingEmail.composeURL(to: "a+b@fake.in", subject: "Call & link", body: "Hi,\nlink: https://x.io/a?b=1",
                                                   via: .gmail, account: "me@fake.in"))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(url.host == "mail.google.com")
    #expect(q["to"] == "a+b@fake.in")
    #expect(q["su"] == "Call & link")
    #expect(q["body"] == "Hi,\nlink: https://x.io/a?b=1")
    #expect(q["authuser"] == "me@fake.in")
    #expect(url.absoluteString.contains("a%2Bb@fake.in"), "a raw + would arrive as a space")
    let mail = try #require(BookingEmail.composeURL(to: "a@fake.in", subject: "S", body: "B", via: .mail))
    #expect(mail.scheme == "mailto")
}
