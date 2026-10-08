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
    /// Names and words the model should expect (your name, company, products).
    /// Passed as a decoding prompt so it writes "Blaxify" instead of "black sifai".
    /// Kept in ~/.callrec/config.json, never in code: the public repo has no personal data.
    public var vocabulary: [String] = []
    /// Label lines "Me"/"Them" from the two tracks. Off by default: on speakerphone the
    /// mic hears both people, so per-track labels were wrong and the merge scrambled
    /// the order. Off = one chronological transcript of the whole call.
    public var speakerLabels = false

    // Power dialer guardrails (docs/specs/power-dialer.md). Every value is enforced by
    // DialPolicy; these are the defaults.
    /// Dial attempts per calendar day, any list.
    public var dailyCap = 30
    /// Dial attempts per rolling 60 minutes.
    public var hourlyCap = 10
    /// Random gap in seconds [min, max] between the end of wrap-up and the next dial.
    public var gapSeconds = [45, 120]
    /// Local "HH:mm" start and end (end is exclusive).
    public var callingHours = ["10:00", "18:30"]
    /// ISO weekdays, 1 = Monday ... 7 = Sunday.
    public var callingDays = [1, 2, 3, 4, 5, 6]
    /// A number is never redialled within this many days.
    public var cooldownDays = 7
    /// Expected SIM/line value for the cold-calling SIM, captured at pre-flight. "" = not set.
    public var coldSIM = ""
    /// Pause the session when this many numbers are added to the do-not-call list in one day.
    public var dncPausePerDay = 3
    /// Pause after this many consecutive dials that fail to connect or are shorter than `shortCallSeconds`.
    public var failurePauseCount = 3
    public var shortCallSeconds = 5
    /// No call started this many seconds after dialing: mark "not placed" and pause.
    public var notPlacedTimeoutSeconds = 45
    /// Default list for the Dialer (a CSV under ~/.callrec/lists/). Empty = pick one in the app.
    public var dialerListPath = ""
    /// Only dial rows whose `caller` column equals this. Empty = every row.
    public var dialerCaller = ""
    /// YOUR OWN numbers for testing the dialer. Exempt from calling hours, the 7-day
    /// no-redial and the caps (test dials don't count toward them), with a 10 s gap,
    /// and may repeat in a list. Never put a prospect here. Config only, never in code.
    public var testNumbers: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case recordingsDir, modelFolder, vadModelPath, announcementPhrases, language, triggerBundleIDs, leadsCSV
        case minCallSeconds, stopAfterSilentSeconds, vocabulary, speakerLabels
        case dailyCap, hourlyCap, gapSeconds, callingHours, callingDays, cooldownDays, coldSIM
        case dncPausePerDay, failurePauseCount, shortCallSeconds, notPlacedTimeoutSeconds
        case dialerListPath, dialerCaller, testNumbers
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
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? vocabulary
        speakerLabels = try c.decodeIfPresent(Bool.self, forKey: .speakerLabels) ?? speakerLabels
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? dailyCap
        hourlyCap = try c.decodeIfPresent(Int.self, forKey: .hourlyCap) ?? hourlyCap
        gapSeconds = try c.decodeIfPresent([Int].self, forKey: .gapSeconds) ?? gapSeconds
        callingHours = try c.decodeIfPresent([String].self, forKey: .callingHours) ?? callingHours
        callingDays = try c.decodeIfPresent([Int].self, forKey: .callingDays) ?? callingDays
        cooldownDays = try c.decodeIfPresent(Int.self, forKey: .cooldownDays) ?? cooldownDays
        coldSIM = try c.decodeIfPresent(String.self, forKey: .coldSIM) ?? coldSIM
        dncPausePerDay = try c.decodeIfPresent(Int.self, forKey: .dncPausePerDay) ?? dncPausePerDay
        failurePauseCount = try c.decodeIfPresent(Int.self, forKey: .failurePauseCount) ?? failurePauseCount
        shortCallSeconds = try c.decodeIfPresent(Int.self, forKey: .shortCallSeconds) ?? shortCallSeconds
        notPlacedTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .notPlacedTimeoutSeconds) ?? notPlacedTimeoutSeconds
        dialerListPath = try c.decodeIfPresent(String.self, forKey: .dialerListPath) ?? dialerListPath
        dialerCaller = try c.decodeIfPresent(String.self, forKey: .dialerCaller) ?? dialerCaller
        testNumbers = try c.decodeIfPresent([String].self, forKey: .testNumbers) ?? testNumbers
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
