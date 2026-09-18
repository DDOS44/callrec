import Contacts
import Foundation

/// Resolves a phone number to a name from the user's contacts. Silent on
/// failure: the daemon has no way to ask for permission, so it just tries.
public enum ContactsLookup {

    public static var authorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    public static func name(for number: String) -> String? {
        guard authorized, !number.isEmpty else { return nil }
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        guard let matches = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
              let contact = matches.first,
              let name = CNContactFormatter.string(from: contact, style: .fullName),
              !name.isEmpty else { return nil }
        return name
    }

    /// Asks for access; only the app should call this.
    public static func request(_ done: @escaping (Bool) -> Void) {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in done(granted) }
    }
}
