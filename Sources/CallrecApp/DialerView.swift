import CallrecCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Left column: the list

struct DialerListColumn: View {
    @EnvironmentObject var dialer: DialerModel
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dialer").font(.title2.weight(.semibold))
            if let imported = dialer.imported, let runner = dialer.runner {
                ListSummary(imported: imported, runner: runner, name: dialer.listName)
            } else {
                Text("Import a CSV with at least company and phone columns.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button { picking = true } label: { Label("Import list…", systemImage: "square.and.arrow.down") }
                .disabled(dialer.sessionRunning)
            if let e = dialer.error {
                Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                dialer.importList(from: url)
            case .failure(let e): dialer.error = e.localizedDescription
            }
        }
    }
}

private struct ListSummary: View {
    let imported: LeadImport
    @ObservedObject var runner: DialRunner
    let name: String

    var body: some View {
        let counts = LeadQueue.counts(runner.queue)
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline).lineLimit(2)
            row("Pending", counts[.pending] ?? 0)
            row("Called", counts[.called] ?? 0)
            row("No answer", counts[.noAnswer] ?? 0)
            row("Do not call", counts[.doNotCall] ?? 0)
            row("Skipped", counts[.skipped] ?? 0)
            Divider()
            row("Dials today", runner.dialsToday)
            if imported.filteredOut > 0 { row("Other callers", imported.filteredOut) }
            if !imported.rejected.isEmpty {
                DisclosureGroup("\(imported.rejected.count) rows rejected") {
                    ScrollView {
                        Text(imported.rejectedReport)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .foregroundStyle(.orange)
            }
            ForEach(imported.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func row(_ label: String, _ n: Int) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text("\(n)").monospacedDigit() }.font(.callout)
    }
}

// MARK: - Main column

struct DialerMainColumn: View {
    @EnvironmentObject var dialer: DialerModel

    var body: some View {
        Group {
            if let runner = dialer.runner {
                DialerSession(runner: runner)
            } else {
                ContentUnavailableView("No list yet", systemImage: "phone.arrow.up.right",
                                       description: Text("Import a CSV to start a calling session."))
            }
        }
        .navigationSplitViewColumnWidth(min: 460, ideal: 640)
    }
}

private struct DialerSession: View {
    @ObservedObject var runner: DialRunner

    private var phase: DialSession.Phase { runner.session.phase }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                banners
                stateCard
                controls
                if let item = runner.current ?? runner.nextUp {
                    LeadCard(item: item, heading: runner.current == nil ? "Next up" : "Calling",
                             calledBefore: runner.snapshot?.lastCallByKey[item.lead.number])
                }
                queue
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { phase == .preflight }, set: { _ in })) {
            PreflightSheet(runner: runner)
        }
        .sheet(isPresented: Binding(get: { if case .wrapUp = phase { return true } else { return false } }, set: { _ in })) {
            if case .wrapUp(let w) = phase, let item = runner.queue.first(where: { $0.id == w.leadID }) {
                WrapUpSheet(runner: runner, item: item, wrap: w)
            }
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let text = runner.session.banner {
            Label(text, systemImage: runner.session.isRedBanner ? "exclamationmark.octagon.fill" : "pause.circle.fill")
                .font(.callout.weight(.medium))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .background(runner.session.isRedBanner ? Color.red : Color.orange, in: RoundedRectangle(cornerRadius: 8))
        }
        ForEach(Array(runner.alerts.enumerated()), id: \.offset) { _, alert in
            Label(alert, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        if !runner.alerts.isEmpty { Button("Dismiss") { runner.dismissAlerts() }.controlSize(.small) }
    }

    // MARK: State

    @ViewBuilder private var stateCard: some View {
        switch phase {
        case .idle, .stopped:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(runner.unfinished) { item in
                    let title = runner.queue.first { $0.id == item.attempt.leadID }?.lead.title ?? item.attempt.leadID
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(title) has no wrap-up").font(.headline)
                            Text("Dialled \(item.attempt.ts.formatted(date: .omitted, time: .shortened)); the session was interrupted"
                                 + (item.recordingStart == nil ? "." : ". Notes will go into that call's transcript."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Finish wrap-up") { runner.recover(item) }.buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Not running. \(runner.dialsToday) dials today.").foregroundStyle(.secondary)
            }
        case .preflight:
            Text("Pre-flight checklist…").foregroundStyle(.secondary)
        case .dialing, .waitingForCall, .resolvingDial:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Click Call in the macOS prompt. Check it shows your cold SIM first.")
            }
        case .onCall(_, let startedAt):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("On the call").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(clock(ctx.date.timeIntervalSince(startedAt))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(role: .destructive) { runner.doNotCallAgain() } label: { Label("Do not call again", systemImage: "nosign") }
                    Button { runner.pauseAfterThisCall() } label: { Label("Pause after this call", systemImage: "pause") }
                }
            }
        case .wrapUp:
            Text("Wrap up the call to continue.").foregroundStyle(.secondary)
        case .countdown(let c):
            CountdownView(countdown: c, runner: runner)
        case .paused:
            Text("Paused. Nothing will dial until you resume.").foregroundStyle(.secondary)
        }
    }

    private func clock(_ s: TimeInterval) -> String {
        let n = max(Int(s), 0)
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            switch phase {
            case .idle, .stopped:
                Button { runner.start() } label: { Label("Start session", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.nextUp == nil)
            case .paused:
                Button { runner.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                Button(role: .destructive) { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            case .preflight:
                EmptyView()
            default:
                Button { runner.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                if case .countdown = phase {
                    Button { runner.skipNext() } label: { Label("Skip", systemImage: "forward.fill") }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Button { runner.dialNow() } label: { Label("Dial now", systemImage: "phone.fill") }
                            .disabled(!runner.session.canDialNow(at: ctx.date))
                    }
                }
                Button(role: .destructive) { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
        }
    }

    // MARK: Queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queue").font(.headline)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(runner.queue) { item in
                    QueueRow(item: item, isCurrent: item.id == runner.current?.id)
                    Divider()
                }
            }
        }
    }
}

private struct CountdownView: View {
    let countdown: DialSession.Countdown
    @ObservedObject var runner: DialRunner

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(Int(countdown.until.timeIntervalSince(ctx.date).rounded(.up)), 0)
            VStack(alignment: .leading, spacing: 6) {
                if let blocked = countdown.blocked {
                    Label(blocked.message, systemImage: "hourglass").font(.callout).foregroundStyle(.orange)
                } else if left > 0 {
                    HStack(spacing: 8) {
                        Text("Next dial in").foregroundStyle(.secondary)
                        Text("\(left)s").font(.title2.weight(.semibold)).monospacedDigit()
                    }
                } else {
                    Text("Dialing…").foregroundStyle(.secondary)
                }
                Text("A random gap between calls keeps the pace human.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Cards

private struct LeadCard: View {
    let item: QueueItem
    let heading: String
    /// Last time this number appears in call history (either direction), if ever.
    var calledBefore: Date?

    var body: some View {
        let lead = item.lead
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                ConfidenceBadge(confidence: lead.confidence)
            }
            Text(lead.title).font(.title.weight(.semibold)).tracking(-0.3)
            Text([lead.city, lead.owner.isEmpty ? nil : "Owner: \(lead.owner)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            if !lead.whatTheyDo.isEmpty { field("What they do", lead.whatTheyDo) }
            if !lead.angle.isEmpty { field("Angle", lead.angle) }
            if let when = calledBefore {
                // iPhone dials a number on the line last used with it, overriding the
                // Default Voice Line. A prospect once called from the main SIM would go
                // out on the main SIM again.
                Label("Called before on \(when.formatted(date: .abbreviated, time: .shortened)). Your iPhone may use the SIM from that call. Check the prompt.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: LeadConfidence

    var body: some View {
        Text(confidence.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
        case .unknown: return .secondary
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ConfidenceBadge(confidence: item.lead.confidence)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.lead.title).font(.body.weight(isCurrent ? .semibold : .regular)).lineLimit(1)
                Text([item.lead.city, item.lead.owner].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(label).font(.caption).foregroundStyle(color)
        }
        .padding(.vertical, 6)
    }

    private var label: String {
        switch item.status {
        case .pending: return "pending"
        case .called: return item.record.outcome.isEmpty ? "called" : item.record.outcome
        case .noAnswer: return "no answer"
        case .doNotCall: return "do not call"
        case .skipped: return "skipped"
        }
    }

    private var color: Color {
        switch item.status {
        case .pending: return .secondary
        case .called: return .blue
        case .noAnswer: return .gray
        case .doNotCall: return .red
        case .skipped: return .orange
        }
    }
}

// MARK: - Sheets

private struct PreflightSheet: View {
    @ObservedObject var runner: DialRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before the first dial").font(.title2.weight(.semibold))
            ForEach(runner.preflightItems()) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(item.state)).foregroundStyle(color(item.state)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if item.id == "sim" { simControls }
                    }
                }
            }
            Text("Use a dedicated SIM. This dialer keeps the pace human but cannot make cold calling from a 10-digit number compliant.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { runner.cancelPreflight() }.keyboardShortcut(.cancelAction)
                Button("Start dialing") { runner.passPreflight() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!runner.canPassPreflight)
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var simControls: some View {
        if runner.simDetectionActive {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent lines on this Mac:").font(.caption).foregroundStyle(.secondary)
                ForEach(runner.simValues, id: \.value) { v in
                    Button("\(v.value)  (\(v.count) calls, last \(v.lastSeen.formatted(date: .abbreviated, time: .shortened)))") {
                        runner.chooseColdSIM(v.value)
                    }
                    .controlSize(.small)
                }
            }
        } else {
            Toggle("Default Voice Line is the cold SIM, and I'll check the SIM in every Call prompt", isOn: Binding(get: { runner.preflightItems().first { $0.id == "sim" }?.state == .ok },
                                                                      set: { runner.confirmManualSIM($0) }))
        }
    }

    private func icon(_ s: PreflightItem.State) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .manual: return "hand.raised.fill"
        }
    }

    private func color(_ s: PreflightItem.State) -> Color {
        switch s {
        case .ok: return .green
        case .fail: return .red
        case .manual: return .orange
        }
    }
}

private struct WrapUpSheet: View {
    @ObservedObject var runner: DialRunner
    let item: QueueItem
    let wrap: DialSession.WrapUp
    @State private var outcome: Outcome
    @State private var notes = ""
    @State private var doNotCall = false

    init(runner: DialRunner, item: QueueItem, wrap: DialSession.WrapUp) {
        self.runner = runner; self.item = item; self.wrap = wrap
        _outcome = State(initialValue: wrap.connected ? .none : .noConnect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wrap up: \(item.lead.title)").font(.title2.weight(.semibold))
            Text(wrap.connected ? "Call lasted \(wrap.seconds / 60)m \(wrap.seconds % 60)s." : "The call did not connect.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Outcome.allCases.filter { $0 != .none && $0 != .test }) { option in
                    Button { outcome = outcome == option ? .none : option } label: { Text(option.rawValue).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .tint(outcome == option ? option.color : .secondary)
                        .background { if outcome == option { RoundedRectangle(cornerRadius: 6).fill(option.color.opacity(0.22)) } }
                }
            }
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Toggle("Do not call again", isOn: $doNotCall)
            HStack {
                Spacer()
                Button("Save") { runner.saveWrapUp(outcome: outcome.rawValue, notes: notes, doNotCall: doNotCall) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}
