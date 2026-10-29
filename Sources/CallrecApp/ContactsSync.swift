import CallrecCore
import Contacts
import Foundation

/// Saves a list's leads to the Contacts app in the "callrec leads" group (see ContactsPlan for the
/// safety rule), and removes that group's cards on request. Contacts sync to the iPhone via iCloud,
/// so a lead calling back shows by agency name.
enum ContactsSync {
    struct Report: Equatable {
        var created = 0, grouped = 0, alreadyDone = 0, personal = 0
        var text: String {
            var bits = ["\(created) saved", "\(grouped) existing cards grouped"]
            if alreadyDone > 0 { bits.append("\(alreadyDone) already there") }
            if personal > 0 { bits.append("\(personal) skipped (number belongs to one of your own contacts)") }
            return "Contacts: " + bits.joined(separator: ", ") + "."
        }
    }

    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? {
            "callrec is not allowed to use Contacts. Allow it in System Settings → Privacy & Security → Contacts."
        }
    }

    private static let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactOrganizationNameKey,
                                                 CNContactPhoneNumbersKey].map { $0 as CNKeyDescriptor }

    static func save(_ leads: [Lead]) async throws -> Report {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw Failure.denied }
        let group = try findOrCreateGroup(store)
        let inGroup = Set(try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
                                                    keysToFetch: keys).map(\.identifier))
        var existing: [String: [ContactsPlan.Existing]] = [:]
        var byID: [String: CNContact] = [:]
        for lead in leads {
            for n in AltNumbers.allNumbers(of: lead) where existing[n] == nil {
                let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+91" + n)),
                                                      keysToFetch: keys)
                for c in found { byID[c.identifier] = c }
                existing[n] = found.map { .init(id: $0.identifier, organization: $0.organizationName, inGroup: inGroup.contains($0.identifier)) }
            }
        }
        let plan = ContactsPlan.plan(leads: leads, existing: existing)
        let request = CNSaveRequest()
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
        }
        for id in plan.addToGroup { if let c = byID[id] { request.addMember(c, to: group) } }
        if !plan.create.isEmpty || !plan.addToGroup.isEmpty { try store.execute(request) }
        log("contacts: saved \(plan.create.count), grouped \(plan.addToGroup.count), skipped \(plan.personal.count) personal")
        return Report(created: plan.create.count, grouped: plan.addToGroup.count,
                      alreadyDone: plan.alreadyDone, personal: plan.personal.count)
    }

    /// Deletes every card in the "callrec leads" group (only lead cards are ever put there), and the group.
    static func removeAll() async throws -> Int {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw Failure.denied }
        guard let group = try store.groups(matching: nil).first(where: { $0.name == ContactsPlan.groupName }) else { return 0 }
        let members = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
                                                keysToFetch: keys)
        let request = CNSaveRequest()
        for c in members { if let m = c.mutableCopy() as? CNMutableContact { request.delete(m) } }
        if let g = group.mutableCopy() as? CNMutableGroup { request.delete(g) }
        try store.execute(request)
        log("contacts: removed \(members.count) callrec lead card(s)")
        return members.count
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
