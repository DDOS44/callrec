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
    /// Grouped once per call, NOT per render. Grouping inside `body` re-ran over
    /// every line on every redraw — and the player redraws this view 4x a second.
    @State private var groups: [TranscriptGroup] = []
    /// Line start times, ascending, for a binary search instead of a linear
    /// scan of the whole transcript on every player tick.
    @State private var starts: [Double] = []
    /// Auto-scroll to the playing line. Turns off as soon as you scroll yourself
    /// (it used to snap back 4x a second and you couldn't scroll up while playing).
    @State private var followAudio = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                PlayerCard(player: player)
                if call.audioOnly {
                    // No .md yet, so there is nowhere to save an outcome or notes.
                    Label(model.pendingStatus(for: call), systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    outcomeSection
                    whoSection
                    transcriptSection
                    notesSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveNow).keyboardShortcut("s", modifiers: .command)
            }
        }
        .modifier(StopFollowingOnUserScroll(follow: $followAudio))
        .onAppear(perform: sync)
        .onChange(of: call.id) { sync(); followAudio = true }
        .onChange(of: model.showFiltered) { rebuildTranscript() }
        .onDisappear { saveTask?.cancel() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(call.title)
                .font(.largeTitle.weight(.semibold))
                .tracking(-0.5)
                .monospacedDigit()
            Text(subtitleLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(call.warnings, id: \.self) { warning in
                Label(warning.prefix(1).uppercased() + warning.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            if !call.warnings.isEmpty {
                Button("Open Microphone settings") { model.openMicSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var subtitleLine: String {
        var bits = [call.hasIdentity ? "\(dayLabel), \(call.time)" : dayLabel, call.durationLabel]
        if !call.identity.owner.isEmpty { bits.append(call.identity.owner) }
        if !call.identity.number.isEmpty, call.identity.number != call.title { bits.append(call.identity.number) }
        return bits.joined(separator: " · ")
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
                        // At once, not after the typing delay: counts and lists in the sidebar follow the outcome.
                        saveNow()
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
            HStack {
                SectionLabel("Transcript")
                Spacer()
                if !visibleTranscript.isEmpty {
                    Toggle(isOn: $followAudio) {
                        Label("Follow audio", systemImage: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Keep the playing line in view. Turns off when you scroll.")
                }
            }
            if visibleTranscript.isEmpty {
                Text(call.transcript.isEmpty ? "Not transcribed yet. It appears a minute or so after the call ends."
                     : "Every line in this call is filtered. Turn on \u{201C}Show filtered lines\u{201D} in the toolbar to see them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            TranscriptGroupView(group: group,
                                                currentLine: currentLine?.id,
                                                onTap: { player.seek(to: $0) })
                        }
                    }
                    // Only when the playing line CHANGES, not on every player tick.
                    .onChange(of: currentLine?.id) {
                        guard followAudio, player.playing, let id = currentLine?.id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: followAudio) {
                        guard followAudio, let id = currentLine?.id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var visibleTranscript: [TranscriptLine] {
        model.showFiltered ? call.transcript : call.transcript.filter { !$0.isFlagged }
    }

    private var currentLine: TranscriptLine? {
        guard player.duration > 0 else { return nil }
        let lines = visibleTranscript
        guard let i = Self.lastIndex(atOrBefore: player.time, in: starts), i < lines.count else { return nil }
        return lines[i]
    }

    /// Index of the last start time <= `t`, or nil if `t` precedes them all.
    /// `starts` must be ascending.
    static func lastIndex(atOrBefore t: Double, in starts: [Double]) -> Int? {
        var lo = 0, hi = starts.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Recompute grouping and the search index. Cheap, and only on real changes.
    private func rebuildTranscript() {
        let lines = visibleTranscript
        groups = TranscriptGroup.group(lines)
        starts = lines.map(\.start)
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
        rebuildTranscript()
    }

    /// Autosave a second after the last edit, so typing does not thrash the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            // Only throws when cancelled; the guard below handles that.
            // swiftlint:disable:next no_try_optional
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
    let currentLine: String?
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
                .strikethrough(line.isFlagged)
                .foregroundStyle(line.isFlagged ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if line.isFlagged {
                Text(line.flags.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(line.isFlagged ? 0.55 : 1)
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


/// Turns auto-follow off the moment the user starts scrolling (macOS 15+). On
/// macOS 14 the "Follow audio" toggle is the only control.
private struct StopFollowingOnUserScroll: ViewModifier {
    @Binding var follow: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting { follow = false }
            }
        } else {
            content
        }
    }
}
