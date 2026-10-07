import CoreAudio
import Foundation

/// Accumulates sum-of-squares from audio buffers on the audio thread and
/// reports (and resets) the RMS when asked from another thread.
public final class RMSMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var count: Double = 0

    public init() {}

    public func accumulate(_ abl: UnsafePointer<AudioBufferList>, frames: UInt32, format: AudioStreamBasicDescription) {
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        var sum: Double = 0
        var n: Double = 0
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<total {
                let v = Double(samples[i])
                sum += v * v
            }
            n += Double(total)
        }
        _ = frames
        lock.lock()
        sumSquares += sum
        count += n
        lock.unlock()
    }

    public func takeRMS() -> Double {
        lock.lock()
        let s = sumSquares, c = count
        sumSquares = 0; count = 0
        lock.unlock()
        return c > 0 ? (s / c).squareRoot() : 0
    }
}
