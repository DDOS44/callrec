import Foundation
import os

/// One place for diagnostics.
///
/// - Unified log: `Logger(subsystem: "com.blaxify.callrec", category: ...)`. Read it with
///   `log show --predicate 'subsystem == "com.blaxify.callrec"' --last 1h`.
/// - A human-readable line in `~/.callrec/callrec.log`, which `callrec doctor` and
///   the README point people at.
/// - Signpost intervals (VAD, transcription, merge) for timing without Xcode:
///   `log stream --signpost --predicate 'subsystem == "com.blaxify.callrec"'`.
///
/// Privacy: everything passed to `log` is marked public, so callers must never
/// pass transcript text or phone numbers. Paths, durations and error text are fine.
public enum LogCategory: String, Sendable {
    case capture, transcribe, watcher, app
}

public enum Log {
    public static let subsystem = "com.blaxify.callrec"

    private static let loggers: [LogCategory: Logger] = [
        .capture: Logger(subsystem: subsystem, category: "capture"),
        .transcribe: Logger(subsystem: subsystem, category: "transcribe"),
        .watcher: Logger(subsystem: subsystem, category: "watcher"),
        .app: Logger(subsystem: subsystem, category: "app")
    ]

    public static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    /// ~/.callrec/callrec.log, next to the config. CALLREC_LOG_FILE overrides it (the test runner uses this
    /// so tests never write into the real log).
    public static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["CALLREC_LOG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Config.url.deletingLastPathComponent().appendingPathComponent("callrec.log")
    }

    static let rotateAbove = 5_000_000
    private static let fileLock = NSLock()

    static func write(_ message: String, _ category: LogCategory, error: Bool) {
        let logger = loggers[category] ?? loggers[.app]!
        if error {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        appendToFile("[\(Date().ISO8601Format())] [\(category.rawValue)] \(message)\n")
        // An interactive command shows progress; under launchd stdout already
        // goes to callrec.log, so printing there would duplicate every line.
        if isatty(STDOUT_FILENO) != 0 { print("[callrec] \(message)") }
    }

    private static func appendToFile(_ line: String) {
        fileLock.lock(); defer { fileLock.unlock() }
        // The logger cannot log its own failure to the log; stderr is the fallback.
        func fallback(_ why: String) {
            FileHandle.standardError.write(Data("callrec: could not write \(fileURL.path): \(why)\n".utf8))
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let size = sizeIfPresent(fileURL), size > rotateAbove {
                let rotated = fileURL.appendingPathExtension("1")
                try removeIfPresent(rotated)
                try FileManager.default.moveItem(at: fileURL, to: rotated)
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: Data(line.utf8),
                                                     attributes: [.posixPermissions: 0o600]) else {
                    return fallback("create failed")
                }
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                do { try handle.close() } catch { fallback("close: \(error.localizedDescription)") }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            fallback(error.localizedDescription)
        }
    }

    // Local, non-logging versions: this file must not call `log`, or a failing log would recurse.
    private static func sizeIfPresent(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int // swiftlint:disable:this no_try_optional
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Times a block as a signpost interval.
    @discardableResult
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Async variant for the model calls.
    @discardableResult
    public static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }
}

/// Diagnostics for the log. Never pass transcript text or phone numbers: the
/// message is public in the unified log.
public func log(_ message: String, _ category: LogCategory = .app) {
    Log.write(message, category, error: false)
}

/// Same, at error level (shown in Console and kept longer than notices).
public func logError(_ message: String, _ category: LogCategory = .app) {
    Log.write(message, category, error: true)
}
