@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Records the microphone (your side of the call) to a 16 kHz mono file. The caller
/// passes a `.caf` URL (AVAudioFile picks the container from the extension): CAF
/// survives a crash, WAV does not. See `Finalize`.
///
/// FOLLOWS THE MIC. Bluetooth headphones switch into their call profile when a call
/// connects, which replaces the input device (and usually its sample rate) mid-call.
/// The old recorder bound to the device present at start, received nothing after the
/// switch, and padded the gap with silence: a -inf dB mic track with no warning
/// (2026-10-07, test call on headphones). Now: the file is always 16 kHz mono, every
/// input is converted to that, and on any engine configuration change or default
/// input change the tap is rebuilt on the current default device. Each buffer is
/// placed on the wall clock, so gaps during a switch become silence in the right place.
public final class MicRecorder: @unchecked Sendable {
    public static let fileRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var running = false
    private var startHost: UInt64 = 0
    private var framesWritten: Int64 = 0
    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var reconfigurations = 0

    public init(url: URL) throws {
        self.url = url
    }

    public func start() throws {
        guard !running else { return }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: Self.fileRate, channels: 1) else {
            throw NSError(domain: "callrec", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create the 16 kHz mono format."])
        }
        self.target = target
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)
        startHost = Clock.nowHost
        try attachToCurrentInput(reason: "start")
        running = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.reattach(reason: "engine configuration changed")
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reattach(reason: "default input device changed")
        }
        var addr = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)
        if status == noErr {
            defaultInputListener = listener
        } else {
            log("could not watch for microphone device changes (CoreAudio \(status)); a mid-call device switch may go unrecorded", .capture)
        }
    }

    /// (Re)bind the input node to the current default input and start the engine.
    private func attachToCurrentInput(reason: String) throws {
        let input = engine.inputNode
        if let device = Self.defaultInputDevice(), let unit = input.audioUnit {
            var dev = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                log("could not bind the microphone to device \(device) (CoreAudio \(status)); using the engine default", .capture)
            }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "callrec", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No microphone input available. Check System Settings -> Privacy & Security -> Microphone."])
        }
        guard let target, let conv = AVAudioConverter(from: fmt, to: target) else {
            throw NSError(domain: "callrec", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Could not convert the microphone (\(fmt.sampleRate) Hz, \(fmt.channelCount) ch) to 16 kHz mono."])
        }
        lock.lock(); converter = conv; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, when in
            self?.write(buf, at: when)
        }
        engine.prepare()
        try engine.start()
        log("[mic] \(reason): \(Self.deviceName(Self.defaultInputDevice()) ?? "unknown device") at \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch", .capture)
    }

    private func reattach(reason: String) {
        lock.lock(); let live = running; lock.unlock()
        guard live else { return }
        reconfigurations += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try attachToCurrentInput(reason: reason)
        } catch {
            logError("[mic] lost the microphone after \(reason) and could not reattach: \(error.localizedDescription). Your side of this call may be missing from this point.", .capture)
        }
    }

    private func write(_ buf: AVAudioPCMBuffer, at when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard let file, let converter, let target else { return }
        let host = when.isHostTimeValid ? when.hostTime : Clock.nowHost
        padSilence(upTo: host, file: file, format: target)

        let ratio = target.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        // The converter pulls synchronously, on this thread, before convert() returns.
        nonisolated(unsafe) var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        if let err {
            logError("[mic] conversion failed: \(err.localizedDescription)", .capture)
            return
        }
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
        } catch {
            logError("[mic] write failed: \(error.localizedDescription)", .capture)
        }
    }

    /// Fill any gap between what's written and `host` with silence, so the mic
    /// track stays on the wall clock through device switches and dropouts.
    private func padSilence(upTo host: UInt64, file: AVAudioFile, format: AVAudioFormat) {
        let pad = Clock.framesToPad(writtenFrames: framesWritten, startHost: startHost,
                                    bufferHost: host, rate: format.sampleRate)
        guard pad > 0 else { return }
        let chunk = AVAudioFrameCount(min(pad, Int64(format.sampleRate)))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let data = silence.floatChannelData?[0] else { return }
        var remaining = pad
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(chunk)))
            silence.frameLength = n
            memset(data, 0, Int(n) * MemoryLayout<Float>.size)
            do { try file.write(from: silence) } catch {
                logError("[mic] could not pad the mic track with silence, tracks may be misaligned: \(error.localizedDescription)", .capture)
                return
            }
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()

        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let listener = defaultInputListener {
            var addr = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)
        }
        defaultInputListener = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        if let file, let target { padSilence(upTo: Clock.nowHost, file: file, format: target) }
        file = nil
        lock.unlock()
        if reconfigurations > 0 {
            log("[mic] followed \(reconfigurations) microphone change(s) during this call", .capture)
        }
    }

    deinit { stop() }

    // MARK: - CoreAudio helpers

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = Self.defaultInputAddress
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return status == noErr && dev != 0 ? dev : nil
    }

    static func deviceName(_ device: AudioDeviceID?) -> String? {
        guard let device else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}
