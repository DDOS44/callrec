import Foundation
import Testing
@testable import callrec

@Test func speakerAttributionAndBleedGuard() {
    let failures = SelfTest.speakerMerge()
    #expect(failures.isEmpty, "\(failures)")
}
