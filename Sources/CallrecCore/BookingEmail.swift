import Foundation

/// "Send booking link": after asking for their email on the call, open a ready email with the
/// meeting link. The app never sends mail itself: it opens a compose window (Gmail in the browser,
/// or the Mail app) so the user sees the address they typed from a phone call before it goes out.
public enum BookingEmail {

    /// A plain sanity check for an address typed during a call: one @, something before it, a dot in
    /// the domain, no spaces. Not full RFC 5322; the compose window is the final check.
    public static func isValid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !s.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.distance(from: dot, to: domain.endIndex) > 2
    }

    /// First name for the greeting, from an owner cell like "Rahul Sharma (Founder)"; empty when unclear.
    public static func firstName(from owner: String) -> String {
        let word = owner.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
        return word.count >= 2 && word.allSatisfy(\.isLetter) ? word : ""
    }

    /// Fills {name}, {company}, {link}, {sender}. "Hi {name}," with no name reads "Hi,".
    public static func fill(_ template: String, name: String, company: String, link: String, sender: String) -> String {
        template
            .replacingOccurrences(of: " {name}", with: name.isEmpty ? "" : " \(name)")
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{company}", with: company)
            .replacingOccurrences(of: "{link}", with: link)
            .replacingOccurrences(of: "{sender}", with: sender)
    }

    public enum Via: String, Sendable { case gmail, mail }

    /// Gmail's compose page (`account` picks the signed-in Google account) or a mailto: for Mail.
    public static func composeURL(to: String, subject: String, body: String, via: Via, account: String = "") -> URL? {
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        switch via {
        case .gmail:
            var q = [("view", "cm"), ("fs", "1"), ("to", to), ("su", subject), ("body", body)]
            if !account.isEmpty { q.append(("authuser", account)) }
            return URL(string: "https://mail.google.com/mail/?" + q.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&"))
        case .mail:
            return URL(string: "mailto:\(encode(to))?subject=\(encode(subject))&body=\(encode(body))")
        }
    }

    /// Strict query encoding: "+" and "&" in an address or the body must survive as themselves.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
