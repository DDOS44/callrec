import Foundation

public enum PauseReason: Equatable, Sendable {
    /// The user pressed Pause.
    case user
    /// The user pressed "Pause after this call".
    case afterThisCall
    /// No call started within the timeout after dialing; the dial is marked not placed.
    case notPlaced
    /// macOS refused to open the call, or the dial could not be logged first.
    case dialFailed(String)
    case policy(DialPause)

    public var message: String {
        switch self {
        case .user: return "Paused."
        case .afterThisCall: return "Paused after the call, as requested."
        case .notPlaced: return "No call started after dialing, so it was marked not placed. Check the iPhone, then resume."
        case .dialFailed(let m): return "The call could not be started: \(m)"
        case .policy(let p): return p.message
        }
    }
}

public enum StopReason: Equatable, Sendable {
    case user
    case listExhausted
    case policy(DialStop)

    public var message: String {
        switch self {
        case .user: return "Stopped."
        case .listExhausted: return "No more leads to call in this list."
        case .policy(let s): return s.message
        }
    }
}

/// A pause or stop that takes effect as soon as it is safe (after the call and its wrap-up),
/// or immediately when nothing is in progress.
public enum DialHalt: Equatable, Sendable {
    case pause(PauseReason)
    case stop(StopReason)

    public var message: String {
        switch self {
        case .pause(let r): return r.message
        case .stop(let r): return r.message
        }
    }
}

/// What the dial session decides to do, as data. The runner performs these; the
/// state machine itself touches no clock, file or phone.
public enum DialEffect: Equatable, Sendable {
    /// Ask the policy whether the next lead may be dialled now, then send `.dialChecked`.
    case evaluateNext
    /// Log the attempt, then open the call. Send `.dialPlaced` or `.dialFailed`.
    case dial(leadID: String)
    case recordNotPlaced(leadID: String)
    /// The dial was not seen as a call: look in call history, then send `.dialResolved`.
    case lookUpCall(leadID: String, dialedAt: Date)
    /// The call ended: log the result and read its line. `connected` is false for a call that rang out.
    case recordCallEnded(leadID: String, seconds: Int, connected: Bool)
    /// A number of a multi-number lead did not connect (rang out, or was shorter than the short-call
    /// threshold). Log the result; no wrap-up. `exhausted`: it was the lead's last number, so the lead
    /// is done (no answer). Otherwise the lead stays pending and its next number is dialled.
    case recordUnanswered(leadID: String, seconds: Int, connected: Bool, exhausted: Bool)
    case saveWrapUp(leadID: String, outcome: String, notes: String)
    case addToDoNotCall(leadID: String)
    case setLeadStatus(leadID: String, status: LeadStatus)
}

public enum DialEvent: Equatable, Sendable {
    case start
    case preflightPassed(now: Date)
    case preflightCancelled
    case tick(now: Date)
    /// The runner's answer to `.evaluateNext`. `next` is nil when the list is exhausted.
    /// `numberCount`: how many numbers the lead has in its dial sequence (main + usable alts).
    case dialChecked(now: Date, nextLeadID: String?, decision: DialDecision, numberCount: Int = 1)
    case dialPlaced(now: Date)
    case dialFailed(message: String)
    case callStarted(now: Date)
    /// `gap`/`minGap` are used only when the call did not connect and the lead has another number to try.
    case callEnded(now: Date, gap: TimeInterval = 0, minGap: TimeInterval = 0)
    case dialResolved(DialResolution, now: Date, gap: TimeInterval = 0, minGap: TimeInterval = 0)
    /// Save in the wrap-up sheet. `gap` is the random gap, drawn by the runner.
    case wrapUpSaved(now: Date, outcome: String, notes: String, doNotCall: Bool, gap: TimeInterval, minGap: TimeInterval)
    /// Open a wrap-up for a call left unfinished by an interrupted session. Idle/stopped only.
    case recover(leadID: String)
    case doNotCallAgain
    /// Countdown before an alt number: give up on the lead's remaining numbers (status no answer).
    case skipRemainingNumbers
    case pauseAfterThisCall
    case pause
    case resume(now: Date, gap: TimeInterval, minGap: TimeInterval)
    case skipNext(leadID: String)
    case dialNow(now: Date)
    case stop
    /// The policy found a stop or pause reason after a call (wrong SIM, a barred call...).
    case policyHalt(DialHalt)
}

public enum DialResolution: Equatable, Sendable {
    /// Call history shows the call was placed (it rang, or ran `seconds`) though no recording started.
    case placed(seconds: Int)
    case notPlaced
}

/// The dial session as a pure state machine: idle, preflight, dialing, waitingForCall,
/// onCall, wrapUp, countdown, plus paused and stopped with a reason. Events in, effects
/// out. An event that makes no sense in the current phase is ignored, never a crash.
public struct DialSession: Equatable, Sendable {

    public struct WrapUp: Equatable, Sendable {
        public var leadID: String
        public var seconds: Int
        /// False when the call rang out and never connected.
        public var connected: Bool
        /// Finishing a call from an interrupted session: saving returns to idle, no next dial.
        public var recovered: Bool = false
    }

    public struct Countdown: Equatable, Sendable {
        /// When the next dial is due.
        public var until: Date
        /// "Dial now" is allowed from this moment (the minimum gap since wrap-up).
        public var minGapUntil: Date
        /// Why the dial is held back right now, if it is.
        public var blocked: DialBlock?
        /// The next dial is another number of the lead just tried (an alt), not a new lead.
        public var altFallback: Bool = false
        /// ...and it follows a number that did not connect (false when only resuming on that number).
        public var afterNoAnswer: Bool = false
    }

    /// Where a lead stands in its dial sequence. `index` is the number being dialled, or due next.
    public struct NumberPlan: Equatable, Sendable {
        public var leadID: String
        public var count: Int
        public var index: Int
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case preflight
        case dialing(leadID: String)
        case waitingForCall(leadID: String, since: Date)
        case resolvingDial(leadID: String, since: Date)
        case onCall(leadID: String, startedAt: Date)
        case wrapUp(WrapUp)
        case countdown(Countdown)
        case paused(PauseReason)
        case stopped(StopReason)
    }

    public private(set) var phase: Phase = .idle
    /// A pause or stop waiting for the call and its wrap-up to finish.
    public private(set) var pendingHalt: DialHalt?
    public private(set) var dials = 0
    public private(set) var calls = 0
    /// The current lead's dial sequence position; nil between leads.
    public private(set) var numberPlan: NumberPlan?

    /// A connected call shorter than this counts as not connected (see `Config.shortCallSeconds`).
    public var shortCallSeconds: Int

    /// No call this many seconds after dialing: look in call history, else not placed.
    public var notPlacedTimeout: TimeInterval
    /// Extra seconds a ringing call may take to show up in call history before it is declared not placed.
    public var resolveGrace: TimeInterval = 75

    public init(notPlacedTimeout: TimeInterval = 45, shortCallSeconds: Int = 5) {
        self.notPlacedTimeout = notPlacedTimeout
        self.shortCallSeconds = shortCallSeconds
    }

    public var currentLeadID: String? {
        switch phase {
        case .dialing(let id), .waitingForCall(let id, _), .resolvingDial(let id, _), .onCall(let id, _): return id
        case .wrapUp(let w): return w.leadID
        default: return nil
        }
    }

    /// True while the session owns the phone line: dialing, ringing, on a call or wrapping one up.
    public var isBusy: Bool { currentLeadID != nil }

    public var isRunning: Bool {
        switch phase {
        case .idle, .stopped: return false
        default: return true
        }
    }

    /// The message to show in a banner, from a halt that is waiting or already in force.
    public var banner: String? {
        if let h = pendingHalt {
            // A user Stop waiting on a call is not in force yet: say what will happen.
            // Policy halts and pauses keep their own messages, which already say so.
            if case .stop(.user) = h { return "Will stop after this call." }
            return h.message
        }
        switch phase {
        case .paused(let r): return r.message
        case .stopped(let r): return r.message
        default: return nil
        }
    }

    public var isRedBanner: Bool {
        if case .stop(.policy) = pendingHalt { return true }
        if case .stopped(.policy) = phase { return true }
        return false
    }

    public func canDialNow(at now: Date) -> Bool {
        if case .countdown(let c) = phase { return now >= c.minGapUntil }
        return false
    }

    // MARK: - Events

    @discardableResult
    public mutating func handle(_ event: DialEvent) -> [DialEffect] {
        switch event {
        case .start: return start()
        case .preflightPassed(let now): return preflightPassed(now)
        case .preflightCancelled:
            if phase == .preflight { phase = .idle }
            return []
        case .tick(let now): return tick(now)
        case .dialChecked(let now, let next, let decision, let count): return dialChecked(now, next, decision, count)
        case .dialPlaced(let now): return dialPlaced(now)
        case .dialFailed(let message): return dialFailed(message)
        case .callStarted(let now): return callStarted(now)
        case .callEnded(let now, let gap, let minGap): return callEnded(now, gap, minGap)
        case .dialResolved(let r, let now, let gap, let minGap): return dialResolved(r, now, gap, minGap)
        case .wrapUpSaved(let now, let outcome, let notes, let dnc, let gap, let minGap):
            return wrapUpSaved(now, outcome, notes, dnc, gap, minGap)
        case .doNotCallAgain:
            guard let id = currentLeadID else { return [] }
            numberPlan = nil   // the lead is finished: its remaining numbers are never dialled
            return [.addToDoNotCall(leadID: id), .setLeadStatus(leadID: id, status: .doNotCall)]
        case .skipRemainingNumbers:
            guard case .countdown(var c) = phase, c.altFallback, let plan = numberPlan else { return [] }
            numberPlan = nil
            c.altFallback = false; c.afterNoAnswer = false
            phase = .countdown(c)
            return [.setLeadStatus(leadID: plan.leadID, status: .noAnswer)]
        case .pauseAfterThisCall: return request(.pause(.afterThisCall))
        case .pause: return request(.pause(.user))
        case .resume(let now, let gap, let minGap): return resume(now, gap, minGap)
        case .skipNext(let id):
            guard case .countdown = phase else { return [] }
            return [.setLeadStatus(leadID: id, status: .skipped)]
        case .dialNow(let now):
            guard case .countdown(var c) = phase, now >= c.minGapUntil else { return [] }
            c.until = now
            phase = .countdown(c)
            return [.evaluateNext]
        case .stop: return request(.stop(.user))
        case .recover(let id):
            switch phase {
            case .idle, .stopped:
                phase = .wrapUp(WrapUp(leadID: id, seconds: 0, connected: true, recovered: true))
            default: break
            }
            return []
        case .policyHalt(let halt): return request(halt)
        }
    }

    // MARK: - Transitions

    private mutating func start() -> [DialEffect] {
        switch phase {
        case .idle, .stopped:
            self = DialSession(notPlacedTimeout: notPlacedTimeout, shortCallSeconds: shortCallSeconds)
            phase = .preflight
        default: break
        }
        return []
    }

    private mutating func preflightPassed(_ now: Date) -> [DialEffect] {
        guard phase == .preflight else { return [] }
        // The first dial has no gap to wait for.
        phase = .countdown(Countdown(until: now, minGapUntil: now, blocked: nil))
        return [.evaluateNext]
    }

    private mutating func tick(_ now: Date) -> [DialEffect] {
        switch phase {
        case .countdown(let c):
            return now >= c.until ? [.evaluateNext] : []
        case .waitingForCall(let id, let since):
            guard now.timeIntervalSince(since) >= notPlacedTimeout else { return [] }
            phase = .resolvingDial(leadID: id, since: since)
            return [.lookUpCall(leadID: id, dialedAt: since)]
        case .resolvingDial(let id, let since):
            if now.timeIntervalSince(since) >= notPlacedTimeout + resolveGrace {
                return notPlaced(id)
            }
            return [.lookUpCall(leadID: id, dialedAt: since)]
        default:
            return []
        }
    }

    private mutating func dialChecked(_ now: Date, _ next: String?, _ decision: DialDecision, _ numberCount: Int) -> [DialEffect] {
        guard case .countdown(var c) = phase else { return [] }
        switch decision {
        case .stop(let s):
            phase = .stopped(.policy(s))
            return []
        case .pause(let p):
            phase = .paused(.policy(p))
            return []
        case .blocked(let b):
            if b == .coldSIMNotConfirmed {
                phase = .paused(.dialFailed(b.message))
                return []
            }
            if b.isLeadSpecific, let next, let plan = numberPlan, plan.leadID == next, plan.index > 0 {
                // An alt number is the problem (cooldown, do-not-call): skip it, never the lead.
                if let i = AltNumbers.advance(from: plan.index, count: plan.count) {
                    numberPlan?.index = i
                    return [.evaluateNext]
                }
                numberPlan = nil
                return [.setLeadStatus(leadID: next, status: .noAnswer), .evaluateNext]
            }
            if b.isLeadSpecific, let next {
                numberPlan = nil
                // This lead is the problem, not the moment: mark it and move to the next one.
                let status: LeadStatus = b == .doNotCall ? .doNotCall : .skipped
                return [.setLeadStatus(leadID: next, status: status), .evaluateNext]
            }
            c.blocked = b
            // Keep asking while blocked; the countdown just shows why.
            c.until = min(c.until, now)
            phase = .countdown(c)
            return []
        case .allowed:
            guard let next else {
                phase = .stopped(.listExhausted)
                return []
            }
            if numberPlan?.leadID != next { numberPlan = NumberPlan(leadID: next, count: max(numberCount, 1), index: 0) }
            dials += 1
            phase = .dialing(leadID: next)
            return [.dial(leadID: next)]
        }
    }

    private mutating func dialPlaced(_ now: Date) -> [DialEffect] {
        guard case .dialing(let id) = phase else { return [] }
        phase = .waitingForCall(leadID: id, since: now)
        return []
    }

    private mutating func dialFailed(_ message: String) -> [DialEffect] {
        guard case .dialing(let id) = phase else { return [] }
        phase = .paused(.dialFailed(message))
        let effects: [DialEffect] = [.recordNotPlaced(leadID: id)]
        applyHaltIfAny()
        return effects
    }

    private mutating func notPlaced(_ id: String) -> [DialEffect] {
        phase = .paused(.notPlaced)
        applyHaltIfAny()
        return [.recordNotPlaced(leadID: id)]
    }

    private mutating func callStarted(_ now: Date) -> [DialEffect] {
        switch phase {
        case .waitingForCall(let id, _), .resolvingDial(let id, _):
            phase = .onCall(leadID: id, startedAt: now)
        default: break   // a call we did not place: the policy blocks dialing while it is active
        }
        return []
    }

    /// A number did not connect. With another number left on the lead, the next dial goes to it;
    /// with none left the lead is done. Either way there is no wrap-up. nil when the lead has only
    /// one number: that keeps today's behaviour (a wrap-up sheet).
    private mutating func unanswered(_ id: String, seconds: Int, connected: Bool, now: Date,
                                     gap: TimeInterval, minGap: TimeInterval) -> [DialEffect]? {
        guard let plan = numberPlan, plan.leadID == id, plan.count > 1 else { return nil }
        let next = AltNumbers.advance(from: plan.index, count: plan.count)
        if let next { numberPlan?.index = next } else { numberPlan = nil }
        phase = .countdown(Countdown(until: now.addingTimeInterval(gap), minGapUntil: now.addingTimeInterval(minGap),
                                     blocked: nil, altFallback: next != nil, afterNoAnswer: next != nil))
        applyHaltIfAny()
        return [.recordUnanswered(leadID: id, seconds: seconds, connected: connected, exhausted: next == nil)]
    }

    private mutating func callEnded(_ now: Date, _ gap: TimeInterval, _ minGap: TimeInterval) -> [DialEffect] {
        guard case .onCall(let id, let startedAt) = phase else { return [] }
        let seconds = max(Int(now.timeIntervalSince(startedAt).rounded()), 0)
        calls += 1
        if seconds < shortCallSeconds,
           let effects = unanswered(id, seconds: seconds, connected: true, now: now, gap: gap, minGap: minGap) {
            return effects
        }
        numberPlan = nil
        phase = .wrapUp(WrapUp(leadID: id, seconds: seconds, connected: true))
        return [.recordCallEnded(leadID: id, seconds: seconds, connected: true)]
    }

    private mutating func dialResolved(_ resolution: DialResolution, _ now: Date,
                                       _ gap: TimeInterval, _ minGap: TimeInterval) -> [DialEffect] {
        guard case .resolvingDial(let id, _) = phase else { return [] }
        switch resolution {
        case .notPlaced:
            return notPlaced(id)
        case .placed(let seconds):
            // It rang (or ran) without a recording starting: wrap it up as a call that did not connect.
            calls += 1
            // A ring-out is an unanswered number. History showing a real conversation (no recording
            // started) still gets its wrap-up.
            if seconds < shortCallSeconds,
               let effects = unanswered(id, seconds: seconds, connected: false, now: now, gap: gap, minGap: minGap) {
                return effects
            }
            numberPlan = nil
            phase = .wrapUp(WrapUp(leadID: id, seconds: seconds, connected: false))
            return [.recordCallEnded(leadID: id, seconds: seconds, connected: false)]
        }
    }

    private mutating func wrapUpSaved(_ now: Date, _ outcome: String, _ notes: String, _ dnc: Bool,
                                      _ gap: TimeInterval, _ minGap: TimeInterval) -> [DialEffect] {
        guard case .wrapUp(let w) = phase else { return [] }
        var effects: [DialEffect] = [.saveWrapUp(leadID: w.leadID, outcome: outcome, notes: notes)]
        if dnc { effects += [.addToDoNotCall(leadID: w.leadID), .setLeadStatus(leadID: w.leadID, status: .doNotCall)] }
        if w.recovered { phase = .idle; return effects }
        numberPlan = nil
        phase = .countdown(Countdown(until: now.addingTimeInterval(gap), minGapUntil: now.addingTimeInterval(minGap), blocked: nil))
        applyHaltIfAny()
        return effects
    }

    private mutating func resume(_ now: Date, _ gap: TimeInterval, _ minGap: TimeInterval) -> [DialEffect] {
        guard case .paused = phase else { return [] }
        pendingHalt = nil
        // Resuming mid-lead (paused between a lead's numbers, or its dial was not placed): the lead's
        // next number is still due, not a new lead.
        phase = .countdown(Countdown(until: now.addingTimeInterval(gap), minGapUntil: now.addingTimeInterval(minGap),
                                     blocked: nil, altFallback: (numberPlan?.index ?? 0) > 0))
        return []
    }

    /// A halt is applied at once when nothing is in progress, otherwise it waits for the
    /// call and wrap-up. A stop outranks a pause; the first pause is kept.
    private mutating func request(_ halt: DialHalt) -> [DialEffect] {
        switch phase {
        case .idle, .stopped: return []
        case .paused:
            if case .stop(let r) = halt { phase = .stopped(r) }
            return []
        case .preflight, .countdown:
            phase = Self.phase(for: halt)
        case .dialing, .waitingForCall, .resolvingDial:
            // No conversation yet, so nothing to protect: a Stop takes effect now
            // (it used to wait up to ~2 min for the not-placed timeout while the UI
            // said "Stopped" over a "Dialing…" spinner). A pause still waits, so a call
            // that does connect gets its wrap-up.
            // The attempt is already in the dial log, so it is closed as not placed here:
            // left open it would resurface later as a phantom "has no wrap-up" card.
            if case .stop = halt, let id = currentLeadID {
                pendingHalt = nil
                phase = Self.phase(for: halt)
                return [.recordNotPlaced(leadID: id)]
            }
            if pendingHalt == nil { pendingHalt = halt }
        case .onCall, .wrapUp:
            // Mid-call or wrap-up: wait, so notes are never lost.
            if case .stop = halt { pendingHalt = halt }
            else if pendingHalt == nil { pendingHalt = halt }
        }
        return []
    }

    private mutating func applyHaltIfAny() {
        guard let halt = pendingHalt else { return }
        pendingHalt = nil
        // A pause that arrives with the session already paused for a reason keeps that reason.
        if case .pause(let r) = halt, case .paused = phase {
            // "History unavailable" explains more than "not placed" does: let it win.
            if case .policy(.historyUnavailable) = r { phase = .paused(r) }
            return
        }
        phase = Self.phase(for: halt)
    }

    private static func phase(for halt: DialHalt) -> Phase {
        switch halt {
        case .pause(let r): return .paused(r)
        case .stop(let r): return .stopped(r)
        }
    }
}
