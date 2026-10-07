import Foundation

/// Where the dialer keeps its files: all under `~/.callrec/` next to the config,
/// never in the repo. Directories 0700, files 0600 (the process umask is 077).
public enum DialerPaths {
    public static var home: URL { Config.url.deletingLastPathComponent() }
    public static var dialLog: URL { home.appendingPathComponent("dial-log.jsonl") }
    public static var dnc: URL { home.appendingPathComponent("dnc.txt") }
    public static var listsDir: URL { home.appendingPathComponent("lists") }
    public static func stateURL(forList csv: URL) -> URL {
        let name = csv.deletingPathExtension().lastPathComponent
        return csv.deletingLastPathComponent().appendingPathComponent("\(name).state.json")
    }
}
