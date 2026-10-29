import AppKit
import CallrecCore
import SwiftUI

/// `callrec-app --snapshot-booking out.png`: renders the booking box with fake data (a fake lead, a
/// fake Cal.com that never touches the network) to a PNG, to show what it looks like without a call.
/// Writes nothing anywhere else: the lead state lives in a temporary folder that is removed.
@MainActor
enum BookingSnapshot {
    static func render(to out: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("callrec-snapshot-\(UUID())")
        defer { Fs.remove(dir) }
        do {
            try Paths.ensureDir(dir)
            let leads = try LeadImporter.parse("company,phone,owner\nFake Recruiters Pvt Ltd,9000000001,Rahul Sharma\n")
            let store = try LeadStateStore(url: dir.appendingPathComponent("s.state.json"), listName: "snapshot")
            var config = Config(); config.recordingsDir = dir.path; config.calcomEventTypeId = 1
            config.bookingLink = "https://cal.com/example/30min"
            var services = DialRunner.Services(
                dialer: TelURLDialer(), config: config, listName: "snapshot", leads: leads, store: store,
                dialLogURL: dir.appendingPathComponent("log.jsonl"), dncURL: dir.appendingPathComponent("dnc.txt"),
                calendar: .current, now: { Date() }, callState: { .init(recording: false) },
                loadHistory: { HistorySnapshot(rows: [], detection: .unavailable(reason: "snapshot")) },
                applyToMarkdown: { _, _, _, _ in false }, saveColdSIM: { _ in }, autoTick: false)
            services.calcom = CalCom(apiKey: "none", eventTypeId: 1, timeZone: .current) { _ in throw CalCom.Failure(message: "offline") }
            let runner = DialRunner(services)
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            let slots = stride(from: 10.0, through: 16.5, by: 0.5).map { tomorrow.addingTimeInterval($0 * 3600) }
            let view = BookingBox(runner: runner, leadID: "9000000001",
                                  preview: (name: "Rahul Sharma", email: "rahul@fakerecruiters.in", slots: slots, picked: slots[3]))
                .frame(width: 760).padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let onAppear fill the fields
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("could not render"); return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out)
            print("wrote \(out.path)")
        } catch { print("snapshot failed: \(error.localizedDescription)") }
    }
}
