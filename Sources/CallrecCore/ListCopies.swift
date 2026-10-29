import Foundation

/// Re-importing a list must not start it from scratch. Every import used to create a fresh copy
/// (MASTER-CALL-LIST-2, -3, ...) with its own, empty progress file, so loading the same sheet
/// again lost every lead status. An identical file already in the lists folder is reused instead.
public enum ListCopies {

    /// The copy in `dir` whose bytes equal `source`'s, or nil. With several identical copies, the
    /// one whose progress file was written last wins (that is the one the user was working in).
    public static func existingCopy(of source: URL, in dir: URL) -> URL? {
        let wanted: Data
        do { wanted = try Data(contentsOf: source) } catch {
            // Fail safe: no reuse, the import makes a fresh copy as before.
            log("lists: could not read \(source.lastPathComponent) to compare with earlier imports: \(error.localizedDescription)")
            return nil
        }
        let copies = Fs.list(dir)
            .filter { $0.lowercased().hasSuffix(".csv") }
            .map { dir.appendingPathComponent($0) }
            .filter { csv in
                do { return try Data(contentsOf: csv) == wanted } catch {
                    log("lists: could not read \(csv.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
            }
        return copies.max { a, b in
            let da = progressDate(a), db = progressDate(b)
            return da == db ? a.lastPathComponent > b.lastPathComponent : da < db
        }
    }

    /// When the list's progress file was last written; distant past when it has none yet (normal).
    private static func progressDate(_ csv: URL) -> Date {
        let state = DialerPaths.stateURL(forList: csv)
        guard FileManager.default.fileExists(atPath: state.path) else { return .distantPast }
        do {
            return try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as? Date ?? .distantPast
        } catch {
            log("lists: could not read the date of \(state.lastPathComponent): \(error.localizedDescription)")
            return .distantPast
        }
    }
}
