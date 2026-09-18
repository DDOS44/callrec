import Foundation
import Testing
@testable import callrec

@Test func watcherTransitions() {
    let failures = SelfTest.watcherStateMachine()
    #expect(failures.isEmpty, "\(failures)")
}
