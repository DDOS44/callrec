import Foundation

struct Config: Codable {
    var recordingsDir = "~/CallRecordings"
    var modelPath = "~/.callrec/models/ggml-large-v3-turbo.bin"
    var language = "en"            // whisper -l; "auto" allowed
    var glossary = ["Blaxify", "Devansh", "Anurag", "recruitment", "closures", "joinings",
                    "CTC", "requirement", "outreach", "AI cold outreach",
                    "haan ji", "boliye", "theek hai", "bas", "dijiye"]
    // Task 0 spike: com.apple.avconferenced is the process that goes live
    // exactly when a Continuity call connects.
    var triggerBundleIDs = ["com.apple.avconferenced"]
    var minCallSeconds = 8          // shorter recordings are deleted (misdials, no pickup)
    var stopAfterSilentSeconds = 3  // watcher: process stops output for this long => call ended

    /// Overridable for tests and for pointing the watcher at another app.
    nonisolated(unsafe) static var url: URL = {
        if let override = ProcessInfo.processInfo.environment["CALLREC_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".callrec/config.json")
    }()

    static func load() -> Config {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Config.url)
    }

    var recordingsURL: URL { URL(fileURLWithPath: (recordingsDir as NSString).expandingTildeInPath) }
    var modelURL: URL { URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath) }
}
