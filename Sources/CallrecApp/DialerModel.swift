import AppKit
import CallrecCore
import Combine
import Foundation

/// Owns the imported list and the dial runner for the Dialer section. The app is the
/// only writer of the dial log, the lead state and the do-not-call list.
@MainActor
final class DialerModel: ObservableObject {
    @Published private(set) var runner: DialRunner?
    @Published private(set) var imported: LeadImport?
    @Published private(set) var listName = ""
    @Published private(set) var listPath: URL?
    @Published var error: String?
    /// Result of the last Contacts save/remove, shown under the list.
    @Published var contactsNote: String?
    @Published var contactsBusy = false

    private let dialer = TelURLDialer()

    init() {
        let path = Config.load().dialerListPath
        if !path.isEmpty { open(csv: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), copy: false) }
    }

    var sessionRunning: Bool { runner?.session.isRunning ?? false }

    /// Imports a CSV chosen by the user: a copy goes into ~/.callrec/lists (the original is never touched).
    func importList(from url: URL) {
        open(csv: url, copy: true)
        // Every imported list goes to Contacts too, so a lead calling back shows by agency name.
        if error == nil { saveLeadsToContacts() }
    }

    func saveLeadsToContacts() {
        guard let leads = imported?.leads, !contactsBusy else { return }
        contactsBusy = true; contactsNote = "Saving \(leads.count) leads to Contacts…"
        Task {
            do { contactsNote = try await ContactsSync.save(leads).text } catch { contactsNote = error.localizedDescription }
            contactsBusy = false
        }
    }

    func removeLeadContacts() {
        guard !contactsBusy else { return }
        contactsBusy = true
        Task {
            do { contactsNote = "Removed \(try await ContactsSync.removeAll()) callrec lead contacts." } catch { contactsNote = error.localizedDescription }
            contactsBusy = false
        }
    }

    private func open(csv source: URL, copy: Bool) {
        guard !sessionRunning else { error = "Stop the session before changing the list."; return }
        do {
            let config = Config.load()
            // Parse the chosen file FIRST: a file that fails to import must leave no copy behind,
            // and the previous list stays loaded because nothing below runs on a throw.
            let result = try LeadImporter.load(source, caller: config.dialerCaller, repeatable: config.dialRules.testKeys)
            var csv = source
            if copy, source.deletingLastPathComponent().standardizedFileURL != DialerPaths.listsDir.standardizedFileURL,
               let same = ListCopies.existingCopy(of: source, in: DialerPaths.listsDir) {
                csv = same   // already imported: keep its progress instead of starting a fresh copy
            } else if copy, source.deletingLastPathComponent().standardizedFileURL != DialerPaths.listsDir.standardizedFileURL {
                try Paths.ensureDir(DialerPaths.listsDir)
                csv = Self.uniqueDestination(for: source)
                try FileManager.default.copyItem(at: source, to: csv)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: csv.path)
            }
            let name = csv.deletingPathExtension().lastPathComponent
            // The rejected rows are written next to the list so they can be fixed and never get lost.
            let report = DialerPaths.listsDir.appendingPathComponent("\(name).rejected.txt")
            if !result.rejected.isEmpty, csv.deletingLastPathComponent().standardizedFileURL == DialerPaths.listsDir.standardizedFileURL {
                try Data(result.rejectedReport.utf8).write(to: report, options: .atomic)
            }
            let store = try LeadStateStore(url: DialerPaths.stateURL(forList: csv), listName: name)
            imported = result
            listName = name
            listPath = csv
            error = nil
            runner = DialRunner(Self.services(dialer: dialer, config: config, name: name, leads: result, store: store))
            rememberList(csv)
        } catch {
            self.error = error.localizedDescription
            logError("dialer: could not open list \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The list that opens next time the app starts: whatever was loaded last.
    private func rememberList(_ csv: URL) {
        var c = Config.load()
        guard c.dialerListPath != csv.path else { return }
        c.dialerListPath = csv.path
        do { try c.save() } catch {
            self.error = "The list is loaded, but could not be remembered for next launch: \(error.localizedDescription)"
            logError("dialer: could not save dialerListPath: \(error.localizedDescription)")
        }
    }

    private static func uniqueDestination(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = DialerPaths.listsDir.appendingPathComponent("\(base).csv")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = DialerPaths.listsDir.appendingPathComponent("\(base)-\(n).csv")
            n += 1
        }
        return candidate
    }

    private static func askRecorder(days: Int) async throws -> HistorySnapshot {
        let since = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let response = try await HistoryMailbox.ask(HistoryMailbox.Request(sinceEpoch: since))
        let rows = response.rows.map {
            HistoryCall(key: $0.numberKey, date: Date(timeIntervalSince1970: $0.epoch), seconds: $0.seconds, originated: $0.originated)
        }
        return HistorySnapshot(rows: rows, detection: .unavailable(reason: "call history is read by the recorder, which does not report the line"))
    }

    private static func services(dialer: Dialer, config: Config, name: String, leads: LeadImport,
                                 store: LeadStateStore) -> DialRunner.Services {
        let stateURL = DialerPaths.home.appendingPathComponent("state.json")
        let root = config.recordingsURL
        var services = DialRunner.Services(
            dialer: dialer, config: config, listName: name, leads: leads, store: store,
            callState: {
                guard let s = StatusProbe.watcherState(at: stateURL) else { return .init(recording: false) }
                return .init(recording: s.state == "recording", since: ISO8601DateFormatter().date(from: s.since))
            },
            // Only the recorder (which holds Full Disk Access) reads call history; ask it.
            // A year, not just the cooldown window: iPhone reuses the line last used with a
            // number, so an old call from the main SIM matters for the "called before" warning.
            loadHistory: { try await Self.askRecorder(days: max(config.cooldownDays, 365)) },
            applyToMarkdown: { start, lead, outcome, notes in
                try DialMarkdown.apply(root: root, callStart: start, lead: lead, outcome: outcome, notes: notes)
            },
            saveColdSIM: { value in
                var c = Config.load()
                c.coldSIM = value
                try c.save()
            })
        services.openURL = { NSWorkspace.shared.open($0) }
        if config.calcomEventTypeId > 0 {
            // The key is read when booking, not now: opening the app never triggers a Keychain prompt.
            services.calcom = CalCom(key: { try CalCom.loadKey() }, eventTypeId: config.calcomEventTypeId,
                                     timeZone: TimeZone(identifier: config.calcomTimeZone) ?? .current)
        }
        return services
    }
}
