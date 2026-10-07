import Foundation
import Testing
@testable import CallrecCore

private let haveFFmpeg = Shell.which("ffmpeg") != nil

private func tempPaths() throws -> RecordingPaths {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("callrec-fin-\(UUID())/2026-10-06")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return RecordingPaths(dir: dir, base: "10-00-00")
}

private func makeCAF(_ url: URL, rate: Int, seconds: Int) throws {
    let r = try Shell.run(Shell.which("ffmpeg")!, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                                                   "-ar", "\(rate)", "-ac", "1", "-c:a", "pcm_s16le", url.path])
    #expect(r.status == 0, "ffmpeg could not make the test CAF: \(r.stderr)")
}

/// Makes a CAF look like one a killed process left behind: the data chunk has no
/// length (-1) and the file ends mid-stream.
private func damageLikeACrash(_ url: URL, chopBytes: Int) throws {
    var bytes = try Data(contentsOf: url)
    guard let range = bytes.range(of: Data("data".utf8)) else { Issue.record("no data chunk"); return }
    let sizeField = range.upperBound
    bytes.replaceSubrange(sizeField..<(sizeField + 8), with: Data(repeating: 0xFF, count: 8))
    bytes.removeLast(chopBytes)
    try bytes.write(to: url)
}

@Test(.enabled(if: haveFFmpeg)) func interruptedRecordingIsRecoveredFromRawCapture() throws {
    let paths = try tempPaths(); defer { try? FileManager.default.removeItem(at: paths.dir.deletingLastPathComponent()) }
    try makeCAF(paths.farCaf, rate: 16_000, seconds: 4)
    try makeCAF(paths.micCaf, rate: 48_000, seconds: 4)
    try damageLikeACrash(paths.farCaf, chopBytes: 1001)
    try damageLikeACrash(paths.micCaf, chopBytes: 3001)

    expect(Finalize.isInterrupted(paths), "recover.detected")
    let issues = Doctor.scan(root: paths.dir.deletingLastPathComponent())
    expect(issues.contains { $0.base == "10-00-00" && $0.problem.hasPrefix("interrupted") }, "recover.doctorFlags", "\(issues)")

    try Finalize.recover(paths: paths)

    let far = Media.duration(of: paths.farWav) ?? 0
    let mic = Media.duration(of: paths.micWav) ?? 0
    expect(far > 3.8 && far <= 4.01, "recover.farDuration", "\(far)")
    expect(mic > 3.8 && mic <= 4.01, "recover.micDuration", "\(mic)")
    expect(FileManager.default.fileExists(atPath: paths.m4a.path), "recover.m4aBuilt")
    expect(!FileManager.default.fileExists(atPath: paths.farCaf.path), "recover.rawRemovedAfterVerification")
    expect(!FileManager.default.fileExists(atPath: paths.micCaf.path), "recover.rawRemovedAfterVerification2")
    expect(!Finalize.isInterrupted(paths), "recover.noLongerInterrupted")
    expect(!Doctor.scan(root: paths.dir.deletingLastPathComponent()).contains { $0.problem.hasPrefix("interrupted") },
           "recover.doctorClean")
}

@Test(.enabled(if: haveFFmpeg)) func rawCaptureIsNeverDeletedWhenConversionFails() throws {
    let paths = try tempPaths(); defer { try? FileManager.default.removeItem(at: paths.dir.deletingLastPathComponent()) }
    try makeCAF(paths.farCaf, rate: 16_000, seconds: 2)
    try Data("this is not audio at all".utf8).write(to: paths.micCaf)

    #expect(throws: (any Error).self) { try Finalize.tracks(paths: paths) }
    expect(FileManager.default.fileExists(atPath: paths.farCaf.path), "safe.goodRawKeptWhenSiblingFails")
    expect(FileManager.default.fileExists(atPath: paths.micCaf.path), "safe.badRawKept")
}

@Test(.enabled(if: haveFFmpeg)) func healthyStopFinalizesTracksAndMix() throws {
    let paths = try tempPaths(); defer { try? FileManager.default.removeItem(at: paths.dir.deletingLastPathComponent()) }
    try makeCAF(paths.farCaf, rate: 16_000, seconds: 3)
    try makeCAF(paths.micCaf, rate: 48_000, seconds: 3)
    try Finalize.tracks(paths: paths)
    try Finalize.mixAndEncode(paths: paths, wallClockSeconds: 3)
    equal(Doctor.hasAudio(paths), true, "finalize.hasAudio")
    expect((Media.duration(of: paths.mixWav) ?? 0) > 2.9, "finalize.mixDuration")
    expect(FileManager.default.fileExists(atPath: paths.m4a.path), "finalize.m4a")
    expect(!Finalize.hasRawCapture(paths), "finalize.noRawLeft")
}
