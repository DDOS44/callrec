import Foundation
import Testing
@testable import callrec

@Test func silenceSplitting() {
    let failures = SelfTest.silenceSplitter()
    #expect(failures.isEmpty, "\(failures)")
}
