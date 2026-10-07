import Foundation
import AVFoundation
import CallrecCore

/// `callrec watch`: starts a recording when the call process goes live and
/// stops it when the call ends. Never exits on error.
@available(macOS 14.2, *)
final class Watcher {
    private let config: Config
    private var machine: WatcherStateMachine
    private var recorder: CallRecorder?
    private var startedAt = Date()
    private var lastSnapshotError: String?
    private let transcribeQueue = DispatchQueue(label: "callrec.transcribe", qos: .utility)

    nonisolated(unsafe) static var stateURL: URL = WatcherState.url
    private var microphone: String?
    private var systemAudio: String?
    private let stateLock = NSLock()
    private var transcribing: String?
    private var modelReady = false
    private var modelError: String?

    init(config: Config) {
        self.config = config
        self.machine = WatcherStateMachine(stopAfterSilentPolls: config.stopAfterSilentSeconds,
                                           settledAfterPolls: 10, settledStopPolls: 2)
    }

    func run() -> Never {
        AudioRecordingPermission.request()
        // Ask for the mic up front so callrec appears in System Settings > Microphone before the first call.
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { FileHandle.standardError.write("Microphone permission not granted. System Settings > Privacy & Security > Microphone > enable callrec.\n".data(using: .utf8)!) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        let auth = Watcher.logAuthorization()
        microphone = auth.mic
        systemAudio = auth.system
        Permissions.enforceAtStartup(config: config)
        // A fresh daemon has no recording in progress, so raw capture with no finished
        // m4a is what a crash left behind. Say so; `callrec doctor` shows the fix.
        let orphans = Doctor.scan(root: config.recordingsURL).filter { $0.problem.hasPrefix("interrupted") }
        if !orphans.isEmpty {
            log("\(orphans.count) interrupted recording(s) have raw capture but no finished audio; run: callrec doctor", error: true)
        }
        log("watching for \(config.triggerBundleIDs.joined(separator: ", "))")
        writeState(state: "idle", lastCall: nil)
        startModelWarmUp()

        while true {
            let snapshot: [AudioProcessInfo]
            do {
                snapshot = try AudioProcessWatcher.snapshot()
                lastSnapshotError = nil
            } catch {
                // Logged once per distinct error, not once per second.
                let message = error.localizedDescription
                if message != lastSnapshotError { log("could not read the audio process list: \(message)", error: true) }
                lastSnapshotError = message
                snapshot = []
            }
            let active = WatcherStateMachine.callActive(in: snapshot, triggerBundleIDs: config.triggerBundleIDs)

            switch machine.poll(callActive: active) {
            case .none:
                break
            case .startRecording:
                do {
                    startedAt = Date()
                    let r = try CallRecorder(config: config, startedAt: startedAt)
                    try r.start()
                    recorder = r
                    log("call started")
                    writeState(state: "recording", lastCall: nil)
                } catch {
                    log("could not start recording: \(error.localizedDescription)", error: true)
                    recorder = nil
                    machine.reset()
                }
            case .stopRecording:
                finishRecording()
            }

            serveHistoryRequests()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private let mailboxQueue = DispatchQueue(label: "callrec.history-mailbox")
    private let mailboxBusy = NSLock()
    private var mailboxRunning = false

    /// The dialer app has no Full Disk Access, so it asks this daemon to read call history
    /// (see HistoryMailbox). Runs off the watch loop so a slow query never delays call detection.
    private func serveHistoryRequests() {
        mailboxBusy.lock()
        if mailboxRunning { mailboxBusy.unlock(); return }
        mailboxRunning = true
        mailboxBusy.unlock()
        mailboxQueue.async { [weak self] in
            HistoryMailbox.serve { try CallHistory.mailboxRows(since: $0.sinceEpoch) }
            self?.mailboxBusy.lock(); self?.mailboxRunning = false; self?.mailboxBusy.unlock()
        }
    }

    /// Mic and system-audio permission as macOS reports them to this process, logged at startup.
    /// A denied mic is silent otherwise: the track is recorded as zeros.
    @discardableResult
    static func logAuthorization() -> (mic: String, system: String) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let sys = AudioRecordingPermission.status
        let micOK = mic == .authorized, sysOK = sys == .authorized
        let line = "[authorization] microphone: \(micName(mic)), system audio: \(sys.rawValue)"
        if micOK && sysOK { CallrecCore.log(line, .watcher) } else {
            logError(line + " — recordings will be silent on the missing side. System Settings → Privacy & Security → Microphone / Screen & System Audio Recording → callrec", .watcher)
        }
        return (micName(mic), sys.rawValue)
    }

    static func micName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Loads the speech model in the background and publishes progress in state.json.
    private func startModelWarmUp() {
        Transcriber.warmUp(config: config) { [weak self] result in
            guard let self else { return }
            self.stateLock.lock()
            switch result {
            case .success: self.modelReady = true; self.modelError = nil
            case .failure(let error): self.modelError = error.localizedDescription
            }
            let (st, last) = (self.currentState, self.currentLast)
            self.stateLock.unlock()
            self.writeState(state: st, lastCall: last, keepSince: true)
        }
    }

    private func finishRecording() {
        guard let r = recorder else { machine.reset(); return }
        recorder = nil
        let callDate = startedAt
        do {
            let result = try r.stop()
            if result.kept {
                log("call ended, saved \(result.paths.m4a.path)")
                writeState(state: "idle", lastCall: result.paths.m4a.path)
                let config = self.config
                let id = "\(result.paths.dir.lastPathComponent)/\(result.paths.base)"
                transcribeQueue.async { [weak self] in
                    self?.setTranscribing(id)
                    defer { self?.setTranscribing(nil) }
                    do {
                        let md = try Transcriber.run(paths: result.paths, seconds: result.seconds,
                                                     date: callDate, config: config)
                        self?.log("transcript \(md.path)")
                    } catch {
                        self?.log("transcription failed: \(error.localizedDescription)", error: true)
                    }
                }
            } else {
                log("call too short (\(Int(result.seconds))s), discarded")
                writeState(state: "idle", lastCall: nil)
            }
        } catch {
            log("could not stop recording: \(error.localizedDescription)", error: true)
            if Doctor.hasAudio(r.paths) {
                Transcriber.writeFailure(paths: r.paths, seconds: Date().timeIntervalSince(callDate),
                                         date: callDate, error: error)
            }
            writeState(state: "idle", lastCall: nil)
        }
    }

    // MARK: - State and log

    private var currentState = "idle"
    private var currentSince = ISO8601DateFormatter().string(from: Date())
    private var currentLast: String?

    /// Marks which call is being transcribed (nil when idle) without changing the recording state.
    private func setTranscribing(_ id: String?) {
        stateLock.lock()
        transcribing = id
        let (st, last) = (currentState, currentLast)
        stateLock.unlock()
        // Keep the recording clock's `since` as it was.
        writeState(state: st, lastCall: last, keepSince: true)
    }

    private func writeState(state: String, lastCall: String?, keepSince: Bool = false) {
        stateLock.lock(); defer { stateLock.unlock() }
        if !keepSince { currentSince = ISO8601DateFormatter().string(from: Date()) }
        currentState = state
        currentLast = lastCall
        let s = WatcherState(state: state, since: currentSince, lastCall: lastCall,
                             microphone: microphone, systemAudio: systemAudio, transcribing: transcribing,
                             modelReady: modelReady, modelError: modelError)
        do {
            try Paths.ensureDir(Watcher.stateURL.deletingLastPathComponent())
            try s.encoded().write(to: Watcher.stateURL, options: .atomic)
        } catch {
            // Status shows stale data if this fails, so say so.
            log("could not write \(Watcher.stateURL.path): \(error.localizedDescription)", error: true)
        }
    }

    func log(_ message: String, error: Bool = false) {
        if error { logError(message, .watcher) } else { CallrecCore.log(message, .watcher) }
    }

    // MARK: - status

    static func statusText(config: Config) -> String {
        var lines: [String] = []
        let state: WatcherState?
        do {
            state = try WatcherState.decode(Data(contentsOf: stateURL))
        } catch {
            state = nil
            if !Fs.isMissing(error) { lines.append("Could not read \(stateURL.path): \(error.localizedDescription)") }
        }
        // launchd is the source of truth for "alive"; the state file can be stale.
        let job = Agent.jobState()
        if !job.running {
            lines.append("NOT RUNNING — the background recorder is \(job.detail). Calls are not being recorded.")
            lines.append("Fix: ~/.callrec/bin/callrec install-agent, then check ~/.callrec/callrec.log")
        } else if let s = state {
            let since = ISO8601DateFormatter().date(from: s.since) ?? Date()
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            if s.state == "recording" {
                let secs = Int(Date().timeIntervalSince(since))
                lines.append("Recording since \(f.string(from: since)) (\(secs / 60)m \(secs % 60)s).")
            } else {
                lines.append("Watching. Not in a call.")
            }
            if let last = s.lastCall { lines.append("Last call: \(last)") }
            if let err = s.modelError {
                lines.append("WARNING: the speech model failed to load: \(err). Calls will not be transcribed until this is fixed.")
            } else if s.preparingModel {
                lines.append("Preparing speech model (one-time after an update)… calls are recorded and transcribed once it is ready.")
            }
            // Permissions are the daemon's own, recorded by it at startup (this CLI's would be the terminal's).
            if !s.permissionProblems.isEmpty {
                lines.append("WARNING: permissions: \(s.permissionProblems.joined(separator: ", ")). A missing one records silence. Fix in System Settings → Privacy & Security → Microphone / Screen & System Audio Recording → callrec")
            }
        } else {
            lines.append("Not running. Start with: callrec install-agent")
        }

        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let folder = config.recordingsURL.appendingPathComponent(day.string(from: Date()))
        let files = Fs.list(folder)
        lines.append("Today's folder: \(folder.path)")
        lines.append("Transcripts today: \(files.filter { $0.hasSuffix(".md") }.count)")
        let weekAgo = DateFormatter(); weekAgo.dateFormat = "yyyy-MM-dd"
        let since = weekAgo.string(from: Date().addingTimeInterval(-3 * 86400))
        for w in Doctor.warnings(root: config.recordingsURL, sinceDay: since) {
            lines.append("WARNING: \(w.id): \(w.warning). Check System Settings → Privacy & Security → Microphone → callrec")
        }
        if !CallHistory.readable {
            lines.append("Note: " + CallHistory.noAccessMessage)
        }
        return lines.joined(separator: "\n")
    }
}
