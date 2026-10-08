import Foundation

/// Deleting a call from history. User-initiated delete always goes to the Trash
/// (never `removeItem`), so it is undoable from Finder until the Trash is emptied.
public enum CallTrash {

    /// Every file in a day folder that belongs to the recording `base` ("HH-mm-ss"):
    /// `.m4a`, `.md`, raw `.far/.mic` `.wav/.caf`, `.mix.wav`, and the hidden
    /// `.<base>.md.lock`. Names are matched exactly on the base, so "09-05-07"
    /// never picks up "09-05-070.md". Audio and extras come first and the `.md`
    /// last: if a move fails midway the call still shows in the list with its transcript.
    public static func files(forBase base: String, in listing: [String]) -> [String] {
        guard !base.isEmpty else { return [] }
        let mine = listing.filter { name in
            name.hasPrefix(base + ".") || name == ".\(base).md.lock"
        }
        return mine.sorted { a, b in
            let am = a == base + ".md", bm = b == base + ".md"
            if am != bm { return bm }
            return a < b
        }
    }

    public struct Failure: Equatable, Sendable {
        public let file: String
        public let reason: String
    }

    public struct Result: Equatable, Sendable {
        public var trashed: [String] = []
        public var failed: [Failure] = []
        public var isComplete: Bool { failed.isEmpty }

        /// Plain-language report of a partial delete: which files moved, which did not.
        public var report: String {
            guard !failed.isEmpty else { return "" }
            let bad = failed.map { "\($0.file) (\($0.reason))" }.joined(separator: ", ")
            return "Could not move to the Trash: \(bad). \(trashed.count) other file(s) were moved; nothing was deleted permanently."
        }
    }

    /// Moves every file of the call to the Trash via `trash`. A failure never stops the
    /// others and is never swallowed: the result names each file that did not move.
    public static func trash(base: String, in dir: URL, listing: [String]? = nil,
                             using trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        -> Result {
        let names = files(forBase: base, in: listing ?? Fs.list(dir))
        var result = Result()
        for name in names {
            do {
                try trash(dir.appendingPathComponent(name))
                result.trashed.append(name)
            } catch {
                result.failed.append(Failure(file: name, reason: error.localizedDescription))
                log("could not move \(name) to the Trash: \(error.localizedDescription)")
            }
        }
        return result
    }
}
