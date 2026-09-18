import Foundation
import Testing
@testable import callrec

// XCTest is unavailable here (Command Line Tools only, no Xcode), so the suite
// uses swift-testing and wraps the same checks `callrec selftest` runs.
@Test func pathScheme() {
    let failures = SelfTest.paths()
    #expect(failures.isEmpty, "\(failures)")
}
