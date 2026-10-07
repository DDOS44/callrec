import Foundation

public struct Config: Codable, Sendable {
    public var recordingsDir = "~/CallRecordings"
    /// WhisperKit CoreML export of Oriserve/Whisper-Hindi2Hinglish-Apex, loaded
    /// from disk only (see scripts/download-model.sh).
    public var modelFolder = "~/.callrec/models/whisperkit/Oriserve_Whisper-Hindi2Hinglish-Apex"
    public var vadModelPath = "~/.callrec/models/silero-vad/silero-vad-unified-v6.0.0.mlmodelc"
    public var announcementPhrases = Announcements.defaultPhrases
    // Must stay "en". This model is a Hindi-to-Hinglish fine-tune that writes
    // Roman Hinglish only when told the language is English: "hi" produced
    // garbage and leaving the language out produced empty output (measured in
    // the 2026-10 benchmark). Counterintuitive, but it is how the model works.
    public var language = "en"
    // Task 0 spike: com.apple.avconferenced is the process that goes live
    // exactly when a Continuity call connects.
    public var triggerBundleIDs = ["com.apple.avconferenced"]
    public var leadsCSV = ""  // optional: path to your own leads CSV
    public var minCallSeconds = 8          // shorter recordings are deleted (misdials, no pickup)
    public var stopAfterSilentSeconds = 6  // watcher: process stops output for this long => call ended

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case recordingsDir, modelFolder, vadModelPath, announcementPhrases, language, triggerBundleIDs, leadsCSV
        case minCallSeconds, stopAfterSilentSeconds
    }

    /// Every key is optional so a config written by an older build, or by hand
    /// with only the keys that matter, still loads instead of resetting to defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingsDir = try c.decodeIfPresent(String.self, forKey: .recordingsDir) ?? recordingsDir
        modelFolder = try c.decodeIfPresent(String.self, forKey: .modelFolder) ?? modelFolder
        vadModelPath = try c.decodeIfPresent(String.self, forKey: .vadModelPath) ?? vadModelPath
        announcementPhrases = try c.decodeIfPresent([String].self, forKey: .announcementPhrases) ?? announcementPhrases
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        triggerBundleIDs = try c.decodeIfPresent([String].self, forKey: .triggerBundleIDs) ?? triggerBundleIDs
        leadsCSV = try c.decodeIfPresent(String.self, forKey: .leadsCSV) ?? leadsCSV
        minCallSeconds = try c.decodeIfPresent(Int.self, forKey: .minCallSeconds) ?? minCallSeconds
        stopAfterSilentSeconds = try c.decodeIfPresent(Int.self, forKey: .stopAfterSilentSeconds) ?? stopAfterSilentSeconds
    }

    /// Overridable for tests and for pointing the watcher at another app.
    public nonisolated(unsafe) static var url: URL = {
        if let override = ProcessInfo.processInfo.environment["CALLREC_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".callrec/config.json")
    }()

    public static func load() -> Config {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            // No config yet is normal. Anything else (permissions, I/O) is not.
            if !Fs.isMissing(error) { log("could not read \(url.path), using defaults: \(error.localizedDescription)") }
            return Config()
        }
        do { return try JSONDecoder().decode(Config.self, from: data) }
        catch {
            log("\(url.path) is not valid, using defaults: \(error.localizedDescription)")
            return Config()
        }
    }

    public func save() throws {
        try Paths.ensureDir(Config.url.deletingLastPathComponent())
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Config.url)
    }

    public var recordingsURL: URL { URL(fileURLWithPath: (recordingsDir as NSString).expandingTildeInPath) }
    public var leadsURL: URL { URL(fileURLWithPath: (leadsCSV as NSString).expandingTildeInPath) }

    public var modelFolderURL: URL { URL(fileURLWithPath: (modelFolder as NSString).expandingTildeInPath) }
    public var vadModelURL: URL { URL(fileURLWithPath: (vadModelPath as NSString).expandingTildeInPath) }
}
