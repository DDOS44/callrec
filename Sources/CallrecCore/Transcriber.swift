import Foundation

public enum Transcriber {

    /// Transcribes a wav. Audio longer than 10 minutes is cut into chunks on
    /// silences, each is transcribed on its own, and the timestamps are shifted
    /// back onto the full recording's timeline.
    public static func transcribe(wav: URL, config: Config) throws -> [Segment] {
        try Log.interval("transcribe") { try transcribeChunked(wav: wav, config: config) }
    }

    private static func transcribeChunked(wav: URL, config: Config) throws -> [Segment] {
        guard let total = Media.duration(of: wav), total > Chunking.maxChunkSeconds,
              let ffmpeg = Shell.which("ffmpeg") else {
            return try transcribeSingle(wav: wav, config: config)
        }
        var silences: [Double] = []
        do {
            let r = try Shell.run(ffmpeg, ["-nostats", "-i", wav.path, "-af", "silencedetect=noise=-35dB:d=0.4",
                                           "-f", "null", "-"], timeout: max(600, total))
            silences = Chunking.silenceMidpoints(fromSilencedetect: r.stderr)
        } catch {
            log("silence detection failed on \(wav.lastPathComponent), cutting chunks at fixed intervals: \(error.localizedDescription)", .transcribe)
        }
        let plan = Chunking.chunks(totalSeconds: total, silences: silences)
        log("\(wav.lastPathComponent): \(Int(total))s, transcribing in \(plan.count) chunk(s)", .transcribe)
        var all: [Segment] = []
        for (i, c) in plan.enumerated() {
            let piece = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("callrec-chunk-\(UUID().uuidString).wav")
            defer { Fs.remove(piece) }
            let cut = try Shell.run(ffmpeg, ["-y", "-ss", "\(c.start)", "-t", "\(c.end - c.start)", "-i", wav.path,
                                             "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", piece.path], timeout: 600)
            guard cut.status == 0 else {
                throw NSError(domain: "callrec", code: Int(cut.status), userInfo: [NSLocalizedDescriptionKey:
                    "Could not cut chunk \(i + 1) of \(wav.lastPathComponent).\n\(cut.stderr.suffix(300))"])
            }
            let started = Date()
            let segs = try transcribeSingle(wav: piece, config: config)
            log(String(format: "chunk %d/%d (%.0fs-%.0fs) done in %.0fs", i + 1, plan.count, c.start, c.end,
                       Date().timeIntervalSince(started)), .transcribe)
            all += Chunking.offset(segs, by: c.start)
        }
        return all
    }

    /// One wav through VAD and WhisperKit, under a timeout that scales with the
    /// audio length. Timestamps are on the wav's own clock.
    static func transcribeSingle(wav: URL, config: Config) throws -> [Segment] {
        // Loading is outside the timeout: the first run compiles the CoreML
        // model for this Mac, which takes several minutes and happens once.
        let loaded = ResultBox()
        let loadSem = DispatchSemaphore(value: 0)
        Task {
            do { try await Engine.shared.load(config: config); loaded.set(.success([])) }
            catch { loaded.set(.failure(error)) }
            loadSem.signal()
        }
        loadSem.wait()
        _ = try loaded.get()

        let audioSeconds = Media.duration(of: wav) ?? 0
        let limit = Chunking.timeout(forAudioSeconds: audioSeconds)
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let task = Task {
            do { box.set(.success(try await Engine.shared.transcribe(wav: wav, config: config))) }
            catch { box.set(.failure(error)) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + limit) == .timedOut {
            task.cancel()
            throw NSError(domain: "callrec", code: 9, userInfo: [NSLocalizedDescriptionKey:
                "Transcription of \(wav.lastPathComponent) timed out after \(Int(limit))s."])
        }
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[Segment], Error>?
        func set(_ r: Result<[Segment], Error>) { lock.lock(); value = r; lock.unlock() }
        func get() throws -> [Segment] {
            lock.lock(); defer { lock.unlock() }
            return try (value ?? .failure(NSError(domain: "callrec", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Transcription produced no result"]))).get()
        }
    }

    /// Calls being transcribed right now, so the warm-up never frees a model a call is using.
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeCalls = 0
    private static func adjustActive(_ delta: Int) -> Int {
        activeLock.lock(); defer { activeLock.unlock() }
        activeCalls += delta
        return activeCalls
    }

    /// Loads the speech model on a background queue right away, so the one-time CoreML
    /// compile (several minutes after the binary changes) happens at start-up, loudly,
    /// instead of silently inside the first call. A call that arrives meanwhile waits
    /// on this same load. The models are freed afterwards unless a call is using them.
    public static func warmUp(config: Config, completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        log("preparing speech model (first run after an update can take several minutes)", .transcribe)
        let started = Date()
        Task.detached(priority: .utility) {
            do {
                try await Engine.shared.load(config: config)
                let seconds = Date().timeIntervalSince(started)
                log(String(format: "speech model ready in %.0fs", seconds), .transcribe)
                if adjustActive(0) == 0 { await Engine.shared.release() }
                completion(.success(seconds))
            } catch {
                logError("speech model failed to load: \(error.localizedDescription). Transcription will retry on the next call.", .transcribe)
                completion(.failure(error))
            }
        }
    }

    /// Frees the CoreML models. The watcher is long-lived, so it should not sit
    /// on about half a gigabyte between calls.
    public static func releaseModels() {
        let sem = DispatchSemaphore(value: 0)
        Task { await Engine.shared.release(); sem.signal() }
        sem.wait()
    }

    /// Transcribes a finished recording and writes the markdown next to it.
    ///
    /// The two tracks are transcribed separately so each line can be labelled:
    /// the tap is the other person, the microphone is you. The passes run one
    /// after the other rather than in parallel.
    ///
    /// Any failure still produces a `.md` with an `- error:` line, so a missing
    /// file is never the only symptom.
    @discardableResult
    public static func run(paths: RecordingPaths, seconds: Double, date: Date, config: Config) throws -> URL {
        let id = "\(paths.dir.lastPathComponent)/\(paths.base)"
        let started = Date()
        _ = adjustActive(1)
        log("transcription started: \(id) (\(Int(seconds))s of audio)", .transcribe)
        defer {
            let remaining = adjustActive(-1)
            log(String(format: "transcription finished: %@ in %.0fs", id, Date().timeIntervalSince(started)), .transcribe)
            if remaining == 0 { releaseModels() }
        }
        do {
            return try runPipeline(paths: paths, seconds: seconds, date: date, config: config)
        } catch {
            return writeFailure(paths: paths, seconds: seconds, date: date, error: error)
        }
    }

    /// Writes the error transcript and logs one line. Never throws.
    @discardableResult
    public static func writeFailure(paths: RecordingPaths, seconds: Double, date: Date, error: Error) -> URL {
        let id = "\(paths.dir.lastPathComponent)/\(paths.base)"
        let message = MarkdownFields.oneLine(error.localizedDescription)
        logError("FAILED \(id): \(message). Wrote \(paths.md.lastPathComponent) with an error line; re-run: callrec retranscribe \(id)", .transcribe)
        // The failure reporter must not fail silently: if even this write fails,
        // say so in the log with the path and the reason.
        do {
            try MarkdownStore.recordFailure(paths.md, message: message, date: date, seconds: seconds,
                                            audioName: paths.m4a.lastPathComponent, id: id)
        } catch {
            logError("could not record the failure for \(id) in \(paths.md.path): \(error.localizedDescription). The error was: \(message)", .transcribe)
        }
        return paths.md
    }

    private static func runPipeline(paths: RecordingPaths, seconds: Double, date: Date, config: Config) throws -> URL {
        let fm = FileManager.default
        var segments: [Segment]
        let health = TrackHealth.check(paths: paths)

        if config.speakerLabels, fm.fileExists(atPath: paths.farWav.path), fm.fileExists(atPath: paths.micWav.path) {
            let them = try transcribe(wav: paths.farWav, config: config)
            let me = try transcribe(wav: paths.micWav, config: config)
            let themRMS = levels(paths.farWav)
            let meRMS = levels(paths.micWav)
            segments = Log.interval("merge") {
                SpeakerMerge.merge(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
            }
        } else {
            segments = try transcribe(wav: paths.mixWav, config: config)
        }

        segments = Announcements.mark(segments, phrases: config.announcementPhrases)
        if segments.isEmpty { log("no speech detected in \(paths.dir.lastPathComponent)/\(paths.base)", .transcribe) }
        try MarkdownStore.writeTranscript(paths.md, date: date, seconds: seconds,
                                          audioName: paths.m4a.lastPathComponent, segments: segments)
        recordHealth(health, paths: paths)
        let identity = Identify.apply(to: paths.md, callDate: date, config: config)
        if identity.isEmpty, !CallHistory.readable {
            log(CallHistory.noAccessMessage, .transcribe)
        }
        // The two tracks stay: they are what makes a re-transcription possible.
        Fs.remove(paths.mixWav)
        return paths.md
    }

    /// Re-runs transcription for calls already on disk and rewrites only the
    /// transcript, keeping outcome, notes and the identity fields. A recording
    /// that has audio but no `.md` (a past failure) gets a fresh one.
    public static func retranscribe(target: String?, config: Config) -> (done: Int, skipped: Int) {
        let fm = FileManager.default
        let root = config.recordingsURL
        var done = 0, skipped = 0

        var days = Fs.list(root).filter { $0.count == 10 }
        var onlyCall: String? = nil
        if let target, target.contains("/") {
            let parts = target.components(separatedBy: "/")
            days = [parts[0]]
            onlyCall = parts[1]
        } else if let target, target.count == 10 {
            days = [target]
        } else if let target {
            onlyCall = target
        }

        defer { releaseModels() }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        for day in days.sorted() {
            let dir = root.appendingPathComponent(day)
            for base in Doctor.bases(in: dir) {
                if let onlyCall, base != onlyCall { continue }
                let paths = RecordingPaths(dir: dir, base: base)
                let existing = Fs.text(paths.md)
                guard Doctor.hasAudio(paths) else { skipped += 1; continue }
                guard let date = stamp.date(from: "\(day) \(base)") else {
                    log("skipping \(day)/\(base): not a call recording (use: callrec transcribe <file>)", .transcribe)
                    skipped += 1
                    continue
                }
                // An interrupted recording only has its raw capture: rebuild the tracks and
                // the m4a first (the raw files are removed only after the conversion is checked).
                if Finalize.hasRawCapture(paths) {
                    do { try Finalize.recover(paths: paths) }
                    catch {
                        writeFailure(paths: paths, seconds: 0, date: date, error: error)
                        skipped += 1
                        continue
                    }
                }
                let seconds = [paths.m4a, paths.farWav, paths.mixWav].lazy
                    .filter { fm.fileExists(atPath: $0.path) }.compactMap { Media.duration(of: $0) }.first ?? 0

                var segments: [Segment] = []
                let health = TrackHealth.check(paths: paths)
                do {
                    if config.speakerLabels, fm.fileExists(atPath: paths.farWav.path), fm.fileExists(atPath: paths.micWav.path) {
                        let them = try transcribe(wav: paths.farWav, config: config)
                        let me = try transcribe(wav: paths.micWav, config: config)
                        let themRMS = levels(paths.farWav)
                        let meRMS = levels(paths.micWav)
                        segments = Log.interval("merge") {
                SpeakerMerge.merge(me: me, them: them, meRMS: meRMS, themRMS: themRMS, frameSeconds: 1)
            }
                    } else if fm.fileExists(atPath: paths.m4a.path) || fm.fileExists(atPath: paths.mixWav.path) {
                        // No tracks kept for this call: the mix is all there is,
                        // so the lines come back without speaker labels.
                        let source = fm.fileExists(atPath: paths.m4a.path) ? paths.m4a : paths.mixWav
                        let wav = try toWhisperWav(source)
                        defer { if wav != source { Fs.remove(wav) } }
                        segments = try transcribe(wav: wav, config: config)
                    } else {
                        skipped += 1
                        continue
                    }
                } catch {
                    // Records the error on the existing transcript (keeping the
                    // human fields) or creates a failure transcript.
                    writeFailure(paths: paths, seconds: seconds, date: date, error: error)
                    skipped += 1
                    continue
                }

                segments = Announcements.mark(segments, phrases: config.announcementPhrases)
                do {
                    try MarkdownStore.writeTranscript(paths.md, date: date, seconds: seconds,
                                                      audioName: paths.m4a.lastPathComponent, segments: segments)
                    recordHealth(health, paths: paths)
                    if existing == nil { Identify.apply(to: paths.md, callDate: date, config: config) }
                } catch {
                    logError("could not write \(paths.md.path): \(error.localizedDescription)", .transcribe)
                    skipped += 1
                    continue
                }
                done += 1
                log("re-transcribed \(day)/\(base) (\(segments.count) segments)", .transcribe)
            }
        }
        return (done, skipped)
    }

    /// Puts the silent-track warning in the .md header (or clears a stale one). The log line
    /// was already written when the call was captured.
    static func recordHealth(_ health: TrackHealth.Report, paths: RecordingPaths) {
        let id = "\(paths.dir.lastPathComponent)/\(paths.base)"
        do { try MarkdownStore.setWarnings(paths.md, health.warnings) }
        catch { logError("could not write the silent-track warning for \(id): \(error.localizedDescription)", .transcribe) }
    }

    /// Per-second RMS of a track, for the bleed guard's energy check. If it cannot
    /// be read the merge still runs (text check only) and the log says why.
    private static func levels(_ wav: URL) -> [Float] {
        attempt("could not measure levels of \(wav.lastPathComponent); bleed energy check skipped") {
            try AudioLevels.perSecond(url: wav)
        } ?? []
    }

    /// Converts any audio file to the 16 kHz mono wav whisper expects.
    public static func toWhisperWav(_ input: URL) throws -> URL {
        if input.pathExtension.lowercased() == "wav" { return input }
        guard let ffmpeg = Shell.which("ffmpeg") else {
            throw NSError(domain: "callrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg not found. Run: brew install ffmpeg"])
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callrec-\(UUID().uuidString).wav")
        let r = try Shell.run(ffmpeg, ["-y", "-i", input.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out.path])
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey:
                "Could not convert \(input.lastPathComponent) for transcription.\n\(r.stderr.suffix(400))"])
        }
        return out
    }
}
