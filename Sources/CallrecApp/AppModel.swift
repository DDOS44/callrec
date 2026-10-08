import AVFoundation
import AppKit
import CallrecCore
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var days: [Day] = []
    @Published var selectedDay: String?
    @Published var selectedCall: String?
    /// Everything highlighted in the call list (Cmd/Shift-click). `selectedCall` is the one the detail column shows.
    @Published var selectedCalls: Set<String> = []
    /// Calls waiting for the "Move to Trash" confirmation.
    @Published var pendingTrash: [String] = []
    @Published var trashProblem: String?
    @Published var search = ""
    /// Show lines the pipeline flagged (bleed, operator, loop). Display only: never changes the file.
    @Published var showFiltered = false
    @Published var agentRunning = false
    @Published var recordingSince: Date?
    @Published var lastCallAt: Date?
    /// "<day>/<time>" the daemon is transcribing right now (from state.json).
    @Published var transcribingID: String?
    /// The daemon is loading the speech model (one-time after an update).
    @Published var modelPreparing = false
    @Published var modelError: String?
    @Published var permissionProblems: [String] = []
    @Published var savedFlash = false
    @Published var statsRange: StatsRange = .today

    @Published var callHistoryReadable = true
    private var checkedCallHistory = false
    private var folderWatcher: FolderWatcher?
    private var timer: Timer?

    /// launchd is a process spawn, so it is asked at most every 30 s. The state
    /// file is a tiny read and is checked on every 2 s tick. Both run off the main actor.
    private var launchdThrottle = Throttle(interval: 30)
    private var statusInFlight = false
    private var reloadGeneration = 0

    init() {
        ContactsLookup.request { _ in }
        reload()
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        refreshStatus()
    }

    // MARK: - Library

    /// Loads the library off the main actor (it parses markdown, which is slow
    /// with hundreds of calls) and applies the result here. If a newer reload
    /// starts first, the older result is dropped.
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Library.load()
            await self?.apply(loaded, generation: generation)
        }
    }

    /// We just changed launchd ourselves: do not wait out the throttle.
    private func agentChanged() {
        launchdThrottle.reset()
        refreshStatus()
    }

    private func apply(_ loaded: [Day], generation: Int) {
        guard generation == reloadGeneration else { return }
        let previous = selectedCall
        days = loaded
        lastCallAt = loaded.first?.calls.first?.date
        if selectedDay == nil || !(days.contains(where: { $0.name == selectedDay }) || selectedDay == AppModel.dialerTag) {
            selectedDay = days.first?.name
        }
        if previous == nil || !allCalls.contains(where: { $0.id == previous }) {
            select(visibleCalls.first?.id)
        } else {
            selectedCalls = selectedCalls.filter { id in allCalls.contains { $0.id == id } }
        }
    }

    /// Selects exactly one call (or none).
    func select(_ id: String?) {
        selectedCall = id
        selectedCalls = id.map { [$0] } ?? []
    }

    /// The list's selection changed. The detail column keeps its call while it is still
    /// selected; otherwise it shows the first selected call in list order.
    func setSelection(_ ids: Set<String>) {
        selectedCalls = ids
        if let current = selectedCall, ids.contains(current) { return }
        selectedCall = visibleCalls.first(where: { ids.contains($0.id) })?.id ?? ids.first
    }

    // MARK: - Delete (to the Trash)

    /// Asks for confirmation. `ids` is what was right-clicked; otherwise the current selection.
    func requestTrash(_ ids: Set<String>? = nil) {
        let wanted = ids ?? selectedCalls
        let calls = allCalls.filter { wanted.contains($0.id) }
        guard !calls.isEmpty else { return }
        if let busy = calls.first(where: { $0.id == transcribingID || ($0.rawOnly && recordingSince != nil) }) {
            // The recorder would write the transcript back after the delete.
            trashProblem = "\(busy.title) is still being recorded or transcribed. Try again when it has finished."
            return
        }
        pendingTrash = calls.map(\.id)
    }

    var trashPrompt: String { pendingTrash.count == 1 ? "Move 1 call to the Trash?" : "Move \(pendingTrash.count) calls to the Trash?" }
    var trashDetail: String {
        pendingTrash.count == 1
            ? "Its audio and transcript go to the Trash and can be restored from Finder until you empty it."
            : "Their audio and transcripts go to the Trash and can be restored from Finder until you empty it."
    }

    func confirmTrash() {
        let targets = allCalls.filter { pendingTrash.contains($0.id) }.map { (day: $0.day, base: $0.time.replacingOccurrences(of: ":", with: "-")) }
        pendingTrash = []
        guard !targets.isEmpty else { return }
        let root = Library.root
        Task.detached(priority: .userInitiated) { [weak self] in
            var problems: [String] = []
            for t in targets {
                let r = CallTrash.trash(base: t.base, in: root.appendingPathComponent(t.day))
                if !r.isComplete { problems.append("\(t.day)/\(t.base): \(r.report)") }
            }
            let report = problems.joined(separator: "\n")
            await self?.trashed(problem: report.isEmpty ? nil : report)
        }
    }

    private func trashed(problem: String?) {
        trashProblem = problem
        reload()
    }

    private func startWatching() {
        attempt("could not create \(Library.root.path)") {
            try Permissions.protectRecordings(Library.root)
        }
        folderWatcher = FolderWatcher(url: Library.root) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    static let allDaysTag = "__all__"
    static let dialerTag = "__dialer__"

    var allCalls: [Call] { days.flatMap(\.calls) }

    /// The calls shown in the middle column: one day, or everything.
    var visibleCalls: [Call] {
        selectedDay == AppModel.allDaysTag ? filteredDays.flatMap(\.calls) : callsForSelectedDay
    }

    var columnTitle: String {
        if selectedDay == AppModel.allDaysTag { return "All calls" }
        return filteredDays.first(where: { $0.name == selectedDay })?.pretty ?? "Calls"
    }

    var filteredDays: [Day] {
        guard !search.isEmpty else { return days }
        let q = search.lowercased()
        return days.compactMap { day in
            let hits = day.calls.filter { $0.searchText.contains(q) }
            return hits.isEmpty ? nil : Day(name: day.name, calls: hits)
        }
    }

    var callsForSelectedDay: [Call] {
        filteredDays.first(where: { $0.name == selectedDay })?.calls ?? []
    }

    var current: Call? { allCalls.first(where: { $0.id == selectedCall }) }

    func update(_ call: Call) {
        guard let dayIndex = days.firstIndex(where: { $0.name == call.day }),
              let callIndex = days[dayIndex].calls.firstIndex(where: { $0.id == call.id }) else { return }
        days[dayIndex].calls[callIndex] = call
    }

    func save(_ call: Call) {
        update(call)
        do { try Library.save(call) } catch {
            // The beep is for the person; the log line is for whoever debugs it later.
            log("could not save \(call.id): \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    // MARK: - Stats

    struct Stats {
        var dials = 0, connects = 0, booked = 0, talk: Double = 0
    }

    var visibleStats: Stats { statsRange == .today ? todayStats : stats(days: 7) }

    func stats(days back: Int) -> Stats {
        let cutoff = Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date()
        var s = Stats()
        for call in allCalls where call.date >= cutoff && !call.isTest {
            s.dials += 1
            if call.connected { s.connects += 1; s.talk += call.seconds }
            if call.booked { s.booked += 1 }
        }
        return s
    }

    var todayStats: Stats {
        var s = Stats()
        for call in allCalls where Calendar.current.isDateInToday(call.date) && !call.isTest {
            s.dials += 1
            if call.connected { s.connects += 1; s.talk += call.seconds }
            if call.booked { s.booked += 1 }
        }
        return s
    }

    // MARK: - Recorder status and permissions

    /// Health comes from the launchd job and the watcher's own state file.
    /// The app never checks its own audio permission: recording is done by a
    /// separate binary, which has its own grants.
    private var lastStateSignature: String?

    func refreshStatus() {
        guard !statusInFlight else { return }
        statusInFlight = true
        let askLaunchd = launchdThrottle.shouldRun()
        let askHistory = !checkedCallHistory
        let stateURL = self.stateURL
        Task.detached(priority: .utility) { [weak self] in
            let state = StatusProbe.watcherState(at: stateURL)
            let launchd = askLaunchd ? StatusProbe.launchdRunning() : nil
            let history = askHistory ? CallHistory.readable : nil
            await self?.applyStatus(state: state, launchd: launchd, history: history)
        }
    }

    private func applyStatus(state: WatcherState?, launchd: Bool?, history: Bool?) {
        statusInFlight = false
        // Assigned every tick on purpose: the recording clock in the status pill redraws off this.
        agentRunning = launchd ?? agentRunning
        if let state, state.state == "recording" {
            recordingSince = ISO8601DateFormatter().date(from: state.since)
        } else {
            recordingSince = nil
        }
        modelPreparing = agentRunning && (state?.preparingModel ?? false)
        modelError = state?.modelError
        permissionProblems = state?.permissionProblems ?? []
        if transcribingID != state?.transcribing { transcribingID = state?.transcribing }
        // The daemon rewrites state.json whenever a call starts, ends, or finishes
        // transcribing. Reload on any change, so a new transcript shows up even if the
        // folder watcher missed the write (2026-10-07: list showed "Not transcribed yet"
        // after the .md existed).
        let signature = [state?.state, state?.since, state?.transcribing, state?.lastCall]
            .map { $0 ?? "-" }.joined(separator: "|")
        if let lastStateSignature, lastStateSignature != signature { reload() }
        lastStateSignature = signature
        if let history {
            checkedCallHistory = true
            callHistoryReadable = history
        }
    }

    var healthy: Bool { agentRunning }

    /// Soft hint, never an error: without Full Disk Access we simply cannot say
    /// who a call was with.
    var callHistoryHint: String? {
        callHistoryReadable ? nil : CallHistory.noAccessMessage
    }

    private var stateURL: URL {
        Config.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }


    /// What to say about a call that has audio but no transcript.
    func pendingStatus(for call: Call) -> String {
        if call.rawOnly, let since = recordingSince, abs(call.date.timeIntervalSince(since)) < 5 { return "Recording…" }
        if call.id == transcribingID { return "Transcribing…" }
        return "Not transcribed yet — run `callrec retranscribe \(call.id)`"
    }

    var statusLine: String {
        [statusWord, recordingClock].compactMap { $0 }.joined(separator: " ")
    }

    var statusWord: String {
        if recordingSince != nil { return "Recording" }
        if !agentRunning { return "Not running" }
        return modelPreparing ? "Preparing speech model…" : "Watching"
    }

    /// Only while recording, so the pill's width stays stable otherwise.
    var recordingClock: String? {
        guard let since = recordingSince else { return nil }
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func setAgent(running: Bool) {
        guard let cli = CLI.path else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            attempt("could not run \(cli)") { try Shell.run(cli, [running ? "install-agent" : "uninstall-agent"], timeout: 30) }
            await self?.agentChanged()
        }
    }

    func openAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(Library.root)
    }

    func revealInFinder() {
        guard let call = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([call.audio])
    }

    func flashSaved() {
        savedFlash = true
        Task { @MainActor in
            // Only throws when cancelled, and a cancelled flash just ends early.
            // swiftlint:disable:next no_try_optional
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            savedFlash = false
        }
    }
}

/// The CLI that does the actual recording. Prefer the copy inside this app
/// bundle, fall back to an installed one.
enum CLI {
    static var path: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/callrec").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for p in ["/usr/local/bin/callrec",
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".callrec/bin/callrec").path] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "Week"
    var id: String { rawValue }
}

/// The two status reads, kept off the main actor.
enum StatusProbe {
    /// state.json is written by the daemon. Missing means "not running"; anything else is logged.
    static func watcherState(at url: URL) -> WatcherState? {
        do {
            return try JSONDecoder().decode(WatcherState.self, from: Data(contentsOf: url))
        } catch {
            if !Fs.isMissing(error) { log("could not read \(url.path): \(error.localizedDescription)") }
            return nil
        }
    }

    static func launchdRunning() -> Bool {
        let out = attempt("could not run launchctl") {
            try Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/com.blaxify.callrec"], timeout: 5)
        }
        return out?.status == 0
    }
}
