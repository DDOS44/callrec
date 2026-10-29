import Foundation
import Testing
@testable import CallrecCore

private final class Probe {}

@Test func aParkedObjectOutlivesItsOwnerUntilTheDelayEnds() {
    var pending: [@Sendable () -> Void] = []
    let parking = DelayedRelease { _, work in pending.append(work) }
    weak var weakProbe: Probe?
    do {
        let probe = Probe()
        weakProbe = probe
        parking.keep(probe, for: 30)
    }
    #expect(weakProbe != nil, "still alive after the owner let go")
    #expect(parking.count == 1)
    pending.forEach { $0() }
    #expect(weakProbe == nil, "released once the delay is over")
    #expect(parking.count == 0)
}
