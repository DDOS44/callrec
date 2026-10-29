import Foundation

/// Dial-to-pick-up ratio for one list, for the list summary.
/// Dials: every real dial placed from this list (alt numbers included; test numbers and dials that
/// macOS never placed left out). Picked up: leads whose wrap-up outcome is anything but
/// "no connect" (a person answered: gatekeeper, pitched, booked, not interested, ...).
public enum PickupRate {
    public struct Value: Equatable, Sendable {
        public var pickedUp: Int
        public var dials: Int
        public var percent: Int? { dials > 0 ? Int((Double(pickedUp) / Double(dials) * 100).rounded()) : nil }
        public var text: String { "\(pickedUp) of \(dials) dials" + (percent.map { " · \($0)%" } ?? "") }
    }

    public static func compute(log: [DialLogEntry], list: String, records: [String: LeadRecord],
                               testKeys: Set<String>) -> Value {
        let notPlaced = Set(log.filter { $0.kind == .result && $0.result == .notPlaced }.map(\.attemptID))
        let dials = log.filter {
            $0.kind == .attempt && $0.list == list && !notPlaced.contains($0.attemptID)
                && !testKeys.contains(PhoneNumber.normalize($0.key) ?? $0.key)
        }.count
        let picked = records.filter { id, rec in
            let o = rec.outcome.trimmingCharacters(in: .whitespaces).lowercased()
            let key = String(id.split(separator: "#").first ?? Substring(id))
            return !o.isEmpty && o != "no connect" && o != "test" && !testKeys.contains(key)
        }.count
        return Value(pickedUp: picked, dials: dials)
    }
}
