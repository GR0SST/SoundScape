import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var audioEnginePool: AudioEnginePool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            AppTheme.appBackground
                .ignoresSafeArea()

            if let activeID = store.activeSessionID,
               let index = store.sessions.firstIndex(where: { $0.id == activeID }) {
                WorkspaceView(
                    session: Binding(
                        get: { store.sessions[index] },
                        set: { store.sessions[index] = $0 }
                    ),
                    audioEngine: audioEnginePool.engine(for: activeID),
                    close: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            store.activeSessionID = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                SessionListView()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.activeSessionID)
        .sheet(isPresented: $settings.isSettingsPresented) {
            AppSettingsView(settings: settings)
        }
        .onAppear {
            settings.applyDockIconVisibility()
        }
    }
}
