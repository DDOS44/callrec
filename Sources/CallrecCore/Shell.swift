import Foundation

public enum Shell {
    @discardableResult
    public static func run(_ cmd: String, _ args: [String], timeout: TimeInterval = 600) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            throw NSError(domain: "callrec", code: 124, userInfo: [NSLocalizedDescriptionKey: "\(cmd) timed out after \(Int(timeout))s"])
        }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, o, e)
    }

    public static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
