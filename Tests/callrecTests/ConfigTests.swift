import Foundation
import Testing
@testable import callrec

@Test func configDefaultsAndRoundTrip() {
    let failures = SelfTest.config()
    #expect(failures.isEmpty, "\(failures)")
}
