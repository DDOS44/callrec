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

    public func write(_ abl: UnsafePointer<AudioBufferList>, frames: UInt32) {
        lock.lock(); defer { lock.unlock() }
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
