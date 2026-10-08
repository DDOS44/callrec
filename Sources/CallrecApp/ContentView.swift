import CallrecCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } content: {
            if model.selectedDay == AppModel.dialerTag { DialerListColumn() }
            else if model.selectedDay == AppModel.calendarTag { CalendarColumn() }
            else { CallListColumn() }
        } detail: {
            if model.selectedDay == AppModel.dialerTag { DialerMainColumn() } else { DetailColumn() }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search transcripts and notes")
        .toolbar {
            ToolbarItem(placement: .status) { StatusPill() }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.showFiltered) {
                    Label("Show filtered lines", systemImage: "eye.slash")
                }
                .toggleStyle(.button)
                .help("Show filtered lines: bleed, operator announcements, suspected loops. Display only; the file is never changed.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(model.current == nil)
                .help("Reveal the recording in Finder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(model.selectedCalls.isEmpty || model.selectedDay == AppModel.dialerTag)
                .help("Move the selected calls to the Trash")
            }
        }
        .navigationTitle("callrec")
        .frame(minWidth: 980, minHeight: 620)
        .alert(model.trashPrompt, isPresented: Binding(get: { !model.pendingTrash.isEmpty }, set: { if !$0 { model.pendingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text(model.trashDetail)
        }
        .alert("Could not move to the Trash", isPresented: Binding(get: { model.trashProblem != nil }, set: { if !$0 { model.trashProblem = nil } })) {
            Button("OK") { model.trashProblem = nil }
        } message: {
            Text(model.trashProblem ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedDay) {
            Section("Dialer") {
                Label("Power dialer", systemImage: "phone.arrow.up.right")
                    .tag(AppModel.dialerTag)
            }
            Section("Calendar") {
                Label("Calendar", systemImage: "calendar.day.timeline.left")
                    .tag(AppModel.calendarTag)
            }
            Section("Outcomes") {
                ForEach(Outcome.allCases.filter { $0 != .none }) { outcome in
                    OutcomeRow(name: outcome.rawValue, color: outcome.color, count: model.outcomeCounts[outcome.rawValue] ?? 0)
                        .tag(AppModel.outcomeTag(outcome.rawValue))
                }
                OutcomeRow(name: "Untagged", color: .secondary, count: model.outcomeCounts[OutcomeBuckets.untagged] ?? 0)
                    .tag(AppModel.outcomeTag(OutcomeBuckets.untagged))
            }
            Section("Days") {
                Label("All calls", systemImage: "tray.full")
                    .badge(model.allCalls.count)
                    .tag(AppModel.allDaysTag)
                ForEach(model.filteredDays) { day in
                    Label(day.pretty, systemImage: icon(for: day))
                        .badge(day.calls.count)
                        .tag(day.name)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
    }

    private func icon(for day: Day) -> String {
        day.pretty == "Today" ? "calendar.badge.clock" : "calendar"
    }
}

private struct OutcomeRow: View {
    let name: String
    let color: Color
    let count: Int

    var body: some View {
        Label {
            Text(name)
        } icon: {
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .badge(count)
    }
}

// MARK: - Call list

struct CallListColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatsHeader()
            Divider()
            CallListBody()
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        .navigationTitle(model.columnTitle)
    }
}

/// The list of calls in the middle column, with the empty state. Shared by the day list and the calendar.
struct CallListBody: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.visibleCalls.isEmpty {
            emptyState
        } else {
            List(selection: Binding(get: { model.selectedCalls }, set: { model.setSelection($0) })) {
                if model.selectedOutcomeBucket != nil {
                    ForEach(model.outcomeDays) { day in
                        Section(day.pretty) {
                            ForEach(day.calls) { call in CallRow(call: call).tag(call.id) }
                        }
                    }
                } else {
                    ForEach(model.visibleCalls) { call in
                        CallRow(call: call, showDay: model.selectedDay == AppModel.allDaysTag).tag(call.id)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Move to Trash…", systemImage: "trash") { model.requestTrash(ids) }
            }
            .onDeleteCommand { model.requestTrash() }
            // No .alternatingRowBackgrounds(): it keeps painting striped
            // rows below the last call, which read as empty placeholders.
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.search.isEmpty ? "phone.badge.waveform" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(model.search.isEmpty ? emptyTitle : "Nothing matches \u{201C}\(model.search)\u{201D}")
                .font(.headline)
            Text(model.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        if model.selectedDay == AppModel.calendarTag { return "No calls on this day" }
        if model.selectedOutcomeBucket != nil { return "No calls with this outcome" }
        return "No calls yet today"
    }
}

struct CallRow: View {
    @EnvironmentObject var model: AppModel
    let call: Call
    var showDay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(call.title)
                    .font(call.hasIdentity ? .body.weight(.medium)
                                           : .system(.body, design: .rounded).monospacedDigit().weight(.medium))
                    .lineLimit(1)
                if call.hasIdentity {
                    Text(call.time)
                        .font(.system(.caption, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(call.durationLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 4)
                if let outcome = Outcome(rawValue: call.outcome), outcome != .none {
                    OutcomeCapsule(outcome: outcome)
                }
            }
            HStack(spacing: 6) {
                if showDay {
                    Text(call.day)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(call.audioOnly ? model.pendingStatus(for: call)
                     : (call.subtitle.isEmpty ? (call.preview.isEmpty ? "No transcript yet" : call.preview) : call.subtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

struct OutcomeCapsule: View {
    let outcome: Outcome

    var body: some View {
        Text(outcome.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(outcome.color.opacity(0.18), in: Capsule())
            .foregroundStyle(outcome.color)
    }
}

// MARK: - Stats

struct StatsHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $model.statsRange) {
                ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 0) {
                stat("\(model.visibleStats.dials)", "dials")
                stat("\(model.visibleStats.connects)", "connects")
                stat("\(model.visibleStats.booked)", "booked")
                stat(talk(model.visibleStats.talk), "talk")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: model.statsRange)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func talk(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        return m >= 60 ? "\(m / 60)h\(m % 60)" : "\(m)m"
    }
}

// MARK: - Status

struct StatusPill: View {
    @EnvironmentObject var model: AppModel
    @State private var showDetails = false

    /// Anything the user may need to act on: the pill shows an (i) inside itself.
    private var hasNotes: Bool {
        !model.healthy || model.modelPreparing || model.modelError != nil
            || !model.permissionProblems.isEmpty || model.callHistoryHint != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            if model.savedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity)
            }
            // One capsule, one click target: dot, label, timer and (i) all live inside it.
            Button { showDetails.toggle() } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(model.statusWord)
                        .font(.callout)
                        .foregroundStyle(model.healthy ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if let timer = model.recordingClock {
                        Text(timer)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    // Always reserve the glyph's space so the capsule never changes width.
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(hasNotes ? 1 : 0)
                }
                // Wide enough for the longest label ("Preparing speech model…") plus the timer slot.
                .frame(minWidth: 220, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Recorder status")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
            .animation(.easeInOut(duration: 0.3), value: model.recordingSince != nil)
        }
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: model.savedFlash)
    }

    private var dotColor: Color {
        if model.recordingSince != nil { return .red }
        if !model.healthy { return .secondary }
        return model.modelPreparing || !model.permissionProblems.isEmpty ? .orange : .green
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.statusLine).font(.headline)
            if !model.healthy {
                note("The background recorder is not running, so calls are not being recorded.")
                Button("Start recorder") { model.setAgent(running: true); showDetails = false }
            }
            if model.modelPreparing {
                note("Preparing the speech model. This is a one-time step after an update and can take several minutes. Calls are still recorded and are transcribed once it is ready.")
            }
            if let err = model.modelError {
                note("The speech model failed to load: \(err)")
            }
            if !model.permissionProblems.isEmpty {
                note("Permissions: \(model.permissionProblems.joined(separator: ", ")). A missing one records silence.")
                HStack {
                    Button("Microphone settings") { model.openMicSettings() }
                    Button("System audio settings") { model.openAudioSettings() }
                }
            }
            if let hint = model.callHistoryHint { note(hint) }
            if model.healthy, !model.modelPreparing, model.modelError == nil,
               model.permissionProblems.isEmpty, model.callHistoryHint == nil {
                note("Everything is working.")
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Detail

struct DetailColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let call = model.current {
                CallDetailView(call: call).id(call.id)
            } else {
                ContentUnavailableView(
                    "Select a call",
                    systemImage: "phone",
                    description: Text("Pick a call on the left to hear it and read the transcript.")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
    }
}
