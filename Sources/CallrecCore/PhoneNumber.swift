import Foundation

/// Phone numbers are written a dozen ways. Everything the dialer compares (do-not-call
/// list, cooldown, dial log, call history) uses the same 10-digit key.
public enum PhoneNumber {

    /// Strict: the 10-digit Indian number inside `raw`, or nil. Accepts `9000000001`,
    /// `+91 90000 00001`, `091-90000-00001`, `0 9000000001`, `00919000000001`. Anything
    /// else (extensions, two numbers in one cell, a foreign number, too few digits) is
    /// nil, so a CSV import lists it as rejected instead of guessing. The first digit
    /// must be 1-9 (a leading 0 is a trunk prefix, not part of the number).
    public static func normalize(_ raw: String) -> String? {
        var d = digits(raw)
        switch d.count {
        case 10: break
        case 11 where d.hasPrefix("0"): d.removeFirst(1)
        case 12 where d.hasPrefix("91"): d.removeFirst(2)
        case 13 where d.hasPrefix("091"): d.removeFirst(3)
        case 14 where d.hasPrefix("0091"): d.removeFirst(4)
        default: return nil
        }
        guard d.count == 10, let first = d.first, first != "0" else { return nil }
        return d
    }

    /// Lenient: the last ten digits, for matching numbers from call history (which may
    /// carry any country code) against our keys. nil when there are fewer than 10 digits.
    /// Lenient on purpose: for a block list, matching too much is the safe direction.
    public static func key(_ raw: String) -> String? {
        let d = digits(raw)
        return d.count >= 10 ? String(d.suffix(10)) : nil
    }

    /// How a number reads on screen: "+91 82199 71169" for any Indian number `normalize`
    /// accepts. Anything else is shown as it came, trimmed, never guessed at.
    public static func display(_ raw: String) -> String {
        guard let n = normalize(raw) else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "+91 \(n.prefix(5)) \(n.suffix(5))"
    }

    private static func digits(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }))
    }
}
