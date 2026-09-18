import Foundation
import AVFoundation
import CallrecCore

struct WatcherState: Codable {
    var state: String          // "idle" | "recording"
    var since: String          // ISO8601
    var lastCall: String?
}

/// `callrec watch`: starts a recording when the call process goes live and
/// stops it when the call ends. Never exits on error.
@available(macOS 14.2, *)
final class Watcher {
    private let config: Config
    private var machine: WatcherStateMachine
    private var recorder: CallRecorder?
    private var startedAt = Date()
    private let transcribeQueue = DispatchQueue(label: "callrec.transcribe", qos: .utility)

    nonisolated(unsafe) static var stateURL: URL =
        Config.url.deletingLastPathComponent().appendingPathComponent("state.json")
    nonisolated(unsafe) static var logURL: URL =
        Config.url.deletingLastPathComponent().appendingPathComponent("callrec.log")

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
        log("watching for \(config.triggerBundleIDs.joined(separator: ", "))")
        writeState(state: "idle", lastCall: nil)

        while true {
            let snapshot = (try? AudioProcessWatcher.snapshot()) ?? []
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
                    log("could not start recording: \(error.localizedDescription)")
                    recorder = nil
                    machine.reset()
                }
            case .stopRecording:
                finishRecording()
            }

            Thread.sleep(forTimeInterval: 1)
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
                transcribeQueue.async { [weak self] in
                    do {
                        let md = try Transcriber.run(paths: result.paths, seconds: result.seconds,
                                                     date: callDate, config: config)
                        self?.log("transcript \(md.path)")
                    } catch {
                        self?.log("transcription failed: \(error.localizedDescription)")
                    }
                }
            } else {
                log("call too short (\(Int(result.seconds))s), discarded")
                writeState(state: "idle", lastCall: nil)
            }
        } catch {
            log("could not stop recording: \(error.localizedDescription)")
            writeState(state: "idle", lastCall: nil)
        }
    }

    // MARK: - State and log

    private func writeState(state: String, lastCall: String?) {
        let s = WatcherState(state: state, since: ISO8601DateFormatter().string(from: Date()), lastCall: lastCall)
        try? FileManager.default.createDirectory(at: Watcher.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(s).write(to: Watcher.stateURL)
    }

    func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        print(message)
        let url = Watcher.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(url)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 5_000_000 else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    // MARK: - status

    static func statusText(config: Config) -> String {
        var lines: [String] = []
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(WatcherState.self, from: d) {
            let since = ISO8601DateFormatter().date(from: s.since) ?? Date()
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            if s.state == "recording" {
                let secs = Int(Date().timeIntervalSince(since))
                lines.append("Recording since \(f.string(from: since)) (\(secs / 60)m \(secs % 60)s).")
            } else {
                lines.append("Watching. Not in a call.")
            }
            if let last = s.lastCall { lines.append("Last call: \(last)") }
        } else {
            lines.append("Not running. Start with: callrec install-agent")
        }

        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let folder = config.recordingsURL.appendingPathComponent(day.string(from: Date()))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        lines.append("Today's folder: \(folder.path)")
        lines.append("Transcripts today: \(files.filter { $0.hasSuffix(".md") }.count)")
        if !CallHistory.readable {
            lines.append("Note: " + CallHistory.noAccessMessage)
        }
        return lines.joined(separator: "\n")
    }
}
