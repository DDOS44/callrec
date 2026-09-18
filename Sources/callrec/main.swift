import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("usage: callrec <probe|tap-test|record|watch|transcribe|status|session>")
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
        let fmt = tap.format
        print("Tap format: \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, \(fmt.mBitsPerChannel)-bit")
        let writer = try WavWriter(url: outURL, format: fmt)

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
