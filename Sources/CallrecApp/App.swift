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
                Button("Open Recordings Folder") { model.openRecordingsFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            Text(model.statusLine)
            Divider()
            Button("Open callrec") { activate() }
            if model.agentRunning {
                Button("Stop recorder") { model.setAgent(running: false) }
            } else {
                Button("Start recorder") { model.setAgent(running: true) }
            }
            Button("Open recordings folder") { model.openRecordingsFolder() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            MenuBarIcon(recording: model.recordingSince != nil)
        }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarIcon: View {
    let recording: Bool

    var body: some View {
        Image(systemName: "phone")
            .overlay(alignment: .topTrailing) {
                if recording {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
    }
}
