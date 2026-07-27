import SwiftUI

struct WorkspaceView: View {
    @Binding var session: AudioSession
    @ObservedObject var audioEngine: AudioEngineController
    let close: () -> Void

    @StateObject private var audioDevices = AudioDeviceCatalog()
    @StateObject private var systemAudioApplications =
        SystemAudioApplicationCatalog()
    @State private var selectedNodeID: String?
    @State private var selectedNodeIDs: Set<String> = []
    @State private var searchText = ""
    @State private var inspectorVisible = false
    @State private var undoStack: [AudioSession] = []
    @State private var redoStack: [AudioSession] = []
    @State private var isRenamingSession = false
    @State private var sessionNameDraft = ""
    @State private var libraryInsertionPoint = CGPoint(x: 420, y: 300)
    @State private var pendingLibraryDrop: LibraryDropRequest?
    @State private var activeLibraryDrag: LibraryDragState?
    @FocusState private var focusedTextField: WorkspaceTextFocus?

    private var selectedNodeBinding: Binding<AudioNode>? {
        guard let selectedNodeID,
              let index = session.nodes.firstIndex(where: { $0.id == selectedNodeID }) else {
            return nil
        }
        return Binding(
            get: { session.nodes[index] },
            set: { session.nodes[index] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar

            Rectangle()
                .fill(AppTheme.line)
                .frame(height: 1)

            HStack(spacing: 0) {
                BlockLibraryView(
                    searchText: $searchText,
                    addItem: { item in
                        addLibraryItem(
                            item,
                            at: libraryInsertionPoint
                        )
                    },
                    dragChanged: { item, globalLocation in
                        activeLibraryDrag = LibraryDragState(
                            item: item,
                            globalLocation: globalLocation
                        )
                    },
                    dropItem: { item, globalLocation in
                        activeLibraryDrag = nil
                        pendingLibraryDrop = LibraryDropRequest(
                            item: item,
                            globalLocation: globalLocation
                        )
                    },
                    focusedField: $focusedTextField
                )
                .frame(width: 270)

                Rectangle()
                    .fill(AppTheme.line)
                    .frame(width: 1)

                ZStack(alignment: .trailing) {
                    NodeGraphView(
                        session: $session,
                        selectedNodeID: $selectedNodeID,
                        selectedNodeIDs: $selectedNodeIDs,
                        pendingLibraryDrop: $pendingLibraryDrop,
                        activeLibraryDrag: $activeLibraryDrag,
                        removeNode: removeNode,
                        setNodesEnabled: setNodesEnabled,
                        registerUndo: registerGraphUndo,
                        canUndo: !undoStack.isEmpty,
                        canRedo: !redoStack.isEmpty,
                        undo: undoGraph,
                        redo: redoGraph,
                        dismissTextInput: clearTextFocus,
                        addLibraryItem: { item, position in
                            addLibraryItem(item, at: position)
                        },
                        viewportInsertionPointChanged: { point in
                            libraryInsertionPoint = point
                        }
                    )

                    if inspectorVisible, let node = selectedNodeBinding {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(AppTheme.line)
                                .frame(width: 1)

                            NodeInspectorView(
                                node: node,
                                audioEngine: audioEngine,
                                audioDevices: audioDevices,
                                systemAudioApplications:
                                    systemAudioApplications,
                                graphNodes: session.nodes,
                                graphConnections: session.connections,
                                focusedField: $focusedTextField,
                                close: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        selectedNodeID = nil
                                        inspectorVisible = false
                                    }
                                },
                                delete: {
                                    if let selectedNodeID {
                                        removeNode(selectedNodeID)
                                    }
                                }
                            )
                            .frame(width: 310)
                        }
                        .frame(width: 311)
                        .background(AppTheme.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle()
                .fill(AppTheme.line)
                .frame(height: 1)

            transportBar
        }
        .background(AppTheme.background)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                clearTextFocus()
            }
        }
        .onChange(of: selectedNodeID) { _, newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: 0.18)) {
                    inspectorVisible = true
                }
            }
        }
        .onChange(of: session.processingFingerprint) { oldValue, newValue in
            guard oldValue != newValue else { return }
            guard audioEngine.isFlowEnabled else {
                audioEngine.clearIdleError()
                return
            }
            Task {
                await audioEngine.start(session: session)
                syncSessionWithEngine()
            }
        }
        .onChange(of: audioEngine.isRunning) { _, running in
            session.status = running ? .running : .ready
        }
        .onChange(of: focusedTextField) { _, newValue in
            if isRenamingSession, newValue != .sessionName {
                commitSessionRename()
            }
        }
        .onDeleteCommand {
            if !selectedNodeIDs.isEmpty {
                removeNodes(selectedNodeIDs)
            } else if let selectedNodeID {
                removeNode(selectedNodeID)
            }
        }
        .onDisappear {
            captureAudioUnitStates()
        }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 14) {
            ClickThroughToolbarButton(
                title: nil,
                systemImage: "chevron.left",
                accessibilityLabel: "Back to Audio Flows",
                appearance: .navigation,
                action: close
            )
            .frame(width: 32, height: 32)

            if isRenamingSession {
                TextField("Flow name", text: $sessionNameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .focused($focusedTextField, equals: .sessionName)
                    .frame(width: 240)
                    .onSubmit {
                        commitSessionRename()
                    }
                    .onExitCommand {
                        cancelSessionRename()
                    }
                    .accessibilityLabel("Flow name")
            } else {
                Text(session.name)
                    .font(.system(size: 14, weight: .bold))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginSessionRename()
                    }
            }

            Spacer()

            ClickThroughToolbarButton(
                title: audioEngine.isFlowEnabled ? "Stop Flow" : "Run Flow",
                systemImage: audioEngine.isFlowEnabled ? "stop.fill" : "play.fill",
                accessibilityLabel:
                    audioEngine.isFlowEnabled ? "Stop Flow" : "Run Flow",
                appearance: .transport(
                    isRunning: audioEngine.isFlowEnabled
                ),
                action: {
                    clearTextFocus()
                    toggleAudioEngine()
                }
            )
            .frame(width: 110, height: 34)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color.black.opacity(0.10))
        .zIndex(100)
    }

    private var transportBar: some View {
        HStack(spacing: 15) {
            StatusPill(
                label: runtimeStatus.label,
                color: runtimeStatus.color
            )

            OutputLevelMeter(
                levelDB: audioEngine.outputLevelDB,
                isRunning: audioEngine.isRunning,
                color: DemoContent.mint
            )

            Text(audioEngine.errorMessage ?? audioEngine.statusMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    audioEngine.errorMessage != nil
                        ? Color.red.opacity(0.85)
                        : (audioEngine.isRunning ? DemoContent.mint : AppTheme.secondaryText)
                )
                .lineLimit(1)

            Spacer()

            Label(
                audioEngine.sampleRate.map {
                    String(format: "%.1f kHz", $0 / 1_000)
                } ?? session.sampleRate,
                systemImage: "waveform"
            )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)

            Text("128 samples")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.black.opacity(0.13))
    }

    private var runtimeStatus: (label: String, color: Color) {
        if audioEngine.isRunning {
            return ("Running", DemoContent.mint)
        }
        if audioEngine.isFlowEnabled {
            return (
                audioEngine.isLoading ? "Connecting" : "Reconnecting",
                DemoContent.orange
            )
        }
        switch session.status {
        case .draft:
            return ("Draft", AppTheme.secondaryText)
        case .ready, .running:
            return ("Stopped", DemoContent.cyan)
        }
    }

    private func addLibraryItem(
        _ item: LibraryItem,
        at preferredPosition: CGPoint
    ) {
        clearTextFocus()
        registerGraphUndo()
        let uniqueID = "\(item.id)-\(UUID().uuidString.prefix(5))"
        var node = AudioNode(
            id: uniqueID,
            title: item.title,
            subtitle: nodeSubtitle(for: item.nodeType),
            icon: item.icon,
            kind: item.kind,
            accent: DemoContent.cyan,
            position: nextAvailablePosition(near: preferredPosition),
            nodeType: item.nodeType
        )
        if case .builtInEffect(let effect) = item.nodeType {
            node.parameterValues = effect.defaultParameters
            if effect == .parametricEQ {
                node.parametricEQBands = [
                    ParametricEQBand(
                        type: .highPass,
                        frequency: 80,
                        q: 0.71
                    ),
                    ParametricEQBand(
                        type: .peaking,
                        frequency: 1_000,
                        q: 1
                    ),
                    ParametricEQBand(
                        type: .highShelf,
                        frequency: 8_000,
                        q: 0.71
                    )
                ]
            }
        }
        session.nodes.append(node)
        selectedNodeID = nil
        selectedNodeIDs = []
        inspectorVisible = false
    }

    private func nodeSubtitle(for nodeType: AudioNodeType) -> String {
        switch nodeType {
        case .inputDevice:
            "Default macOS input"
        case .applicationAudioInput:
            "Choose an application"
        case .systemAudioInput:
            "All system audio"
        case .outputDevice:
            "Default macOS output"
        case .recorder:
            "WAV recording"
        case .combine:
            "Multi-input mixer"
        case .builtInEffect:
            "Built-in effect"
        case .audioUnit(let descriptor):
            descriptor.manufacturerName
        }
    }

    private func selectExistingNode(_ id: String) {
        selectedNodeIDs = [id]
        selectedNodeID = id
        inspectorVisible = true
    }

    private func nextAvailablePosition(near preferred: CGPoint) -> CGPoint {
        let horizontalStep: CGFloat = 206
        let verticalStep: CGFloat = 158

        for radius in 0...8 {
            for row in -radius...radius {
                for column in -radius...radius
                where radius == 0
                    || abs(row) == radius
                    || abs(column) == radius {
                    let candidate = clampedLibraryPosition(
                        CGPoint(
                            x: preferred.x
                                + CGFloat(column) * horizontalStep,
                            y: preferred.y
                                + CGFloat(row) * verticalStep
                        )
                    )
                    let occupied = session.nodes.contains { node in
                        abs(node.position.x - candidate.x) < 150
                            && abs(node.position.y - candidate.y) < 112
                    }
                    if !occupied {
                        return candidate
                    }
                }
            }
        }

        return clampedLibraryPosition(preferred)
    }

    private func clampedLibraryPosition(_ point: CGPoint) -> CGPoint {
        let nodeSize = CGSize(width: 176, height: 132)
        let canvasSize = CGSize(width: 6_000, height: 4_000)
        return CGPoint(
            x: min(
                max(point.x, 8),
                canvasSize.width - nodeSize.width - 8
            ),
            y: min(
                max(point.y, 8),
                canvasSize.height - nodeSize.height - 8
            )
        )
    }

    private func removeNode(_ id: String) {
        removeNodes([id])
    }

    private func removeNodes(_ ids: Set<String>) {
        guard session.nodes.contains(where: { ids.contains($0.id) }) else { return }
        registerGraphUndo()

        withAnimation(.easeInOut(duration: 0.16)) {
            session.nodes.removeAll { ids.contains($0.id) }
            session.connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
            selectedNodeIDs.subtract(ids)

            if let currentNodeID = selectedNodeID, ids.contains(currentNodeID) {
                self.selectedNodeID = nil
                inspectorVisible = false
            }
        }
    }

    private func setNodesEnabled(_ ids: Set<String>, _ enabled: Bool) {
        let affectedIndices = session.nodes.indices.filter { index in
            ids.contains(session.nodes[index].id)
                && session.nodes[index].isEnabled != enabled
                && {
                    switch session.nodes[index].nodeType {
                    case .audioUnit, .builtInEffect, .combine, .recorder:
                        return true
                    case .inputDevice,
                         .applicationAudioInput,
                         .systemAudioInput,
                         .outputDevice:
                        return false
                    }
                }()
        }
        guard !affectedIndices.isEmpty else { return }

        registerGraphUndo()
        for index in affectedIndices {
            session.nodes[index].isEnabled = enabled
        }
    }

    private func registerGraphUndo() {
        undoStack.append(session)
        if undoStack.count > 60 {
            undoStack.removeFirst(undoStack.count - 60)
        }
        redoStack.removeAll()
    }

    private func undoGraph() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(session)
        session = previous
        clearGraphSelection()
    }

    private func redoGraph() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(session)
        session = next
        clearGraphSelection()
    }

    private func clearGraphSelection() {
        selectedNodeID = nil
        selectedNodeIDs = []
        inspectorVisible = false
    }

    private func clearTextFocus() {
        if isRenamingSession {
            commitSessionRename()
        }
        focusedTextField = nil
        dismissTextInputFocus()
    }

    private func beginSessionRename() {
        sessionNameDraft = session.name
        isRenamingSession = true
        Task { @MainActor in
            await Task.yield()
            focusedTextField = .sessionName
        }
    }

    private func commitSessionRename() {
        guard isRenamingSession else { return }
        let trimmedName = sessionNameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedName.isEmpty {
            session.name = trimmedName
        }
        isRenamingSession = false
        focusedTextField = nil
    }

    private func cancelSessionRename() {
        isRenamingSession = false
        sessionNameDraft = session.name
        focusedTextField = nil
    }

    private func toggleAudioEngine() {
        if audioEngine.isFlowEnabled {
            captureAudioUnitStates()
            audioEngine.stop()
            session.status = .ready
        } else {
            Task {
                await audioEngine.start(session: session)
                syncSessionWithEngine()
            }
        }
    }

    private func syncSessionWithEngine() {
        session.status = audioEngine.isFlowEnabled ? .running : .ready
        if let sampleRate = audioEngine.sampleRate {
            session.sampleRate = String(format: "%.1f kHz", sampleRate / 1_000)
        }
    }

    private func captureAudioUnitStates() {
        let states = audioEngine.capturedAudioUnitStates()
        guard !states.isEmpty else { return }
        for index in session.nodes.indices {
            if let state = states[session.nodes[index].id] {
                session.nodes[index].audioUnitState = state
            }
        }
    }
}
