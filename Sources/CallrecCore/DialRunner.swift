import Combine
import Foundation

/// A line of the pre-flight checklist.
public struct PreflightItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case ok, fail, manual }
    public var id: String
    public var title: String
    public var detail: String
    public var state: State
}

/// Runs a dial session: feeds the pure `DialSession` with clock, call state, policy answers
/// and user actions, and performs its effects (dial log, lead state, do-not-call list, the
/// call's .md). One writer for each file. Everything it touches arrives through `Services`,
/// so tests run a whole session with a fake dialer and temp files.
@MainActor
public final class DialRunner: ObservableObject {

    public struct CallState: Sendable {
        public var recording: Bool
        public var since: Date?
        public init(recording: Bool, since: Date? = nil) { self.recording = recording; self.since = since }
    }

    public struct Services {
        public var dialer: Dialer
        public var config: Config
        public var listName: String
        public var leads: LeadImport
        public var store: LeadStateStore
        public var dialLogURL: URL
        public var dncURL: URL
        public var calendar: Calendar
        public var now: () -> Date
        public var callState: () -> CallState
        public var loadHistory: @Sendable () async throws -> HistorySnapshot
        /// Writes outcome/notes/company/owner into the call's .md. False when the .md does not exist yet.
        public var applyToMarkdown: (_ callStart: Date, _ lead: Lead, _ outcome: String, _ notes: String) throws -> Bool
        public var saveColdSIM: (String) throws -> Void
        public var autoTick: Bool

        public init(dialer: Dialer, config: Config, listName: String, leads: LeadImport, store: LeadStateStore,
                    dialLogURL: URL = DialerPaths.dialLog, dncURL: URL = DialerPaths.dnc, calendar: Calendar = .current,
                    now: @escaping () -> Date = { Date() }, callState: @escaping () -> CallState,
                    loadHistory: @escaping @Sendable () async throws -> HistorySnapshot,
                    applyToMarkdown: @escaping (Date, Lead, String, String) throws -> Bool,
                    saveColdSIM: @escaping (String) throws -> Void, autoTick: Bool = true) {
            self.dialer = dialer; self.config = config; self.listName = listName; self.leads = leads; self.store = store
            self.dialLogURL = dialLogURL; self.dncURL = dncURL; self.calendar = calendar; self.now = now
            self.callState = callState; self.loadHistory = loadHistory; self.applyToMarkdown = applyToMarkdown
            self.saveColdSIM = saveColdSIM; self.autoTick = autoTick
        }
    }

    @Published public private(set) var session: DialSession
    @Published public private(set) var queue: [QueueItem] = []
    /// Errors the user must see (a file that could not be written, history unreadable...). Never swallowed.
    @Published public private(set) var alerts: [String] = []
    @Published public private(set) var snapshot: HistorySnapshot?
    @Published public private(set) var dnc = DNCList()
    @Published public private(set) var dialLog: [DialLogEntry] = []
    @Published public private(set) var preflightChecked = false

    public let services: Services
    private let rules: DialRules
    private var coldSIM: String?
    private var manualSIMConfirmed = false
    private var sessionStart: Date
    private var lastWrapUpEnd: Date?
    private var wasRecording: Bool?
    private var callStart: Date?
    private var dialedAt: Date?
    private var attempt: DialLogEntry?
    private var lookupInFlight = false
    private var timer: Timer?
    private var rng = SystemRandomNumberGenerator()
    private struct PendingMarkdown { var callStart: Date; var lead: Lead; var outcome: String; var notes: String }
    private var pendingMarkdown: [PendingMarkdown] = []

    public init(_ services: Services) {
        self.services = services
        self.rules = services.config.dialRules
        self.session = DialSession(notPlacedTimeout: rules.notPlacedTimeout)
        self.sessionStart = services.now()
        refreshQueue()
    }

    // MARK: - Reading

    public var current: QueueItem? { session.currentLeadID.flatMap { id in queue.first { $0.id == id } } }
    public var nextUp: QueueItem? { LeadQueue.nextUp(queue) }
    public var rulesInForce: DialRules { rules }

    public var dialsToday: Int {
        let now = services.now()
        return dialLog.filter { $0.kind == .attempt && services.calendar.isDate($0.ts, inSameDayAs: now) }.count
    }

    public var dialsLastHour: Int {
        let now = services.now()
        return dialLog.filter { $0.kind == .attempt && $0.ts > now.addingTimeInterval(-3600) && $0.ts <= now }.count
    }

    private func refreshQueue() { queue = LeadQueue.build(services.leads, state: services.store.all) }

    private func alert(_ message: String) {
        logError("dialer: \(message)")
        alerts.append(message)
    }

    public func dismissAlerts() { alerts.removeAll() }

    // MARK: - Pre-flight

    /// Opens the pre-flight: loads the dial log, the do-not-call list and call history.
    public func start() {
        guard !session.isRunning else { return }
        session.handle(.start)
        sessionStart = services.now()
        lastWrapUpEnd = nil
        manualSIMConfirmed = false
        preflightChecked = false
        coldSIM = services.config.coldSIM.isEmpty ? nil : services.config.coldSIM
        reloadFiles()
        Task { await reloadHistory() }
    }

    public func cancelPreflight() { session.handle(.preflightCancelled) }

    private func reloadFiles() {
        logUnreadable = false
        do {
            let loaded = try DialLog.load(from: services.dialLogURL)
            dialLog = loaded.entries
            if loaded.skipped > 0 { alert("\(loaded.skipped) unreadable line(s) in the dial log were skipped. They are still in the file.") }
        } catch { alert("Could not read the dial log: \(error.localizedDescription). Dialing is blocked until this is fixed.") ; dialLog = [] ; logUnreadable = true }
        do {
            dnc = try DNCList.load(from: services.dncURL)
            if dnc.unreadable > 0 { alert("\(dnc.unreadable) line(s) in dnc.txt are not phone numbers and were ignored.") }
        } catch { alert("Could not read the do-not-call list: \(error.localizedDescription). Dialing is blocked until this is fixed."); logUnreadable = true }
    }

    /// True when the dial log or DNC list could not be read: the session must not dial blind.
    private var logUnreadable = false

    private func reloadHistory() async {
        do {
            let snap = try await services.loadHistory()
            snapshot = snap
            log(SIMDetector.summary(snap.detection, candidates: snap.detection.column.map { [$0] } ?? []))
        } catch {
            snapshot = nil
            alert("Call history could not be read (\(error.localizedDescription)). Cooldown uses the dial log only and the SIM check is manual.")
        }
    }

    public var simValues: [LineValue] {
        if case .available(_, let values)? = snapshot?.detection { return values }
        return []
    }

    public var simDetectionActive: Bool { snapshot?.detection.column != nil }

    /// What the user must tick or fix before the first dial.
    public func preflightItems() -> [PreflightItem] {
        let now = services.now()
        var items: [PreflightItem] = []
        if let block = DialPolicy.hoursBlock(now: now, rules: rules, calendar: services.calendar) {
            items.append(.init(id: "hours", title: "Calling hours", detail: block.message, state: .fail))
        } else {
            items.append(.init(id: "hours", title: "Calling hours", detail: "Open now.", state: .ok))
        }
        let capBlock = DialPolicy.capBlock(now: now, rules: rules, log: dialLog, calendar: services.calendar)
        let left = max(rules.dailyCap - dialsToday, 0)
        items.append(.init(id: "caps", title: "Dials left today",
                           detail: capBlock?.message ?? "\(left) of \(rules.dailyCap) today, \(max(rules.hourlyCap - dialsLastHour, 0)) of \(rules.hourlyCap) this hour.",
                           state: capBlock == nil ? .ok : .fail))
        items.append(.init(id: "dnc", title: "Do-not-call list", detail: "\(dnc.keys.count) number(s) loaded.",
                           state: logUnreadable ? .fail : .ok))
        if simDetectionActive {
            let ok = coldSIM.map { c in simValues.contains { $0.value == c } } ?? false
            items.append(.init(id: "sim", title: "Cold SIM",
                               detail: ok ? "Line recorded; every call is checked against it." : "Pick which line is the cold SIM below.",
                               state: ok ? .ok : .fail))
        } else {
            items.append(.init(id: "sim", title: "Cold SIM",
                               detail: "Cannot be read on this Mac. iPhone Settings > Cellular > Default Voice Line = cold SIM.",
                               state: manualSIMConfirmed ? .ok : .manual))
        }
        return items
    }

    public var canPassPreflight: Bool { preflightItems().allSatisfy { $0.state == .ok } && !logUnreadable }

    public func chooseColdSIM(_ value: String) {
        coldSIM = value
        do { try services.saveColdSIM(value) } catch { alert("Could not save the cold SIM to the config: \(error.localizedDescription)") }
        objectWillChange.send()
    }

    public func confirmManualSIM(_ on: Bool) { manualSIMConfirmed = on; objectWillChange.send() }

    public func passPreflight() {
        guard canPassPreflight else { return }
        preflightChecked = true
        sessionStart = services.now()
        perform(session.handle(.preflightPassed(now: services.now())))
        startTimer()
    }

    // MARK: - User actions

    public func pause() { perform(session.handle(.pause)) }
    public func pauseAfterThisCall() { perform(session.handle(.pauseAfterThisCall)) }
    public func stop() { perform(session.handle(.stop)); if !session.isRunning { stopTimer() } }
    public func doNotCallAgain() { perform(session.handle(.doNotCallAgain)) }
    public func dialNow() { perform(session.handle(.dialNow(now: services.now()))) }
    public func skipNext() {
        guard let id = nextUp?.id else { return }
        perform(session.handle(.skipNext(leadID: id)))
    }
    public func resume() {
        perform(session.handle(.resume(now: services.now(), gap: rules.randomGap(using: &rng), minGap: rules.gapMin)))
    }
    public func saveWrapUp(outcome: String, notes: String, doNotCall: Bool) {
        let now = services.now()
        lastWrapUpEnd = now
        perform(session.handle(.wrapUpSaved(now: now, outcome: outcome, notes: notes, doNotCall: doNotCall,
                                            gap: rules.randomGap(using: &rng), minGap: rules.gapMin)))
        if !session.isRunning { stopTimer() }
    }

    // MARK: - Clock

    private func startTimer() {
        guard services.autoTick, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// One step of the clock: reads the call state, then ticks the session. Public for tests.
    public func tick() {
        let now = services.now()
        let state = services.callState()
        if let was = wasRecording {
            if state.recording && !was {
                callStart = state.since ?? now
                perform(session.handle(.callStarted(now: now)))
            } else if !state.recording && was {
                perform(session.handle(.callEnded(now: now)))
            }
        }
        wasRecording = state.recording
        perform(session.handle(.tick(now: now)))
        retryMarkdown()
        if !session.isRunning { stopTimer() }
    }

    // MARK: - Effects

    private func perform(_ effects: [DialEffect]) {
        for effect in effects { perform(effect) }
        objectWillChange.send()
    }

    private func perform(_ effect: DialEffect) {
        switch effect {
        case .evaluateNext: evaluateNext()
        case .dial(let id): dial(id)
        case .recordNotPlaced(let id): recordNotPlaced(id)
        case .lookUpCall(let id, let at): lookUp(id, dialedAt: at)
        case .recordCallEnded(let id, let seconds, let connected): callEnded(id, seconds: seconds, connected: connected)
        case .saveWrapUp(let id, let outcome, let notes): wrapUp(id, outcome: outcome, notes: notes)
        case .addToDoNotCall(let id): addToDNC(id)
        case .setLeadStatus(let id, let status): setStatus(id, status)
        }
    }

    private func facts() -> DialSessionFacts {
        DialSessionFacts(start: sessionStart, callActive: services.callState().recording, lastWrapUpEnd: lastWrapUpEnd,
                         expectedSIM: simDetectionActive ? coldSIM : nil, manualSIMConfirmed: manualSIMConfirmed)
    }

    private func evaluateNext() {
        let now = services.now()
        let next = nextUp
        var decision: DialDecision
        if logUnreadable {
            decision = .pause(.simUnverified)   // never dial without a readable log
        } else {
            decision = DialPolicy.evaluate(number: next?.lead.number ?? "", now: now, rules: rules, log: dialLog, dnc: dnc,
                                           history: snapshot?.lastCallByKey ?? [:], session: facts(), calendar: services.calendar)
            // With nothing left to dial, report the session-level answer, not "invalid number".
            if next == nil, decision == .blocked(.invalidNumber) { decision = .allowed }
        }
        perform(session.handle(.dialChecked(now: now, nextLeadID: next?.id, decision: decision)))
    }

    private func append(_ entry: DialLogEntry) -> Bool {
        do {
            try DialLog.append(entry, to: services.dialLogURL)
            dialLog.append(entry)
            return true
        } catch {
            alert("Could not write the dial log: \(error.localizedDescription)")
            return false
        }
    }

    private func dial(_ id: String) {
        guard let lead = services.leads.leads.first(where: { $0.id == id }) else {
            perform(session.handle(.dialFailed(message: "lead not found")))
            return
        }
        let now = services.now()
        let entry = DialLogEntry.attempt(at: now, list: services.listName, leadID: id, key: lead.number)
        // The attempt is logged before the call is placed, so a crash can never leave an uncounted dial.
        guard append(entry) else {
            perform(session.handle(.dialFailed(message: "the dial could not be logged, so it was not placed")))
            return
        }
        attempt = entry
        dialedAt = now
        do {
            try services.dialer.dial(number: lead.number)
        } catch {
            perform(session.handle(.dialFailed(message: error.localizedDescription)))
            return
        }
        update(id) { $0.attempts += 1; $0.lastDialedAt = now }
        perform(session.handle(.dialPlaced(now: services.now())))
    }

    private func recordNotPlaced(_ id: String) {
        guard let a = attempt, a.leadID == id else { return }
        _ = append(a.finished(at: services.now(), result: .notPlaced))
    }

    private func lookUp(_ id: String, dialedAt: Date) {
        guard !lookupInFlight, let lead = services.leads.leads.first(where: { $0.id == id }) else { return }
        lookupInFlight = true
        let load = services.loadHistory
        Task {
            defer { lookupInFlight = false }
            do {
                let snap = try await load()
                snapshot = snap
                if let row = SIMDetector.call(forNumber: lead.number, dialedAt: dialedAt, rows: snap.rows) {
                    perform(session.handle(.dialResolved(.placed(seconds: row.seconds), now: services.now())))
                }
            } catch { alert("Call history could not be read to check the dial: \(error.localizedDescription)") }
        }
    }

    private func callEnded(_ id: String, seconds: Int, connected: Bool) {
        let ended = services.now()
        let start = callStart
        update(id) {
            $0.status = connected ? .called : .noAnswer
            if let start { $0.callID = Self.callID(start) }
        }
        guard let a = attempt, a.leadID == id else { return }
        let load = services.loadHistory
        let dialed = dialedAt ?? ended
        Task {
            var line: String?
            do {
                let snap = try await load()
                snapshot = snap
                line = snap.line(forNumber: a.key, dialedAt: dialed)
            } catch { alert("Call history could not be read after the call: \(error.localizedDescription)") }
            let result: DialResult = connected ? .connected : .noConnect
            guard append(a.finished(at: ended, result: result, seconds: seconds, sim: line)) else { return }
            if let halt = haltAfterCall() { perform(session.handle(.policyHalt(halt))) }
        }
    }

    /// Stop or pause reasons found after a call (wrong SIM, failure streak, carrier restriction...).
    private func haltAfterCall() -> DialHalt? {
        let f = facts()
        if let s = DialPolicy.stopReason(log: dialLog, session: f) { return .stop(.policy(s)) }
        if let p = DialPolicy.pauseReason(now: services.now(), rules: rules, log: dialLog, dnc: dnc, session: f,
                                          calendar: services.calendar) { return .pause(.policy(p)) }
        return nil
    }

    private static func callID(_ start: Date) -> String {
        let p = Paths.forCall(at: start)
        return "\(p.dir.lastPathComponent)/\(p.base)"
    }

    private func wrapUp(_ id: String, outcome: String, notes: String) {
        update(id) { $0.outcome = outcome; $0.notes = notes }
        guard let lead = services.leads.leads.first(where: { $0.id == id }), let start = callStart else { return }
        let item = PendingMarkdown(callStart: start, lead: lead, outcome: outcome, notes: notes)
        write(item)
    }

    private func write(_ item: PendingMarkdown) {
        do {
            if try !services.applyToMarkdown(item.callStart, item.lead, item.outcome, item.notes) { pendingMarkdown.append(item) }
        } catch {
            alert("Could not save the notes into the call's file: \(error.localizedDescription). They are kept in the lead's state.")
        }
    }

    /// The daemon writes the call's .md only after transcription; keep trying until it exists.
    private func retryMarkdown() {
        guard !pendingMarkdown.isEmpty else { return }
        let items = pendingMarkdown
        pendingMarkdown = []
        for item in items { write(item) }
    }

    public var pendingMarkdownCount: Int { pendingMarkdown.count }

    private func addToDNC(_ id: String) {
        guard let lead = services.leads.leads.first(where: { $0.id == id }) else { return }
        do {
            try DNCList.add(lead.number, now: services.now(), to: services.dncURL)
            dnc = try DNCList.load(from: services.dncURL)
        } catch { alert("Could not add the number to the do-not-call list: \(error.localizedDescription)") }
    }

    private func setStatus(_ id: String, _ status: LeadStatus) { update(id) { $0.status = status } }

    private func update(_ id: String, _ change: (inout LeadRecord) -> Void) {
        do { try services.store.update(id, now: services.now(), change) }
        catch { alert("Could not save the lead's state: \(error.localizedDescription)") }
        refreshQueue()
    }
}
