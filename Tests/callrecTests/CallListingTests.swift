import Testing
@testable import CallrecCore

@Test func callsListedByAudioOrTranscript() {
    let files = [
        "00-16-31.m4a", "00-16-31.far.wav", "00-16-31.mic.wav",          // audio only: transcription pending
        "09-00-00.md",                                                   // transcript only
        "10-00-00.m4a", "10-00-00.md",                                   // both
        "11-00-00.far.caf", "11-00-00.mic.caf",                          // interrupted / live: raw only
        "session-12-00-00.m4a", ".10-00-00.md.lock", ".metadata_never_index", "notes.txt"
    ]
    let entries = CallListing.entries(files: files)
    equal(entries.map(\.base), ["11-00-00", "10-00-00", "09-00-00", "00-16-31"], "listing.bases.newestFirst")

    let audioOnly = entries.first { $0.base == "00-16-31" }
    expect(audioOnly?.audioOnly == true, "listing.audioOnly", "m4a with no .md must be listed")
    equal(audioOnly?.audioFile, "00-16-31.m4a", "listing.prefersM4a")
    expect(audioOnly?.rawOnly == false, "listing.audioOnlyNotRaw")

    let mdOnly = entries.first { $0.base == "09-00-00" }
    expect(mdOnly?.hasMarkdown == true && mdOnly?.audioFile == nil, "listing.mdOnly")
    expect(mdOnly?.audioOnly == false, "listing.mdOnlyNotAudioOnly")

    let both = entries.first { $0.base == "10-00-00" }
    expect(both?.hasMarkdown == true && both?.audioFile == "10-00-00.m4a" && both?.audioOnly == false, "listing.both")

    let raw = entries.first { $0.base == "11-00-00" }
    expect(raw?.rawOnly == true && raw?.audioOnly == true, "listing.rawOnly", "interrupted recording is listed")
    equal(raw?.audioFile, "11-00-00.far.caf", "listing.rawPlayable")
}
