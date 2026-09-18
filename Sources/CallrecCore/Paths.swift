import Foundation

public struct RecordingPaths {
    public let dir: URL
    public let base: String
    public var m4a: URL { dir.appendingPathComponent(base + ".m4a") }
    public var md: URL { dir.appendingPathComponent(base + ".md") }
    public var farWav: URL { dir.appendingPathComponent(base + ".far.wav") }
    public var micWav: URL { dir.appendingPathComponent(base + ".mic.wav") }
    public var mixWav: URL { dir.appendingPathComponent(base + ".mix.wav") }
}

public enum Paths {
    public nonisolated(unsafe) static var root: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CallRecordings")

    public static func forCall(at date: Date, root: URL = Paths.root) -> RecordingPaths {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH-mm-ss"
        return RecordingPaths(dir: root.appendingPathComponent(day.string(from: date)),
                              base: time.string(from: date))
    }

    public static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
