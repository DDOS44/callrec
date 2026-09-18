import AudioToolbox
import Foundation

/// Recording diagnostics go to stdout, which launchd sends to ~/.callrec/callrec.log.
func log(_ message: String) {
    print("[callrec] \(message)")
}

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
        let fmt = (try? tap.liveFormat()) ?? tap.format
        log("tap rates at start: \(tap.diagnostics)")
        let writer = try TapWavWriter(url: paths.farWav, sourceFormat: fmt)
        tap.onFormatChange = { [weak writer] newFormat in
            log(String(format: "device changed to %.0f Hz mid-call, converter updated", newFormat.mSampleRate))
            writer?.setSource(newFormat)
        }
        writer.markStart()
        try tap.start { abl, frames, host in writer.write(abl, frames: frames, hostTime: host) }
        self.tap = tap
        self.writer = writer

        let mic = try MicRecorder(url: paths.micWav)
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
            log(String(format: "far side captured %.1fs of audio over %.1fs of call (%.2fx)", far, seconds, far / seconds))
        }
        let fm = FileManager.default

        if seconds < Double(config.minCallSeconds) {
            try? fm.removeItem(at: paths.farWav)
            try? fm.removeItem(at: paths.micWav)
            return RecordingResult(paths: paths, seconds: seconds, kept: false)
        }

        guard let ffmpeg = Shell.which("ffmpeg") else {
            throw NSError(domain: "callrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg not found. Run: brew install ffmpeg"])
        }

        let mix = try Shell.run(ffmpeg, [
            "-y", "-i", paths.farWav.path, "-i", paths.micWav.path,
            // The tap file is already 16 kHz mono; the mic is at its own rate.
            "-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0,aresample=16000",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", paths.mixWav.path
        ])
        guard mix.status == 0 else {
            throw NSError(domain: "callrec", code: Int(mix.status), userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not merge the two recordings.\n\(mix.stderr.suffix(500))"])
        }

        let enc = try Shell.run(ffmpeg, ["-y", "-i", paths.mixWav.path, "-c:a", "aac", "-b:a", "64k", paths.m4a.path])
        guard enc.status == 0 else {
            throw NSError(domain: "callrec", code: Int(enc.status), userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not write the m4a.\n\(enc.stderr.suffix(500))"])
        }

        // The two tracks stay on disk: they are what tells us who said what.
        // The microphone is resampled to match the tap. Both are deleted after
        // transcription.
        let micDown = paths.micWav.deletingPathExtension().appendingPathExtension("16k.wav")
        let down = try Shell.run(ffmpeg, ["-y", "-i", paths.micWav.path, "-ac", "1", "-ar", "16000",
                                          "-c:a", "pcm_s16le", micDown.path])
        if down.status == 0 {
            try? fm.removeItem(at: paths.micWav)
            try? fm.moveItem(at: micDown, to: paths.micWav)
        }
        return RecordingResult(paths: paths, seconds: seconds, kept: true)
    }
}
