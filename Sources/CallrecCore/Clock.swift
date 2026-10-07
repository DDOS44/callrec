import Darwin
import Foundation

/// Host-clock helpers for keeping a recording on the wall clock.
public enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(fromHost host: UInt64) -> Double {
        Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static var nowHost: UInt64 { mach_absolute_time() }

    /// How many silent frames to insert so that the next buffer lands at its
    /// real position in time.
    ///
    /// The process tap only delivers frames while something is playing, so a
    /// quiet stretch in a call produces no callbacks at all. Without padding,
    /// later audio slides earlier and stops matching the microphone track.
    /// A gap under `tolerance` is normal jitter and is ignored.
    public static func framesToPad(writtenFrames: Int64,
                                   startHost: UInt64,
                                   bufferHost: UInt64,
                                   rate: Double,
                                   tolerance: Double = 0.02) -> Int64 {
        guard rate > 0, bufferHost > startHost else { return 0 }
        let elapsed = seconds(fromHost: bufferHost - startHost)
        let written = Double(writtenFrames) / rate
        let gap = elapsed - written
        guard gap > tolerance else { return 0 }
        return Int64((gap * rate).rounded())
    }
}
