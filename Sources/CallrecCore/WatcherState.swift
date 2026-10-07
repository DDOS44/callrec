import Foundation

/// `~/.callrec/state.json`: what the daemon is doing, read by `callrec status` and the app.
/// The daemon is the only writer. Every field added after the first release is
/// optional, so an older daemon's file still decodes.
public struct WatcherState: Codable, Equatable {
    public var state: String          // "idle" | "recording"
    public var since: String          // ISO8601
    public var lastCall: String?
    /// Permission as macOS reports it to the daemon: "authorized", "denied", ...
    public var microphone: String?
    public var systemAudio: String?
    /// "<day>/<time>" of the call being transcribed right now, nil when idle.
    public var transcribing: String?
    /// False while the speech model loads at start-up (the first load after an update
    /// recompiles it, which takes minutes). nil from an older daemon: treat as ready.
    public var modelReady: Bool?
    /// Why the model failed to load, if it did.
    public var modelError: String?

    /// True when the daemon is still preparing the speech model.
    public var preparingModel: Bool { modelReady == false && modelError == nil }

    public init(state: String, since: String, lastCall: String? = nil,
                microphone: String? = nil, systemAudio: String? = nil, transcribing: String? = nil,
                modelReady: Bool? = nil, modelError: String? = nil) {
        self.modelReady = modelReady
        self.modelError = modelError
        self.transcribing = transcribing
        self.state = state
        self.since = since
        self.lastCall = lastCall
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public static var url: URL {
        Config.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    /// Plain-language problems with the recorded permissions, empty when fine or unknown.
    public var permissionProblems: [String] {
        var out: [String] = []
        if let m = microphone, m != "authorized" { out.append("microphone is \(m)") }
        if let s = systemAudio, s != "authorized" { out.append("system audio is \(s)") }
        return out
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatcherState {
        try JSONDecoder().decode(WatcherState.self, from: data)
    }
}
