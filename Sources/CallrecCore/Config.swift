import Foundation

public struct Config: Codable {
    public var recordingsDir = "~/CallRecordings"
    public var modelPath = "~/.callrec/models/ggml-large-v3-turbo.bin"
    // "hi" plus a Roman-script Hinglish prompt is what produces readable Roman
    // Hinglish. "en" and "auto" translate the call into mangled English.
    public var language = "hi"
    public var prompt = "Haan ji, boliye. Theek hai. Devansh Blaxify se bol raha hoon. Hum recruitment agencies ko naye clients dilate hain, AI cold outreach se. Closures, joinings, CTC, requirement, outreach, meeting, Thursday ya Friday. Kya haal hai bhai."
    // Task 0 spike: com.apple.avconferenced is the process that goes live
    // exactly when a Continuity call connects.
    public var triggerBundleIDs = ["com.apple.avconferenced"]
    public var leadsCSV = "~/Documents/Claude OS /references/call-sheet-2026-09-18.csv"
    public var minCallSeconds = 8          // shorter recordings are deleted (misdials, no pickup)
    public var stopAfterSilentSeconds = 6  // watcher: process stops output for this long => call ended

    /// Overridable for tests and for pointing the watcher at another app.
    public nonisolated(unsafe) static var url: URL = {
        if let override = ProcessInfo.processInfo.environment["CALLREC_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".callrec/config.json")
    }()

    public static func load() -> Config {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Config.url)
    }

    public var recordingsURL: URL { URL(fileURLWithPath: (recordingsDir as NSString).expandingTildeInPath) }
    public var leadsURL: URL { URL(fileURLWithPath: (leadsCSV as NSString).expandingTildeInPath) }
    public var modelURL: URL { URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath) }
}
