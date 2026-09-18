import Foundation

struct RecordingPaths {
    let dir: URL
    let base: String
    var m4a: URL { dir.appendingPathComponent(base + ".m4a") }
    var md: URL { dir.appendingPathComponent(base + ".md") }
    var farWav: URL { dir.appendingPathComponent(base + ".far.wav") }
    var micWav: URL { dir.appendingPathComponent(base + ".mic.wav") }
    var mixWav: URL { dir.appendingPathComponent(base + ".mix.wav") }
}

enum Paths {
    nonisolated(unsafe) static var root: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CallRecordings")

    static func forCall(at date: Date, root: URL = Paths.root) -> RecordingPaths {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH-mm-ss"
        return RecordingPaths(dir: root.appendingPathComponent(day.string(from: date)),
                              base: time.string(from: date))
    }

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
