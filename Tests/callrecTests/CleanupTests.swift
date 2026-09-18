import Foundation
import Testing
@testable import callrec

@Test func operatorAnnouncementStripping() {
    let failures = SelfTest.announcements()
    #expect(failures.isEmpty, "\(failures)")
}

@Test func llmCleanupParsing() {
    let failures = SelfTest.cleanupParsing()
    #expect(failures.isEmpty, "\(failures)")
}
