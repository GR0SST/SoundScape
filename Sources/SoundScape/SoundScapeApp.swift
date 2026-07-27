import SwiftUI

enum AppWindow {
    static let dashboard = "dashboard"
}

final class SoundScapeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

@main
struct SoundScapeApp: App {
    @NSApplicationDelegateAdaptor(SoundScapeAppDelegate.self)
    private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var audioUnitCatalog = AudioUnitCatalog()
    @StateObject private var audioEnginePool = AudioEnginePool()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        Window("SoundScape", id: AppWindow.dashboard) {
            RootView()
                .environmentObject(store)
                .environmentObject(audioUnitCatalog)
                .environmentObject(audioEnginePool)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Audio Flow") {
                    store.createSession()
                }
                .keyboardShortcut("n")
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    settings.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            GraphPasteboardCommands()
        }

        MenuBarExtra(
            "SoundScape",
            systemImage: "waveform",
            isInserted: Binding(
                get: { settings.showMenuBarIcon },
                set: { isVisible in
                    guard settings.showMenuBarIcon != isVisible else { return }
                    settings.showMenuBarIcon = isVisible
                }
            )
        ) {
            MenuBarContentView()
                .environmentObject(store)
                .environmentObject(audioEnginePool)
        }
        .menuBarExtraStyle(.menu)
    }
}
