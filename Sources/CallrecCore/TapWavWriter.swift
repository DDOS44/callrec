import AVFoundation
import AudioToolbox
import Foundation

/// Writes tap audio to a 16 kHz mono 16-bit WAV, converting from whatever rate
/// the device is actually running at.
///
/// This exists because a phone call puts the output device into a voice mode at
/// 8, 16 or 24 kHz. Trusting the rate reported when the tap was created wrote a
/// 48 kHz header over 24 kHz frames, so the far side played back several times
/// too fast and whisper heard gibberish.
public final class TapWavWriter: @unchecked Sendable {
    public static let targetRate: Double = 16_000

    private var ref: ExtAudioFileRef?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat
    private(set) var framesWritten: Int64 = 0
    /// Host time the recording started, so gaps can be filled with silence.
    private var startHost: UInt64 = Clock.nowHost

    public init(url: URL, sourceFormat source: AudioStreamBasicDescription) throws {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TapWavWriter.targetRate,
                                      channels: 1, interleaved: false) else {
            throw NSError(domain: "callrec", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not set up the recording format."])
        }
        outputFormat = out

        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: TapWavWriter.targetRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

        var newRef: ExtAudioFileRef?
        try AudioProcessWatcher.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFormat, nil,
                                                               AudioFileFlags.eraseFile.rawValue, &newRef))
        ref = newRef
        var client = out.streamDescription.pointee
        try AudioProcessWatcher.check(ExtAudioFileSetProperty(newRef!, kExtAudioFileProperty_ClientDataFormat,
                                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
        setSource(source)
    }

    /// Swap the converter when the device changes rate mid-call.
    public func setSource(_ asbd: AudioStreamBasicDescription) {
        var desc = asbd
        guard desc.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &desc) else { return }
        lock.lock(); defer { lock.unlock() }
        guard sourceFormat?.streamDescription.pointee.mSampleRate != desc.mSampleRate
                || sourceFormat?.channelCount != format.channelCount else { return }
        sourceFormat = format
        converter = AVAudioConverter(from: format, to: outputFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    /// Call once when the tap actually starts.
    public func markStart(host: UInt64 = Clock.nowHost) {
        lock.lock(); defer { lock.unlock() }
        startHost = host
    }

    /// Fills the file with silence up to `host` (used at stop, so the far and
    /// mic tracks end at the same length).
    public func padToWallClock(host: UInt64 = Clock.nowHost) {
        lock.lock(); defer { lock.unlock() }
        padLocked(to: host)
    }

    private func padLocked(to host: UInt64) {
        let pad = Clock.framesToPad(writtenFrames: framesWritten, startHost: startHost,
                                    bufferHost: host, rate: TapWavWriter.targetRate)
        guard pad > 0, let ref else { return }
        let chunk = AVAudioFrameCount(min(pad, 16_000))
        guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk) else { return }
        var remaining = pad
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(chunk)))
            silence.frameLength = n
            if let data = silence.floatChannelData?[0] {
                memset(data, 0, Int(n) * MemoryLayout<Float>.size)
            }
            if ExtAudioFileWrite(ref, n, silence.audioBufferList) != noErr { return }
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
    }

    public func write(_ abl: UnsafePointer<AudioBufferList>, frames: UInt32, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        padLocked(to: hostTime)
        guard let ref, let converter, let sourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                           bufferListNoCopy: abl,
                                           deallocator: nil) else { return }
        input.frameLength = frames

        let ratio = TapWavWriter.targetRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return }
        if ExtAudioFileWrite(ref, output.frameLength, output.audioBufferList) == noErr {
            framesWritten += Int64(output.frameLength)
        }
    }

    /// Seconds of audio actually written, for the "did the rate drift" check.
    public var secondsWritten: Double { Double(framesWritten) / TapWavWriter.targetRate }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let ref { ExtAudioFileDispose(ref) }
        ref = nil
    }

    deinit { close() }
}
