import Foundation
import Testing
@testable import callrec

@Test func callIdentityAndLeadMatching() {
    let failures = SelfTest.callIdentity()
    #expect(failures.isEmpty, "\(failures)")
}
