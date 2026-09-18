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

    static func install() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.callrec", withIntermediateDirectories: true)
        try plistText(binary: binary, home: home).write(to: plistURL, atomically: true, encoding: .utf8)

        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        let r = try Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path], timeout: 30)
        guard r.status == 0 else {
            throw NSError(domain: "callrec", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey:
                "Could not start the background recorder.\n\(r.stderr)"])
        }
        print("Background recorder started. It runs every time you log in.")
        print("Check it anytime with: callrec status")
    }

    static func uninstall() throws {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        try? FileManager.default.removeItem(at: plistURL)
        print("Background recorder stopped.")
    }
}
