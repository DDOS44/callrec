import Foundation

/// Small helpers so an error is either handled or leaves a line in the log.
/// They exist so production code never needs a bare `try?`.

/// Runs `body`. If it throws, logs "<what>: <error>" and returns nil.
@discardableResult
public func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
    do {
        return try body()
    } catch {
        log("\(what): \(error.localizedDescription)")
        return nil
    }
}

/// Filesystem calls where "it was not there" is fine but anything else is not.
public enum Fs {
    /// True when the error just means the file or folder does not exist.
    public static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, underlying as NSError != ns { return isMissing(underlying) }
        return false
    }

    /// Names in a folder. A missing folder is an empty list; any other failure is logged.
    public static func list(_ dir: URL) -> [String] { list(path: dir.path) }

    public static func list(path: String) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            if !isMissing(error) { log("could not list \(path): \(error.localizedDescription)") }
            return []
        }
    }

    /// Size in bytes, or nil if the file does not exist or cannot be read (the latter is logged).
    public static func size(of url: URL) -> Int? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        } catch {
            if !isMissing(error) { log("could not stat \(url.path): \(error.localizedDescription)") }
            return nil
        }
    }

    /// Removes a file. Already gone is fine; any other failure is logged.
    public static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if !isMissing(error) { log("could not remove \(url.path): \(error.localizedDescription)") }
        }
    }

    /// Text of a file, or nil if it does not exist. Any other failure is logged and also nil.
    public static func text(_ url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            if !isMissing(error) { log("could not read \(url.path): \(error.localizedDescription)") }
            return nil
        }
    }
}
