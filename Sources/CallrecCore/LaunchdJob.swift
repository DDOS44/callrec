import Foundation

/// Parses `launchctl print gui/<uid>/<label>` output. launchd is the source of
/// truth for whether the recorder is alive; the daemon's own state file can be
/// stale (it said "Watching" while the job was crash-looping with EX_CONFIG).
public enum LaunchdJob {
    public struct State: Equatable {
        public let running: Bool
        public let detail: String
    }

    public static func parse(_ out: String) -> State {
        func value(_ key: String) -> String? {
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + " = ") { return String(t.dropFirst(key.count + 3)) }
            }
            return nil
        }
        let state = value("state") ?? "unknown"
        let running = state == "running"
        var detail = "state \(state)"
        if !running, let exit = value("last exit code") { detail += ", last exit \(exit)" }
        return State(running: running, detail: detail)
    }
}
