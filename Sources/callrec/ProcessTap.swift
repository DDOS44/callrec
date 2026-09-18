import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Core Audio process tap: captures what other processes are playing.
/// Structure follows insidegui/AudioCap's ProcessTap.swift (MIT).
@available(macOS 14.2, *)
final class ProcessTap: @unchecked Sendable {

    enum Mode {
        /// Global stereo tap of everything except the given processes.
        case globalExcluding([AudioObjectID])
    }

    private let mode: Mode
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private let queue = DispatchQueue(label: "callrec.tap", qos: .userInitiated)

    private(set) var format = AudioStreamBasicDescription()

    init(mode: Mode) throws {
        self.mode = mode
        try prepare()
    }

    deinit { stop() }

    private func prepare() throws {
        let excluded: [AudioObjectID]
        switch mode {
        case .globalExcluding(let ids): excluded = ids
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.muteBehavior = CATapMuteBehavior.unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try AudioProcessWatcher.check(AudioHardwareCreateProcessTap(desc, &newTap))
        tapID = newTap

        format = try readTapFormat(tapID)

        let outputUID = try defaultOutputDeviceUID()
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "callrec-tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try AudioProcessWatcher.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate))
        aggregateID = newAggregate
    }

    /// onBuffer is called on a real-time audio thread. Keep it fast and allocation-free.
    func start(onBuffer: @escaping (UnsafePointer<AudioBufferList>, UInt32) -> Void) throws {
        guard !started else { return }
        let bytesPerFrame = max(format.mBytesPerFrame, 1)
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) { _, inInputData, _, _, _ in
            let frames = inInputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
            if frames > 0 { onBuffer(inInputData, frames) }
        }
        try AudioProcessWatcher.check(status)
        procID = newProcID
        try AudioProcessWatcher.check(AudioDeviceStart(aggregateID, procID))
        started = true
    }

    func stop() {
        if started {
            AudioDeviceStop(aggregateID, procID)
            started = false
        }
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Property helpers

    private func readTapFormat(_ id: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try AudioProcessWatcher.check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd))
        return asbd
    }

    private func defaultOutputDeviceUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try AudioProcessWatcher.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID))

        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try AudioProcessWatcher.check(AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid))
        guard let value = uid?.takeRetainedValue() as String? else {
            throw NSError(domain: "callrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read the default output device UID."])
        }
        return value
    }
}

/// Writes float buffers coming off a tap into a 16-bit PCM WAV file.
final class WavWriter: @unchecked Sendable {
    private var ref: ExtAudioFileRef?
    private let lock = NSLock()

    init(url: URL, format: AudioStreamBasicDescription) throws {
        var clientFormat = format
        let channels = max(format.mChannelsPerFrame, 1)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0)

        var newRef: ExtAudioFileRef?
        try AudioProcessWatcher.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &outFormat, nil,
                                                               AudioFileFlags.eraseFile.rawValue, &newRef))
        ref = newRef
        try AudioProcessWatcher.check(ExtAudioFileSetProperty(newRef!, kExtAudioFileProperty_ClientDataFormat,
                                                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat))
    }

    func write(_ abl: UnsafePointer<AudioBufferList>, frames: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard let ref else { return }
        ExtAudioFileWrite(ref, frames, abl)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let ref { ExtAudioFileDispose(ref) }
        ref = nil
    }

    deinit { close() }
}
