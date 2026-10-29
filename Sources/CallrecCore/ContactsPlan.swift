import Foundation

/// Saving a list's leads to the Contacts app, in a "callrec leads" group, so a lead calling back shows
/// by agency name. Pure planning; the app does the Contacts calls.
///
/// Safety: only a lead card is ever put in the group (that group is what "Remove callrec contacts"
/// deletes). A card counts as a lead card when it is already in the group or its organisation name is
/// the lead's company. Any other contact sharing a lead's number is a personal contact: left alone.
public enum ContactsPlan {
    public static let groupName = "callrec leads"

    public struct Existing: Equatable, Sendable {
        public var id: String
        public var organization: String
        public var inGroup: Bool
        public init(id: String, organization: String, inGroup: Bool) {
            self.id = id; self.organization = organization; self.inGroup = inGroup
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Leads with no contact on any of their numbers: create a card in the group.
        public var create: [Lead] = []
        /// Existing lead cards to add to the group (not in it yet).
        public var addToGroup: [String] = []
        /// Leads whose number belongs to someone else's contact: untouched.
        public var personal: [Lead] = []
        public var alreadyDone = 0
    }

    /// `existing`: contacts found for each number key (main and alts).
    public static func plan(leads: [Lead], existing: [String: [Existing]]) -> Plan {
        var p = Plan()
        var queued = Set<String>()
        for lead in leads {
            let found = AltNumbers.allNumbers(of: lead).flatMap { existing[$0] ?? [] }
            if found.isEmpty { p.create.append(lead); continue }
            let mine = found.filter { $0.inGroup || same($0.organization, lead.company) }
            if mine.isEmpty { p.personal.append(lead); continue }
            let toAdd = mine.filter { !$0.inGroup && !queued.contains($0.id) }
            if toAdd.isEmpty { p.alreadyDone += 1 }
            for c in toAdd { p.addToGroup.append(c.id); queued.insert(c.id) }
        }
        return p
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let n = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return !n(a).isEmpty && n(a) == n(b)
    }
}
