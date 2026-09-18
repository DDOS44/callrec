import Foundation
import Testing
@testable import callrec

@Test func devanagariToHinglish() {
    let failures = SelfTest.transliteration()
    #expect(failures.isEmpty, "\(failures)")
}
