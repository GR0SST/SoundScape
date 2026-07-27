import AppKit
import SwiftUI

struct NodeGraphView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var session: AudioSession
    @Binding var selectedNodeID: String?
    @Binding var selectedNodeIDs: Set<String>
    @Binding var pendingLibraryDrop: LibraryDropRequest?
    @Binding var activeLibraryDrag: LibraryDragState?
    let removeNode: (String) -> Void
    let setNodesEnabled: (Set<String>, Bool) -> Void
    let registerUndo: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let dismissTextInput: () -> Void
    let addLibraryItem: (LibraryItem, CGPoint) -> Void
    let viewportInsertionPointChanged: (CGPoint) -> Void

    @State private var viewOffset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    @State private var lassoStart: CGPoint?
    @State private var lassoCurrent: CGPoint?

    @State private var activeDragNodeID: String?
    @State private var dragOrigins: [String: CGPoint] = [:]
    @State private var lastNodeDragTranslation: CGSize = .zero

    @State private var connectionDraft: ConnectionDraft?
    @State private var copiedNodes: [AudioNode] = []
    @State private var copiedConnections: [GraphConnection] = []
    @State private var pasteCount = 0

    private let baseNodeSize = CGSize(width: 176, height: 132)
    private let canvasSize = CGSize(width: 6000, height: 4000)

    var body: some View {
        GeometryReader { geometry in
            let viewportFrame = geometry.frame(in: .global)
            let dragPreview = activeLibraryDrag.flatMap { drag in
                viewportFrame.contains(drag.globalLocation)
                    ? drag
                    : nil
            }

            ZStack(alignment: .topLeading) {
                canvasContent
                    .offset(viewOffset)

                if let dragPreview {
                    LibraryNodeDragPreview(item: dragPreview.item)
                        .position(
                            x: dragPreview.globalLocation.x
                                - viewportFrame.minX,
                            y: dragPreview.globalLocation.y
                                - viewportFrame.minY
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(200)
                }

                if selectedNodeIDs.count > 1 {
                    Text("\(selectedNodeIDs.count) nodes selected")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AppTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        }
                        .position(x: geometry.size.width / 2, y: 24)
                        .allowsHitTesting(false)
                }

                MiddleMouseMonitor { delta in
                    panCanvas(by: delta, viewport: geometry.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                CanvasContextMenuMonitor(
                    shouldOpen: { viewportPoint in
                        let canvasPoint = CGPoint(
                            x: viewportPoint.x - viewOffset.width,
                            y: viewportPoint.y - viewOffset.height
                        )
                        return CGRect(origin: .zero, size: canvasSize).contains(canvasPoint)
                            && !isPointInsideNode(canvasPoint)
                    },
                    canCopy: !selectedNodeIDs.isEmpty,
                    canPaste: !copiedNodes.isEmpty,
                    copy: { copyNodes(selectedNodeIDs) },
                    paste: pasteNodes,
                    selectAll: {
                        selectedNodeIDs = Set(session.nodes.map(\.id))
                        selectedNodeID = nil
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .clipped()
            .contentShape(Rectangle())
            .background(AppTheme.background)
            .overlay {
                if dragPreview != nil {
                    Rectangle()
                        .stroke(
                            DemoContent.cyan.opacity(0.68),
                            style: StrokeStyle(
                                lineWidth: 2,
                                dash: [7, 5]
                            )
                        )
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
            .focusedSceneValue(
                \.graphCommandActions,
                GraphCommandActions(
                    canCopy: !selectedNodeIDs.isEmpty,
                    canPaste: !copiedNodes.isEmpty,
                    copy: { copyNodes(selectedNodeIDs) },
                    paste: pasteNodes,
                    delete: {
                        let ids = selectedNodeIDs
                        for id in ids {
                            removeNode(id)
                        }
                    },
                    canUndo: canUndo,
                    canRedo: canRedo,
                    undo: undo,
                    redo: redo
                )
            )
            .onAppear {
                viewportSize = geometry.size
                reportViewportInsertionPoint(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                clampCanvasOffset()
                reportViewportInsertionPoint(in: newSize)
            }
            .onChange(of: pendingLibraryDrop?.id) { _, _ in
                guard let request = pendingLibraryDrop else { return }
                defer { pendingLibraryDrop = nil }

                let viewportFrame = geometry.frame(in: .global)
                guard viewportFrame.contains(request.globalLocation) else {
                    return
                }
                dismissTextInput()
                let localPoint = CGPoint(
                    x: request.globalLocation.x - viewportFrame.minX,
                    y: request.globalLocation.y - viewportFrame.minY
                )
                addLibraryItem(
                    request.item,
                    clampedNodePosition(
                        CGPoint(
                            x: localPoint.x
                                - viewOffset.width
                                - baseNodeSize.width / 2,
                            y: localPoint.y
                                - viewOffset.height
                                - baseNodeSize.height / 2
                        )
                    )
                )
            }
        }
    }

    private var canvasContent: some View {
        ZStack(alignment: .topLeading) {
            GridBackground()
                .contentShape(Rectangle())

            connectionsLayer

            if let connectionDraft {
                connectionDraftLayer(connectionDraft)
            }

            ForEach(session.nodes) { node in
                let size = nodeSize(for: node)
                AudioNodeView(
                    node: node,
                    isSelected: selectedNodeIDs.contains(node.id),
                    combineInputCount: audioInputConnections(to: node.id).count
                )
                .frame(width: size.width, height: size.height)
                .position(
                    x: node.position.x + size.width / 2,
                    y: node.position.y + size.height / 2
                )
                .highPriorityGesture(nodeGesture(node.id))
                .contextMenu {
                    nodeContextMenu(node)
                }
                .help("Click to inspect · drag to move")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(node.title), \(node.kind.label)")
                .accessibilityAction {
                    selectNodeWithClick(node.id)
                }
            }

            portLayer

            if let rect = lassoRectangle {
                Rectangle()
                    .fill(DemoContent.cyan.opacity(0.08))
                    .overlay {
                        Rectangle()
                            .stroke(DemoContent.cyan.opacity(0.72), lineWidth: 1)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            if session.nodes.isEmpty {
                emptyState
                    .position(x: canvasSize.width / 2, y: canvasSize.height / 2)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .coordinateSpace(name: "graphCanvas")
        .simultaneousGesture(canvasSelectionGesture)
    }

    // MARK: - Selection and movement

    private var canvasSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("graphCanvas"))
            .onChanged { value in
                if lassoStart == nil {
                    dismissTextInput()
                }
                // The canvas gesture is simultaneous with node dragging. Re-check the
                // gesture origin on every update so dragging a node can never turn into
                // a lasso when SwiftUI changes gesture ownership mid-drag.
                if activeDragNodeID != nil || isPointInsideNode(value.startLocation) {
                    lassoStart = nil
                    lassoCurrent = nil
                    return
                }

                if lassoStart == nil {
                    lassoStart = value.startLocation
                }
                guard lassoStart != nil else { return }
                lassoCurrent = value.location
            }
            .onEnded { value in
                guard lassoStart != nil else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 3 {
                    selectedNodeIDs = []
                } else if let rect = lassoRectangle {
                    selectedNodeIDs = Set(
                        session.nodes.compactMap { node in
                            nodeFrame(node).intersects(rect) ? node.id : nil
                        }
                    )
                }

                selectedNodeID = nil
                lassoStart = nil
                lassoCurrent = nil
            }
    }

    private var lassoRectangle: CGRect? {
        guard let lassoStart, let lassoCurrent else { return nil }
        return CGRect(
            x: lassoStart.x,
            y: lassoStart.y,
            width: lassoCurrent.x - lassoStart.x,
            height: lassoCurrent.y - lassoStart.y
        ).standardized
    }

    private func nodeGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let translation = stableTranslation(for: value)
                let distance = hypot(translation.width, translation.height)
                guard distance >= 3 else { return }
                updateNodeDrag(id, translation: translation)
            }
            .onEnded { value in
                let wasDragging = activeDragNodeID == id
                if !wasDragging {
                    selectNodeWithClick(id)
                } else {
                    let translation = stableTranslation(for: value)
                    let endDistance = hypot(translation.width, translation.height)
                    updateNodeDrag(
                        id,
                        translation: endDistance >= 3 ? translation : lastNodeDragTranslation
                    )
                }
                activeDragNodeID = nil
                dragOrigins = [:]
                lastNodeDragTranslation = .zero
            }
    }

    private func stableTranslation(
        for value: DragGesture.Value
    ) -> CGSize {
        CGSize(
            width: value.location.x - value.startLocation.x,
            height: value.location.y - value.startLocation.y
        )
    }

    private func isPointInsideNode(_ point: CGPoint) -> Bool {
        session.nodes.contains { node in
            nodeFrame(node).insetBy(dx: -10, dy: -10).contains(point)
        }
    }

    private func selectNodeWithClick(_ id: String) {
        dismissTextInput()
        if NSEvent.modifierFlags.contains(.shift) {
            if selectedNodeIDs.contains(id) {
                selectedNodeIDs.remove(id)
            } else {
                selectedNodeIDs.insert(id)
            }
            selectedNodeID = selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil
        } else {
            selectedNodeIDs = [id]
            selectedNodeID = id
        }
    }

    private func updateNodeDrag(_ id: String, translation: CGSize) {
        lastNodeDragTranslation = translation

        if activeDragNodeID == nil {
            dismissTextInput()
            registerUndo()
            activeDragNodeID = id
            let movingIDs = selectedNodeIDs.contains(id) ? selectedNodeIDs : [id]
            dragOrigins = Dictionary(
                uniqueKeysWithValues: session.nodes.compactMap { node in
                    movingIDs.contains(node.id) ? (node.id, node.position) : nil
                }
            )
        }

        guard activeDragNodeID == id else { return }

        for (nodeID, origin) in dragOrigins {
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            session.nodes[index].position = clampedNodePosition(
                CGPoint(
                    x: origin.x + translation.width,
                    y: origin.y + translation.height
                )
            )
        }
    }

    private func clampedNodePosition(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 8), canvasSize.width - baseNodeSize.width - 8),
            y: min(max(point.y, 8), canvasSize.height - baseNodeSize.height - 8)
        )
    }

    private func nodeFrame(_ node: AudioNode) -> CGRect {
        CGRect(origin: node.position, size: nodeSize(for: node))
    }

    private func nodeSize(for node: AudioNode) -> CGSize {
        guard case .combine = node.nodeType else { return baseNodeSize }
        let inputCount = audioInputConnections(to: node.id).count + 1
        return CGSize(
            width: baseNodeSize.width,
            height: max(baseNodeSize.height, CGFloat(78 + inputCount * 28))
        )
    }

    private func audioInputConnections(to nodeID: String) -> [GraphConnection] {
        session.connections.filter { $0.to == nodeID && !$0.isReference }
    }

    // MARK: - Connections

    private var portLayer: some View {
        ForEach(session.nodes) { node in
            if node.kind != .source {
                if case .combine = node.nodeType {
                    ForEach(audioInputConnections(to: node.id)) { connection in
                        inputPort(
                            for: node,
                            connectionID: connection.id,
                            isReference: false
                        )
                    }
                    inputPort(
                        for: node,
                        connectionID: nil,
                        isReference: false
                    )
                } else {
                    inputPort(
                        for: node,
                        connectionID: audioInputConnections(to: node.id).first?.id,
                        isReference: false
                    )
                }

                if node.id == "aec" || node.title == "Echo Cancellation" {
                    inputPort(
                        for: node,
                        connectionID: session.connections.first {
                            $0.to == node.id && $0.isReference
                        }?.id,
                        isReference: true
                    )
                }
            }

            if node.kind != .output {
                outputPort(for: node)
            }
        }
    }

    private func inputPort(
        for node: AudioNode,
        connectionID: UUID?,
        isReference: Bool
    ) -> some View {
        let point = inputPoint(
            for: node,
            connectionID: connectionID,
            isReference: isReference
        )
        let hasConnection = connectionID != nil

        return ConnectionPortView(
            color: DemoContent.cyan,
            isConnected: hasConnection,
            isInput: true
        )
        .frame(width: 18, height: 18)
        .position(point)
        .highPriorityGesture(
            inputRewireGesture(
                nodeID: node.id,
                connectionID: connectionID,
                isReference: isReference
            )
        )
        .contextMenu {
            Button(role: .destructive) {
                disconnectInput(
                    node.id,
                    connectionID: connectionID,
                    isReference: isReference
                )
            } label: {
                Label("Disconnect Input", systemImage: "link.badge.minus")
            }
            .disabled(!hasConnection)
        }
        .help(isReference ? "AEC reference input" : "Input · drag to disconnect or rewire")
    }

    private func outputPort(for node: AudioNode) -> some View {
        let point = outputPoint(for: node)
        let hasConnection = session.connections.contains { $0.from == node.id }

        return ConnectionPortView(
            color: DemoContent.cyan,
            isConnected: hasConnection,
            isInput: false
        )
        .frame(width: 18, height: 18)
        .position(point)
        .highPriorityGesture(outputConnectionGesture(nodeID: node.id))
        .contextMenu {
            Button(role: .destructive) {
                if hasConnection {
                    registerUndo()
                }
                session.connections.removeAll { $0.from == node.id }
            } label: {
                Label("Disconnect Outputs", systemImage: "link.badge.minus")
            }
            .disabled(!hasConnection)
        }
        .help("Output · drag to an input")
    }

    private func outputConnectionGesture(nodeID: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("graphCanvas"))
            .onChanged { value in
                if connectionDraft == nil {
                    connectionDraft = ConnectionDraft(
                        fromNodeID: nodeID,
                        currentPoint: value.location
                    )
                } else {
                    connectionDraft?.currentPoint = value.location
                }
            }
            .onEnded { value in
                completeConnectionDrag(at: value.location)
            }
    }

    private func inputRewireGesture(
        nodeID: String,
        connectionID: UUID?,
        isReference: Bool
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graphCanvas"))
            .onChanged { value in
                if connectionDraft == nil,
                   let connectionID,
                   let index = session.connections.firstIndex(where: {
                       $0.id == connectionID
                   }) {
                    registerUndo()
                    let connection = session.connections.remove(at: index)
                    removeCombineSettings(
                        nodeID: nodeID,
                        connectionID: connection.id
                    )
                    connectionDraft = ConnectionDraft(
                        fromNodeID: connection.from,
                        currentPoint: value.location
                    )
                } else if connectionDraft != nil {
                    connectionDraft?.currentPoint = value.location
                }
            }
            .onEnded { value in
                completeConnectionDrag(at: value.location)
            }
    }

    private func completeConnectionDrag(at point: CGPoint) {
        guard let draft = connectionDraft else { return }

        if let target = nearestInput(to: point, excluding: draft.fromNodeID) {
            connect(
                from: draft.fromNodeID,
                to: target.nodeID,
                isReference: target.isReference
            )
        }

        connectionDraft = nil
    }

    private func connect(from sourceID: String, to targetID: String, isReference: Bool) {
        guard sourceID != targetID else { return }

        registerUndo()
        let isCombine = session.nodes.first(where: { $0.id == targetID }).map {
            if case .combine = $0.nodeType { return true }
            return false
        } ?? false
        if !isCombine || isReference {
            let removed = session.connections.filter {
                $0.to == targetID && $0.isReference == isReference
            }
            session.connections.removeAll {
                $0.to == targetID && $0.isReference == isReference
            }
            for connection in removed {
                removeCombineSettings(
                    nodeID: targetID,
                    connectionID: connection.id
                )
            }
        }

        guard !session.connections.contains(where: {
            $0.from == sourceID &&
            $0.to == targetID &&
            $0.isReference == isReference
        }) else { return }

        let connection = GraphConnection(
            from: sourceID,
            to: targetID,
            isReference: isReference
        )
        session.connections.append(connection)
        if isCombine, !isReference,
           let nodeIndex = session.nodes.firstIndex(where: { $0.id == targetID }) {
            session.nodes[nodeIndex].combineInputSettings[
                connection.id.uuidString
            ] = CombineInputSettings()
        }
    }

    private func disconnectInput(
        _ nodeID: String,
        connectionID: UUID?,
        isReference: Bool
    ) {
        guard session.connections.contains(where: {
            $0.to == nodeID
                && $0.isReference == isReference
                && (connectionID == nil || $0.id == connectionID)
        }) else { return }
        registerUndo()
        let removed = session.connections.filter {
            $0.to == nodeID
                && $0.isReference == isReference
                && (connectionID == nil || $0.id == connectionID)
        }
        session.connections.removeAll {
            $0.to == nodeID
                && $0.isReference == isReference
                && (connectionID == nil || $0.id == connectionID)
        }
        for connection in removed {
            removeCombineSettings(nodeID: nodeID, connectionID: connection.id)
        }
    }

    private func removeCombineSettings(nodeID: String, connectionID: UUID) {
        guard let nodeIndex = session.nodes.firstIndex(where: {
            $0.id == nodeID
        }) else { return }
        session.nodes[nodeIndex].combineInputSettings[connectionID.uuidString] = nil
    }

    private func disconnectAll(_ nodeIDs: Set<String>) {
        guard session.connections.contains(where: {
            nodeIDs.contains($0.from) || nodeIDs.contains($0.to)
        }) else { return }
        registerUndo()
        session.connections.removeAll {
            nodeIDs.contains($0.from) || nodeIDs.contains($0.to)
        }
    }

    private func nearestInput(to point: CGPoint, excluding sourceID: String) -> InputTarget? {
        var candidates: [(InputTarget, CGFloat)] = []

        for node in session.nodes where node.id != sourceID && node.kind != .source {
            let connectionID: UUID? = {
                if case .combine = node.nodeType { return nil }
                return audioInputConnections(to: node.id).first?.id
            }()
            let normalDistance = distance(
                point,
                inputPoint(
                    for: node,
                    connectionID: connectionID,
                    isReference: false
                )
            )
            candidates.append((InputTarget(nodeID: node.id, isReference: false), normalDistance))

            if node.id == "aec" || node.title == "Echo Cancellation" {
                let referenceDistance = distance(
                    point,
                    inputPoint(
                        for: node,
                        connectionID: session.connections.first {
                            $0.to == node.id && $0.isReference
                        }?.id,
                        isReference: true
                    )
                )
                candidates.append((InputTarget(nodeID: node.id, isReference: true), referenceDistance))
            }
        }

        return candidates
            .filter { $0.1 <= 30 }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func inputPoint(
        for node: AudioNode,
        connectionID: UUID?,
        isReference: Bool
    ) -> CGPoint {
        let size = nodeSize(for: node)
        if isReference {
            return CGPoint(
                x: node.position.x + size.width / 2,
                y: node.position.y
            )
        }
        if case .combine = node.nodeType {
            let connections = audioInputConnections(to: node.id)
            let index = connectionID.flatMap { id in
                connections.firstIndex(where: { $0.id == id })
            } ?? connections.count
            return CGPoint(
                x: node.position.x,
                y: node.position.y + 58 + CGFloat(index * 28)
            )
        }
        return CGPoint(
            x: node.position.x,
            y: node.position.y + size.height / 2
        )
    }

    private func outputPoint(for node: AudioNode) -> CGPoint {
        let size = nodeSize(for: node)
        return CGPoint(
            x: node.position.x + size.width,
            y: node.position.y + size.height / 2
        )
    }

    private var connectionsLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let flowPhase = reduceMotion
                ? CGFloat.zero
                : -CGFloat(elapsed.truncatingRemainder(dividingBy: 120)) * 24

            Canvas { context, _ in
                for connection in session.connections {
                    guard let fromNode = session.nodes.first(where: { $0.id == connection.from }),
                          let toNode = session.nodes.first(where: { $0.id == connection.to }) else {
                        continue
                    }

                    let start = outputPoint(for: fromNode)
                    let end = inputPoint(
                        for: toNode,
                        connectionID: connection.id,
                        isReference: connection.isReference
                    )
                    let path = connectionPath(from: start, to: end)

                    if connection.isReference {
                        context.stroke(
                            path,
                            with: .color(DemoContent.cyan.opacity(0.68)),
                            style: StrokeStyle(
                                lineWidth: 2.2,
                                lineCap: .round,
                                dash: [6, 7],
                                dashPhase: flowPhase
                            )
                        )
                    } else {
                        context.stroke(
                            path,
                            with: .color(
                                DemoContent.cyan.opacity(
                                    session.status == .running ? 0.50 : 0.30
                                )
                            ),
                            style: StrokeStyle(
                                lineWidth: 1.8,
                                lineCap: .round
                            )
                        )

                        context.stroke(
                            path,
                            with: .color(
                                Color(
                                    red: 0.58,
                                    green: 0.92,
                                    blue: 1.00
                                )
                                .opacity(session.status == .running ? 0.88 : 0.58)
                            ),
                            style: StrokeStyle(
                                lineWidth: 2.5,
                                lineCap: .round,
                                dash: [8, 15],
                                dashPhase: flowPhase
                            )
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private func connectionDraftLayer(_ draft: ConnectionDraft) -> some View {
        Canvas { context, _ in
            guard let source = session.nodes.first(where: { $0.id == draft.fromNodeID }) else {
                return
            }

            context.stroke(
                connectionPath(from: outputPoint(for: source), to: draft.currentPoint),
                with: .color(DemoContent.cyan.opacity(0.82)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
            )
        }
        .allowsHitTesting(false)
    }

    private func connectionPath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)

        let horizontalDistance = abs(end.x - start.x)
        let controlDistance = max(horizontalDistance * 0.45, 54)
        let direction: CGFloat = end.x >= start.x ? 1 : -1

        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlDistance * direction, y: start.y),
            control2: CGPoint(x: end.x - controlDistance * direction, y: end.y)
        )
        return path
    }

    // MARK: - Copy and paste

    @ViewBuilder
    private var canvasContextMenu: some View {
        Button {
            copyNodes(selectedNodeIDs)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(selectedNodeIDs.isEmpty)

        Button {
            pasteNodes()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(copiedNodes.isEmpty)

        Divider()

        Button {
            selectedNodeIDs = Set(session.nodes.map(\.id))
            selectedNodeID = nil
        } label: {
            Label("Select All", systemImage: "selection.pin.in.out")
        }
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: AudioNode) -> some View {
        let operationIDs: Set<String> = selectedNodeIDs.contains(node.id)
            ? selectedNodeIDs
            : [node.id]
        let toggleableIDs = Set<String>(session.nodes.compactMap { candidate in
            guard operationIDs.contains(candidate.id) else {
                return nil
            }
            switch candidate.nodeType {
            case .audioUnit, .builtInEffect, .combine, .recorder:
                return candidate.id
            case .inputDevice,
                 .applicationAudioInput,
                 .systemAudioInput,
                 .outputDevice:
                return nil
            }
        })

        Button {
            copyNodes(operationIDs)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            copyNodes(operationIDs)
            pasteNodes()
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button {
            pasteNodes()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(copiedNodes.isEmpty)

        Divider()

        if !toggleableIDs.isEmpty {
            Button {
                setNodesEnabled(toggleableIDs, !node.isEnabled)
            } label: {
                Label(
                    node.isEnabled
                        ? (toggleableIDs.count > 1 ? "Disable Nodes" : "Disable Node")
                        : (toggleableIDs.count > 1 ? "Enable Nodes" : "Enable Node"),
                    systemImage: node.isEnabled ? "pause.circle" : "play.circle"
                )
            }

            Divider()
        }

        Button(role: .destructive) {
            disconnectAll(operationIDs)
        } label: {
            Label("Disconnect", systemImage: "link.badge.minus")
        }

        Button(role: .destructive) {
            for id in operationIDs {
                removeNode(id)
            }
        } label: {
            Label(operationIDs.count > 1 ? "Remove Nodes" : "Remove Node", systemImage: "trash")
        }
    }

    private func copyNodes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        copiedNodes = session.nodes.filter { ids.contains($0.id) }
        copiedConnections = session.connections.filter {
            ids.contains($0.from) && ids.contains($0.to)
        }
        pasteCount = 0
    }

    private func pasteNodes() {
        guard !copiedNodes.isEmpty else { return }
        registerUndo()
        pasteCount += 1
        let offset = CGFloat(28 * pasteCount)
        var idMap: [String: String] = [:]
        var pastedIDs: Set<String> = []

        for copiedNode in copiedNodes {
            let newID = "\(copiedNode.id)-copy-\(UUID().uuidString.prefix(5))"
            idMap[copiedNode.id] = newID
            pastedIDs.insert(newID)

            var pastedNode = AudioNode(
                    id: newID,
                    title: copiedNode.title,
                    subtitle: copiedNode.subtitle,
                    icon: copiedNode.icon,
                    kind: copiedNode.kind,
                    accent: copiedNode.accent,
                    position: clampedNodePosition(
                        CGPoint(
                            x: copiedNode.position.x + offset,
                            y: copiedNode.position.y + offset
                        )
                    ),
                    nodeType: copiedNode.nodeType,
                    isEnabled: copiedNode.isEnabled,
                    level: copiedNode.level,
                    gain: copiedNode.gain,
                    deviceUID: copiedNode.deviceUID,
                    parameterValues: copiedNode.parameterValues,
                    audioUnitState: copiedNode.audioUnitState,
                    recordingDirectoryPath: copiedNode.recordingDirectoryPath,
                    recordingFormat: copiedNode.recordingFormat,
                    recordingFilePrefix: copiedNode.recordingFilePrefix,
                    combineInputSettings: [:],
                    combineOutputMode: copiedNode.combineOutputMode,
                    parametricEQBands: copiedNode.parametricEQBands
            )
            if case .combine = copiedNode.nodeType {
                pastedNode.combineInputSettings = [:]
            }
            session.nodes.append(pastedNode)
        }

        for copiedConnection in copiedConnections {
            guard let newFrom = idMap[copiedConnection.from],
                  let newTo = idMap[copiedConnection.to] else {
                continue
            }
            let pastedConnection = GraphConnection(
                from: newFrom,
                to: newTo,
                isReference: copiedConnection.isReference
            )
            session.connections.append(pastedConnection)
            if let targetIndex = session.nodes.firstIndex(where: {
                $0.id == newTo
            }),
               case .combine = session.nodes[targetIndex].nodeType {
                let originalSettings = copiedNodes.first(where: {
                    $0.id == copiedConnection.to
                })?.combineInputSettings[copiedConnection.id.uuidString]
                    ?? CombineInputSettings()
                session.nodes[targetIndex].combineInputSettings[
                    pastedConnection.id.uuidString
                ] = originalSettings
            }
        }

        selectedNodeIDs = pastedIDs
        selectedNodeID = nil
    }

    // MARK: - Canvas panning

    private func panCanvas(by delta: CGSize, viewport: CGSize) {
        viewportSize = viewport
        viewOffset.width += delta.width
        viewOffset.height += delta.height
        clampCanvasOffset()
        reportViewportInsertionPoint(in: viewport)
    }

    private func clampCanvasOffset() {
        let margin: CGFloat = 800
        let minimumX = min(0, viewportSize.width - canvasSize.width) - margin
        let minimumY = min(0, viewportSize.height - canvasSize.height) - margin

        viewOffset.width = min(margin, max(minimumX, viewOffset.width))
        viewOffset.height = min(margin, max(minimumY, viewOffset.height))
    }

    private func reportViewportInsertionPoint(in viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        viewportInsertionPointChanged(
            clampedNodePosition(
                CGPoint(
                    x: viewport.width / 2
                        - viewOffset.width
                        - baseNodeSize.width / 2,
                    y: viewport.height / 2
                        - viewOffset.height
                        - baseNodeSize.height / 2
                )
            )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(DemoContent.cyan.opacity(0.10))
                    .frame(width: 72, height: 72)

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(DemoContent.cyan)
            }

            Text("Empty Flow")
                .font(.system(size: 17, weight: .bold))
        }
    }
}

private struct ConnectionDraft {
    let fromNodeID: String
    var currentPoint: CGPoint
}

private struct InputTarget {
    let nodeID: String
    let isReference: Bool
}

private struct ConnectionPortView: View {
    let color: Color
    let isConnected: Bool
    let isInput: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.background)
                .overlay {
                    Circle()
                        .stroke(color.opacity(0.95), lineWidth: 2)
                }

            if isConnected {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            } else if isInput {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 4, height: 4)
            }
        }
        .contentShape(Circle())
    }
}

private struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var x: CGFloat = 0
            while x <= size.width {
                var y: CGFloat = 0
                while y <= size.height {
                    let rect = CGRect(x: x, y: y, width: 1.3, height: 1.3)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.075)))
                    y += spacing
                }
                x += spacing
            }
        }
        .background(AppTheme.background)
    }
}

private struct LibraryNodeDragPreview: View {
    let item: LibraryItem

    var body: some View {
        AudioNodeView(
            node: AudioNode(
                id: "library-drag-preview",
                title: item.title,
                subtitle: " ",
                icon: item.icon,
                kind: item.kind,
                accent: DemoContent.cyan,
                position: .zero,
                nodeType: item.nodeType
            ),
            isSelected: true,
            combineInputCount: 0
        )
        .frame(width: 176, height: 132)
        .opacity(0.88)
    }
}

private struct AudioNodeView: View {
    let node: AudioNode
    let isSelected: Bool
    let combineInputCount: Int
    private let accent = DemoContent.cyan

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(node.kind.label)
                    .font(.system(size: 8.5, weight: .black))
                    .tracking(0.8)
                    .foregroundStyle(accent)

                Spacer()

                Circle()
                    .fill(node.isEnabled ? DemoContent.mint : AppTheme.tertiaryText)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Color.white.opacity(0.025))

            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.11))

                    Image(systemName: node.displayIcon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(node.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(maxHeight: .infinity)

            if case .combine = node.nodeType {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.merge")
                    Text("\(combineInputCount) input\(combineInputCount == 1 ? "" : "s")")
                    Spacer()
                    Text(node.combineOutputMode.title)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 28)
            }
        }
        .background(AppTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? accent : Color.white.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .opacity(node.isEnabled ? 1 : 0.56)
        .contentShape(Rectangle())
    }
}

private struct CanvasContextMenuMonitor: NSViewRepresentable {
    let shouldOpen: (CGPoint) -> Bool
    let canCopy: Bool
    let canPaste: Bool
    let copy: () -> Void
    let paste: () -> Void
    let selectAll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldOpen: shouldOpen,
            canCopy: canCopy,
            canPaste: canPaste,
            copy: copy,
            paste: paste,
            selectAll: selectAll
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldOpen = shouldOpen
        context.coordinator.canCopy = canCopy
        context.coordinator.canPaste = canPaste
        context.coordinator.copy = copy
        context.coordinator.paste = paste
        context.coordinator.selectAll = selectAll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator: NSObject {
        weak var view: NSView?
        var shouldOpen: (CGPoint) -> Bool
        var canCopy: Bool
        var canPaste: Bool
        var copy: () -> Void
        var paste: () -> Void
        var selectAll: () -> Void
        private var monitor: Any?

        init(
            shouldOpen: @escaping (CGPoint) -> Bool,
            canCopy: Bool,
            canPaste: Bool,
            copy: @escaping () -> Void,
            paste: @escaping () -> Void,
            selectAll: @escaping () -> Void
        ) {
            self.shouldOpen = shouldOpen
            self.canCopy = canCopy
            self.canPaste = canPaste
            self.copy = copy
            self.paste = paste
            self.selectAll = selectAll
        }

        func installMonitor() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self,
                      let view,
                      event.window === view.window else {
                    return event
                }

                let localPoint = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(localPoint) else { return event }

                let viewportPoint = CGPoint(
                    x: localPoint.x,
                    y: view.bounds.height - localPoint.y
                )
                guard shouldOpen(viewportPoint) else { return event }

                let menu = NSMenu()

                let copyItem = NSMenuItem(
                    title: "Copy",
                    action: #selector(copySelection),
                    keyEquivalent: ""
                )
                copyItem.target = self
                copyItem.isEnabled = canCopy
                menu.addItem(copyItem)

                let pasteItem = NSMenuItem(
                    title: "Paste",
                    action: #selector(pasteSelection),
                    keyEquivalent: ""
                )
                pasteItem.target = self
                pasteItem.isEnabled = canPaste
                menu.addItem(pasteItem)

                menu.addItem(.separator())

                let selectAllItem = NSMenuItem(
                    title: "Select All",
                    action: #selector(selectEveryNode),
                    keyEquivalent: ""
                )
                selectAllItem.target = self
                menu.addItem(selectAllItem)

                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return nil
            }
        }

        @objc private func copySelection() {
            copy()
        }

        @objc private func pasteSelection() {
            paste()
        }

        @objc private func selectEveryNode() {
            selectAll()
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct MiddleMouseMonitor: NSViewRepresentable {
    let onPan: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPan: onPan)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPan = onPan
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onPan: (CGSize) -> Void
        private var monitor: Any?
        private var lastMiddlePoint: CGPoint?

        init(onPan: @escaping (CGSize) -> Void) {
            self.onPan = onPan
        }

        func installMonitor() {
            guard monitor == nil else { return }
            let mask = NSEvent.EventTypeMask.otherMouseDown
                .union(.otherMouseDragged)
                .union(.otherMouseUp)

            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self,
                      event.buttonNumber == 2,
                      let view,
                      event.window === view.window else {
                    return event
                }

                let localPoint = view.convert(event.locationInWindow, from: nil)
                switch event.type {
                case .otherMouseDown:
                    if view.bounds.contains(localPoint) {
                        lastMiddlePoint = localPoint
                    }

                case .otherMouseDragged:
                    guard let previousPoint = lastMiddlePoint else { return event }
                    onPan(
                        CGSize(
                            width: localPoint.x - previousPoint.x,
                            height: -(localPoint.y - previousPoint.y)
                        )
                    )
                    lastMiddlePoint = localPoint

                case .otherMouseUp:
                    lastMiddlePoint = nil

                default:
                    break
                }

                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            lastMiddlePoint = nil
        }

        deinit {
            removeMonitor()
        }
    }
}
