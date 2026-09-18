import CallrecCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } content: {
            CallListColumn()
        } detail: {
            DetailColumn()
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search transcripts and notes")
        .toolbar {
            ToolbarItem(placement: .status) { StatusPill() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(model.current == nil)
                .help("Reveal the recording in Finder")
            }
        }
        .navigationTitle("callrec")
        .frame(minWidth: 980, minHeight: 620)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedDay) {
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

// MARK: - Call list

struct CallListColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatsHeader()
            Divider()
            if model.visibleCalls.isEmpty {
                emptyState
            } else {
                List(model.visibleCalls, selection: $model.selectedCall) { call in
                    CallRow(call: call, showDay: model.selectedDay == AppModel.allDaysTag)
                        .tag(call.id)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        .navigationTitle(model.columnTitle)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.search.isEmpty ? "phone.badge.waveform" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(model.search.isEmpty ? "No calls yet today" : "Nothing matches “\(model.search)”")
                .font(.headline)
            Text(model.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct CallRow: View {
    let call: Call
    var showDay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(call.time)
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .fontWeight(.medium)
                Text(call.durationLabel)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .monospacedDigit()
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
                Text(call.preview.isEmpty ? "No transcript yet" : call.preview)
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

    var body: some View {
        HStack(spacing: 10) {
            if model.savedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(model.recordingSince != nil ? Color.red : (model.healthy ? .green : .secondary))
                    .frame(width: 7, height: 7)
                Text(model.statusLine)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(model.healthy ? .primary : .secondary)
            }
            if !model.healthy {
                Button("Start recorder") { model.setAgent(running: true) }
                    .controlSize(.small)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: model.savedFlash)
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
