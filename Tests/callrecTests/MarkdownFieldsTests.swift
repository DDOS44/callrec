import Foundation
import Testing
@testable import callrec

@Test func markdownFieldRoundTrip() {
    let failures = SelfTest.markdownFields()
    #expect(failures.isEmpty, "\(failures)")
}
