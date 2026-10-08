import CallrecCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Left column: the list

struct DialerListColumn: View {
    @EnvironmentObject var dialer: DialerModel
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            row("Pending", "circle", .secondary, counts[.pending] ?? 0)
            row("Called", "checkmark.circle.fill", .green, counts[.called] ?? 0)
            row("No answer", "phone.down.fill", .secondary, counts[.noAnswer] ?? 0)
            row("Do not call", "nosign", .red, counts[.doNotCall] ?? 0)
            row("Skipped", "forward.fill", .orange, counts[.skipped] ?? 0)
            Divider()
            row("Dials today", "phone.arrow.up.right", .secondary, runner.dialsToday)
            if imported.filteredOut > 0 { row("Other callers", "person.2", .secondary, imported.filteredOut) }
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

    private func row(_ label: String, _ symbol: String, _ color: Color, _ n: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("\(n)").monospacedDigit()
        }
        .font(.callout)
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
        VStack(spacing: 0) {
            SessionHeader(runner: runner)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    banners
                    recovery
                    phaseCard
                    if let item = runner.current ?? runner.nextUp {
                        LeadHero(item: item, isCalling: runner.current != nil, isTest: runner.isTestLead(item.lead),
                                 calledBefore: runner.snapshot?.lastCallByKey[item.lead.number])
                    }
                    QueueSection(runner: runner)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        if let note = runner.saveNote {
            Label(note, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .task(id: note) {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    runner.dismissSaveNote()
                }
        }
        // A pause or stop that waits for the call to finish. Paused and stopped states carry
        // their reason in the header capsule.
        if runner.session.pendingHalt != nil, let text = runner.session.banner {
            Label(text, systemImage: runner.session.isRedBanner ? "exclamationmark.octagon.fill" : "pause.circle.fill")
                .font(.callout.weight(.medium))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .background(runner.session.isRedBanner ? Color.red : Color.orange, in: RoundedRectangle(cornerRadius: 10))
        }
        ForEach(Array(runner.alerts.enumerated()), id: \.offset) { _, alert in
            Label(alert, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        if !runner.alerts.isEmpty { Button("Dismiss") { runner.dismissAlerts() }.controlSize(.small) }
    }

    @ViewBuilder private var recovery: some View {
        if case .idle = phase { recoveryCards } else if case .stopped = phase { recoveryCards }
    }

    private var recoveryCards: some View {
        ForEach(runner.unfinished) { item in
            let title = runner.queue.first { $0.id == item.attempt.leadID }?.lead.title ?? item.attempt.leadID
            HStack(alignment: .firstTextBaseline, spacing: 12) {
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
            .padding(16)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Phase card

    @ViewBuilder private var phaseCard: some View {
        switch phase {
        case .countdown(let c): CountdownCard(countdown: c, runner: runner)
        case .onCall(_, let startedAt): OnCallCard(startedAt: startedAt, runner: runner)
        default: EmptyView()
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
