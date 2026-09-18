import Foundation
import Testing
@testable import callrec

@Test func wallClockGapFilling() {
    let failures = SelfTest.wallClockPadding()
    #expect(failures.isEmpty, "\(failures)")
}
