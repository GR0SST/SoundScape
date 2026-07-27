import AudioToolbox
import SwiftUI

enum SessionStatus: String, Codable {
    case ready = "Ready"
    case running = "Running"
    case draft = "Draft"
}

enum NodeKind: String, Codable, CaseIterable {
    case source
    case processor
    case effect
    case combine
    case utility
    case output

    var label: String {
        switch self {
        case .source: "INPUT"
        case .processor: "AUDIO UNIT"
        case .effect: "BUILT-IN"
        case .combine: "COMBINE"
        case .utility: "RECORDER"
        case .output: "OUTPUT"
        }
    }
}

enum BuiltInEffectType: String, Codable, CaseIterable, Hashable, Identifiable {
    case tenBandEQ
    case balance
    case lowPassFilter
    case magicBoost
    case pan
    case simpleCompressor
    case volume
    case parametricEQ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tenBandEQ: "10-Band EQ"
        case .balance: "Balance"
        case .lowPassFilter: "Low Pass Filter"
        case .magicBoost: "Magic Boost"
        case .pan: "Pan"
        case .simpleCompressor: "Simple Compressor"
        case .volume: "Volume"
        case .parametricEQ: "Parametric EQ"
        }
    }

    var icon: String {
        switch self {
        case .tenBandEQ: "slider.vertical.3"
        case .balance: "scale.3d"
        case .lowPassFilter: "waveform.path.ecg"
        case .magicBoost: "wand.and.stars"
        case .pan: "arrow.left.and.right"
        case .simpleCompressor: "arrow.down.right.and.arrow.up.left"
        case .volume: "speaker.wave.2.fill"
        case .parametricEQ: "waveform.path"
        }
    }

    var defaultParameters: [String: Double] {
        switch self {
        case .tenBandEQ:
            Dictionary(
                uniqueKeysWithValues: Self.graphicEQFrequencies.map {
                    ("eq.\(Int($0))", 0)
                }
            )
        case .balance:
            ["balance": 0]
        case .lowPassFilter:
            ["cutoff": 12_000, "resonance": 0.71]
        case .magicBoost:
            ["amount": 0.5]
        case .pan:
            ["pan": 0]
        case .simpleCompressor:
            [
                "threshold": -18,
                "ratio": 4,
                "attack": 0.01,
                "release": 0.12,
                "makeupGain": 0
            ]
        case .volume:
            ["gainDB": 0]
        case .parametricEQ:
            [:]
        }
    }

    static let graphicEQFrequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]
}

enum ChannelMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case stereo
    case mono

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CombineInputSettings: Codable, Hashable {
    var gainDB: Double = 0
    var pan: Double = 0
    var channelMode: ChannelMode = .stereo
}

enum ParametricFilterType: String, Codable, CaseIterable, Hashable, Identifiable {
    case highPass
    case lowShelf
    case peaking
    case highShelf
    case lowPass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highPass: "High Pass"
        case .lowShelf: "Low Shelf"
        case .peaking: "Peaking"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        }
    }
}

struct ParametricEQBand: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var isEnabled = true
    var type: ParametricFilterType = .peaking
    var frequency: Double = 1_000
    var q: Double = 1
    var gainDB: Double = 0
}

enum RecorderFileFormat: String, Codable, CaseIterable, Hashable, Identifiable {
    case wav
    case caf

    var id: String { rawValue }

    var label: String {
        rawValue.uppercased()
    }

    var fileExtension: String {
        rawValue
    }
}

enum RecorderDestination {
    static var defaultDirectoryURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(
            for: .musicDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return base.appendingPathComponent(
            "SoundScape",
            isDirectory: true
        )
    }
}

struct AudioUnitDescriptor: Identifiable, Codable, Hashable {
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32
    let name: String
    let manufacturerName: String
    let typeName: String
    let hasCustomView: Bool

    var id: String {
        [
            String(format: "%08X", componentType),
            String(format: "%08X", componentSubType),
            String(format: "%08X", componentManufacturer)
        ].joined(separator: "-")
    }

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

struct VST3Descriptor: Identifiable, Codable, Hashable, Sendable {
    let modulePath: String
    let classID: String
    let name: String
    let vendor: String
    let version: String
    let subcategories: String

    var id: String { classID }
}

enum AudioNodeType: Codable, Hashable {
    case inputDevice
    case applicationAudioInput
    case systemAudioInput
    case activeEchoCancellation
    case outputDevice
    case recorder
    case combine
    case builtInEffect(BuiltInEffectType)
    case audioUnit(AudioUnitDescriptor)
    case vst3(VST3Descriptor)

    var stableID: String {
        switch self {
        case .inputDevice: "input-device"
        case .applicationAudioInput: "application-audio-input"
        case .systemAudioInput: "system-audio-input"
        case .activeEchoCancellation: "active-echo-cancellation"
        case .outputDevice: "output-device"
        case .recorder: "recorder"
        case .combine: "combine"
        case .builtInEffect(let effect): "built-in-\(effect.rawValue)"
        case .audioUnit(let descriptor): "audio-unit-\(descriptor.id)"
        case .vst3(let descriptor): "vst3-\(descriptor.id)"
        }
    }
}

struct AudioNode: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var icon: String
    var kind: NodeKind
    var accent: Color
    var position: CGPoint
    var nodeType: AudioNodeType
    var isEnabled: Bool = true
    var level: Double = 0.75
    var gain: Double = 1.0
    var deviceUID: String?
    var upmixMonoToStereo: Bool = true
    var applicationBundleIdentifier: String?
    var excludesCurrentProcessAudio: Bool = true
    var parameterValues: [String: Double] = [:]
    var audioUnitState: Data?
    var recordingDirectoryPath: String?
    var recordingFormat: RecorderFileFormat = .wav
    var recordingFilePrefix: String = "SoundScape"
    var combineInputSettings: [String: CombineInputSettings] = [:]
    var combineOutputMode: ChannelMode = .stereo
    var parametricEQBands: [ParametricEQBand] = []

    var displayIcon: String {
        if case .applicationAudioInput = nodeType {
            return "macwindow"
        }
        return icon
    }

    var categoryLabel: String {
        if case .vst3 = nodeType {
            return "VST3"
        }
        return kind.label
    }

    static func == (lhs: AudioNode, rhs: AudioNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.kind == rhs.kind &&
        lhs.position == rhs.position &&
        lhs.nodeType == rhs.nodeType &&
        lhs.isEnabled == rhs.isEnabled &&
        lhs.level == rhs.level &&
        lhs.gain == rhs.gain &&
        lhs.deviceUID == rhs.deviceUID &&
        lhs.upmixMonoToStereo == rhs.upmixMonoToStereo &&
        lhs.applicationBundleIdentifier == rhs.applicationBundleIdentifier &&
        lhs.excludesCurrentProcessAudio == rhs.excludesCurrentProcessAudio &&
        lhs.parameterValues == rhs.parameterValues &&
        lhs.audioUnitState == rhs.audioUnitState &&
        lhs.recordingDirectoryPath == rhs.recordingDirectoryPath &&
        lhs.recordingFormat == rhs.recordingFormat &&
        lhs.recordingFilePrefix == rhs.recordingFilePrefix &&
        lhs.combineInputSettings == rhs.combineInputSettings &&
        lhs.combineOutputMode == rhs.combineOutputMode &&
        lhs.parametricEQBands == rhs.parametricEQBands
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct GraphConnection: Identifiable, Hashable {
    let id: UUID
    let from: String
    let to: String
    var isReference = false

    init(
        id: UUID = UUID(),
        from: String,
        to: String,
        isReference: Bool = false
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.isReference = isReference
    }
}

struct AudioSession: Identifiable {
    let id: UUID
    var name: String
    var description: String
    var icon: String
    var accent: Color
    var status: SessionStatus
    var sampleRate: String
    var nodes: [AudioNode]
    var connections: [GraphConnection]

    var sourceCount: Int {
        nodes.filter { $0.kind == .source }.count
    }

    var effectCount: Int {
        nodes.filter { $0.kind == .processor || $0.kind == .effect }.count
    }

    var topologyFingerprint: String {
        let nodePart = nodes
            .map {
                "\($0.id):\($0.nodeType.stableID):\($0.deviceUID ?? "default"):\($0.applicationBundleIdentifier ?? "all"):\($0.excludesCurrentProcessAudio)"
            }
            .sorted()
            .joined(separator: "|")
        let connectionPart = connections
            .map {
                "\($0.id.uuidString):\($0.from)>\($0.to):\($0.isReference ? "reference" : "audio")"
            }
            .sorted()
            .joined(separator: "|")
        return "\(nodePart)#\(connectionPart)"
    }

    var processingFingerprint: String {
        let audioConnections = connections.filter { !$0.isReference }
        let referenceConnections = connections.filter(\.isReference)
        let inputIDs = Set(nodes.compactMap { node -> String? in
            switch node.nodeType {
            case .inputDevice, .applicationAudioInput, .systemAudioInput:
                return node.id
            default:
                return nil
            }
        })
        let outputIDs = Set(nodes.compactMap { node -> String? in
            guard case .outputDevice = node.nodeType else { return nil }
            return node.id
        })
        let recorderIDs = Set(nodes.compactMap { node -> String? in
            guard case .recorder = node.nodeType else { return nil }
            return node.id
        })

        var reachableFromInput = inputIDs
        var changed = true
        while changed {
            changed = false
            for connection in audioConnections
            where reachableFromInput.contains(connection.from)
                && !reachableFromInput.contains(connection.to) {
                reachableFromInput.insert(connection.to)
                changed = true
            }
        }

        var canReachOutput = outputIDs.union(recorderIDs)
        changed = true
        while changed {
            changed = false
            for connection in audioConnections
            where canReachOutput.contains(connection.to)
                && !canReachOutput.contains(connection.from) {
                canReachOutput.insert(connection.from)
                changed = true
            }
        }

        var activeNodeIDs = reachableFromInput.intersection(canReachOutput)
        let activeReferenceConnections = referenceConnections.filter {
            activeNodeIDs.contains($0.to)
        }
        activeNodeIDs.formUnion(activeReferenceConnections.map(\.from))
        let nodePart = nodes
            .filter { activeNodeIDs.contains($0.id) }
            .map {
                let combineSettings = $0.combineInputSettings
                    .sorted { $0.key < $1.key }
                    .map {
                        "\($0.key)=\($0.value.channelMode.rawValue)"
                    }
                    .joined(separator: ",")
                return "\($0.id):\($0.nodeType.stableID):\($0.deviceUID ?? "default"):\($0.applicationBundleIdentifier ?? "all"):\($0.excludesCurrentProcessAudio):\($0.isEnabled):\($0.upmixMonoToStereo):\(combineSettings):\($0.combineOutputMode.rawValue):\($0.parametricEQBands.count)"
            }
            .sorted()
            .joined(separator: "|")
        let connectionPart = (audioConnections + activeReferenceConnections)
            .filter {
                activeNodeIDs.contains($0.from)
                    && activeNodeIDs.contains($0.to)
            }
            .map {
                "\($0.id.uuidString):\($0.from)>\($0.to):\($0.isReference)"
            }
            .sorted()
            .joined(separator: "|")
        return "\(nodePart)#\(connectionPart)"
    }
}

struct LibraryItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let icon: String
    let kind: NodeKind
    let nodeType: AudioNodeType

    var displayIcon: String {
        if case .applicationAudioInput = nodeType {
            return "macwindow"
        }
        return icon
    }

}

struct LibraryDropRequest: Identifiable, Equatable {
    let id = UUID()
    let item: LibraryItem
    let globalLocation: CGPoint
}

struct LibraryDragState: Equatable {
    let item: LibraryItem
    let globalLocation: CGPoint
}

struct LibrarySection: Identifiable {
    let id: String
    let title: String
    let items: [LibraryItem]
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AudioSession] {
        didSet { scheduleSave() }
    }

    @Published var activeSessionID: UUID?

    private let persistence: SQLiteProjectStore
    private var pendingSave: Task<Void, Never>?

    init(persistence: SQLiteProjectStore = .shared) {
        self.persistence = persistence
        let loadedSessions = persistence.loadSessions()
        self.sessions = loadedSessions.isEmpty
            ? DemoContent.sessions
            : loadedSessions
        self.activeSessionID = nil
        persistence.setSetting(nil, forKey: "last_active_project")

        // Persist decoded migrations immediately instead of waiting for the
        // user to edit the graph.
        persistence.saveSessions(self.sessions)
    }

    func createSession() {
        let session = DemoContent.blankSession(number: sessions.count + 1)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
    }

    func deleteSession(id: UUID) {
        if activeSessionID == id {
            activeSessionID = nil
        }
        sessions.removeAll { $0.id == id }
    }

    func renameSession(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[index].name = trimmedName
    }

    func duplicateSession(id: UUID) {
        guard let sourceIndex = sessions.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        let source = sessions[sourceIndex]
        let copy = AudioSession(
            id: UUID(),
            name: availableCopyName(for: source.name),
            description: source.description,
            icon: source.icon,
            accent: source.accent,
            status: .ready,
            sampleRate: source.sampleRate,
            nodes: source.nodes,
            connections: source.connections
        )
        sessions.insert(copy, at: sourceIndex + 1)
    }

    private func availableCopyName(for name: String) -> String {
        let baseName = "\(name) Copy"
        let existingNames = Set(sessions.map(\.name))
        guard existingNames.contains(baseName) else {
            return baseName
        }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func scheduleSave() {
        let snapshot = sessions
        pendingSave?.cancel()
        pendingSave = Task { [persistence] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            persistence.saveSessions(snapshot)
        }
    }
}

enum DemoContent {
    static let cyan = Color(red: 0.20, green: 0.80, blue: 0.95)
    static let violet = Color(red: 0.57, green: 0.45, blue: 0.98)
    static let mint = Color(red: 0.25, green: 0.86, blue: 0.68)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.23)

    static let sessions: [AudioSession] = [
        AudioSession(
            id: UUID(),
            name: "Microphone Chain",
            description: "",
            icon: "waveform.badge.mic",
            accent: cyan,
            status: .ready,
            sampleRate: "Device",
            nodes: [
                AudioNode(
                    id: "input",
                    title: "Input Device",
                    subtitle: "Default macOS microphone",
                    icon: "mic.fill",
                    kind: .source,
                    accent: cyan,
                    position: CGPoint(x: 160, y: 320),
                    nodeType: .inputDevice
                ),
                AudioNode(
                    id: "output",
                    title: "Output Device",
                    subtitle: "Default macOS output",
                    icon: "speaker.wave.3.fill",
                    kind: .output,
                    accent: cyan,
                    position: CGPoint(x: 620, y: 320),
                    nodeType: .outputDevice,
                    gain: 0.7
                )
            ],
            connections: [
                GraphConnection(from: "input", to: "output")
            ]
        )
    ]

    static let builtInLibrarySection = LibrarySection(
        id: "built-in",
        title: "Built-in",
        items: [
            LibraryItem(
                id: "input-device",
                title: "Input Device",
                icon: "mic.fill",
                kind: .source,
                nodeType: .inputDevice
            ),
            LibraryItem(
                id: "application-audio-input",
                title: "Application Audio Input",
                icon: "macwindow",
                kind: .source,
                nodeType: .applicationAudioInput
            ),
            LibraryItem(
                id: "system-audio-input",
                title: "System-Wide Audio Input",
                icon: "desktopcomputer",
                kind: .source,
                nodeType: .systemAudioInput
            ),
            LibraryItem(
                id: "output-device",
                title: "Output Device",
                icon: "speaker.wave.3.fill",
                kind: .output,
                nodeType: .outputDevice
            ),
            LibraryItem(
                id: "recorder",
                title: "Recorder",
                icon: "record.circle",
                kind: .utility,
                nodeType: .recorder
            ),
            LibraryItem(
                id: "combine",
                title: "Combine",
                icon: "arrow.triangle.merge",
                kind: .combine,
                nodeType: .combine
            ),
            LibraryItem(
                id: "active-echo-cancellation",
                title: "Active Echo Cancellation",
                icon: "waveform.badge.minus",
                kind: .effect,
                nodeType: .activeEchoCancellation
            )
        ] + BuiltInEffectType.allCases.map { effect in
            LibraryItem(
                id: "built-in-\(effect.rawValue)",
                title: effect.title,
                icon: effect.icon,
                kind: .effect,
                nodeType: .builtInEffect(effect)
            )
        }
    )

    static func blankSession(number: Int) -> AudioSession {
        AudioSession(
            id: UUID(),
            name: "Audio Flow \(number)",
            description: "",
            icon: "point.3.connected.trianglepath.dotted",
            accent: cyan,
            status: .draft,
            sampleRate: "Device",
            nodes: [],
            connections: []
        )
    }
}
