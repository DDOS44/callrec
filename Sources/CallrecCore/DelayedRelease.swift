import Foundation

/// Keeps an object alive for a while after its owner is done with it.
///
/// Regression (2026-10-29, crash report callrec-2026-10-29-161832): the call ended, MicRecorder
/// stopped and freed its AVAudioEngine, and a CoreAudio "device changed" notification already in
/// flight for that engine's IO unit was delivered a moment later to the freed object
/// (EXC_BAD_ACCESS in AVAudioIOUnit::IOUnitPropertyListener). The recorder died before finishing
/// the call: no m4a, no transcript, until recovered from the raw capture. A stopped engine is now
/// parked here for `seconds` so late notifications land on a live object.
public final class DelayedRelease: @unchecked Sendable {
    public static let shared = DelayedRelease()

    private let lock = NSLock()
    private var held: [UUID: AnyObject] = [:]
    private let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Void

    public init(schedule: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    public func keep(_ object: AnyObject, for seconds: TimeInterval) {
        let id = UUID()
        lock.lock(); held[id] = object; lock.unlock()
        schedule(seconds) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.held[id] = nil; self.lock.unlock()
        }
    }
}
