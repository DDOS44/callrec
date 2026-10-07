import AppKit
import CallrecCore

/// The real dialer: hands a `tel:` URL to macOS, which places the call through the
/// iPhone (Continuity). macOS may ask the user to confirm; the session waits for the call to start.
@MainActor
final class TelURLDialer: Dialer {
    func dial(number: String) throws {
        guard let url = TelURL.url(for: number) else { throw DialerError.invalidNumber(number) }
        guard NSWorkspace.shared.open(url) else { throw DialerError.refused }
    }
}
