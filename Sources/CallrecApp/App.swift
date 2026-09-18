import AppKit
import CallrecCore
import SwiftUI

@main
struct CallrecAppMain: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { model.reload() }.keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            Text(model.statusLine)
            Divider()
            Button("Open callrec") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            if model.agentRunning {
                Button("Stop recorder") { model.setAgent(running: false) }
            } else {
                Button("Start recorder") { model.setAgent(running: true) }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.recordingSince != nil ? "phone.fill" : "phone")
                .foregroundStyle(model.recordingSince != nil ? .red : .primary)
        }
    }
}
