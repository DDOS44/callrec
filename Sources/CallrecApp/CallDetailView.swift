import CallrecCore
import SwiftUI

struct CallDetailView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var player = Player()
    let call: Call

    @State private var outcome: Outcome = .none
    @State private var who = ""
    @State private var notes = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                PlayerCard(player: player)
                outcomeSection
                whoSection
                transcriptSection
                notesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveNow).keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear(perform: sync)
        .onDisappear { saveTask?.cancel() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(call.time)
                .font(.largeTitle.weight(.semibold))
                .tracking(-0.5)
                .monospacedDigit()
            Text("\(dayLabel) · \(call.durationLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        return f.string(from: call.date)
    }

    private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Outcome")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Outcome.allCases.filter { $0 != .none }) { option in
                    Button {
                        outcome = (outcome == option) ? .none : option
                        scheduleSave()
                    } label: {
                        Text(option.rawValue)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(outcome == option ? option.color : .secondary)
                    .background {
                        if outcome == option {
                            RoundedRectangle(cornerRadius: 6).fill(option.color.opacity(0.22))
                        }
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 1.0), value: outcome)
        }
    }

    private var whoSection: some View {
        LabeledContent("Who picked up") {
            TextField("name", text: $who)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onChange(of: who) { scheduleSave() }
        }
        .font(.body)
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Transcript")
            if call.transcript.isEmpty {
                Text("Not transcribed yet. It appears a minute or so after the call ends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(TranscriptGroup.group(call.transcript)) { group in
                            TranscriptGroupView(group: group,
                                                currentLine: currentLine?.id,
                                                onTap: { player.seek(to: $0) })
                        }
                    }
                    .onChange(of: player.time) {
                        guard player.playing, let current = call.transcript.last(where: { $0.start <= player.time }) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var currentLine: TranscriptLine? {
        guard player.duration > 0 else { return nil }
        return call.transcript.last(where: { $0.start <= player.time })
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Notes")
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: notes) { scheduleSave() }
        }
    }

    // MARK: Saving

    private func sync() {
        outcome = Outcome(rawValue: call.outcome) ?? .none
        who = call.who
        notes = call.notes
        player.load(call.audio)
    }

    /// Autosave a second after the last edit, so typing does not thrash the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        var updated = call
        updated.outcome = outcome.rawValue
        updated.who = who
        updated.notes = notes
        guard updated.outcome != call.outcome || updated.who != call.who || updated.notes != call.notes else { return }
        model.save(updated)
        model.flashSaved()
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
    }
}

struct TranscriptGroupView: View {
    let group: TranscriptGroup
    let currentLine: UUID?
    let onTap: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if group.speaker != .unknown {
                Text(group.speaker == .me ? "You" : "Them")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.speaker == .me ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .padding(.leading, 8)
            }
            ForEach(group.lines) { line in
                TranscriptRow(line: line,
                              isCurrent: currentLine == line.id,
                              onTap: { onTap(line.start) })
                    .id(line.id)
            }
        }
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(line.stamp, action: onTap)
                .buttonStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Text(line.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

struct PlayerCard: View {
    @ObservedObject var player: Player

    var body: some View {
        HStack(spacing: 14) {
            Button(action: player.toggle) {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(player.duration == 0)
            .keyboardShortcut(.space, modifiers: [])

            Button { player.seek(to: player.time - 10) } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button { player.seek(to: player.time + 10) } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(Player.clock(player.time))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()

            Slider(value: Binding(get: { min(player.time, max(player.duration, 1)) },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))

            Text("-" + Player.clock(max(player.duration - player.time, 0)))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
