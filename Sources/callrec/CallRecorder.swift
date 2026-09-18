import AudioToolbox
import Foundation

struct RecordingResult {
    let paths: RecordingPaths
    let seconds: Double
    let kept: Bool
}

/// Runs the process tap (far side) and the microphone (near side) together,
/// then merges them into one m4a plus a 16 kHz mono wav for transcription.
@available(macOS 14.2, *)
final class CallRecorder: @unchecked Sendable {
    let paths: RecordingPaths
    private let config: Config
    private let startedAt: Date
    private var tap: ProcessTap?
    private var writer: WavWriter?
    private var mic: MicRecorder?
    private var stopped = false

    /// `basePrefix` is used by session mode so the long session file can never
    /// collide with the per-call files cut out of it.
    init(config: Config, startedAt: Date = Date(), basePrefix: String = "") throws {
        self.config = config
        self.startedAt = startedAt
        let base = Paths.forCall(at: startedAt, root: config.recordingsURL)
        self.paths = basePrefix.isEmpty ? base : RecordingPaths(dir: base.dir, base: basePrefix + base.base)
    }

    func start() throws {
        try Paths.ensureDir(paths.dir)

        let tap = try ProcessTap(mode: .globalExcluding([]))
        let fmt = tap.format
        let writer = try WavWriter(url: paths.farWav, format: fmt)
        try tap.start { abl, frames in writer.write(abl, frames: frames) }
        self.tap = tap
        self.writer = writer

        let mic = try MicRecorder(url: paths.micWav)
        try mic.start()
        self.mic = mic
    }

    func stop() throws -> RecordingResult {
        guard !stopped else { return RecordingResult(paths: paths, seconds: 0, kept: false) }
        stopped = true

        tap?.stop(); writer?.close(); mic?.stop()
        tap = nil; writer = nil; mic = nil

        let seconds = Date().timeIntervalSince(startedAt)
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
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,aresample=16000",
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

        try? fm.removeItem(at: paths.farWav)
        try? fm.removeItem(at: paths.micWav)
        return RecordingResult(paths: paths, seconds: seconds, kept: true)
    }
}
