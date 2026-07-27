import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var audioEnginePool: AudioEnginePool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Dashboard") {
            openWindow(id: AppWindow.dashboard)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        ForEach(store.sessions) { session in
            Button {
                let sessionID = session.id
                Task {
                    await audioEnginePool.toggleFlow(sessionID: sessionID, in: store)
                }
            } label: {
                Label(
                    "\(session.status == .running ? "Stop" : "Run") \(session.name)",
                    systemImage: session.status == .running
                        ? "stop.fill"
                        : "play.fill"
                )
            }
        }

        Divider()

        Button("Quit SoundScape") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
