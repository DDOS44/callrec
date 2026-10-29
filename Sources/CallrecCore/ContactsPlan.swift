import Foundation

/// Saving a list's leads to the Contacts app, in a "callrec leads" group, so a lead calling back shows
/// by agency name. Pure planning; the app does the Contacts calls.
///
/// Safety (code review 2026-10-29): callrec only ever groups, and later deletes, cards IT created; it
/// records their ids in a ledger. A lead whose number is already on any contact is left alone, even
/// when the names match: that card could be one the user made, and "Remove callrec contacts" must
/// never be able to delete it. Test numbers are never saved, and a number is saved once.
public enum ContactsPlan {
    public static let groupName = "callrec leads"

    public struct Existing: Equatable, Sendable {
        public var id: String
        public var organization: String
        public init(id: String, organization: String) { self.id = id; self.organization = organization }
    }

    /// A contact card as seen for the .vcf check.
    public struct Card: Equatable, Sendable {
        public var id: String
        public var organization: String
        public var givenName: String
        public var familyName: String
        /// 10-digit keys of its phone numbers.
        public var numbers: [String]
        public init(id: String, organization: String, givenName: String, familyName: String, numbers: [String]) {
            self.id = id; self.organization = organization; self.givenName = givenName
            self.familyName = familyName; self.numbers = numbers
        }
    }

    /// True only for a card made from callrec's own lead .vcf (2026-10-29 export): name and organisation
    /// both exactly the lead's company, no surname, and exactly the lead's numbers. Such a card can be
    /// adopted into the ledger so "Remove callrec contacts" covers it; any other card never is.
    public static func isFromCallrecVcf(_ card: Card, lead: Lead) -> Bool {
        let company = lead.company.trimmingCharacters(in: .whitespaces)
        return !company.isEmpty
            && card.organization.trimmingCharacters(in: .whitespaces) == company
            && card.givenName.trimmingCharacters(in: .whitespaces) == company
            && card.familyName.trimmingCharacters(in: .whitespaces).isEmpty
            && Set(card.numbers) == Set(AltNumbers.allNumbers(of: lead))
    }

    public struct Plan: Equatable, Sendable {
        /// Leads with no contact on any of their numbers: callrec creates a card in the group.
        public var create: [Lead] = []
        /// Leads already on a contact (made by the user, or imported earlier): untouched.
        public var alreadySaved: [Lead] = []
    }

    /// `existing`: contacts found for each number key (main and alts). `skip`: the user's test numbers.
    public static func plan(leads: [Lead], existing: [String: [Existing]], skip: Set<String> = []) -> Plan {
        var p = Plan()
        var planned = Set<String>()
        for lead in leads {
            let numbers = AltNumbers.allNumbers(of: lead)
            if numbers.contains(where: skip.contains) || numbers.contains(where: planned.contains) { continue }
            if numbers.contains(where: { !(existing[$0] ?? []).isEmpty }) { p.alreadySaved.append(lead); continue }
            p.create.append(lead)
            planned.formUnion(numbers)
        }
        return p
    }
}
