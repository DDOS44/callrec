// Runs the Swift Testing tests in the SwiftPM test bundle.
//
// Why this exists: on a Command Line Tools-only Mac, `swift test` builds the
// test bundle and then exits 0 WITHOUT running anything (no XCTest, and
// SwiftPM does not launch swiftpm-testing-helper). A green `swift test` there
// means nothing. This runner dlopens the bundle and drives the swift-testing
// ABI entry point directly, prints every failure, and exits non-zero on any.
//
// Usage: scripts/test.sh   (builds, compiles this file, runs it)
import Foundation

typealias EntryPoint = @convention(thin) @Sendable (
    _ configurationJSON: UnsafeRawBufferPointer?,
    _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
) async throws -> Bool

final class Tally: @unchecked Sendable {
    let lock = NSLock()
    var names: [String: String] = [:]     // test id -> display name (functions only)
    var started = Set<String>()
    var failed: [String: [String]] = [:]  // test id -> issue messages
    var rawIssues: [String] = []
    func with(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: run-tests <bundle-binary> [name-substring]\n".utf8))
    exit(2)
}
let bundle = CommandLine.arguments[1]
// Tests must never write into the real ~/.callrec/callrec.log.
setenv("CALLREC_LOG_FILE", NSTemporaryDirectory() + "callrec-tests.log", 1)
guard let handle = dlopen(bundle, RTLD_NOW) else {
    FileHandle.standardError.write(Data("dlopen failed: \(String(cString: dlerror()))\n".utf8))
    exit(2)
}
guard let sym = dlsym(handle, "swt_abiv0_getEntryPoint") else {
    FileHandle.standardError.write(Data("swt_abiv0_getEntryPoint not found: is Testing linked into the bundle?\n".utf8))
    exit(2)
}
typealias Getter = @convention(c) () -> UnsafeRawPointer
let entry = unsafeBitCast(unsafeBitCast(sym, to: Getter.self)(), to: EntryPoint.self)

let tally = Tally()
let handler: @Sendable (UnsafeRawBufferPointer) -> Void = { buf in
    guard let obj = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any],
          let kind = obj["kind"] as? String,
          let payload = obj["payload"] as? [String: Any] else { return }
    tally.with {
        if kind == "test", payload["kind"] as? String == "function",
           let id = payload["id"] as? String, let name = payload["name"] as? String {
            tally.names[id] = name
        } else if kind == "event" {
            let ek = payload["kind"] as? String ?? ""
            let tid = payload["testID"] as? String
            if ek == "testStarted", let tid { tally.started.insert(tid) }
            if ek == "issueRecorded" {
                let msgs = (payload["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                let text = msgs.joined(separator: " | ")
                if let tid { tally.failed[tid, default: []].append(text) } else { tally.rawIssues.append(text) }
            }
        }
    }
}

var config: [String: Any] = ["verbosity": 0]
if CommandLine.arguments.count >= 3 { config["filter"] = [CommandLine.arguments[2]] }
let configData = try JSONSerialization.data(withJSONObject: config)

let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: configData.count, alignment: 1)
configData.copyBytes(to: raw)
let ok: Bool = try await entry(UnsafeRawBufferPointer(raw), handler)
raw.deallocate()

let functionIDs = tally.names.keys.filter { tally.started.contains($0) }.sorted()
var failedCount = 0
for id in functionIDs {
    if let msgs = tally.failed[id] ?? tally.failed[id.replacingOccurrences(of: "()", with: "")] {
        failedCount += 1
        print("FAIL \(tally.names[id] ?? id)")
        for m in msgs { print("     \(m)") }
    }
}
for m in tally.rawIssues { print("ISSUE \(m)") }
let total = functionIDs.count
print("\(total - failedCount)/\(total) tests passed")
if total == 0 {
    print("ERROR: no tests ran. A green result with zero tests is a false green.")
    exit(1)
}
exit((ok && failedCount == 0 && tally.rawIssues.isEmpty) ? 0 : 1)
