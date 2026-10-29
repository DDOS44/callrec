import CallrecCore
import Contacts
import Foundation

/// Saves a list's leads to the Contacts app in the "callrec leads" group, and removes them on request.
/// Contacts sync to the iPhone via iCloud, so a lead calling back shows by agency name.
///
/// Safety (code review 2026-10-29): callrec keeps a ledger of the cards IT created
/// (~/.callrec/contacts-created.json) and "Remove" deletes only those, never anything else in the
/// group or any card it did not make. A lead already on any contact is left alone (ContactsPlan).
enum ContactsSync {
    struct Report: Equatable {
        var created = 0, alreadySaved = 0
        var text: String {
            "Contacts: \(created) saved to 'callrec leads'" + (alreadySaved > 0 ? ", \(alreadySaved) already in your contacts (left as they are)." : ".")
        }
    }

    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? {
            "callrec is not allowed to use Contacts. Allow it in System Settings → Privacy & Security → Contacts."
        }
    }

    static var ledgerURL: URL { DialerPaths.home.appendingPathComponent("contacts-created.json") }

    private static let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactOrganizationNameKey,
                                                 CNContactPhoneNumbersKey].map { $0 as CNKeyDescriptor }

    static func save(_ leads: [Lead], skip: Set<String>) async throws -> Report {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw Failure.denied }
        var existing: [String: [ContactsPlan.Existing]] = [:]
        for lead in leads {
            for n in AltNumbers.allNumbers(of: lead) where existing[n] == nil {
                let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+91" + n)),
                                                      keysToFetch: keys)
                existing[n] = found.map { .init(id: $0.identifier, organization: $0.organizationName) }
            }
        }
        let plan = ContactsPlan.plan(leads: leads, existing: existing, skip: skip)
        guard !plan.create.isEmpty else { return Report(created: 0, alreadySaved: plan.alreadySaved.count) }
        let group = try findOrCreateGroup(store)
        let request = CNSaveRequest()
        var made: [String] = []
        for lead in plan.create {
            let c = CNMutableContact()
            c.contactType = .organization
            c.organizationName = lead.company.isEmpty ? PhoneNumber.display(lead.number) : lead.company
            c.phoneNumbers = AltNumbers.allNumbers(of: lead).enumerated().map { i, n in
                CNLabeledValue(label: i == 0 ? CNLabelWork : CNLabelOther, value: CNPhoneNumber(stringValue: "+91" + n))
            }
            if !lead.email.isEmpty { c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: lead.email as NSString)] }
            request.add(c, toContainerWithIdentifier: nil)
            request.addMember(c, to: group)
            made.append(c.identifier)
        }
        try store.execute(request)
        try recordCreated(made)
        log("contacts: saved \(made.count), left \(plan.alreadySaved.count) existing contact(s) alone")
        return Report(created: made.count, alreadySaved: plan.alreadySaved.count)
    }

    /// Deletes only the cards callrec created (the ledger), then the group if it is left empty.
    static func removeAll() async throws -> Int {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw Failure.denied }
        let ids = try readLedger()
        guard !ids.isEmpty else { return 0 }
        let ours = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: keys)
        let request = CNSaveRequest()
        for c in ours { if let m = c.mutableCopy() as? CNMutableContact { request.delete(m) } }
        if let group = try store.groups(matching: nil).first(where: { $0.name == ContactsPlan.groupName }) {
            let left = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier), keysToFetch: keys)
                .filter { !ids.contains($0.identifier) }
            if left.isEmpty, let g = group.mutableCopy() as? CNMutableGroup { request.delete(g) }
        }
        try store.execute(request)
        try writeLedger([])
        log("contacts: removed \(ours.count) card(s) callrec created")
        return ours.count
    }

    // MARK: Ledger

    private static func readLedger() throws -> [String] {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: ledgerURL))
    }

    private static func recordCreated(_ ids: [String]) throws {
        var all = try readLedger()
        for id in ids where !all.contains(id) { all.append(id) }
        try writeLedger(all)
    }

    private static func writeLedger(_ ids: [String]) throws {
        try Paths.ensureDir(ledgerURL.deletingLastPathComponent())
        try JSONEncoder().encode(ids).write(to: ledgerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }

    private static func findOrCreateGroup(_ store: CNContactStore) throws -> CNGroup {
        if let g = try store.groups(matching: nil).first(where: { $0.name == ContactsPlan.groupName }) { return g }
        let g = CNMutableGroup()
        g.name = ContactsPlan.groupName
        let r = CNSaveRequest()
        r.add(g, toContainerWithIdentifier: nil)
        try store.execute(r)
        return try store.groups(matching: nil).first(where: { $0.name == ContactsPlan.groupName }) ?? g
    }
}
