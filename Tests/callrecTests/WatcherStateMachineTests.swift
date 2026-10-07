import Foundation
import Testing
@testable import CallrecCore

@Test func watcherTransitions() {

    var m = WatcherStateMachine(stopAfterSilentPolls: 3)
    equal(m.poll(callActive: false), .none, "watcher.idleStaysIdle")
    equal(m.poll(callActive: true), .startRecording, "watcher.idleToRecording")
    equal(m.state, .recording, "watcher.stateAfterStart")
    equal(m.poll(callActive: true), .none, "watcher.stillRecording")

    // Two inactive polls are not enough; the third ends the call.
    equal(m.poll(callActive: false), .none, "watcher.inactive1")
    equal(m.poll(callActive: false), .none, "watcher.inactive2")
    equal(m.poll(callActive: false), .stopRecording, "watcher.inactive3Stops")
    equal(m.state, .idle, "watcher.stateAfterStop")

    // Once the call has settled, a short quiet stretch ends it: no more
    // seconds of dead air after the hang-up.
    var q = WatcherStateMachine(stopAfterSilentPolls: 6, settledAfterPolls: 10, settledStopPolls: 2)
    equal(q.poll(callActive: true), .startRecording, "watcher.settled.start")
    equal(q.patience, 6, "watcher.settled.earlyPatience")
    for _ in 0..<12 { _ = q.poll(callActive: true) }
    equal(q.patience, 2, "watcher.settled.latePatience")
    equal(q.poll(callActive: false), .none, "watcher.settled.firstQuiet")
    equal(q.poll(callActive: false), .stopRecording, "watcher.settled.stopsFast")
    // The connect blip inside the first ten polls must not end the call.
    var b2 = WatcherStateMachine(stopAfterSilentPolls: 6, settledAfterPolls: 10, settledStopPolls: 2)
    _ = b2.poll(callActive: true)
    for _ in 0..<5 { equal(b2.poll(callActive: false), .none, "watcher.settled.connectBlipTolerated") }

    // A blip of inactivity mid-call must not end the recording.
    var b = WatcherStateMachine(stopAfterSilentPolls: 3)
    _ = b.poll(callActive: true)
    _ = b.poll(callActive: false)
    _ = b.poll(callActive: true)
    equal(b.poll(callActive: false), .none, "watcher.blipDoesNotStop")
    equal(b.consecutiveInactivePolls, 1, "watcher.blipResetsCounter")

    // Back-to-back calls: a new call starts cleanly after a stop.
    equal(b.poll(callActive: false), .none, "watcher.secondCall.inactive2")
    equal(b.poll(callActive: false), .stopRecording, "watcher.secondCall.stops")
    equal(b.poll(callActive: true), .startRecording, "watcher.secondCall.starts")

    // An error resets to idle rather than exiting, and recording can resume.
    b.reset()
    equal(b.state, .idle, "watcher.resetGoesIdle")
    equal(b.poll(callActive: true), .startRecording, "watcher.resumesAfterReset")

    // Trigger matching only fires on the configured bundle IDs.
    let snap = [
        AudioProcessInfo(objectID: 1, pid: 10, bundleID: "com.spotify.client", isRunningOutput: true, isRunningInput: false),
        AudioProcessInfo(objectID: 2, pid: 11, bundleID: "com.apple.avconferenced", isRunningOutput: false, isRunningInput: false)
    ]
    expect(WatcherStateMachine.callActive(in: snap, triggerBundleIDs: ["com.spotify.client"]),
                "watcher.matchesTrigger", "spotify should count as active")
    expect(!WatcherStateMachine.callActive(in: snap, triggerBundleIDs: ["com.apple.avconferenced"]),
                "watcher.idleTriggerNotActive", "avconferenced is present but not running audio")
}
