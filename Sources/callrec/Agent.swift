import Foundation
import CallrecCore

/// The launchd agent that keeps `callrec watch` running in the background.
enum Agent {
    static let label = "com.blaxify.callrec"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func plistText(binary: String, home: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(binary)</string><string>watch</string></array>
          <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
          <key>StandardOutPath</key><string>\(home)/.callrec/callrec.log</string>
          <key>StandardErrorPath</key><string>\(home)/.callrec/callrec.log</string>
          <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
        </dict></plist>
        """
    }

    /// Absolute path of the running executable. NOT `CommandLine.arguments[0]`:
    /// when invoked via PATH that is just "callrec", which resolved against the
    /// current directory and wrote a non-existent path into the launchd plist —
    /// the recorder then exited on every start (EX_CONFIG) while `status` said
    /// "Watching". Keep this absolute.
    static func executablePath() throws -> String {
        guard let raw = Bundle.main.executablePath else {
            throw NSError(domain: "callrec", code: 70, userInfo: [NSLocalizedDescriptionKey:
                "Could not determine where the callrec binary lives."])
        }
        let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw NSError(domain: "callrec", code: 70, userInfo: [NSLocalizedDescriptionKey:
                "Resolved binary path is not an executable file: \(path)"])
        }
        return path
    }

    static func install() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binary = try executablePath()
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Paths.ensureDir(URL(fileURLWithPath: home + "/.callrec"))
        try plistText(binary: binary, home: home).write(to: plistURL, atomically: true, encoding: .utf8)

        unload()
        let r = try Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path], timeout: 30)
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey:
                "Could not start the background recorder.\n\(r.stderr)"])
        }
        // Fail loudly: confirm the job actually stays up instead of assuming it did.
        Thread.sleep(forTimeInterval: 2)
        let job = jobState()
        guard job.running else {
            throw NSError(domain: "callrec", code: 71, userInfo: [NSLocalizedDescriptionKey:
                "The background recorder was registered but is not running (\(job.detail)). See ~/.callrec/callrec.log"])
        }
        print("Background recorder started (\(binary)). It runs every time you log in.")
        print("Check it anytime with: callrec status")
    }

    /// What launchd says about the job right now. The daemon's own state file can
    /// be stale; launchd is the source of truth for "is it alive".
    static func jobState() -> (loaded: Bool, running: Bool, detail: String) {
        guard let r = try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 10), // swiftlint:disable:this no_try_optional
              r.status == 0 else {
            return (false, false, "not loaded")
        }
        return parseJobState(r.stdout)
    }

    static func parseJobState(_ out: String) -> (loaded: Bool, running: Bool, detail: String) {
        let st = LaunchdJob.parse(out)
        return (true, st.running, st.detail)
    }

    /// `bootout` exits nonzero when the job is not loaded, which is fine and not an error here.
    /// Only failing to run launchctl at all is reported.
    private static func unload() {
        do { _ = try Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20) }
        catch { print("warning: could not run launchctl bootout: \(error.localizedDescription)") }
    }

    static func uninstall() throws {
        unload()
        Fs.remove(plistURL)
        print("Background recorder stopped.")
    }
}
