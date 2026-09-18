import AVFoundation
import Foundation
import CallrecCore

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("usage: callrec <watch|status|record|session|transcribe|install-agent|uninstall-agent|probe|tap-test|mic-test|selftest>")
    exit(2)
}

guard let cmd = args.first else { usage() }

switch cmd {
case "probe":
    AudioRecordingPermission.request()
    print("System audio permission: \(AudioRecordingPermission.status.rawValue)")
    print("Polling audio processes every second. Make a call now. Ctrl-C to stop.")
    var last = Set<String>()
    while true {
        let snap = (try? AudioProcessWatcher.snapshot()) ?? []
        let active = Set(snap.filter { $0.isRunningOutput || $0.isRunningInput }.map {
            "\($0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID) out=\($0.isRunningOutput) in=\($0.isRunningInput)"
        })
        if active != last {
            print("[\(Date())]")
            active.sorted().forEach { print("  ", $0) }
            last = active
        }
        Thread.sleep(forTimeInterval: 1)
    }

case "tap-test":
    guard #available(macOS 14.2, *) else {
        print("tap-test needs macOS 14.2 or newer.")
        exit(1)
    }
    if AudioRecordingPermission.request() != .authorized {
        print("System audio permission: \(AudioRecordingPermission.status.rawValue)")
        print(AudioRecordingPermission.deniedMessage)
    }
    let outURL = URL(fileURLWithPath: "/tmp/callrec-tap-test.wav")
    do {
        let tap = try ProcessTap(mode: .globalExcluding([]))
        let fmt = (try? tap.liveFormat()) ?? tap.format
        print("Rates: \(tap.diagnostics)")
        let writer = try TapWavWriter(url: outURL, sourceFormat: fmt)
        tap.onFormatChange = { [weak writer] new in
            print(String(format: "device changed to %.0f Hz mid-recording", new.mSampleRate))
            writer?.setSource(new)
        }

        let meter = RMSMeter()
        try tap.start { abl, frames in
            writer.write(abl, frames: frames)
            meter.accumulate(abl, frames: frames, format: fmt)
        }
        print("Recording 20 s to \(outURL.path). RMS once per second:")
        var sawAudio = false
        var warned = false
        for i in 1...20 {
            Thread.sleep(forTimeInterval: 1)
            let rms = meter.takeRMS()
            if rms > 0 { sawAudio = true }
            print(String(format: "  %2ds  rms=%.5f", i, rms))
            if i >= 3 && !sawAudio && !warned {
                warned = true
                print(AudioRecordingPermission.deniedMessage)
            }
        }
        tap.stop()
        writer.close()
        print("Wrote \(outURL.path)")
        if !sawAudio {
            print("Captured silence for the whole 20 s. " + AudioRecordingPermission.deniedMessage)
        }
    } catch {
        let ns = error as NSError
        FileHandle.standardError.write("tap-test failed: \(ns.localizedDescription) (domain \(ns.domain), OSStatus \(ns.code))\n".data(using: .utf8)!)
        exit(1)
    }

case "install-agent":
    do { try Agent.install() } catch {
        FileHandle.standardError.write("install-agent failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "uninstall-agent":
    do { try Agent.uninstall() } catch {
        FileHandle.standardError.write("uninstall-agent failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "session":
    guard #available(macOS 14.2, *) else {
        print("callrec needs macOS 14.2 or newer.")
        exit(1)
    }
    guard args.count >= 2, ["start", "stop"].contains(args[1]) else {
        print("usage: callrec session <start|stop>")
        exit(2)
    }
    do {
        if args[1] == "start" {
            try Session.start(config: Config.load())
        } else {
            try Session.stop()
        }
    } catch {
        FileHandle.standardError.write("session failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "watch":
    guard #available(macOS 14.2, *) else {
        print("callrec needs macOS 14.2 or newer.")
        exit(1)
    }
    let watcher = Watcher(config: Config.load())
    watcher.run()

case "status":
    guard #available(macOS 14.2, *) else {
        print("callrec needs macOS 14.2 or newer.")
        exit(1)
    }
    print(Watcher.statusText(config: Config.load()))

case "transcribe":
    guard args.count >= 2 else {
        print("usage: callrec transcribe <audio file>")
        exit(2)
    }
    do {
        let config = Config.load()
        let input = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        let wav = try Transcriber.toWhisperWav(input)
        let segments = try Transcriber.transcribe(wav: wav, config: config)
        if wav != input { try? FileManager.default.removeItem(at: wav) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: input.path)
        let date = (attrs?[.creationDate] as? Date) ?? Date()
        let md = Markdown.render(date: date, seconds: segments.last?.end ?? 0,
                                 audioName: input.lastPathComponent, segments: segments)
        let mdURL = input.deletingPathExtension().appendingPathExtension("md")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        print(mdURL.path)
    } catch {
        FileHandle.standardError.write("transcribe failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "record":
    guard #available(macOS 14.2, *) else {
        print("callrec needs macOS 14.2 or newer.")
        exit(1)
    }
    AudioRecordingPermission.request()
    var seconds: Double? = nil
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count { seconds = Double(args[i + 1]) }
    do {
        let config = Config.load()
        let recorder = try CallRecorder(config: config)
        try recorder.start()

        let finish: () -> Never = {
            do {
                let result = try recorder.stop()
                if result.kept {
                    print("Saved \(result.paths.m4a.path)")
                } else {
                    print("Too short (\(Int(result.seconds))s), discarded")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write("record failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        if let seconds {
            print("Recording \(Int(seconds))s…")
            Thread.sleep(forTimeInterval: seconds)
            finish()
        } else {
            print("Recording… Ctrl-C to stop.")
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { finish() }
            source.resume()
            dispatchMain()
        }
    } catch {
        FileHandle.standardError.write("record failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "mic-test":
    let micURL = URL(fileURLWithPath: "/tmp/callrec-mic-test.wav")
    do {
        let mic = try MicRecorder(url: micURL)
        try mic.start()
        print("Recording the microphone for 5 s to \(micURL.path). Say something.")
        Thread.sleep(forTimeInterval: 5)
        mic.stop()
        print("Wrote \(micURL.path)")
    } catch {
        FileHandle.standardError.write("mic-test failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

case "selftest":
    let failures = SelfTest.runAll()
    if failures.isEmpty {
        print("selftest: all checks passed")
    } else {
        failures.forEach { print($0) }
        print("selftest: \(failures.count) failure(s)")
        exit(1)
    }

default:
    usage()
}
