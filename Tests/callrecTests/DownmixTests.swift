import Testing
@testable import CallrecCore

// Regression: in a call the built-in mic becomes 3-channel with silent channels, and the
// old downmix produced a fully silent "Me" track (2026-10-07, two test calls).

@Test func downmixUsesTheOnlyActiveChannel() {
    let silent: [Float] = [0, 0, 0, 0]
    let voice: [Float] = [0.5, -0.4, 0.3, -0.2]
    #expect(Downmix.activeAverage([silent, voice, silent]) == voice)
    #expect(Downmix.activeChannels([silent, voice, silent]) == [1])
}

@Test func downmixAveragesSeveralActiveChannels() {
    let a: [Float] = [0.4, 0.2]
    let b: [Float] = [0.2, 0.0001]
    let out = Downmix.activeAverage([a, [0, 0], b])
    #expect(abs(out[0] - 0.3) < 1e-6)
    #expect(abs(out[1] - 0.10005) < 1e-6)
}

@Test func downmixAllSilentStaysSilent() {
    #expect(Downmix.activeAverage([[0, 0, 0], [0, 0, 0]]) == [0, 0, 0])
    #expect(Downmix.activeChannels([[0, 0], [0, 0]]).isEmpty)
}

@Test func downmixMonoPassesThrough() {
    let voice: [Float] = [0.1, -0.1]
    #expect(Downmix.activeAverage([voice]) == voice)
}
