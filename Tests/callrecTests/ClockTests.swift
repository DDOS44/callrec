import Foundation
import Testing
@testable import CallrecCore

@Test func wallClockGapFilling() {
    let rate = 16_000.0
    // Host ticks per second on this machine.
    let oneSecond = UInt64(1.0 / Clock.seconds(fromHost: 1_000_000) * 1_000_000)

    func pad(written: Int64, elapsed: Double) -> Int64 {
        Clock.framesToPad(writtenFrames: written,
                          startHost: 0,
                          bufferHost: UInt64(Double(oneSecond) * elapsed),
                          rate: rate)
    }

    // In sync: nothing to pad.
    equal(pad(written: 16_000, elapsed: 1.0), 0, "pad.inSync")
    // Ten seconds of silence after one second of audio.
    equal(pad(written: 16_000, elapsed: 11.0), 160_000, "pad.tenSecondGap")
    // Jitter below the 20 ms tolerance is ignored.
    equal(pad(written: 16_000, elapsed: 1.01), 0, "pad.jitterIgnored")
    // Just over the tolerance is filled.
    expect(pad(written: 16_000, elapsed: 1.05) > 0, "pad.aboveTolerance", "small real gap was not padded")
    // Never pad backwards when more was written than time elapsed.
    equal(pad(written: 32_000, elapsed: 1.0), 0, "pad.neverNegative")
    // Nothing before the start, and no division by a zero rate.
    equal(Clock.framesToPad(writtenFrames: 0, startHost: 100, bufferHost: 50, rate: rate), 0, "pad.beforeStart")
    equal(Clock.framesToPad(writtenFrames: 0, startHost: 0, bufferHost: oneSecond, rate: 0), 0, "pad.zeroRate")
    // A gap from nothing written at all: the whole elapsed time.
    equal(pad(written: 0, elapsed: 5.0), 80_000, "pad.fromStart")
}
