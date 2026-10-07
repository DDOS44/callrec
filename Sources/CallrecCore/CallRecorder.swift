import AVFoundation
import AudioToolbox
import Foundation

public struct RecordingResult {
    public let paths: RecordingPaths
    public let seconds: Double
    public let kept: Bool
}

/// Runs the process tap (far side) and the microphone (near side) together,
/// then merges them into one m4a plus a 16 kHz mono wav for transcription.
@available(macOS 14.2, *)
public final class CallRecorder: @unchecked Sendable {
    public let paths: RecordingPaths
    private let config: Config
    private let startedAt: Date
    private var tap: ProcessTap?
    private var writer: TapWavWriter?
    private var mic: MicRecorder?
    private var stopped = false

    /// `basePrefix` is used by session mode so the long session file can never
    /// collide with the per-call files cut out of it.
    public init(config: Config, startedAt: Date = Date(), basePrefix: String = "") throws {
        self.config = config
        self.startedAt = startedAt
        let base = Paths.forCall(at: startedAt, root: config.recordingsURL)
        self.paths = basePrefix.isEmpty ? base : RecordingPaths(dir: base.dir, base: basePrefix + base.base)
    }

    public func start() throws {
        try Paths.ensureDir(paths.dir)

        let tap = try ProcessTap(mode: .globalExcluding([]))
        let fmt = attempt("could not read the live tap format, using the creation format") { try tap.liveFormat() } ?? tap.format
        log("tap rates at start: \(tap.diagnostics)", .capture)
        let writer = try TapWavWriter(url: paths.farCaf, sourceFormat: fmt)
        tap.onFormatChange = { [weak writer] newFormat in
            log(String(format: "device changed to %.0f Hz mid-call, converter updated", newFormat.mSampleRate), .capture)
            writer?.setSource(newFormat)
        }
        writer.markStart()
        try tap.start { abl, frames, host in writer.write(abl, frames: frames, hostTime: host) }
        self.tap = tap
        self.writer = writer

        let mic = try MicRecorder(url: paths.micCaf)
        try mic.start()
        self.mic = mic
    }

    private var farSeconds: Double?

    public func stop() throws -> RecordingResult {
        guard !stopped else { return RecordingResult(paths: paths, seconds: 0, kept: false) }
        stopped = true

        // Pad both tracks to the same stop time so they line up without ffmpeg
        // having to stretch anything.
        tap?.stop()
        writer?.padToWallClock()
        farSeconds = writer?.secondsWritten
        writer?.close()
        mic?.stop()
        tap = nil; writer = nil; mic = nil

        let seconds = Date().timeIntervalSince(startedAt)
        if let far = farSeconds, seconds > 2 {
            log(String(format: "far side captured %.1fs of audio over %.1fs of call (%.2fx)", far, seconds, far / seconds), .capture)
        }

        if seconds < Double(config.minCallSeconds) {
            for url in [paths.farCaf, paths.micCaf, paths.farWav, paths.micWav] { Fs.remove(url) }
            return RecordingResult(paths: paths, seconds: seconds, kept: false)
        }

        // Raw CAF -> 16 kHz mono wav tracks (the raw files are removed only after
        // the conversion is checked), then the mix and the m4a.
        try Finalize.tracks(paths: paths)
        TrackHealth.logWarnings(TrackHealth.check(paths: paths), id: "\(paths.dir.lastPathComponent)/\(paths.base)")
        try Finalize.mixAndEncode(paths: paths, wallClockSeconds: seconds)
        // The two tracks stay on disk: they are what tells us who said what.
        // Both are deleted after transcription.
        return RecordingResult(paths: paths, seconds: seconds, kept: true)
    }
}
