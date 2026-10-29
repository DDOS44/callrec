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
        /// Opens a URL (the booking email's compose window). The app passes NSWorkspace; tests capture it.
        public var openURL: (URL) -> Bool = { _ in false }
        /// Books meetings on the call; nil when Cal.com is not set up (no event type or no key).
        public var calcom: CalCom?

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
    /// Calls from an interrupted session that still need a wrap-up (see DialRecovery).
    @Published public private(set) var unfinished: [DialRecovery.Unfinished] = []
    private var recovering: DialRecovery.Unfinished?
    @Published public private(set) var dnc = DNCList()
    @Published public private(set) var dialLog: [DialLogEntry] = []
    @Published public private(set) var preflightChecked = false
    /// Where the last wrap-up went, for the confirmation line. Cleared by `dismissSaveNote`.
    @Published public private(set) var saveNote: String?

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
    /// The dial sequence of the lead the session is working through (main + usable alts), fixed when the
    /// lead is first picked so a list change mid-lead cannot shift which number is next.
    private var activeSequence: (leadID: String, numbers: [String])?
    private var timer: Timer?
    private var rng = SystemRandomNumberGenerator()
    private struct PendingMarkdown { var callStart: Date; var lead: Lead; var outcome: String; var notes: String }
    private var pendingMarkdown: [PendingMarkdown] = []

    public init(_ services: Services) {
        self.services = services
        self.rules = services.config.dialRules
        self.session = DialSession(notPlacedTimeout: rules.notPlacedTimeout, shortCallSeconds: rules.shortCallSeconds)
        self.sessionStart = services.now()
        refreshQueue()
        reloadFiles()
        refreshUnfinished()
    }

    /// Attempts on this list with no result, excluding the one the live session owns.
    private func refreshUnfinished() {
        let live = session.isRunning ? attempt?.attemptID : nil
        let orphans = DialRecovery.unfinished(log: dialLog, now: services.now(), excluding: live)
            .filter { a in a.list == services.listName && services.leads.leads.contains { $0.id == a.leadID } }
        let all = orphans.map { a in
            let starts = DialRecovery.recordingStarts(on: a.ts, root: services.config.recordingsURL, calendar: services.calendar)
            return DialRecovery.Unfinished(attempt: a, recordingStart: DialRecovery.recording(after: a.ts, starts: starts))
        }
        let triage = DialRecovery.triage(all, now: services.now())
        // An attempt with no recording never became a call: close it quietly, never show it.
        for a in triage.close where append(a.finished(at: services.now(), result: .notPlaced)) {
            log("dialer: closed orphaned attempt \(a.attemptID) for \(a.leadID) as not placed (no recording)")
        }
        unfinished = triage.offer
    }

    /// Opens the wrap-up for a call an interrupted session left unfinished.
    public func recover(_ item: DialRecovery.Unfinished) {
        guard !session.isRunning else { return }
        recovering = item
        callStart = item.recordingStart
        perform(session.handle(.recover(leadID: item.attempt.leadID)))
    }

    // MARK: - Reading

    public var current: QueueItem? { session.currentLeadID.flatMap { id in queue.first { $0.id == id } } }
    /// A lead the user clicked to call next. Used while it is pending; after it is dialled the queue
    /// goes back to list order.
    @Published public private(set) var pickedNext: String?

    public var nextUp: QueueItem? {
        if let id = pickedNext, let item = queue.first(where: { $0.id == id }), isDialable(item) { return item }
        return mode == .retries ? retryDue.first : LeadQueue.nextUp(queue)
    }

    // MARK: - No-connect retries

    /// What a session dials: new leads, or no-connect leads whose retry is due (RetryPlan).
    public enum Mode: String, Sendable { case fresh, retries }
    @Published public private(set) var mode: Mode = .fresh

    /// Switching is for between sessions only.
    public func setMode(_ m: Mode) {
        guard !session.isRunning, m != mode else { return }
        mode = m; pickedNext = nil; viewing = nil; activeSequence = nil
        objectWillChange.send()
    }

    /// Where a lead stands in the retry cadence, from its placed dials in the dial log (any list).
    public func retryState(for leadID: String) -> RetryPlan.State {
        guard let item = queue.first(where: { $0.id == leadID }) else { return .none }
        let notPlaced = Set(dialLog.filter { $0.kind == .result && $0.result == .notPlaced }.map(\.attemptID))
        let attempts = dialLog.filter { $0.kind == .attempt && $0.leadID == leadID && !notPlaced.contains($0.attemptID) }.map(\.ts)
        return RetryPlan.state(attempts: attempts, status: item.status, now: services.now(), calendar: services.calendar,
                               callingDays: rules.days)
    }

    /// No-connect leads due for a retry: those whose suggested part of the day is now come first,
    /// then the longest-waiting.
    public var retryDue: [QueueItem] {
        let now = RetryPlan.Window.of(services.now(), calendar: services.calendar)
        return queue.compactMap { item -> (QueueItem, Bool, Date)? in
            guard item.status == .noAnswer, case .due(_, let last, let suggested) = retryState(for: item.id) else { return nil }
            return (item, suggested == now, last)
        }
        .sorted { a, b in a.1 != b.1 ? a.1 : a.2 < b.2 }
        .map(\.0)
    }

    /// Pending, or (in retry mode) a no-connect whose retry is due, or a lead returning our missed call.
    private func isDialable(_ item: QueueItem) -> Bool {
        if item.status == .pending { return true }
        return mode == .retries && item.status == .noAnswer && retryState(for: item.id).isDue
    }

    /// Numbers that skip only the 7-day rule at this dial check: due retries and returned missed calls.
    private func retryKeys() -> Set<String> {
        var ids = Set(returning)
        if mode == .retries { ids.formUnion(retryDue.map(\.id)) }
        return Set(queue.filter { ids.contains($0.id) }.flatMap { AltNumbers.allNumbers(of: $0.lead) })
    }

    // MARK: - Callbacks

    /// Calls from leads in the last 7 days (talked and missed), newest first.
    @Published public private(set) var callbacks: [Callbacks.Item] = []
    /// Leads whose missed call to us is being returned: their next dial skips the 7-day rule.
    private var returning: Set<String> = []

    /// Reads call history (through the recorder) and updates the callbacks. A lead who called back and
    /// talked (>= 20 s) is out of no-answer: its status becomes called (its outcome is left alone).
    /// Quiet on failure: this is not a dialing decision.
    public func refreshCallbacks() async {
        do { snapshot = try await services.loadHistory() } catch {
            log("dialer: callbacks not refreshed, call history unavailable: \(error.localizedDescription)")
            return
        }
        let found = Callbacks.find(history: snapshot?.rows ?? [], leads: services.leads.leads, log: dialLog,
                                   since: services.now().addingTimeInterval(-7 * 86_400))
        callbacks = found
        for cb in found where cb.seconds >= 20 {
            guard let item = queue.first(where: { $0.id == cb.leadID }), item.id != session.currentLeadID,
                  [.noAnswer, .skipped, .pending].contains(item.status) else { continue }
            setStatus(cb.leadID, .called)
            log("dialer: \(item.lead.title) called back and talked \(cb.seconds) s: status called")
        }
        objectWillChange.send()
    }

    /// "Call back" on a missed call: that lead is the next dial, on the number that called.
    public func callBack(_ cb: Callbacks.Item) {
        guard canChooseNumber, let item = queue.first(where: { $0.id == cb.leadID }), item.status != .doNotCall else { return }
        returning.insert(cb.leadID)
        if item.status != .pending { setStatus(cb.leadID, .pending) }
        pick(cb.leadID)
        chooseNumber(cb.number, for: cb.leadID)
    }

    /// A finished lead the user clicked to look at (it is shown on the card; nothing about it changes).
    @Published public private(set) var viewing: String?

    /// Queue row click. A pending lead becomes the next dial. A finished lead (called, no answer,
    /// skipped, do-not-call) is only SHOWN: its status and outcome stay. "Call again" re-queues it.
    /// Not while a call is placed, on, or wrapped up.
    public func callNext(_ id: String) {
        guard canChooseNumber, id != session.currentLeadID,
              let item = queue.first(where: { $0.id == id }) else { return }
        guard isDialable(item) else { viewing = id; objectWillChange.send(); return }
        pick(id)
    }

    /// "Call again" on a finished lead: back to pending, and it is the next dial. Never do-not-call.
    /// The 7-day rule and every other guardrail still apply when it is dialled.
    public func callAgain(_ id: String) {
        guard canChooseNumber, id != session.currentLeadID, let item = queue.first(where: { $0.id == id }),
              let back = LeadStatus.afterMoveBack(current: item.status) else { return }
        setStatus(id, back)
        pick(id)
    }

    /// Leave a finished lead being looked at; the card shows the next dial again.
    public func stopViewing() { viewing = nil; objectWillChange.send() }

    private func pick(_ id: String) {
        if skipUndo?.leadID == id { skipUndo = nil }
        // Leaving a lead part-way through its numbers: its remaining numbers are dropped, it stays pending.
        if let p = numberProgress, p.leadID != id { activeSequence = nil }
        pickedNext = id
        viewing = nil
        objectWillChange.send()
    }

    /// Lead card arrows: move "next up" to the previous / next PENDING lead in queue order.
    public func step(_ delta: Int) {
        let pending = queue.filter { $0.status == .pending }
        guard let current = nextUp, let i = pending.firstIndex(where: { $0.id == current.id }) else { return }
        let j = min(max(i + delta, 0), pending.count - 1)
        guard j != i else { return }
        callNext(pending[j].id)
    }

    /// Where the session stands in the current lead's numbers.
    public struct NumberProgress: Equatable, Sendable {
        public var leadID: String
        public var index: Int
        public var numbers: [String]
        /// "Main" / "Alt 1 of 2" by the number's place on the lead, not its place in the (reorderable) sequence.
        public var labels: [String] = []
        public var label: String { labels.indices.contains(index) ? labels[index] : AltNumbers.label(index: index, count: numbers.count) }
        public var number: String { numbers[index] }
    }

    public var numberProgress: NumberProgress? {
        guard let plan = session.numberPlan, let seq = activeSequence, seq.leadID == plan.leadID,
              seq.numbers.indices.contains(plan.index) else { return nil }
        let original = services.leads.leads.first { $0.id == plan.leadID }.map { AltNumbers.allNumbers(of: $0) } ?? seq.numbers
        let labels = seq.numbers.map { n in AltNumbers.label(index: original.firstIndex(of: n) ?? 0, count: original.count) }
        return NumberProgress(leadID: plan.leadID, index: plan.index, numbers: seq.numbers, labels: labels)
    }

    /// The lead in front of the user: the one on the line, else the one whose alt number is due, else the next in the queue.
    public var focus: QueueItem? {
        if let c = current { return c }
        if let v = viewing, let item = queue.first(where: { $0.id == v }) { return item }
        if let p = numberProgress, let item = queue.first(where: { $0.id == p.leadID }), isDialable(item) { return item }
        return nextUp
    }

    /// Countdown text for a due alt number, e.g. "No answer on +91 … . Trying alt 1 of 2 (+91 …)".
    public func altNotice(for countdown: DialSession.Countdown) -> String? {
        guard countdown.altFallback, let p = numberProgress else { return nil }
        return AltNumbers.notice(sequence: p.numbers, nextIndex: p.index, afterNoAnswer: countdown.afterNoAnswer, labels: p.labels)
    }

    /// True when picking which number to dial next is allowed (not while a call is placed, on, or wrapped up).
    public var canChooseNumber: Bool {
        switch session.phase {
        case .idle, .stopped, .preflight, .countdown, .paused: return true
        default: return false
        }
    }

    /// Lead card: dial `number` next for `leadID`. Numbers already tried on this lead keep their place;
    /// the chosen one goes next and the untried others follow as fallbacks. Only for the lead in front
    /// of the user, and never while a call is being placed, on, or wrapped up (the session ignores it).
    public func chooseNumber(_ number: String, for leadID: String) {
        guard let item = queue.first(where: { $0.id == leadID }), isDialable(item),
              focus?.id == leadID || current == nil && nextUp?.id == leadID else { return }
        let full = AltNumbers.sequence(for: item.lead, dnc: dnc, enabled: true)
        guard full.contains(number) else { return }
        var tried: [String] = []
        if let p = numberProgress, p.leadID == leadID { tried = Array(p.numbers.prefix(p.index)) }
        guard !tried.contains(number) else { return }
        let order = tried + [number] + full.filter { $0 != number && !tried.contains($0) }
        activeSequence = (leadID, order)
        perform(session.handle(.chooseNumber(leadID: leadID, count: order.count, index: tried.count)))
        objectWillChange.send()
    }

    /// The email to show in the booking box: one typed this session, else the lead's saved one, else the CSV's.
    public func bookingEmail(for leadID: String) -> String {
        if let typed = emailDrafts[leadID] { return typed }
        guard let item = queue.first(where: { $0.id == leadID }) else { return "" }
        return item.record.email ?? item.lead.email
    }
    public func setBookingEmail(_ email: String, for leadID: String) { emailDrafts[leadID] = email }
    private var emailDrafts: [String: String] = [:]

    /// Opens a ready email with the booking link to `email`. Returns a message to show when it could not
    /// (no link configured, an address that does not look right, nothing to open it with); nil when opened.
    @discardableResult
    public func sendBookingLink(to email: String, for leadID: String) -> String? {
        let c = services.config
        guard !c.bookingLink.isEmpty else { return "No booking link set. Add \"bookingLink\" to ~/.callrec/config.json." }
        let to = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BookingEmail.isValid(to) else { return "That email doesn't look right. Check it with them." }
        guard let item = queue.first(where: { $0.id == leadID }) else { return "Lead not found." }
        let fill = { (t: String) in BookingEmail.fill(t, name: BookingEmail.firstName(from: item.lead.owner),
                                                       company: item.lead.company, link: c.bookingLink, sender: c.bookingSender) }
        let via = BookingEmail.Via(rawValue: c.bookingCompose) ?? .gmail
        guard let url = BookingEmail.composeURL(to: to, subject: fill(c.bookingSubject), body: fill(c.bookingBody),
                                                via: via, account: c.bookingGmailAccount),
              services.openURL(url) else { return "Could not open the email. Copy the link and send it by hand." }
        emailDrafts[leadID] = to
        update(leadID) { $0.email = to; $0.bookingSentAt = services.now() }
        objectWillChange.send()
        return nil
    }

    /// True when meetings can be booked on the call (Cal.com event type + API key present).
    public var canBook: Bool { services.calcom != nil }

    /// Free slots on `day` for the booking box. A failure comes back as a message to show.
    public func freeSlots(on day: Date) async -> Result<[Date], CalCom.Failure> {
        guard let cal = services.calcom else { return .failure(.init(message: "Cal.com is not set up.")) }
        do { return .success(try await cal.slots(on: day).filter { $0 > services.now() }) } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    /// Books `start` for the lead through Cal.com, which emails them the invite and join link.
    /// Returns a message when it could not; nil when booked (saved on the lead, noted in the wrap-up).
    public func bookMeeting(leadID: String, start: Date, name: String, email: String) async -> String? {
        guard let cal = services.calcom else { return "Cal.com is not set up." }
        let to = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BookingEmail.isValid(to) else { return "That email doesn't look right. Check it with them." }
        let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return "Add their name: it goes on the invite." }
        do {
            let b = try await cal.book(start: start, name: who, email: to)
            emailDrafts[leadID] = to
            update(leadID) { $0.email = to; $0.bookingUid = b.uid; $0.bookedFor = b.start; $0.bookingSentAt = services.now() }
            log("calcom: booked \(b.uid) for lead \(leadID)")
            objectWillChange.send()
            return nil
        } catch {
            logError("calcom: booking failed for lead \(leadID): \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Countdown button: give up on the lead's remaining numbers and move to the next lead.
    public func skipRemainingNumbers() { perform(session.handle(.skipRemainingNumbers)) }
    public var rulesInForce: DialRules { rules }

    public var dialsToday: Int {
        let now = services.now()
        return dialLog.filter { $0.kind == .attempt && services.calendar.isDate($0.ts, inSameDayAs: now) }.count
    }

    /// Dials that count against the real caps (test-number dials do not).
    public var realDialsToday: Int {
        let now = services.now()
        return dialLog.filter { $0.kind == .attempt && !rules.testKeys.contains($0.key) && services.calendar.isDate($0.ts, inSameDayAs: now) }.count
    }

    /// Dial-to-pick-up ratio for the loaded list (see PickupRate).
    public var pickupRate: PickupRate.Value {
        PickupRate.compute(log: dialLog, list: services.listName, records: services.store.all, testKeys: rules.testKeys)
    }

    /// Today's dials to the user's own test numbers (they never count against the caps).
    public var testDialsToday: Int { dialsToday - realDialsToday }

    /// "10" or, when test dials exist, "10 (10 test)": the total is every dial, the caps count only real ones.
    nonisolated public static func dialsTodayText(total: Int, test: Int) -> String {
        test > 0 ? "\(total) (\(test) test)" : "\(total)"
    }


    /// True for one of the user's own configured test numbers.
    public func isTestLead(_ lead: Lead) -> Bool { rules.testKeys.contains(lead.number) }


    private func refreshQueue() { queue = LeadQueue.build(services.leads, state: services.store.all) }

    private func alert(_ message: String) {
        logError("dialer: \(message)")
        if alerts.last != message { alerts.append(message) }
    }

    /// History is read only by the recorder. When it does not answer, the session stops dialing
    /// and says why; it never carries on without the data.
    private func historyFailed(_ error: Error, doing what: String) {
        alert("Call history could not be read \(what): \(error.localizedDescription).")
        perform(session.handle(.policyHalt(.pause(.policy(.historyUnavailable)))))
    }

    public func dismissAlerts() { alerts.removeAll() }
    public func dismissSaveNote() { saveNote = nil }

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
            alert("Call history could not be read (\(error.localizedDescription)). Dialing is blocked until the recorder answers.")
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
                           detail: capBlock?.message ?? "\(left) of \(rules.dailyCap) today.",
                           state: capBlock == nil ? .ok : .fail))
        items.append(.init(id: "history", title: "Call history",
                           detail: snapshot == nil ? "The background recorder did not answer. Is it running?" : "Reachable (cooldown and call checks).",
                           state: snapshot == nil ? .fail : .ok))
        items.append(.init(id: "dnc", title: "Do-not-call list", detail: "\(dnc.keys.count) number(s) loaded.",
                           state: logUnreadable ? .fail : .ok))
        if simDetectionActive {
            let ok = coldSIM.map { c in simValues.contains { $0.value == c } } ?? false
            items.append(.init(id: "sim", title: "Cold SIM",
                               detail: ok ? "Line recorded; every call is checked against it." : "Pick which line is the cold SIM below.",
                               state: ok ? .ok : .fail))
        } else {
            items.append(.init(id: "sim", title: "Cold SIM",
                               detail: "Cannot be read on this Mac. Set iPhone Settings > Cellular > Default Voice Line = cold SIM, and check the SIM shown in each macOS Call prompt (numbers called before use the SIM from last time).",
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
    public struct SkipUndo: Equatable, Sendable { public var leadID: String; public var title: String }
    /// The lead just skipped, offered for undo for a few seconds by the view.
    @Published public private(set) var skipUndo: SkipUndo?

    public func skipNext() {
        guard let item = nextUp else { return }
        perform(session.handle(.skipNext(leadID: item.id)))
        if queue.first(where: { $0.id == item.id })?.status == .skipped {
            skipUndo = SkipUndo(leadID: item.id, title: item.lead.title)
        }
    }

    public func undoSkip() {
        guard let u = skipUndo else { return }
        skipUndo = nil
        moveBackToQueue(u.leadID)
    }

    public func dismissSkipUndo() { skipUndo = nil }

    /// Queue-row action: puts a skipped / no-answer / called lead back to pending. Never the lead
    /// the session is working on. The cooldown still applies when it is next dialled.
    public func moveBackToQueue(_ id: String) {
        guard id != session.currentLeadID, let current = queue.first(where: { $0.id == id })?.status,
              let next = LeadStatus.afterMoveBack(current: current) else { return }
        setStatus(id, next)
        objectWillChange.send()
    }

    /// Queue-row action: the lead's number goes on the do-not-call list for good.
    public func markDoNotCall(_ id: String) {
        guard id != session.currentLeadID else { return }
        addToDNC(id)
        setStatus(id, .doNotCall)
        if skipUndo?.leadID == id { skipUndo = nil }
        objectWillChange.send()
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
                perform(session.handle(.callEnded(now: now, gap: rules.randomGap(using: &rng), minGap: rules.gapMin)))
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
        case .recordCallEnded(let id, let seconds, let connected):
            callEnded(id, seconds: seconds, connected: connected, status: connected ? .called : .noAnswer)
        case .recordUnanswered(let id, let seconds, let connected, let exhausted):
            lastWrapUpEnd = services.now()   // the minimum gap runs from here, as after a wrap-up
            callEnded(id, seconds: seconds, connected: connected, status: exhausted ? .noAnswer : nil)
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
        viewing = nil
        // A lead part-way through its numbers goes first, unless something changed its status meanwhile
        // (skipped, do-not-call, moved back): then it is no longer ours to continue.
        var next = nextUp
        var number = next?.lead.number ?? ""
        var count = 1
        if let p = numberProgress, let item = queue.first(where: { $0.id == p.leadID }), isDialable(item) {
            next = item; number = p.number; count = p.numbers.count
        } else if let item = next {
            let seq = AltNumbers.sequence(for: item.lead, dnc: dnc, enabled: services.config.tryAltNumbers)
            activeSequence = (item.id, seq); count = seq.count
        }
        var decision: DialDecision
        if logUnreadable {
            decision = .pause(.simUnverified)   // never dial without a readable log
        } else {
            var r = rules
            r.retryKeys = retryKeys()
            decision = DialPolicy.evaluate(number: number, now: now, rules: r, log: dialLog, dnc: dnc,
                                           history: snapshot?.lastCallByKey ?? [:], session: facts(), calendar: services.calendar)
            // With nothing left to dial, report the session-level answer, not "invalid number".
            if next == nil, decision == .blocked(.invalidNumber) { decision = .allowed }
        }
        perform(session.handle(.dialChecked(now: now, nextLeadID: next?.id, decision: decision, numberCount: count)))
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
        // The number to dial: the lead's main number, or the alt the session has moved on to.
        let number = numberProgress.flatMap { $0.leadID == id ? $0.number : nil } ?? lead.number
        let entry = DialLogEntry.attempt(at: now, list: services.listName, leadID: id, key: number)
        // The attempt is logged before the call is placed, so a crash can never leave an uncounted dial.
        guard append(entry) else {
            perform(session.handle(.dialFailed(message: "the dial could not be logged, so it was not placed")))
            return
        }
        attempt = entry
        dialedAt = now
        returning.remove(id)   // a returned missed call gets its one exemption
        callStart = nil   // this call's recording start, once it begins; never the previous call's
        do {
            try services.dialer.dial(number: number)
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
                if let row = SIMDetector.call(forNumber: attempt?.key ?? lead.number, dialedAt: dialedAt, rows: snap.rows) {
                    perform(session.handle(.dialResolved(.placed(seconds: row.seconds), now: services.now(),
                                                         gap: rules.randomGap(using: &rng), minGap: rules.gapMin)))
                }
            } catch { historyFailed(error, doing: "to check the dial") }
        }
    }

    /// Logs how a dial ended. `status` is the lead's new status, or nil to leave it (a multi-number
    /// lead whose next number is still to be tried).
    private func callEnded(_ id: String, seconds: Int, connected: Bool, status: LeadStatus?) {
        let ended = services.now()
        let start = callStart
        update(id) {
            if let status { $0.status = status }
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
            } catch { historyFailed(error, doing: "after the call") }
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
        var notes = notes
        // A booking link sent during this call goes into the notes, so the call's file says so too.
        if let rec = queue.first(where: { $0.id == id })?.record, let sent = rec.bookingSentAt, let email = rec.email,
           sent >= (dialedAt ?? .distantPast), !notes.contains(email) {
            if let when = rec.bookedFor {
                let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"; f.timeZone = services.calcom?.timeZone ?? .current
                notes += (notes.isEmpty ? "" : "\n") + "Meeting booked for \(f.string(from: when)), invite sent to \(email)"
            } else {
                notes += (notes.isEmpty ? "" : "\n") + "Booking link sent to \(email)"
            }
        }
        update(id) {
            $0.outcome = outcome; $0.notes = notes
            $0.status = LeadStatus.afterWrapUp(outcome: outcome, current: $0.status)
        }
        if let r = recovering, r.attempt.leadID == id {
            // Close the orphaned attempt so it is never offered again.
            _ = append(r.attempt.finished(at: services.now(), result: r.recordingStart == nil ? .noConnect : .connected,
                                          outcome: outcome))
            recovering = nil
            refreshUnfinished()
        }
        guard let lead = services.leads.leads.first(where: { $0.id == id }), let start = callStart else {
            saveNote = "Saved to the lead's record. There is no recording to attach it to."
            return
        }
        let item = PendingMarkdown(callStart: start, lead: lead, outcome: outcome, notes: notes)
        write(item)
    }

    private func write(_ item: PendingMarkdown) {
        do {
            if try services.applyToMarkdown(item.callStart, item.lead, item.outcome, item.notes) {
                saveNote = "Saved to the call's transcript"
            } else {
                pendingMarkdown.append(item)
                saveNote = "Saved. It will be added to the transcript when the transcript is ready."
            }
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
        // The main number and every alt number: a person who asked not to be called asked it of the firm.
        let now = services.now()
        for number in AltNumbers.allNumbers(of: lead) {
            do {
                try DNCList.add(number, now: now, altOf: number == lead.number ? nil : lead.number, to: services.dncURL)
            } catch { alert("Could not add \(PhoneNumber.display(number)) to the do-not-call list: \(error.localizedDescription)") }
        }
        do { dnc = try DNCList.load(from: services.dncURL) }
        catch { alert("Could not read the do-not-call list after adding to it: \(error.localizedDescription)") }
    }

    private func setStatus(_ id: String, _ status: LeadStatus) { update(id) { $0.status = status } }

    private func update(_ id: String, _ change: (inout LeadRecord) -> Void) {
        do { try services.store.update(id, now: services.now(), change) }
        catch { alert("Could not save the lead's state: \(error.localizedDescription)") }
        refreshQueue()
    }
}
