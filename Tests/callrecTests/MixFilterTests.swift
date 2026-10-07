import Testing
@testable import CallrecCore

// Regression: in-call mic came out ~34 LU quieter than the far side (-50.7 vs -16.4
// LUFS), so "Me" was inaudible on playback. Both sides must be loudness-matched.
@Test func mixLoudnessMatchesBothSides() {
    let f = Finalize.mixFilter
    #expect(f.contains("[0:a]loudnorm"))
    #expect(f.contains("[1:a]loudnorm"))
    #expect(f.contains("amix=inputs=2:normalize=0"))
    #expect(f.contains("alimiter"))
}
