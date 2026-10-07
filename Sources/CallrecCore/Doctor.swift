import Foundation

/// `callrec doctor`: finds recordings whose transcript is missing or failed.
public enum Doctor {
    public struct Issue: Equatable {
        public let day: String
        public let base: String
        public let problem: String
        public let fix: String
    }

    static let audioSuffixes = [".far.caf", ".mic.caf", ".far.wav", ".mic.wav", ".mix.wav", ".m4a"]

    /// Recording names in a day folder, from every audio and transcript file.
    public static func bases(in dir: URL) -> [String] {
        let files = Fs.list(dir)
        var out = Set<String>()
        for f in files {
            if f.hasSuffix(".md") { out.insert(String(f.dropLast(3))); continue }
            if let suffix = audioSuffixes.first(where: { f.hasSuffix($0) }) { out.insert(String(f.dropLast(suffix.count))) }
        }
        return out.sorted()
    }

    public static func hasAudio(_ paths: RecordingPaths) -> Bool {
        let fm = FileManager.default
        return [paths.m4a, paths.farCaf, paths.micCaf, paths.farWav, paths.micWav, paths.mixWav].contains { fm.fileExists(atPath: $0.path) }
    }

    public static func scan(root: URL) -> [Issue] {
        let fm = FileManager.default
        var issues: [Issue] = []
        let days = Fs.list(root).filter { $0.count == 10 }.sorted()
        for day in days {
            let dir = root.appendingPathComponent(day)
            for base in bases(in: dir) {
                let paths = RecordingPaths(dir: dir, base: base)
                let isSession = base.hasPrefix("session-")
                let fix: String
                if isSession {
                    let file = fm.fileExists(atPath: paths.m4a.path) ? paths.m4a : paths.mixWav
                    fix = "callrec transcribe \"\(file.path)\""
                } else {
                    fix = "callrec retranscribe \(day)/\(base)"
                }
                // Raw capture with no finished m4a: the recorder was killed mid-call. The
                // raw CAF is intact; retranscribe rebuilds the tracks and the m4a first.
                if !isSession, Finalize.isInterrupted(paths) {
                    issues.append(Issue(day: day, base: base,
                                        problem: "interrupted recording: raw capture left behind, no finished audio", fix: fix))
                } else if let text = Fs.text(paths.md) {
                    if let err = MarkdownFields.error(md: text) {
                        issues.append(Issue(day: day, base: base, problem: "error: \(err)", fix: fix))
                    }
                } else if hasAudio(paths) {
                    issues.append(Issue(day: day, base: base, problem: "audio but no .md", fix: fix))
                }
            }
        }
        return issues
    }

    /// Recordings that transcribed fine but contain no speech (digital silence,
    /// an unanswered call). Informational: nothing to fix.
    public static func noSpeech(root: URL) -> [String] {
        var out: [String] = []
        let days = Fs.list(root).filter { $0.count == 10 }.sorted()
        for day in days {
            let dir = root.appendingPathComponent(day)
            for base in bases(in: dir) {
                let paths = RecordingPaths(dir: dir, base: base)
                if let text = Fs.text(paths.md), MarkdownFields.hasNoSpeech(md: text) {
                    out.append("\(day)/\(base)")
                }
            }
        }
        return out
    }

    /// Calls whose transcript carries a `- warning:` header (a silent track).
    /// `sinceDay` ("yyyy-MM-dd") limits the scan to recent days.
    public static func warnings(root: URL, sinceDay: String? = nil) -> [(id: String, warning: String)] {
        var out: [(id: String, warning: String)] = []
        let days = Fs.list(root).filter { $0.count == 10 && (sinceDay == nil || $0 >= sinceDay!) }.sorted()
        for day in days {
            let dir = root.appendingPathComponent(day)
            for base in bases(in: dir) {
                guard let text = Fs.text(RecordingPaths(dir: dir, base: base).md) else { continue }
                for w in MarkdownFields.warnings(md: text) { out.append(("\(day)/\(base)", w)) }
            }
        }
        return out
    }

    public struct CrashReport: Equatable {
        public let name: String
        public let date: Date
        public let path: String
    }

    public static var diagnosticReportsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// macOS writes a report for every crash of `callrec` (the daemon) and
    /// `callrec-app` (the app). Newest first.
    public static func crashReports(in dir: URL = diagnosticReportsURL) -> [CrashReport] {
        let exts = [".ips", ".crash", ".diag"]
        return Fs.list(dir)
            .filter { name in
                let lower = name.lowercased()
                return lower.hasPrefix("callrec") && exts.contains { lower.hasSuffix($0) }
            }
            .compactMap { name -> CrashReport? in
                let url = dir.appendingPathComponent(name)
                do {
                    let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return CrashReport(name: name, date: date ?? .distantPast, path: url.path)
                } catch {
                    log("could not stat crash report \(url.path): \(error.localizedDescription)")
                    return CrashReport(name: name, date: .distantPast, path: url.path)
                }
            }
            .sorted { $0.date > $1.date }
    }

    /// Prints the report and returns the number of problems found.
    @discardableResult
    public static func run(config: Config) -> Int {
        let issues = scan(root: config.recordingsURL)
        let quiet = noSpeech(root: config.recordingsURL)
        defer {
            let warned = warnings(root: config.recordingsURL)
            if !warned.isEmpty {
                print("doctor: \(warned.count) recording(s) have a capture warning:")
                for w in warned { print("  \(w.id): \(w.warning)") }
                print("  fix: System Settings → Privacy & Security → Microphone → callrec (and Screen & System Audio Recording)")
            }
            reportCrashes()
            if !quiet.isEmpty {
                print("doctor: no speech detected in \(quiet.count) recording(s) (not a failure, nothing to fix): \(quiet.joined(separator: ", "))")
            }
        }
        if issues.isEmpty {
            print("doctor: all recordings under \(config.recordingsURL.path) have a transcript.")
            return 0
        }
        print("doctor: \(issues.count) recording(s) need attention")
        for i in issues {
            print("\(i.day)/\(i.base): \(i.problem)")
            print("  fix: \(i.fix)")
        }
        return issues.count
    }

    private static func reportCrashes() {
        let crashes = crashReports()
        if crashes.isEmpty {
            print("doctor: no callrec crash reports in \(diagnosticReportsURL.path).")
            return
        }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm"
        print("doctor: \(crashes.count) callrec crash report(s) in \(diagnosticReportsURL.path), newest first:")
        for c in crashes.prefix(5) { print("  \(stamp.string(from: c.date))  \(c.path)") }
        if crashes.count > 5 { print("  ... and \(crashes.count - 5) older") }
    }
}
