import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var audioEnginePool: AudioEnginePool
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""
    @State private var selectedFilter = "All"
    @FocusState private var searchFieldFocused: Bool

    private var filteredSessions: [AudioSession] {
        store.sessions.filter { session in
            let matchesSearch = searchText.isEmpty ||
                session.name.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = selectedFilter == "All" ||
                (selectedFilter == "Running" && session.status == .running) ||
                (selectedFilter == "Drafts" && session.status == .draft)
            return matchesSearch && matchesFilter
        }
    }

    var body: some View {
        mainContent
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    searchFieldFocused = false
                    dismissTextInputFocus()
                }
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio Flows")
                    .font(.system(size: 28, weight: .bold))

                Spacer()

                Button {
                    store.createSession()
                } label: {
                    Label("New Flow", systemImage: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(DemoContent.cyan)
                        .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Audio Flow")
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 24)

            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.tertiaryText)

                    TextField("Search flows", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFieldFocused)
                        .onSubmit {
                            searchFieldFocused = false
                            dismissTextInputFocus()
                        }
                        .onExitCommand {
                            searchFieldFocused = false
                            dismissTextInputFocus()
                        }
                }
                .padding(.horizontal, 13)
                .frame(maxWidth: 310)
                .frame(height: 36)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                }

                filterPicker

                Spacer()

                Text("\(filteredSessions.count) flows")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(filteredSessions) { session in
                        SessionRow(
                            session: session,
                            audioEngine: audioEnginePool.engine(for: session.id),
                            open: {
                                searchFieldFocused = false
                                dismissTextInputFocus()
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    store.activeSessionID = session.id
                                }
                            },
                            toggleFlow: {
                                Task {
                                    await audioEnginePool.toggleFlow(
                                        sessionID: session.id,
                                        in: store
                                    )
                                }
                            },
                            rename: { name in
                                store.renameSession(id: session.id, to: name)
                            },
                            duplicate: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.duplicateSession(id: session.id)
                                }
                            },
                            delete: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    audioEnginePool.stopAndRemoveEngine(
                                        for: session.id
                                    )
                                    store.deleteSession(id: session.id)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 34)
            }

            HStack {
                settingsButton
                Spacer()
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 18)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.line)
                    .frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            searchFieldFocused = false
            dismissTextInputFocus()
        }
    }

    private var settingsButton: some View {
        Button {
            settings.isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.055))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private var filterPicker: some View {
        HStack(spacing: 3) {
            ForEach(["All", "Running", "Drafts"], id: \.self) { filter in
                Button(filter) {
                    selectedFilter = filter
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selectedFilter == filter ? .white : AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selectedFilter == filter ? Color.white.opacity(0.09) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

}

private struct SessionRow: View {
    let session: AudioSession
    @ObservedObject var audioEngine: AudioEngineController
    let open: () -> Void
    let toggleFlow: () -> Void
    let rename: (String) -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var isRenaming = false
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 17) {
            if isRenaming {
                rowSummary
            } else {
                Button(action: open) {
                    rowSummary
                }
                .buttonStyle(.plain)
            }

            Button(action: toggleFlow) {
                Label(
                    audioEngine.isFlowEnabled ? "Stop Flow" : "Run Flow",
                    systemImage: audioEngine.isFlowEnabled
                        ? "stop.fill"
                        : "play.fill"
                )
                .font(.system(size: 11, weight: .bold))
                .frame(width: 94, height: 32)
                .background(
                    audioEngine.isFlowEnabled
                        ? DemoContent.mint
                        : DemoContent.cyan
                )
                .foregroundStyle(Color(red: 0.03, green: 0.10, blue: 0.12))
                .clipShape(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                audioEngine.isFlowEnabled ? "Stop Flow" : "Run Flow"
            )
            .frame(width: 108)

            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .frame(width: 24, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(session.name)")
        }
        .padding(.horizontal, 17)
        .frame(height: 72)
        .background(hovering ? AppTheme.surfaceHover : AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hovering ? Color.white.opacity(0.14) : AppTheme.line, lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .onChange(of: nameFieldFocused) { _, focused in
            if isRenaming, !focused {
                commitRename()
            }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(action: duplicate) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Divider()

            Button(role: .destructive, action: delete) {
                Label("Delete Flow", systemImage: "trash")
            }
        }
    }

    private var rowSummary: some View {
        HStack(spacing: 17) {
            Group {
                if isRenaming {
                    TextField("Flow name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .bold))
                        .focused($nameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                        .accessibilityLabel("Flow name")
                } else {
                    Text(session.name)
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                metric(value: "\(session.sourceCount)", label: "Sources")
                metric(value: "\(session.effectCount)", label: "Effects")
            }
            .frame(width: 150)
        }
        .contentShape(Rectangle())
    }

    private func beginRename() {
        nameDraft = session.name
        isRenaming = true
        Task { @MainActor in
            await Task.yield()
            nameFieldFocused = true
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        let trimmedName = nameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedName.isEmpty {
            rename(trimmedName)
        }
        isRenaming = false
        nameFieldFocused = false
    }

    private func cancelRename() {
        isRenaming = false
        nameDraft = session.name
        nameFieldFocused = false
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)
        }
    }
}
