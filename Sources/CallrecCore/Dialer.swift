import Foundation

/// Places a call. The only way the dialer ever dials, so tests use `FakeDialer`
/// and can never ring a real phone.
@MainActor
public protocol Dialer: AnyObject {
    /// Starts a call to `number` (10-digit Indian number). Throws if macOS refused to open it.
    /// Returning does not mean the call connected: the session waits for the call to start.
    func dial(number: String) throws
}

public enum DialerError: Error, LocalizedError {
    case invalidNumber(String)
    case refused

    public var errorDescription: String? {
        switch self {
        case .invalidNumber: return "Not a dialable 10-digit number."
        case .refused: return "macOS did not open the call. Is the iPhone nearby with Calls on Mac turned on?"
        }
    }
}

public enum TelURL {
    /// `tel:+91XXXXXXXXXX` for a 10-digit key, nil for anything else.
    public static func url(for number: String) -> URL? {
        guard let key = PhoneNumber.normalize(number) else { return nil }
        return URL(string: "tel:+91\(key)")
    }
}

/// Test double: records every number it was asked to dial and places nothing.
@MainActor
public final class FakeDialer: Dialer {
    public private(set) var dialed: [String] = []
    public var failWith: Error?
    public init() {}

    public func dial(number: String) throws {
        if let failWith { throw failWith }
        dialed.append(number)
    }
}
