import AppKit
import CallrecCore
import SwiftUI

// Shared look: 8-pt spacing, one primary action per screen, accent colour only for state and
// the primary button. Everything here reads from the runner; nothing does work in `body`
// beyond formatting a handful of values.

private extension View {
    func card(tint: Color? = nil) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint?.opacity(0.12) ?? Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private func clock(_ seconds: TimeInterval) -> String {
    let n = max(Int(seconds), 0)
    return String(format: "%d:%02d", n / 60, n % 60)
}

// MARK: - Session header

struct SessionHeader: View {
    @ObservedObject var runner: DialRunner

    private var phase: DialSession.Phase { runner.session.phase }
    private var focus: QueueItem? { runner.current ?? runner.nextUp }

    private var position: Int? {
        guard let id = focus?.id, let i = runner.queue.firstIndex(where: { $0.id == id }) else { return nil }
        return i + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                StateCapsule(runner: runner)
                Spacer(minLength: 8)
                if let lead = focus?.lead, runner.isTestLead(lead) { TestBadge() }
                if let n = position {
                    Text("Lead \(n) of \(runner.queue.count)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            actions
            GuardrailMeters(runner: runner)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.bar)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch phase {
            case .idle, .stopped:
                Button { runner.start() } label: { Label("Start session", systemImage: "play.fill").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.nextUp == nil)
            case .paused:
                Button { runner.resume() } label: { Label("Resume", systemImage: "play.fill").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            case .preflight:
                EmptyView()
            default:
                Button { runner.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                if case .countdown = phase {
                    Button { runner.skipNext() } label: { Label("Skip", systemImage: "forward.fill") }
                }
                Button(role: .destructive) { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
        }
        .controlSize(.large)
    }
}

struct TestBadge: View {
    var body: some View {
        Label("TEST", systemImage: "testtube.2")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.purple)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .help("A number from testNumbers in your config: rehearsal, not counted against the real limits.")
    }
}

private struct StateInfo {
    var title: String
    var subtitle: String?
    var symbol: String
    var color: Color
}

private struct StateCapsule: View {
    @ObservedObject var runner: DialRunner

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let info = info(at: ctx.date)
            HStack(spacing: 12) {
                Image(systemName: info.symbol).font(.title2).foregroundStyle(info.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
                    if let sub = info.subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(info.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func info(at now: Date) -> StateInfo {
        switch runner.session.phase {
        case .idle:
            return StateInfo(title: "Ready", subtitle: runner.nextUp == nil ? "No pending leads" : nil,
                             symbol: "checkmark.circle.fill", color: .accentColor)
        case .preflight:
            return StateInfo(title: "Pre-flight check", subtitle: nil, symbol: "checklist", color: .secondary)
        case .dialing, .waitingForCall, .resolvingDial:
            return StateInfo(title: "Dialing", subtitle: "Click Call in the prompt, check the SIM",
                             symbol: "phone.arrow.up.right", color: .blue)
        case .onCall(_, let startedAt):
            return StateInfo(title: "On call \(clock(now.timeIntervalSince(startedAt)))", subtitle: nil,
                             symbol: "phone.fill", color: .red)
        case .wrapUp:
            return StateInfo(title: "Wrap-up", subtitle: "Save the outcome to continue", symbol: "square.and.pencil", color: .orange)
        case .countdown(let c):
            let left = max(Int(c.until.timeIntervalSince(now).rounded(.up)), 0)
            if c.blocked != nil { return StateInfo(title: "Waiting", subtitle: c.blocked?.message, symbol: "hourglass", color: .orange) }
            return StateInfo(title: left > 0 ? "Next call in \(left) s" : "Dialing…", subtitle: nil, symbol: "timer", color: .blue)
        case .paused(let reason):
            return StateInfo(title: "Paused", subtitle: reason.message, symbol: "pause.circle.fill", color: .orange)
        case .stopped(let reason):
            return StateInfo(title: "Stopped", subtitle: reason.message, symbol: "stop.circle.fill",
                             color: runner.session.isRedBanner ? .red : .secondary)
        }
    }
}

// MARK: - Guardrail meters

private struct GuardrailMeters: View {
    @ObservedObject var runner: DialRunner

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                Meter(title: "Today", value: runner.realDialsToday, limit: runner.rulesInForce.dailyCap)
                Meter(title: "This hour", value: runner.realDialsLastHour, limit: runner.rulesInForce.hourlyCap)
                HoursChip(status: DialPolicy.hoursStatus(now: ctx.date, rules: runner.rulesInForce, calendar: .current))
            }
        }
    }
}

private struct Meter: View {
    let title: String
    let value: Int
    let limit: Int

    private var tint: Color {
        if limit > 0, value >= limit { return .red }
        if limit > 0, Double(value) / Double(limit) >= 0.8 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(value)/\(limit)").font(.caption.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: Double(min(value, max(limit, 1))), total: Double(max(limit, 1)))
                .progressViewStyle(.linear).tint(tint)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HoursChip: View {
    let status: DialPolicy.HoursStatus

    private static let opens: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isOpen ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isOpen: Bool { if case .open = status { return true } else { return false } }

    private var text: String {
        switch status {
        case .open(let end): return String(format: "Open until %02d:%02d", end / 3600, end % 3600 / 60)
        case .closed(let opens?): return "Closed — opens \(Self.opens.string(from: opens))"
        case .closed: return "Closed — no calling day enabled"
        }
    }
}

// MARK: - Lead hero

struct LeadHero: View {
    let item: QueueItem
    let isCalling: Bool
    let isTest: Bool
    /// Last time this number appears in call history (either direction), if ever.
    var calledBefore: Date?

    @State private var copied = false

    var body: some View {
        let lead = item.lead
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isCalling ? "CALLING" : "NEXT UP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                ConfidenceDot(confidence: lead.confidence, showWord: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lead.title).font(.system(size: 28, weight: .semibold)).tracking(-0.4).lineLimit(2)
                let sub = [lead.city, lead.owner].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Text(PhoneNumber.display(lead.number)).font(.system(.title3, design: .monospaced).weight(.medium)).monospacedDigit()
                    .textSelection(.enabled)
                Button { copy(lead.number) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy the number")
            }
            if !lead.whatTheyDo.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What they do").font(.caption).foregroundStyle(.secondary)
                    Text(lead.whatTheyDo).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !lead.angle.isEmpty { AngleCallout(text: lead.angle) }
            if let when = calledBefore {
                // iPhone dials a number on the line last used with it, overriding the
                // Default Voice Line. A prospect once called from the main SIM would go
                // out on the main SIM again.
                Label("Called before on \(when.formatted(date: .abbreviated, time: .shortened)). Your iPhone may use the SIM from that call. Check the prompt.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
            }
        }
        .card()
        .onChange(of: item.id) { copied = false }
    }

    private func copy(_ number: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("+91" + number, forType: .string)
        copied = true
    }
}

private struct AngleCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "quote.opening").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("ANGLE").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(text).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConfidenceDot: View {
    let confidence: LeadConfidence
    var showWord = false

    private var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
        case .unknown: return Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            if showWord { Text(confidence.label).font(.caption).foregroundStyle(.secondary) }
        }
        .help("Confidence: \(confidence.label)")
    }
}

// MARK: - Phase cards

struct CountdownCard: View {
    let countdown: DialSession.Countdown
    @ObservedObject var runner: DialRunner

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            let left = max(Int(countdown.until.timeIntervalSince(now).rounded(.up)), 0)
            let start = countdown.minGapUntil.addingTimeInterval(-runner.rulesInForce.gapMin)
            let total = max(countdown.until.timeIntervalSince(start), 1)
            let progress = min(max(now.timeIntervalSince(start) / total, 0), 1)
            let unlockIn = max(Int(countdown.minGapUntil.timeIntervalSince(now).rounded(.up)), 0)
            HStack(spacing: 24) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                    VStack(spacing: 0) {
                        Text(left > 0 ? "\(left)" : "…").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        if left > 0 { Text("sec").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 8) {
                    if let blocked = countdown.blocked {
                        Label(blocked.message, systemImage: "hourglass").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Next call").font(.headline)
                        Text("A random gap between calls keeps the pace human.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button { runner.dialNow() } label: { Label("Dial now", systemImage: "phone.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!runner.session.canDialNow(at: now))
                        Button { runner.skipNext() } label: { Label("Skip next", systemImage: "forward.fill") }
                    }
                    .controlSize(.large)
                    if unlockIn > 0 { Text("Dial now unlocks in \(unlockIn) s").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .card()
        }
    }
}

struct OnCallCard: View {
    let startedAt: Date
    @ObservedObject var runner: DialRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("On the call").font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(clock(ctx.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Button(role: .destructive) { runner.doNotCallAgain() } label: { Label("Do not call again", systemImage: "nosign") }
                Button { runner.pauseAfterThisCall() } label: { Label("Pause after this call", systemImage: "pause") }
            }
            .controlSize(.large)
        }
        .card(tint: .red)
    }
}

// MARK: - Queue

struct QueueSection: View {
    @ObservedObject var runner: DialRunner

    var body: some View {
        let focusID = (runner.current ?? runner.nextUp)?.id
        let pending = LeadQueue.counts(runner.queue)[.pending] ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue").font(.headline)
                Text("\(pending) left of \(runner.queue.count)").font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(runner.queue) { item in
                    QueueRow(item: item, isCurrent: item.id == focusID)
                }
            }
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.lead.title).font(.body.weight(isCurrent ? .semibold : .regular)).lineLimit(1)
                let sub = [item.lead.city, item.lead.owner].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if item.status == .called, !item.record.outcome.isEmpty {
                Text(item.record.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ConfidenceDot(confidence: item.lead.confidence)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(item.status == .pending ? 1 : 0.55)
        .help(helpText)
    }

    private var helpText: String {
        switch item.status {
        case .pending: return "Pending"
        case .called: return "Called"
        case .noAnswer: return "No answer"
        case .doNotCall: return "Do not call"
        case .skipped: return "Skipped"
        }
    }

    private var symbol: String {
        switch item.status {
        case .pending: return isCurrent ? "circle.inset.filled" : "circle"
        case .called: return "checkmark.circle.fill"
        case .noAnswer: return "phone.down.fill"
        case .doNotCall: return "nosign"
        case .skipped: return "forward.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .pending: return isCurrent ? .accentColor : Color.secondary.opacity(0.6)
        case .called: return .green
        case .noAnswer: return .secondary
        case .doNotCall: return .red
        case .skipped: return .orange
        }
    }
}

// MARK: - Wrap-up

struct WrapUpSheet: View {
    @ObservedObject var runner: DialRunner
    let item: QueueItem
    let wrap: DialSession.WrapUp
    @State private var outcome: Outcome
    @State private var notes = ""
    @State private var doNotCall = false

    private static let options = Outcome.allCases.filter { $0 != .none }

    init(runner: DialRunner, item: QueueItem, wrap: DialSession.WrapUp) {
        self.runner = runner; self.item = item; self.wrap = wrap
        _outcome = State(initialValue: wrap.connected ? .none : .noConnect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How did it go with \(item.lead.title)?").font(.title2.weight(.semibold))
                Label(durationText, systemImage: wrap.connected ? "clock" : "phone.down")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Outcome").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.options.enumerated()), id: \.element) { index, option in
                        OutcomeChip(option: option, number: index + 1, selected: outcome == option) {
                            outcome = outcome == option ? .none : option
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes").font(.headline)
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 96)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("What did they say? Objections, next step, who to ask for…")
                                .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 12) {
                Image(systemName: "nosign").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Do not call again").font(.body.weight(.medium))
                    Text("Adds the number to the do-not-call list for good.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Do not call again", isOn: $doNotCall).labelsHidden().toggleStyle(.switch).tint(.red)
            }
            .padding(12)
            .background(Color.red.opacity(doNotCall ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(doNotCall ? 0.6 : 0.2), lineWidth: 1))
            HStack {
                Text("Keys 1–\(Self.options.count) pick an outcome.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(wrap.recovered ? "Save" : "Save & continue") {
                    runner.saveWrapUp(outcome: outcome.rawValue, notes: notes, doNotCall: doNotCall)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private var durationText: String {
        if wrap.recovered { return "Recovered call" }
        return wrap.connected ? "Call lasted \(clock(TimeInterval(wrap.seconds)))" : "The call did not connect"
    }
}

private struct OutcomeChip: View {
    let option: Outcome
    let number: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(option.color).frame(width: 9, height: 9)
                Text(option.rawValue).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(number)")
                    .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(selected ? option.color.opacity(0.22) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? option.color : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
    }
}
