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
    public private(set) var state: State = .idle
    public private(set) var consecutiveInactivePolls = 0

    public init(stopAfterSilentPolls: Int) {
        self.stopAfterSilentPolls = max(stopAfterSilentPolls, 1)
    }

    /// Feed one poll of "is the call process live right now".
    public mutating func poll(callActive: Bool) -> Action {
        switch state {
        case .idle:
            consecutiveInactivePolls = 0
            guard callActive else { return .none }
            state = .recording
            return .startRecording

        case .recording:
            if callActive {
                consecutiveInactivePolls = 0
                return .none
            }
            consecutiveInactivePolls += 1
            guard consecutiveInactivePolls >= stopAfterSilentPolls else { return .none }
            state = .idle
            consecutiveInactivePolls = 0
            return .stopRecording
        }
    }

    /// A recording that failed to start or stop puts us back to idle without exiting.
    public mutating func reset() {
        state = .idle
        consecutiveInactivePolls = 0
    }

    public static func callActive(in snapshot: [AudioProcessInfo], triggerBundleIDs: [String]) -> Bool {
        snapshot.contains { triggerBundleIDs.contains($0.bundleID) && ($0.isRunningOutput || $0.isRunningInput) }
    }
}
