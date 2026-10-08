import Foundation

/// The alt-number fallback, as pure functions. A lead's dial sequence is its main number
/// followed by its alt numbers; when a placed call does not connect, the session moves to
/// the next number of the SAME lead instead of the next lead. The state machine
/// (`DialSession`) owns where in the sequence a lead is; this file owns what the sequence is.
public enum AltNumbers {

    /// Main number first, then the alts in order, each number once. Alts on the do-not-call
    /// list are left out; the main number stays so the policy can refuse the lead itself.
    /// With `enabled` false (config `tryAltNumbers`) only the main number is dialled.
    public static func sequence(main: String, alts: [String], dnc: DNCList = DNCList(), enabled: Bool = true) -> [String] {
        var out = [main]
        guard enabled else { return out }
        for alt in alts where !out.contains(alt) && !dnc.contains(alt) { out.append(alt) }
        return out
    }

    public static func sequence(for lead: Lead, dnc: DNCList = DNCList(), enabled: Bool = true) -> [String] {
        sequence(main: lead.number, alts: lead.altNumbers, dnc: dnc, enabled: enabled)
    }

    /// Every number that belongs to the lead, whatever the config and whatever is already listed:
    /// "Do not call again" on a lead covers all of them.
    public static func allNumbers(of lead: Lead) -> [String] {
        sequence(main: lead.number, alts: lead.altNumbers)
    }

    /// The index of the next number to try after `index`, or nil when `index` was the last one.
    public static func advance(from index: Int, count: Int) -> Int? {
        index + 1 < count ? index + 1 : nil
    }

    /// "Main" or "Alt 1 of 2".
    public static func label(index: Int, count: Int) -> String {
        index <= 0 ? "Main" : "Alt \(index) of \(max(count - 1, 1))"
    }

    /// Queue-row badge: "1 alt", "2 alts"; nil when the lead has none.
    public static func queueBadge(altCount: Int) -> String? {
        altCount <= 0 ? nil : (altCount == 1 ? "1 alt" : "\(altCount) alts")
    }

    /// Countdown text before an alt dial, e.g. "No answer on +91 90000 00101. Trying alt 1 of 2 (+91 90000 00201)".
    /// `afterNoAnswer` is false when the session is simply resuming on that number.
    public static func notice(sequence: [String], nextIndex: Int, afterNoAnswer: Bool) -> String? {
        guard nextIndex > 0, sequence.indices.contains(nextIndex) else { return nil }
        let trying = "\(label(index: nextIndex, count: sequence.count).replacingOccurrences(of: "Alt", with: "alt")) (\(PhoneNumber.display(sequence[nextIndex])))"
        guard afterNoAnswer else { return "Next: \(trying)" }
        return "No answer on \(PhoneNumber.display(sequence[nextIndex - 1])). Trying \(trying)"
    }
}
