import Foundation
import Testing
@testable import callrec

@Test func transcriptMarkdown() {
    let failures = SelfTest.markdown()
    #expect(failures.isEmpty, "\(failures)")
}

@Test func srtParsing() {
    let failures = SelfTest.srtParsing()
    #expect(failures.isEmpty, "\(failures)")
}
