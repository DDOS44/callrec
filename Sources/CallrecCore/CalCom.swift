import Foundation
import Security

/// Booking a meeting on the call itself through the Cal.com API (v2): pick one of the event type's
/// free slots, enter their name and email, Book. Cal.com creates the event, adds the meeting link
/// (Google Meet, Cal Video... whatever the event type uses) and emails the invite to them.
///
/// The API key lives in the macOS Keychain (service `callrec-calcom`), never in config or code.
public struct CalCom: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let apiKey: String
    public let eventTypeId: Int
    public let timeZone: TimeZone
    let transport: Transport
    let base = URL(string: "https://api.cal.com/v2")!

    public init(apiKey: String, eventTypeId: Int, timeZone: TimeZone,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey; self.eventTypeId = eventTypeId; self.timeZone = timeZone; self.transport = transport
    }

    public struct Booking: Equatable, Sendable {
        public var uid: String
        public var start: Date
        /// The join link Cal.com created, when the response carries one.
        public var meetingURL: String?
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    // MARK: Slots

    /// Free start times on the calendar day of `day` (in the booking time zone), earliest first.
    public func slots(on day: Date) async throws -> [Date] {
        let req = try slotsRequest(on: day)
        let (data, response) = try await transport(req)
        try Self.check(data, response)
        return try Self.parseSlots(data)
    }

    func slotsRequest(on day: Date) throws -> URLRequest {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { throw Failure(message: "Bad date.") }
        let f = DateFormatter(); f.calendar = cal; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        var c = URLComponents(url: base.appendingPathComponent("slots"), resolvingAgainstBaseURL: false)
        // The end date is exclusive in practice; ask for [day, day+1) and keep only `day`.
        c?.queryItems = [.init(name: "eventTypeId", value: String(eventTypeId)),
                         .init(name: "start", value: f.string(from: start)),
                         .init(name: "end", value: f.string(from: end)),
                         .init(name: "timeZone", value: timeZone.identifier)]
        guard let url = c?.url else { throw Failure(message: "Bad slots URL.") }
        var r = URLRequest(url: url)
        header(&r, version: "2024-09-04")
        return r
    }

    static func parseSlots(_ data: Data) throws -> [Date] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["data"] as? [String: Any] else { throw Failure(message: "Cal.com sent slots in a shape callrec does not know.") }
        let starts = days.values.compactMap { $0 as? [[String: Any]] }.joined().compactMap { $0["start"] as? String }
        return starts.compactMap(parseDate).sorted()
    }

    // MARK: Booking

    public func book(start: Date, name: String, email: String) async throws -> Booking {
        let req = try bookingRequest(start: start, name: name, email: email)
        let (data, response) = try await transport(req)
        try Self.check(data, response)
        return try Self.parseBooking(data)
    }

    func bookingRequest(start: Date, name: String, email: String) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("bookings"))
        r.httpMethod = "POST"
        header(&r, version: "2024-08-13")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let iso = ISO8601DateFormatter(); iso.timeZone = TimeZone(identifier: "UTC")
        let body: [String: Any] = [
            "start": iso.string(from: start),
            "eventTypeId": eventTypeId,
            "attendee": ["name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                         "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                         "timeZone": timeZone.identifier, "language": "en"],
            "metadata": ["source": "callrec"]
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func parseBooking(_ data: Data) throws -> Booking {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any], let uid = d["uid"] as? String,
              let startText = d["start"] as? String, let start = parseDate(startText) else {
            throw Failure(message: "Cal.com answered, but not with a booking callrec can read. Check your Cal.com bookings.")
        }
        let link = (d["meetingUrl"] as? String) ?? (d["location"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
        return Booking(uid: uid, start: start, meetingURL: link)
    }

    // MARK: Shared

    private func header(_ r: inout URLRequest, version: String) {
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue(version, forHTTPHeaderField: "cal-api-version")
        r.setValue("callrec", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
    }

    /// Non-2xx: Cal.com's own message if it sent one (e.g. "slot no longer available").
    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No answer from Cal.com.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        var message = "Cal.com said \(http.statusCode)."
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {   // swiftlint:disable:this no_try_optional
            let err = root["error"] as? [String: Any]
            if let m = (err?["message"] as? String) ?? (root["message"] as? String) { message = "Cal.com: \(m)" }
        }
        if http.statusCode == 401 || http.statusCode == 403 { message += " Check the API key in Keychain (callrec-calcom)." }
        throw Failure(message: message)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Keychain

    public static let keychainService = "callrec-calcom"

    /// The API key from the Keychain, or nil when none is stored.
    public static func apiKeyFromKeychain() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { log("calcom: Keychain read failed (OSStatus \(status))") }
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
