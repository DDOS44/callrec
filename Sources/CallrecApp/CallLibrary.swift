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

    /// What the row leads with: the company, else the contact, else the number,
    /// else just the time.
    var title: String {
        for candidate in [identity.company, identity.contact, identity.number] where !candidate.isEmpty {
            return candidate
        }
        return time
    }

    var hasIdentity: Bool { !identity.isEmpty }

    var subtitle: String {
        var bits: [String] = []
        if !identity.owner.isEmpty { bits.append(identity.owner) }
        if !identity.number.isEmpty, identity.number != title { bits.append(identity.number) }
        return bits.joined(separator: " · ")
    }

    var durationLabel: String {
        let s = Int(seconds)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    var searchText: String { (transcript.map(\.text) + [notes, who, outcome]).joined(separator: " ").lowercased() }
    var connected: Bool { seconds >= 20 }
    /// Test calls are excluded from the counters.
    var isTest: Bool { outcome == Outcome.test.rawValue }
    var booked: Bool { outcome.lowercased() == "booked" }

    static func == (a: Call, b: Call) -> Bool { a.id == b.id && a.outcome == b.outcome && a.who == b.who && a.notes == b.notes }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct TranscriptLine: Identifiable, Hashable {
    let id = UUID()
    let start: Double
    let text: String
    var speaker: Speaker = .unknown
    var stamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
}

/// Consecutive lines from the same person, so a back-and-forth reads as a
/// conversation rather than a list.
struct TranscriptGroup: Identifiable {
    let id = UUID()
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

    static func load() -> [Day] {
        let fm = FileManager.default
        let dayNames = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.count == 10 && $0.contains("-") }
            .sorted(by: >)

        return dayNames.compactMap { name in
            let dir = root.appendingPathComponent(name)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".md") && !$0.hasPrefix("session-") }
                .sorted(by: >)
            let calls = files.compactMap { call(day: name, mdName: $0, dir: dir) }
            return calls.isEmpty ? nil : Day(name: name, calls: calls)
        }
    }

    private static func call(day: String, mdName: String, dir: URL) -> Call? {
        let mdURL = dir.appendingPathComponent(mdName)
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return nil }
        let time = String(mdName.dropLast(3))
        let fields = MarkdownFields.read(md: md)
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
            preview: MarkdownFields.firstTranscriptLine(md: md),
            transcript: MarkdownFields.segments(md: md).map {
                TranscriptLine(start: $0.start, text: $0.text, speaker: $0.speaker)
            }
        )
    }

    static func save(_ call: Call) throws {
        let md = try String(contentsOf: call.markdown, encoding: .utf8)
        let updated = MarkdownFields.update(md: md, outcome: call.outcome, who: call.who, notes: call.notes)
        try updated.write(to: call.markdown, atomically: true, encoding: .utf8)
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
