import Foundation

/// The pure decision logic behind `callrec watch`, separated so it can be tested
/// without Core Audio or a live call.
public struct WatcherStateMachine {

    public enum State: String, Codable {
        case idle, recording
    }

    public enum Action: Equatable {
        case none
        case startRecording
        case stopRecording
    }

    public let stopAfterSilentPolls: Int
    /// Once a call is properly under way we stop almost immediately, so the
    /// recording does not run on for seconds after the hang-up. The longer
    /// patience only covers the unsteady first moments of a connect.
    public let settledAfterPolls: Int
    public let settledStopPolls: Int
    public private(set) var state: State = .idle
    public private(set) var consecutiveInactivePolls = 0
    private var pollsInCall = 0

    public init(stopAfterSilentPolls: Int, settledAfterPolls: Int = 10, settledStopPolls: Int = 2) {
        self.stopAfterSilentPolls = max(stopAfterSilentPolls, 1)
        self.settledAfterPolls = max(settledAfterPolls, 1)
        self.settledStopPolls = max(settledStopPolls, 1)
    }

    /// How many quiet polls end the call right now.
    public var patience: Int {
        pollsInCall >= settledAfterPolls ? settledStopPolls : stopAfterSilentPolls
    }

    /// Feed one poll of "is the call process live right now".
    public mutating func poll(callActive: Bool) -> Action {
        switch state {
        case .idle:
            consecutiveInactivePolls = 0
            guard callActive else { return .none }
            state = .recording
            pollsInCall = 0
            return .startRecording

        case .recording:
            pollsInCall += 1
            if callActive {
                consecutiveInactivePolls = 0
                return .none
            }
            consecutiveInactivePolls += 1
            guard consecutiveInactivePolls >= patience else { return .none }
            state = .idle
            consecutiveInactivePolls = 0
            pollsInCall = 0
            return .stopRecording
        }
    }

    /// A recording that failed to start or stop puts us back to idle without exiting.
    public mutating func reset() {
        state = .idle
        consecutiveInactivePolls = 0
        pollsInCall = 0
    }

    public static func callActive(in snapshot: [AudioProcessInfo], triggerBundleIDs: [String]) -> Bool {
        snapshot.contains { triggerBundleIDs.contains($0.bundleID) && ($0.isRunningOutput || $0.isRunningInput) }
    }
}
