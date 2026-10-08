import CallrecCore
import Foundation
import SwiftUI

/// One recorded call on disk.
struct Call: Identifiable, Hashable {
    let id: String              // "2026-09-18/21-32-47"
    let day: String
    let time: String
    let audio: URL
    let markdown: URL
    var date: Date
    var seconds: Double
    var outcome: String
    var identity: CallIdentity
    var who: String
    var notes: String
    var preview: String
    var transcript: [TranscriptLine]
    /// Header `- warning:` lines, e.g. a silent mic track.
    var warnings: [String] = []
    /// Audio on disk but no transcript yet (still transcribing, or it never ran).
    var audioOnly = false
    /// Raw capture only: being recorded right now, or an interrupted recording.
    var rawOnly = false

    /// What the row leads with: the company, else the contact, else the formatted number,
    /// else just the time.
    var title: String {
        for candidate in [identity.company, identity.contact] where !candidate.isEmpty { return candidate }
        if !identity.number.isEmpty { return PhoneNumber.display(identity.number) }
        return time
    }

    var hasIdentity: Bool { !identity.isEmpty }

    /// True when the title is a company or contact name (so the number is worth showing too).
    var hasName: Bool { !identity.company.isEmpty || !identity.contact.isEmpty }

    var subtitle: String {
        var bits: [String] = []
        if !identity.owner.isEmpty { bits.append(identity.owner) }
        if hasName, !identity.number.isEmpty { bits.append(PhoneNumber.display(identity.number)) }
        return bits.joined(separator: " · ")
    }

    var durationLabel: String {
        let s = Int(seconds)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    var searchText: String { (transcript.filter { !$0.isFlagged }.map(\.text) + [notes, who, outcome]).joined(separator: " ").lowercased() }
    var connected: Bool { seconds >= 20 }
    /// Test calls are excluded from the counters.
    var isTest: Bool { outcome == Outcome.test.rawValue }
    var facts: CallFacts { CallFacts(date: date, seconds: seconds, outcome: outcome) }
    var booked: Bool { outcome.lowercased() == "booked" }

    static func == (a: Call, b: Call) -> Bool { a.id == b.id && a.outcome == b.outcome && a.who == b.who && a.notes == b.notes }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct TranscriptLine: Identifiable, Hashable {
    /// Derived from position in the file, NOT a fresh UUID. A new UUID per parse
    /// gives every row a new identity on every reload, so SwiftUI tears down and
    /// rebuilds the whole transcript instead of reusing it. Keep this stable.
    let id: String
    let start: Double
    let text: String
    var speaker: Speaker = .unknown
    /// Set by the pipeline (bleed, operator, loop). Flagged lines are hidden unless asked for.
    var flags: [String] = []
    var isFlagged: Bool { !flags.isEmpty }
    var stamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
}

/// Consecutive lines from the same person, so a back-and-forth reads as a
/// conversation rather than a list.
struct TranscriptGroup: Identifiable {
    /// Stable for the same reason as TranscriptLine.id — the first line's id.
    var id: String { lines.first?.id ?? "empty" }
    let speaker: Speaker
    var lines: [TranscriptLine]
    var start: Double { lines.first?.start ?? 0 }

    static func group(_ lines: [TranscriptLine]) -> [TranscriptGroup] {
        var out: [TranscriptGroup] = []
        for line in lines {
            if var last = out.last, last.speaker == line.speaker {
                last.lines.append(line)
                out[out.count - 1] = last
            } else {
                out.append(TranscriptGroup(speaker: line.speaker, lines: [line]))
            }
        }
        return out
    }
}

struct Day: Identifiable, Hashable {
    var id: String { name }
    let name: String            // "2026-09-18"
    var calls: [Call]
    var pretty: String {
        let inF = DateFormatter(); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: name) else { return name }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let out = DateFormatter(); out.dateFormat = "EEE d MMM"
        return out.string(from: d)
    }
}

enum Library {
    static var root: URL { Config.load().recordingsURL }

    /// Parsed calls by file identity. Only changed files are re-read, so a reload
    /// after one new transcript costs one parse, not hundreds.
    private static let cache = ParseCache<Call>()

    /// Safe to call off the main thread (it is the slow part, and AppModel does).
    static func load() -> [Day] {
        Log.interval("library.load") {
            let root = Self.root
            cache.beginPass()
            var seen = Set<String>()
            let dayNames = Fs.list(root)
                .filter { $0.count == 10 && $0.contains("-") }
                .sorted(by: >)

            let days: [Day] = dayNames.compactMap { name in
                let dir = root.appendingPathComponent(name)
                // A call is listed if it has audio or a transcript, never only the latter.
                let calls: [Call] = CallListing.entries(files: Fs.list(dir)).compactMap { entry in
                    if entry.hasMarkdown {
                        let url = dir.appendingPathComponent(entry.base + ".md")
                        seen.insert(url.path)
                        return cache.value(for: url) { call(day: name, mdName: entry.base + ".md", dir: dir, mdURL: $0) }
                    }
                    guard let audioName = entry.audioFile else { return nil }
                    let url = dir.appendingPathComponent(audioName)
                    seen.insert(url.path)
                    return cache.value(for: url) { audioOnlyCall(day: name, entry: entry, dir: dir, audioURL: $0) }
                }
                return calls.isEmpty ? nil : Day(name: name, calls: calls)
            }
            cache.prune(keeping: seen)
            return days
        }
    }

    private static func audioOnlyCall(day: String, entry: CallEntry, dir: URL, audioURL: URL) -> Call? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return Call(id: "\(day)/\(entry.base)", day: day, time: entry.base.replacingOccurrences(of: "-", with: ":"),
                    audio: audioURL, markdown: dir.appendingPathComponent(entry.base + ".md"),
                    date: f.date(from: "\(day) \(entry.base)") ?? Date(),
                    seconds: Media.duration(of: audioURL) ?? 0, outcome: "", identity: CallIdentity(),
                    who: "", notes: "", preview: "", transcript: [], warnings: [],
                    audioOnly: true, rawOnly: entry.rawOnly)
    }

    private static func call(day: String, mdName: String, dir: URL, mdURL: URL) -> Call? {
        guard let md = Fs.text(mdURL) else { return nil }
        let time = String(mdName.dropLast(3))
        let fields = MarkdownFields.read(md: md)
        // Parse the transcript once: this used to run twice per call, and the
        // whole library reparses on every file change.
        let segments = MarkdownFields.segments(md: md)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return Call(
            id: "\(day)/\(time)",
            day: day,
            time: time.replacingOccurrences(of: "-", with: ":"),
            audio: dir.appendingPathComponent(time + ".m4a"),
            markdown: mdURL,
            date: f.date(from: "\(day) \(time)") ?? Date(),
            seconds: MarkdownFields.duration(md: md),
            outcome: fields.outcome,
            identity: MarkdownFields.identity(md: md),
            who: fields.who,
            notes: fields.notes,
            preview: preview(for: segments, md: md),
            transcript: segments.enumerated().map { index, seg in
                TranscriptLine(id: "\(day)/\(time)#\(index)",
                               start: seg.start, text: seg.text,
                               speaker: seg.speaker, flags: seg.flags)
            },
            warnings: MarkdownFields.warnings(md: md)
        )
    }

    /// What the other person said first is the useful line; fall back to mine.
    private static func preview(for segments: [Segment], md: String) -> String {
        let shown = segments.filter { $0.flags.isEmpty }
        if let them = shown.first(where: { $0.speaker == .them }) { return them.text }
        if let me = shown.first(where: { $0.speaker == .me }) { return me.text }
        if let any = segments.first { return any.text }
        return MarkdownFields.firstTranscriptLine(md: md)
    }

    static func save(_ call: Call) throws {
        // Read-modify-write under the shared lock; replaces only outcome, who and notes.
        try MarkdownStore.saveHumanFields(call.markdown, outcome: call.outcome, who: call.who, notes: call.notes)
    }
}

enum Outcome: String, CaseIterable, Identifiable {
    case none = ""
    case noConnect = "no connect"
    case gatekeeper = "gatekeeper"
    case pitched = "pitched"
    case booked = "booked"
    case notInterested = "not interested"
    case callback = "callback"
    case nurture = "nurture"
    case test = "test"

    /// Outcome names a call can carry (everything except "no outcome").
    static let knownNames: [String] = allCases.filter { $0 != .none }.map(\.rawValue)

    var id: String { rawValue }
    var label: String { self == .none ? "clear" : rawValue }

    var color: Color {
        switch self {
        case .booked: return .green
        case .callback: return .orange
        case .notInterested: return .gray
        case .pitched: return .blue
        case .gatekeeper: return .purple
        case .nurture: return .teal
        case .test: return .gray
        case .noConnect, .none: return .secondary
        }
    }
}
