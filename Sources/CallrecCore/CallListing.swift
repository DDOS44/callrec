import Foundation

/// What a day folder holds for one recording, worked out from file names alone.
/// A call exists if it has audio OR a transcript: a call whose transcription is
/// still running (or failed before writing anything) must not be invisible.
public struct CallEntry: Equatable {
    public let base: String
    public let hasMarkdown: Bool
    /// The file the player should open: the finished m4a, else a raw track. nil when only a .md exists.
    public let audioFile: String?
    /// No finished audio and no transcript: raw capture only (recording now, or interrupted).
    public let rawOnly: Bool

    public var audioOnly: Bool { !hasMarkdown && audioFile != nil }
}

public enum CallListing {
    /// Best file to play, most finished first.
    static let audioPreference = [".m4a", ".far.wav", ".far.caf", ".mic.wav", ".mic.caf"]

    /// One entry per recording, newest (largest base) first. Session files and hidden files are skipped.
    public static func entries(files: [String]) -> [CallEntry] {
        var bases: [String: (md: Bool, audio: [String])] = [:]
        for f in files where !f.hasPrefix(".") && !f.hasPrefix("session-") {
            if f.hasSuffix(".md") {
                bases[String(f.dropLast(3)), default: (false, [])].md = true
            } else if let suffix = audioPreference.first(where: { f.hasSuffix($0) }) {
                bases[String(f.dropLast(suffix.count)), default: (false, [])].audio.append(suffix)
            }
        }
        return bases.map { base, v in
            let best = audioPreference.first { v.audio.contains($0) }
            return CallEntry(base: base, hasMarkdown: v.md, audioFile: best.map { base + $0 },
                             rawOnly: !v.md && !v.audio.contains(".m4a") && !v.audio.isEmpty)
        }
        .sorted { $0.base > $1.base }
    }
}
