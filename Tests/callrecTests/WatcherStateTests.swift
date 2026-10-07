import Foundation
import Testing
@testable import CallrecCore

@Test func watcherStateRoundTripAndOldFiles() throws {
    let s = WatcherState(state: "idle", since: "2026-10-07T00:00:00Z", lastCall: "/x.m4a",
                         microphone: "denied", systemAudio: "authorized", transcribing: "2026-10-07/00-16-31", modelReady: false)
    let back = try WatcherState.decode(s.encoded())
    equal(back, s, "state.roundTrip")
    equal(back.modelReady, false, "state.modelReadyRoundTrip")
    expect(back.preparingModel, "state.preparingModel", "modelReady=false with no error means preparing")
    var failed = back; failed.modelError = "Model not found"
    expect(!failed.preparingModel, "state.modelErrorNotPreparing", "a failed load is not 'preparing'")
    equal(try WatcherState.decode(failed.encoded()).modelError, "Model not found", "state.modelErrorRoundTrip")
    equal(back.permissionProblems, ["microphone is denied"], "state.permissionProblems")

    // A file written by an older daemon has none of the new keys and must still decode.
    let old = Data(#"{"state":"recording","since":"2026-10-07T00:00:00Z"}"#.utf8)
    let decoded = try WatcherState.decode(old)
    equal(decoded.state, "recording", "state.oldFile")
    expect(decoded.transcribing == nil && decoded.microphone == nil, "state.oldFileNewFieldsNil")
    expect(!decoded.preparingModel, "state.oldFileModelReadyAssumed", "an older daemon must not show 'preparing'")
    equal(decoded.permissionProblems, [], "state.unknownIsNotAProblem")
}
