import Foundation
import Testing

/// Named check: the name lands in the failure message and the failure points at
/// the calling line, not at this helper.
func expect(_ ok: Bool, _ check: String, _ detail: @autoclosure () -> String = "",
            sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(ok, "\(check): \(detail())", sourceLocation: sourceLocation)
}

func equal<T: Equatable>(_ a: T, _ b: T, _ check: String,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, "\(check): got \(a), expected \(b)", sourceLocation: sourceLocation)
}
