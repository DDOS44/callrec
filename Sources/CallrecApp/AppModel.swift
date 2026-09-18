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
    @Published var search = ""
    @Published var agentRunning = false
    @Published var recordingSince: Date?
    @Published var lastCallAt: Date?
    @Published var savedFlash = false
    @Published var statsRange: StatsRange = .today

    private var folderWatcher: FolderWatcher?
    private var timer: Timer?

    init() {
        reload()
        selectedDay = days.first?.name
        selectedCall = days.first?.calls.first?.id
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        refreshStatus()
    }

    // MARK: - Library

    func reload() {
        let previous = selectedCall
        days = Library.load()
        if selectedDay == nil || !days.contains(where: { $0.name == selectedDay }) {
            selectedDay = days.first?.name
        }
        if previous == nil || !allCalls.contains(where: { $0.id == previous }) {
            selectedCall = callsForSelectedDay.first?.id
        }
    }

    private func startWatching() {
        try? FileManager.default.createDirectory(at: Library.root, withIntermediateDirectories: true)
        folderWatcher = FolderWatcher(url: Library.root) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    static let allDaysTag = "__all__"

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
        for call in allCalls where call.date >= cutoff {
            s.dials += 1
            if call.connected { s.connects += 1; s.talk += call.seconds }
            if call.booked { s.booked += 1 }
        }
        return s
    }

    var todayStats: Stats {
        var s = Stats()
        for call in allCalls where Calendar.current.isDateInToday(call.date) {
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
    func refreshStatus() {
        let out = (try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/com.blaxify.callrec"], timeout: 5))
        agentRunning = (out?.status == 0)

        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(WatcherStateFile.self, from: data) {
            recordingSince = state.state == "recording" ? ISO8601DateFormatter().date(from: state.since) : nil
        } else {
            recordingSince = nil
        }
        lastCallAt = allCalls.first?.date
    }

    var healthy: Bool { agentRunning }

    private var stateURL: URL {
        Config.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    struct WatcherStateFile: Codable {
        let state: String
        let since: String
        let lastCall: String?
    }

    var statusLine: String {
        if let since = recordingSince {
            let s = Int(Date().timeIntervalSince(since))
            return "Recording \(s / 60)m \(s % 60)s"
        }
        return agentRunning ? "Watching" : "Not running"
    }

    func setAgent(running: Bool) {
        guard let cli = CLI.path else { return }
        _ = try? Shell.run(cli, [running ? "install-agent" : "uninstall-agent"], timeout: 30)
        refreshStatus()
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
