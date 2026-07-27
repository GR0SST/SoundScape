import AppKit
import AudioToolbox
import AVFAudio
import CoreAudioKit
import Foundation

struct HostedAUParameter: Identifiable, Hashable {
    let address: AUParameterAddress
    let name: String
    let minimum: AUValue
    let maximum: AUValue
    var value: AUValue
    let unit: AudioUnitParameterUnit
    let unitName: String
    let valueStrings: [String]
    let isWritable: Bool

    var id: AUParameterAddress { address }
}

struct HostedAUCustomView {
    let viewController: NSViewController
    let intrinsicSize: CGSize
}

@MainActor
final class AudioEngineController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isFlowEnabled = false
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var sampleRate: Double?
    @Published private(set) var routeDescription: String?
    @Published private(set) var inputLevelDB: Double = -96
    @Published private(set) var processedLevelDB: Double = -96
    @Published private(set) var outputLevelDB: Double = -96
    @Published private(set) var parametersByNodeID: [String: [HostedAUParameter]] = [:]
    @Published private(set) var inspectorErrorsByNodeID: [String: String] = [:]
    @Published private(set) var loadingInspectorNodeIDs: Set<String> = []
    @Published private(set) var customViewsByNodeID: [
        String: HostedAUCustomView
    ] = [:]
    @Published private(set) var loadingCustomViewNodeIDs: Set<String> = []
    @Published private(set) var customViewErrorsByNodeID: [String: String] = [:]
    @Published private(set) var activeRecorderNodeIDs: Set<String> = []
    @Published private(set) var recordingURLsByNodeID: [String: URL] = [:]
    @Published private(set) var recorderErrorsByNodeID: [String: String] = [:]
    @Published private(set) var recordedDurationByNodeID: [String: TimeInterval] = [:]

    private var engine = AVAudioEngine()
    private var outputEngine = AVAudioEngine()
    private var additionalInputEngines: [AVAudioEngine] = []
    private var additionalInputSourceNodes: [AVAudioSourceNode] = []
    private var screenAudioCaptureSources: [ScreenAudioCaptureSource] = []
    private var additionalOutputEngines: [AVAudioEngine] = []
    private var hostedOutputMixers: [String: AVAudioMixerNode] = [:]
    private var outputEngineActive = false
    private var processingEngineOutputActive = false
    private var hostedUnits: [String: AVAudioUnit] = [:]
    private var hostedBuiltInNodes: [String: AVAudioNode] = [:]
    private var hostedCombineMixers: [String: AVAudioMixerNode] = [:]
    private var hostedCombineInputNodes: [String: AVAudioMixerNode] = [:]
    private var audioUnitGeneration = UUID()
    private var bridgeBuffer: AudioRingBuffer?
    private var inputAdapterNode: AVAudioMixerNode?
    private var sinkNode: AVAudioSinkNode?
    private var auxiliarySinkNode: AVAudioSinkNode?
    private var auxiliaryMixerNode: AVAudioMixerNode?
    private var sourceNode: AVAudioSourceNode?
    private var recorderNodesByNodeID: [String: AVAudioMixerNode] = [:]
    private var recorderWritersByNodeID: [String: RecorderWriter] = [:]
    private var recorderTapNodeIDs: Set<String> = []
    private let levelProbe = AudioLevelProbe()
    private var meterTimer: Timer?
    private var hasInputTap = false
    private var hasOutputTap = false
    private var hardwareInputActive = false
    private var activeSession: AudioSession?
    private var recoveryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var configurationObservers: [NSObjectProtocol] = []
    private var startGeneration = UUID()

    func start(session: AudioSession) async {
        let fallbackSession = isRunning ? activeSession : nil
        isFlowEnabled = true
        recoveryTask?.cancel()
        recoveryTask = nil
        startupTask?.cancel()
        startupTask = nil
        startGeneration = UUID()
        let generation = startGeneration
        await attemptStart(
            session: session,
            generation: generation,
            fallbackSession: fallbackSession
        )
    }

    private func attemptStart(
        session: AudioSession,
        generation: UUID,
        fallbackSession: AudioSession? = nil
    ) async {
        guard isFlowEnabled, generation == startGeneration else { return }

        do {
            _ = try graphPlan(in: session)
        } catch {
            guard isFlowEnabled, generation == startGeneration else { return }
            if isRunning, activeSession != nil {
                isLoading = false
                errorMessage = friendlyError(error)
                warningMessage = nil
                statusMessage = "Audio is flowing"
            } else {
                finishFailedStart(error, session: session)
            }
            return
        }

        teardownEngine()
        activeSession = session
        isLoading = true
        errorMessage = nil
        warningMessage = nil
        statusMessage = "Loading audio graph…"

        do {
            statusMessage = "Building audio graph…"
            try await runConfiguration(
                session: session,
                generation: generation
            )
            guard isFlowEnabled, generation == startGeneration else {
                teardownEngine()
                return
            }
            finishSuccessfulStart()
        } catch {
            guard isFlowEnabled, generation == startGeneration else { return }
            if let fallbackSession {
                await restoreLastWorkingSession(
                    fallbackSession,
                    after: error,
                    generation: generation
                )
            } else {
                finishFailedStart(error, session: session)
            }
        }
    }

    private func restoreLastWorkingSession(
        _ session: AudioSession,
        after graphError: Error,
        generation: UUID
    ) async {
        let graphErrorMessage = friendlyError(graphError)
        teardownEngine()
        guard isFlowEnabled, generation == startGeneration else { return }

        isLoading = true
        statusMessage = "Restoring previous audio graph…"
        activeSession = session

        do {
            try await runConfiguration(
                session: session,
                generation: generation
            )
            guard isFlowEnabled, generation == startGeneration else {
                teardownEngine()
                return
            }
            finishSuccessfulStart()
            errorMessage = graphErrorMessage
            statusMessage = "Audio is flowing"
        } catch {
            finishFailedStart(error, session: session)
        }
    }

    func stop() {
        isFlowEnabled = false
        activeSession = nil
        startGeneration = UUID()
        startupTask?.cancel()
        startupTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        teardownEngine()
        isRunning = false
        isLoading = false
        errorMessage = nil
        warningMessage = nil
        statusMessage = "Ready"
    }

    private func runConfiguration(
        session: AudioSession,
        generation: UUID
    ) async throws {
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            try await self.configureAndStart(session: session)
        }
        startupTask = task
        defer {
            if generation == startGeneration {
                startupTask = nil
            }
        }
        try await task.value
    }

    func clearIdleError() {
        guard !isFlowEnabled else { return }
        errorMessage = nil
        warningMessage = nil
        statusMessage = "Ready"
    }

    private func configureAndStart(session: AudioSession) async throws {
        try await configure(session: session)
        try Task.checkCancellation()

        statusMessage = "Starting audio devices…"
        engine.prepare()

        for inputEngine in additionalInputEngines {
            try Task.checkCancellation()
            inputEngine.prepare()
        }
        for outputEngine in additionalOutputEngines {
            try Task.checkCancellation()
            outputEngine.prepare()
        }
        if outputEngineActive {
            try Task.checkCancellation()
            outputEngine.prepare()
        }

        try Task.checkCancellation()
        for inputEngine in additionalInputEngines {
            try Task.checkCancellation()
            try inputEngine.start()
        }
        try Task.checkCancellation()
        try engine.start()
        if outputEngineActive {
            try Task.checkCancellation()
            try outputEngine.start()
        }
        for outputEngine in additionalOutputEngines {
            try Task.checkCancellation()
            try outputEngine.start()
        }
        try Task.checkCancellation()
        installConfigurationObservers()
        startMeterUpdates()
    }

    private func finishSuccessfulStart() {
        recoveryTask?.cancel()
        recoveryTask = nil
        startupTask = nil
        isRunning = true
        isLoading = false
        errorMessage = nil
        statusMessage = warningMessage ?? "Audio is flowing"
    }

    private func finishFailedStart(
        _ error: Error,
        session: AudioSession
    ) {
        teardownEngine()
        isRunning = false
        isLoading = false
        startupTask = nil
        errorMessage = friendlyError(error)
        let shouldRetry =
            (error as? AudioGraphError)?.shouldRetry
            ?? (error as? SystemAudioCaptureError)?.shouldRetry
            ?? true
        if shouldRetry {
            statusMessage = "Waiting to reconnect…"
            scheduleRecovery(for: session)
        } else {
            isFlowEnabled = false
            statusMessage = "Ready"
        }
    }

    private func scheduleRecovery(
        for session: AudioSession,
        delay: Duration = .seconds(2)
    ) {
        guard isFlowEnabled else { return }
        activeSession = session
        recoveryTask?.cancel()
        let generation = startGeneration
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isFlowEnabled,
                  generation == self.startGeneration,
                  let activeSession = self.activeSession else {
                return
            }
            await self.attemptStart(
                session: activeSession,
                generation: generation
            )
        }
    }

    private func handleUnexpectedConfigurationChange() {
        guard isFlowEnabled, !isLoading, let activeSession else { return }
        isRunning = false
        errorMessage = "The audio route changed. Reconnecting automatically…"
        statusMessage = "Reconnecting…"
        scheduleRecovery(for: activeSession, delay: .milliseconds(350))
    }

    private func teardownEngine() {
        removeConfigurationObservers()
        meterTimer?.invalidate()
        meterTimer = nil
        for nodeID in recorderTapNodeIDs {
            recorderNodesByNodeID[nodeID]?.removeTap(onBus: 0)
        }
        recorderTapNodeIDs.removeAll()
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if hasOutputTap {
            if processingEngineOutputActive {
                engine.mainMixerNode.removeTap(onBus: 0)
            } else {
                outputEngine.mainMixerNode.removeTap(onBus: 0)
            }
            hasOutputTap = false
        }
        hardwareInputActive = false
        for capture in screenAudioCaptureSources {
            capture.stop()
        }
        screenAudioCaptureSources.removeAll()
        engine.stop()
        outputEngine.stop()
        for inputEngine in additionalInputEngines {
            inputEngine.stop()
            inputEngine.reset()
        }
        for additionalOutputEngine in additionalOutputEngines {
            additionalOutputEngine.stop()
            additionalOutputEngine.reset()
        }
        finishRecorderWriters()
        engine.reset()
        outputEngine.reset()
        for audioUnit in hostedUnits.values
        where engine.attachedNodes.contains(audioUnit) {
            engine.detach(audioUnit)
        }
        if let sinkNode, engine.attachedNodes.contains(sinkNode) {
            engine.detach(sinkNode)
        }
        if let auxiliarySinkNode,
           engine.attachedNodes.contains(auxiliarySinkNode) {
            engine.detach(auxiliarySinkNode)
        }
        if let auxiliaryMixerNode,
           engine.attachedNodes.contains(auxiliaryMixerNode) {
            engine.detach(auxiliaryMixerNode)
        }
        for builtInNode in hostedBuiltInNodes.values
        where engine.attachedNodes.contains(builtInNode) {
            engine.detach(builtInNode)
        }
        for combineNode in hostedCombineMixers.values
        where engine.attachedNodes.contains(combineNode) {
            engine.detach(combineNode)
        }
        for inputNode in hostedCombineInputNodes.values
        where engine.attachedNodes.contains(inputNode) {
            engine.detach(inputNode)
        }
        for source in additionalInputSourceNodes
        where engine.attachedNodes.contains(source) {
            engine.detach(source)
        }
        if let inputAdapterNode,
           engine.attachedNodes.contains(inputAdapterNode) {
            engine.detach(inputAdapterNode)
        }
        for recorderNode in recorderNodesByNodeID.values
        where engine.attachedNodes.contains(recorderNode) {
            engine.detach(recorderNode)
        }
        if let sourceNode, outputEngine.attachedNodes.contains(sourceNode) {
            outputEngine.detach(sourceNode)
        }
        inputAdapterNode = nil
        sinkNode = nil
        auxiliarySinkNode = nil
        auxiliaryMixerNode = nil
        sourceNode = nil
        additionalInputSourceNodes.removeAll()
        additionalInputEngines.removeAll()
        additionalOutputEngines.removeAll()
        hostedOutputMixers.removeAll()
        bridgeBuffer = nil
        hostedBuiltInNodes.removeAll()
        hostedCombineMixers.removeAll()
        hostedCombineInputNodes.removeAll()
        recorderNodesByNodeID.removeAll()
        activeRecorderNodeIDs.removeAll()
        engine = AVAudioEngine()
        outputEngine = AVAudioEngine()
        outputEngineActive = false
        processingEngineOutputActive = false
        routeDescription = nil
        inputLevelDB = -96
        processedLevelDB = -96
        outputLevelDB = -96
    }

    private func installConfigurationObservers() {
        removeConfigurationObservers()
        let observedEngines = outputEngineActive
            ? [engine, outputEngine]
                + additionalInputEngines
                + additionalOutputEngines
            : [engine] + additionalInputEngines + additionalOutputEngines
        for observedEngine in observedEngines {
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: observedEngine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleUnexpectedConfigurationChange()
                }
            }
            configurationObservers.append(observer)
        }
    }

    private func removeConfigurationObservers() {
        for observer in configurationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObservers.removeAll()
    }

    private func friendlyError(_ error: Error) -> String {
        if !CGPreflightScreenCaptureAccess(),
           activeSession?.nodes.contains(where: {
               switch $0.nodeType {
               case .applicationAudioInput, .systemAudioInput:
                   return true
               default:
                   return false
               }
           }) == true {
            return "Allow Screen & System Audio Recording in System Settings, then restart SoundScape."
        }
        let nsError = error as NSError
        if nsError.code == Int(kAudioUnitErr_FailedInitialization) {
            return "The selected input or output device could not initialize. Check the macOS Sound settings and try again."
        }
        if nsError.code == Int(kAudioUnitErr_FormatNotSupported) {
            return "Core Audio rejected the negotiated PCM format. SoundScape will keep adapting the route and reconnect automatically."
        }
        return error.localizedDescription
    }

    func setParameter(nodeID: String, address: AUParameterAddress, value: AUValue) {
        guard let parameter = hostedUnits[nodeID]?
            .auAudioUnit
            .parameterTree?
            .parameter(withAddress: address) else {
            return
        }
        parameter.setValue(value, originator: nil)

        if let index = parametersByNodeID[nodeID]?.firstIndex(where: {
            $0.address == address
        }) {
            parametersByNodeID[nodeID]?[index].value = value
        }
    }

    func setOutputGain(nodeID: String, _ value: Double) {
        hostedOutputMixers[nodeID]?.outputVolume = Float(value)
    }

    func updateCombineInput(
        connectionID: String,
        settings: CombineInputSettings
    ) {
        guard let mixer = hostedCombineInputNodes[connectionID] else {
            return
        }
        mixer.outputVolume = Float(pow(10, settings.gainDB / 20))
        mixer.pan = Float(settings.pan)
    }

    func updateBuiltInNode(_ node: AudioNode) {
        guard case .builtInEffect(let effect) = node.nodeType,
              let hosted = hostedBuiltInNodes[node.id] else {
            return
        }

        switch effect {
        case .tenBandEQ:
            guard let equalizer = hosted as? AVAudioUnitEQ else { return }
            for (index, frequency) in BuiltInEffectType.graphicEQFrequencies.enumerated()
            where equalizer.bands.indices.contains(index) {
                equalizer.bands[index].gain = Float(
                    node.parameterValues["eq.\(Int(frequency))"] ?? 0
                )
            }
        case .balance, .pan:
            guard let mixer = hosted as? AVAudioMixerNode else { return }
            let key = effect == .balance ? "balance" : "pan"
            mixer.pan = Float(node.parameterValues[key] ?? 0)
        case .lowPassFilter:
            guard let equalizer = hosted as? AVAudioUnitEQ,
                  let band = equalizer.bands.first else {
                return
            }
            band.frequency = Float(node.parameterValues["cutoff"] ?? 12_000)
            band.bandwidth = bandwidth(
                forQ: node.parameterValues["resonance"] ?? 0.71
            )
        case .magicBoost:
            guard let dynamics = hosted as? AVAudioUnitEffect else { return }
            let amount = Float(node.parameterValues["amount"] ?? 0.5)
            setDynamicsParameter(
                kDynamicsProcessorParam_Threshold,
                value: -12 - amount * 24,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_HeadRoom,
                value: 10 - amount * 8,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_OverallGain,
                value: amount * 12,
                on: dynamics
            )
        case .simpleCompressor:
            guard let dynamics = hosted as? AVAudioUnitEffect else { return }
            let ratio = max(1, Float(node.parameterValues["ratio"] ?? 4))
            setDynamicsParameter(
                kDynamicsProcessorParam_Threshold,
                value: Float(node.parameterValues["threshold"] ?? -18),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_HeadRoom,
                value: max(0.1, 18 / ratio),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_AttackTime,
                value: Float(node.parameterValues["attack"] ?? 0.01),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_ReleaseTime,
                value: Float(node.parameterValues["release"] ?? 0.12),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_OverallGain,
                value: Float(node.parameterValues["makeupGain"] ?? 0),
                on: dynamics
            )
        case .volume:
            guard let equalizer = hosted as? AVAudioUnitEQ else { return }
            equalizer.globalGain = Float(node.parameterValues["gainDB"] ?? 0)
        case .parametricEQ:
            guard let equalizer = hosted as? AVAudioUnitEQ,
                  equalizer.bands.count == node.parametricEQBands.count else {
                return
            }
            for (index, modelBand) in node.parametricEQBands.enumerated() {
                let band = equalizer.bands[index]
                band.filterType = audioUnitFilterType(modelBand.type)
                band.frequency = Float(modelBand.frequency)
                band.bandwidth = bandwidth(forQ: modelBand.q)
                band.gain = Float(modelBand.gainDB)
                band.bypass = !modelBand.isEnabled
            }
        }
    }

    func capturedAudioUnitStates() -> [String: Data] {
        var result: [String: Data] = [:]
        for (nodeID, unit) in hostedUnits {
            guard let state = unit.auAudioUnit.fullState,
                  PropertyListSerialization.propertyList(
                    state,
                    isValidFor: .binary
                  ),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: state,
                    format: .binary,
                    options: 0
                  ) else {
                continue
            }
            result[nodeID] = data
        }
        return result
    }

    func hasLoadedUnit(for nodeID: String) -> Bool {
        hostedUnits[nodeID] != nil
    }

    func prepareForInspection(_ node: AudioNode) async {
        guard case .audioUnit(let descriptor) = node.nodeType else {
            return
        }

        if let existing = hostedUnits[node.id] {
            if descriptor.hasCustomView {
                requestCustomViewController(
                    nodeID: node.id,
                    audioUnit: existing,
                    generation: audioUnitGeneration
                )
            }
            return
        }

        guard !loadingInspectorNodeIDs.contains(node.id) else {
            return
        }

        loadingInspectorNodeIDs.insert(node.id)
        inspectorErrorsByNodeID[node.id] = nil
        defer { loadingInspectorNodeIDs.remove(node.id) }

        do {
            let audioUnit = try await instantiateConfiguredUnit(
                descriptor: descriptor,
                node: node
            )
            hostedUnits[node.id] = audioUnit
            parametersByNodeID[node.id] = parameterModels(for: audioUnit)
            if descriptor.hasCustomView {
                requestCustomViewController(
                    nodeID: node.id,
                    audioUnit: audioUnit,
                    generation: audioUnitGeneration
                )
            }
        } catch {
            inspectorErrorsByNodeID[node.id] = error.localizedDescription
        }
    }

    private func configure(session: AudioSession) async throws {
        let plan = try graphPlan(in: session)
        let outputNodeModels = plan.outputs

        engine = AVAudioEngine()
        outputEngine = AVAudioEngine()
        outputEngineActive = false
        processingEngineOutputActive = false
        hardwareInputActive = false
        discardHostedUnitsMissing(from: session)
        let generation = audioUnitGeneration

        let hardwareInputModels = plan.inputs.filter { node in
            if case .inputDevice = node.nodeType { return true }
            return false
        }
        let screenInputModels = plan.inputs.filter { node in
            switch node.nodeType {
            case .applicationAudioInput, .systemAudioInput:
                return true
            default:
                return false
            }
        }
        let resolvedInputs = try hardwareInputModels.map { node in
            (
                node: node,
                device: try resolvedDevice(
                    uid: node.deviceUID,
                    defaultSelector: kAudioHardwarePropertyDefaultInputDevice,
                    role: "input",
                    name: node.subtitle
                )
            )
        }

        guard let screenCaptureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioGraphError.invalidInputFormat
        }

        let inputHardwareFormat: AVAudioFormat
        if let primaryInput = resolvedInputs.first {
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(
                    primaryInput.device.id
                )
                guard engine.inputNode.auAudioUnit.deviceID
                    == primaryInput.device.id else {
                    throw AudioGraphError.routeVerificationFailed
                }
            } catch let error as AudioGraphError {
                throw error
            } catch {
                throw AudioGraphError.deviceSelection(
                    role: "input",
                    name: primaryInput.node.subtitle,
                    detail: error.localizedDescription
                )
            }

            inputHardwareFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputHardwareFormat.channelCount > 0,
                  inputHardwareFormat.sampleRate > 0 else {
                throw AudioGraphError.invalidInputFormat
            }
            hardwareInputActive = true
        } else {
            inputHardwareFormat = screenCaptureFormat
        }

        for node in screenInputModels {
            if case .applicationAudioInput = node.nodeType,
               node.applicationBundleIdentifier == nil {
                throw AudioGraphError.applicationAudioSourceRequired
            }
        }

        let resolvedOutputs = try outputNodeModels.map { node in
            (
                node: node,
                device: try resolvedDevice(
                    uid: node.deviceUID,
                    defaultSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    role: "output",
                    name: node.subtitle
                )
            )
        }
        let outputHardwareFormat: AVAudioFormat
        let primaryOutputUsesProcessingEngine =
            resolvedInputs.isEmpty && !resolvedOutputs.isEmpty
        if let primaryOutput = resolvedOutputs.first {
            do {
                let outputNode = primaryOutputUsesProcessingEngine
                    ? engine.outputNode
                    : outputEngine.outputNode
                try outputNode.auAudioUnit.setDeviceID(
                    primaryOutput.device.id
                )
                guard outputNode.auAudioUnit.deviceID
                    == primaryOutput.device.id else {
                    throw AudioGraphError.routeVerificationFailed
                }
            } catch let error as AudioGraphError {
                throw error
            } catch {
                throw AudioGraphError.deviceSelection(
                    role: "output",
                    name: primaryOutput.node.subtitle,
                    detail: error.localizedDescription
                )
            }
            let outputNode = primaryOutputUsesProcessingEngine
                ? engine.outputNode
                : outputEngine.outputNode
            outputHardwareFormat = outputNode.inputFormat(
                forBus: 0
            )
            routeDescription =
                "\(plan.inputs.map(\.subtitle).joined(separator: " + ")) → \(outputNodeModels.map(\.subtitle).joined(separator: " + "))"
        } else {
            outputHardwareFormat = inputHardwareFormat
            routeDescription =
                "\(plan.inputs.map(\.subtitle).joined(separator: " + ")) → Recorder"
        }
        let processingNodes = plan.nodes.filter { node in
            switch node.nodeType {
            case .inputDevice,
                 .applicationAudioInput,
                 .systemAudioInput,
                 .outputDevice:
                false
            default:
                true
            }
        }
        var enabledUnits: [(node: AudioNode, unit: AVAudioUnit)] = []
        for node in processingNodes {
            switch node.nodeType {
            case .audioUnit(let descriptor):
                statusMessage = "Loading \(descriptor.name)…"
                let audioUnit: AVAudioUnit
                if let existing = hostedUnits[node.id] {
                    audioUnit = existing
                    applyNodeSettings(node, to: audioUnit, restoreFullState: false)
                } else {
                    audioUnit = try await instantiateConfiguredUnit(
                        descriptor: descriptor,
                        node: node
                    )
                    try Task.checkCancellation()
                }

                hostedUnits[node.id] = audioUnit
                parametersByNodeID[node.id] = parameterModels(for: audioUnit)
                if descriptor.hasCustomView {
                    requestCustomViewController(
                        nodeID: node.id,
                        audioUnit: audioUnit,
                        generation: generation
                    )
                }
                if node.isEnabled {
                    enabledUnits.append((node, audioUnit))
                }
            case .recorder:
                recorderErrorsByNodeID[node.id] = nil
                continue
            case .combine, .builtInEffect:
                continue
            case .inputDevice,
                 .applicationAudioInput,
                 .systemAudioInput,
                 .outputDevice:
                throw AudioGraphError.unsupportedNode(node.title)
            }
        }

        let processingFormat = try negotiateProcessingFormat(
            inputFormat: screenInputModels.isEmpty
                ? inputHardwareFormat
                : screenCaptureFormat,
            outputFormat: outputHardwareFormat,
            units: enabledUnits,
            preferStereo: !screenInputModels.isEmpty || resolvedInputs.contains {
                $0.node.upmixMonoToStereo
            }
        )
        if !screenInputModels.isEmpty,
           abs(processingFormat.sampleRate - 48_000) > 0.5 {
            throw AudioGraphError.formatNegotiationFailed(
                enabledUnits.map(\.node.title),
                detail: "System audio capture requires a 48 kHz processing format."
            )
        }

        var engineNodes: [String: AVAudioNode] = [:]
        var sourceByDeviceUID: [String: AVAudioNode] = [:]
        if let primaryInput = resolvedInputs.first {
            let inputAdapter = AVAudioMixerNode()
            inputAdapterNode = inputAdapter
            engine.attach(inputAdapter)
            engine.connect(
                engine.inputNode,
                to: inputAdapter,
                format: inputHardwareFormat
            )
            sourceByDeviceUID[primaryInput.device.uid] = inputAdapter

            for input in resolvedInputs {
                if let existingSource = sourceByDeviceUID[input.device.uid] {
                    engineNodes[input.node.id] = existingSource
                    continue
                }
                let source = try makeAdditionalInputSource(
                    input.node,
                    device: input.device,
                    format: processingFormat
                )
                sourceByDeviceUID[input.device.uid] = source
                engineNodes[input.node.id] = source
            }
        }

        for input in screenInputModels {
            statusMessage = "Connecting \(input.title)…"
            let capture = ScreenAudioCaptureSource(
                format: processingFormat
            ) { [levelProbe] inputData, frameCount in
                levelProbe.updateInput(
                    inputData,
                    frameCount: frameCount
                )
            }
            engine.attach(capture.sourceNode)
            screenAudioCaptureSources.append(capture)
            additionalInputSourceNodes.append(capture.sourceNode)
            engineNodes[input.id] = capture.sourceNode
            try await capture.start(
                for: input,
                format: processingFormat
            )
            try Task.checkCancellation()
        }
        var combineInternals: [
            String: (
                merge: AVAudioMixerNode,
                output: AVAudioMixerNode,
                inputs: [(connection: GraphConnection, node: AVAudioMixerNode)]
            )
        ] = [:]

        for node in plan.nodes {
            switch node.nodeType {
            case .audioUnit:
                if node.isEnabled {
                    guard let audioUnit = hostedUnits[node.id] else {
                        throw AudioGraphError.unsupportedNode(node.title)
                    }
                    engine.attach(audioUnit)
                    engineNodes[node.id] = audioUnit
                } else {
                    let bypass = AVAudioMixerNode()
                    engine.attach(bypass)
                    hostedBuiltInNodes[node.id] = bypass
                    engineNodes[node.id] = bypass
                }
            case .recorder:
                let recorder = attachRecorder(
                    node,
                    format: processingFormat
                )
                engineNodes[node.id] = recorder
            case .combine:
                let merge = AVAudioMixerNode()
                let output = AVAudioMixerNode()
                engine.attach(merge)
                engine.attach(output)
                hostedCombineMixers["\(node.id).merge"] = merge
                hostedCombineMixers["\(node.id).output"] = output
                engineNodes[node.id] = output

                let incoming = plan.connections.filter { $0.to == node.id }
                let inputs = incoming.map { connection in
                    let adapter = AVAudioMixerNode()
                    engine.attach(adapter)
                    hostedCombineInputNodes[connection.id.uuidString] = adapter
                    let settings = node.combineInputSettings[
                        connection.id.uuidString
                    ] ?? CombineInputSettings()
                    adapter.outputVolume = Float(
                        pow(10, settings.gainDB / 20)
                    )
                    adapter.pan = Float(settings.pan)
                    return (connection, adapter)
                }
                combineInternals[node.id] = (merge, output, inputs)
            case .builtInEffect(let effect):
                let builtIn = makeBuiltInNode(effect: effect, model: node)
                engine.attach(builtIn)
                hostedBuiltInNodes[node.id] = builtIn
                engineNodes[node.id] = builtIn
            case .outputDevice:
                let output = AVAudioMixerNode()
                engine.attach(output)
                hostedBuiltInNodes[node.id] = output
                engineNodes[node.id] = output
            case .inputDevice,
                 .applicationAudioInput,
                 .systemAudioInput:
                continue
            }
        }

        var connectionPointsBySource: [
            String: [AVAudioConnectionPoint]
        ] = [:]
        for connection in plan.connections {
            guard let source = engineNodes[connection.from] else {
                throw AudioGraphError.invalidConnection
            }
            let destination: AVAudioNode
            if let combine = combineInternals[connection.to],
               let input = combine.inputs.first(where: {
                   $0.connection.id == connection.id
               })?.node {
                destination = input
            } else if let target = engineNodes[connection.to] {
                destination = target
            } else {
                throw AudioGraphError.invalidConnection
            }
            _ = source
            connectionPointsBySource[connection.from, default: []].append(
                AVAudioConnectionPoint(node: destination, bus: 0)
            )
        }
        for (sourceID, points) in connectionPointsBySource {
            guard let source = engineNodes[sourceID] else {
                throw AudioGraphError.invalidConnection
            }
            engine.connect(
                source,
                to: points,
                fromBus: 0,
                format: processingFormat
            )
        }

        for node in plan.nodes {
            guard case .combine = node.nodeType,
                  let combine = combineInternals[node.id] else {
                continue
            }
            for (index, entry) in combine.inputs.enumerated() {
                let settings = node.combineInputSettings[
                    entry.connection.id.uuidString
                ] ?? CombineInputSettings()
                let format = channelFormat(
                    settings.channelMode,
                    basedOn: processingFormat
                )
                engine.connect(
                    entry.node,
                    to: combine.merge,
                    fromBus: 0,
                    toBus: AVAudioNodeBus(index),
                    format: format
                )
            }
            engine.connect(
                combine.merge,
                to: combine.output,
                format: channelFormat(
                    node.combineOutputMode,
                    basedOn: processingFormat
                )
            )
        }

        let probe = levelProbe
        var renderEnginesByUID: [String: AVAudioEngine] = [:]
        var nextMixerBusByUID: [String: AVAudioNodeBus] = [:]
        if let primaryOutput = resolvedOutputs.first,
           !primaryOutputUsesProcessingEngine {
            renderEnginesByUID[primaryOutput.device.uid] = outputEngine
        }

        for (index, resolvedOutput) in resolvedOutputs.enumerated() {
            guard let outputGraphNode = engineNodes[
                resolvedOutput.node.id
            ] else {
                throw AudioGraphError.invalidConnection
            }
            if primaryOutputUsesProcessingEngine,
               resolvedOutput.device.uid == resolvedOutputs.first?.device.uid {
                let gainMixer = AVAudioMixerNode()
                engine.attach(gainMixer)
                engine.connect(
                    outputGraphNode,
                    to: gainMixer,
                    format: processingFormat
                )
                let mixerBus = nextMixerBusByUID[
                    resolvedOutput.device.uid,
                    default: 0
                ]
                engine.connect(
                    gainMixer,
                    to: engine.mainMixerNode,
                    fromBus: 0,
                    toBus: mixerBus,
                    format: processingFormat
                )
                nextMixerBusByUID[resolvedOutput.device.uid] = mixerBus + 1
                gainMixer.outputVolume = Float(
                    resolvedOutput.node.gain
                )
                hostedOutputMixers[
                    resolvedOutput.node.id
                ] = gainMixer
                continue
            }

            let bridge = AudioRingBuffer(
                channelCount: Int(processingFormat.channelCount)
            )
            let outputSink = AVAudioSinkNode { _, frameCount, inputData in
                bridge.write(inputData, frameCount: frameCount)
                if index == 0 {
                    probe.updateProcessed(
                        inputData,
                        frameCount: frameCount
                    )
                }
                return noErr
            }
            engine.attach(outputSink)
            engine.connect(
                outputGraphNode,
                to: outputSink,
                format: processingFormat
            )

            let source = AVAudioSourceNode(
                format: processingFormat
            ) { isSilence, _, frameCount, outputData in
                let hasAudio = bridge.read(
                    into: outputData,
                    frameCount: frameCount
                )
                isSilence.pointee = ObjCBool(!hasAudio)
                return noErr
            }
            let renderEngine: AVAudioEngine
            if let existing = renderEnginesByUID[
                resolvedOutput.device.uid
            ] {
                renderEngine = existing
            } else {
                let additionalEngine = AVAudioEngine()
                do {
                    try additionalEngine.outputNode.auAudioUnit.setDeviceID(
                        resolvedOutput.device.id
                    )
                    guard additionalEngine.outputNode.auAudioUnit.deviceID
                        == resolvedOutput.device.id else {
                        throw AudioGraphError.routeVerificationFailed
                    }
                } catch let error as AudioGraphError {
                    throw error
                } catch {
                    throw AudioGraphError.deviceSelection(
                        role: "output",
                        name: resolvedOutput.node.subtitle,
                        detail: error.localizedDescription
                    )
                }
                renderEnginesByUID[
                    resolvedOutput.device.uid
                ] = additionalEngine
                additionalOutputEngines.append(additionalEngine)
                renderEngine = additionalEngine
            }

            if index == 0 {
                sinkNode = outputSink
                bridgeBuffer = bridge
                sourceNode = source
            }

            let gainMixer = AVAudioMixerNode()
            renderEngine.attach(source)
            renderEngine.attach(gainMixer)
            renderEngine.connect(
                source,
                to: gainMixer,
                format: processingFormat
            )
            let mixerBus = nextMixerBusByUID[
                resolvedOutput.device.uid,
                default: 0
            ]
            renderEngine.connect(
                gainMixer,
                to: renderEngine.mainMixerNode,
                fromBus: 0,
                toBus: mixerBus,
                format: processingFormat
            )
            nextMixerBusByUID[resolvedOutput.device.uid] = mixerBus + 1
            gainMixer.outputVolume = Float(
                resolvedOutput.node.gain
            )
            hostedOutputMixers[
                resolvedOutput.node.id
            ] = gainMixer
        }

        if primaryOutputUsesProcessingEngine {
            engine.connect(
                engine.mainMixerNode,
                to: engine.outputNode,
                format: nil
            )
        }
        for renderEngine in renderEnginesByUID.values {
            renderEngine.connect(
                renderEngine.mainMixerNode,
                to: renderEngine.outputNode,
                format: nil
            )
        }
        processingEngineOutputActive = primaryOutputUsesProcessingEngine
        outputEngineActive =
            !primaryOutputUsesProcessingEngine && !resolvedOutputs.isEmpty

        let terminalRecorders = plan.nodes.filter { node in
            guard case .recorder = node.nodeType else { return false }
            return node.isEnabled
                && !plan.connections.contains(where: { $0.from == node.id })
        }
        if !terminalRecorders.isEmpty {
            let collector = AVAudioMixerNode()
            auxiliaryMixerNode = collector
            engine.attach(collector)
            for (index, recorder) in terminalRecorders.enumerated() {
                guard let recorderNode = engineNodes[recorder.id] else {
                    continue
                }
                engine.connect(
                    recorderNode,
                    to: collector,
                    fromBus: 0,
                    toBus: AVAudioNodeBus(index),
                    format: processingFormat
                )
            }
            if resolvedInputs.isEmpty && resolvedOutputs.isEmpty {
                engine.connect(
                    collector,
                    to: engine.mainMixerNode,
                    format: processingFormat
                )
                engine.mainMixerNode.outputVolume = 0
                engine.connect(
                    engine.mainMixerNode,
                    to: engine.outputNode,
                    format: nil
                )
                processingEngineOutputActive = true
            } else {
                let nullSink = AVAudioSinkNode { _, frameCount, inputData in
                    if resolvedOutputs.isEmpty {
                        probe.updateProcessed(
                            inputData,
                            frameCount: frameCount
                        )
                    }
                    return noErr
                }
                auxiliarySinkNode = nullSink
                engine.attach(nullSink)
                engine.connect(
                    collector,
                    to: nullSink,
                    format: processingFormat
                )
            }
        }

        sampleRate = processingFormat.sampleRate
        installSignalTaps()
    }

    private func makeAdditionalInputSource(
        _ node: AudioNode,
        device: (id: AudioObjectID, uid: String),
        format: AVAudioFormat
    ) throws -> AVAudioSourceNode {
        let captureEngine = AVAudioEngine()
        do {
            try captureEngine.inputNode.auAudioUnit.setDeviceID(device.id)
            guard captureEngine.inputNode.auAudioUnit.deviceID
                == device.id else {
                throw AudioGraphError.routeVerificationFailed
            }
        } catch let error as AudioGraphError {
            throw error
        } catch {
            throw AudioGraphError.deviceSelection(
                role: "input",
                name: node.subtitle,
                detail: error.localizedDescription
            )
        }

        let hardwareFormat = captureEngine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0,
              hardwareFormat.sampleRate > 0 else {
            throw AudioGraphError.invalidInputFormat
        }

        let bridge = AudioRingBuffer(
            channelCount: Int(format.channelCount)
        )
        let adapter = AVAudioMixerNode()
        let sink = AVAudioSinkNode { _, frameCount, inputData in
            bridge.write(inputData, frameCount: frameCount)
            return noErr
        }
        captureEngine.attach(adapter)
        captureEngine.attach(sink)
        captureEngine.connect(
            captureEngine.inputNode,
            to: adapter,
            format: hardwareFormat
        )
        captureEngine.connect(adapter, to: sink, format: format)

        let source = AVAudioSourceNode(
            format: format
        ) { isSilence, _, frameCount, outputData in
            let hasAudio = bridge.read(
                into: outputData,
                frameCount: frameCount
            )
            isSilence.pointee = ObjCBool(!hasAudio)
            return noErr
        }
        engine.attach(source)
        additionalInputEngines.append(captureEngine)
        additionalInputSourceNodes.append(source)
        return source
    }

    private func attachRecorder(
        _ node: AudioNode,
        format: AVAudioFormat
    ) -> AVAudioNode {
        let recorderNode = AVAudioMixerNode()
        recorderNodesByNodeID[node.id] = recorderNode
        recorderErrorsByNodeID[node.id] = nil
        recordedDurationByNodeID[node.id] = 0
        engine.attach(recorderNode)

        guard node.isEnabled else { return recorderNode }
        do {
            let url = try nextRecordingURL(for: node)
            let writer = try RecorderWriter(
                url: url,
                format: format
            )
            recorderWritersByNodeID[node.id] = writer
            recordingURLsByNodeID[node.id] = url
            activeRecorderNodeIDs.insert(node.id)
            recorderNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format
            ) { buffer, _ in
                writer.write(buffer)
            }
            recorderTapNodeIDs.insert(node.id)
        } catch {
            recorderErrorsByNodeID[node.id] = error.localizedDescription
        }

        return recorderNode
    }

    private func nextRecordingURL(for node: AudioNode) throws -> URL {
        let fileManager = FileManager.default
        let directory = node.recordingDirectoryPath
            .flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            }
            ?? RecorderDestination.defaultDirectoryURL
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let rawPrefix = node.recordingFilePrefix.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prefix = sanitizedFileName(
            rawPrefix.isEmpty ? "SoundScape" : rawPrefix
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = "\(prefix)_\(formatter.string(from: Date()))"
        let fileExtension = node.recordingFormat.fileExtension

        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)_\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func sanitizedFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalid)
        let sanitized = components
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return sanitized.isEmpty ? "SoundScape" : sanitized
    }

    private func channelFormat(
        _ mode: ChannelMode,
        basedOn format: AVAudioFormat
    ) -> AVAudioFormat {
        guard mode == .mono,
              let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else {
            return format
        }
        return mono
    }

    private func makeBuiltInNode(
        effect: BuiltInEffectType,
        model: AudioNode
    ) -> AVAudioNode {
        guard model.isEnabled else {
            return AVAudioMixerNode()
        }

        switch effect {
        case .tenBandEQ:
            let equalizer = AVAudioUnitEQ(
                numberOfBands: BuiltInEffectType.graphicEQFrequencies.count
            )
            for (index, frequency) in BuiltInEffectType.graphicEQFrequencies.enumerated() {
                let band = equalizer.bands[index]
                band.filterType = .parametric
                band.frequency = Float(frequency)
                band.bandwidth = 1
                band.gain = Float(
                    model.parameterValues["eq.\(Int(frequency))"] ?? 0
                )
                band.bypass = false
            }
            return equalizer

        case .balance, .pan:
            let mixer = AVAudioMixerNode()
            let key = effect == .balance ? "balance" : "pan"
            mixer.pan = Float(model.parameterValues[key] ?? 0)
            return mixer

        case .lowPassFilter:
            let equalizer = AVAudioUnitEQ(numberOfBands: 1)
            let band = equalizer.bands[0]
            band.filterType = .lowPass
            band.frequency = Float(
                model.parameterValues["cutoff"] ?? 12_000
            )
            band.bandwidth = bandwidth(
                forQ: model.parameterValues["resonance"] ?? 0.71
            )
            band.bypass = false
            return equalizer

        case .magicBoost:
            let dynamics = makeDynamicsProcessor()
            let amount = Float(model.parameterValues["amount"] ?? 0.5)
            setDynamicsParameter(
                kDynamicsProcessorParam_Threshold,
                value: -12 - amount * 24,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_HeadRoom,
                value: 10 - amount * 8,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_AttackTime,
                value: 0.015,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_ReleaseTime,
                value: 0.18,
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_OverallGain,
                value: amount * 12,
                on: dynamics
            )
            return dynamics

        case .simpleCompressor:
            let dynamics = makeDynamicsProcessor()
            let ratio = max(
                1,
                Float(model.parameterValues["ratio"] ?? 4)
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_Threshold,
                value: Float(model.parameterValues["threshold"] ?? -18),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_HeadRoom,
                value: max(0.1, 18 / ratio),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_AttackTime,
                value: Float(model.parameterValues["attack"] ?? 0.01),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_ReleaseTime,
                value: Float(model.parameterValues["release"] ?? 0.12),
                on: dynamics
            )
            setDynamicsParameter(
                kDynamicsProcessorParam_OverallGain,
                value: Float(model.parameterValues["makeupGain"] ?? 0),
                on: dynamics
            )
            return dynamics

        case .volume:
            let equalizer = AVAudioUnitEQ(numberOfBands: 1)
            equalizer.bands[0].bypass = true
            equalizer.globalGain = Float(
                model.parameterValues["gainDB"] ?? 0
            )
            return equalizer

        case .parametricEQ:
            let equalizer = AVAudioUnitEQ(
                numberOfBands: model.parametricEQBands.count
            )
            for (index, modelBand) in model.parametricEQBands.enumerated() {
                let band = equalizer.bands[index]
                band.filterType = audioUnitFilterType(modelBand.type)
                band.frequency = Float(modelBand.frequency)
                band.bandwidth = bandwidth(forQ: modelBand.q)
                band.gain = Float(modelBand.gainDB)
                band.bypass = !modelBand.isEnabled
            }
            return equalizer
        }
    }

    private func audioUnitFilterType(
        _ type: ParametricFilterType
    ) -> AVAudioUnitEQFilterType {
        switch type {
        case .highPass: .highPass
        case .lowShelf: .lowShelf
        case .peaking: .parametric
        case .highShelf: .highShelf
        case .lowPass: .lowPass
        }
    }

    private func bandwidth(forQ q: Double) -> Float {
        let safeQ = max(0.05, q)
        return Float(2 * asinh(1 / (2 * safeQ)) / log(2))
    }

    private func makeDynamicsProcessor() -> AVAudioUnitEffect {
        AVAudioUnitEffect(
            audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )
    }

    private func setDynamicsParameter(
        _ parameter: AudioUnitParameterID,
        value: AudioUnitParameterValue,
        on unit: AVAudioUnitEffect
    ) {
        AudioUnitSetParameter(
            unit.audioUnit,
            parameter,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
    }

    private func finishRecorderWriters() {
        let writers = recorderWritersByNodeID
        recorderWritersByNodeID.removeAll()
        for (nodeID, writer) in writers {
            let result = writer.finish()
            recordedDurationByNodeID[nodeID] = result.duration
            if let error = result.errorMessage {
                recorderErrorsByNodeID[nodeID] = error
            }
            if result.frameCount == 0 {
                try? FileManager.default.removeItem(at: result.url)
                if recordingURLsByNodeID[nodeID] == result.url {
                    recordingURLsByNodeID[nodeID] = nil
                }
            }
        }
    }

    private func negotiateProcessingFormat(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        units: [(node: AudioNode, unit: AVAudioUnit)],
        preferStereo: Bool
    ) throws -> AVAudioFormat {
        let sampleRates = uniquePositiveValues([
            inputFormat.sampleRate,
            outputFormat.sampleRate,
            48_000,
            44_100
        ])
        let compatibleChannelCount = min(
            inputFormat.channelCount,
            outputFormat.channelCount > 0
                ? outputFormat.channelCount
                : inputFormat.channelCount
        )
        let channelCounts = uniquePositiveChannelCounts(
            preferStereo
                ? [
                    2,
                    compatibleChannelCount,
                    inputFormat.channelCount,
                    outputFormat.channelCount,
                    1
                ]
                : [
                    compatibleChannelCount,
                    inputFormat.channelCount,
                    outputFormat.channelCount,
                    2,
                    1
                ]
        )

        var lastError: Error?
        for sampleRate in sampleRates {
            for channelCount in channelCounts {
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: channelCount,
                    interleaved: false
                ) else {
                    continue
                }

                do {
                    for (_, audioUnit) in units {
                        try setPrimaryBusFormats(
                            format,
                            on: audioUnit
                        )
                    }
                    return format
                } catch {
                    lastError = error
                }
            }
        }

        throw AudioGraphError.formatNegotiationFailed(
            units.map(\.node.title),
            detail: lastError?.localizedDescription
                ?? "No standard Float32 PCM format was accepted."
        )
    }

    private func setPrimaryBusFormats(
        _ format: AVAudioFormat,
        on audioUnit: AVAudioUnit
    ) throws {
        let unit = audioUnit.auAudioUnit
        if unit.renderResourcesAllocated {
            unit.deallocateRenderResources()
        }
        guard unit.inputBusses.count > 0,
              unit.outputBusses.count > 0 else {
            throw AudioGraphError.invalidAudioUnitBusses(audioUnit.name)
        }
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
    }

    private func uniquePositiveValues(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values where value > 0 {
            guard !result.contains(where: {
                abs($0 - value) < 0.5
            }) else {
                continue
            }
            result.append(value)
        }
        return result
    }

    private func uniquePositiveChannelCounts(
        _ values: [AVAudioChannelCount]
    ) -> [AVAudioChannelCount] {
        var result: [AVAudioChannelCount] = []
        for value in values where value > 0 {
            guard !result.contains(value) else { continue }
            result.append(value)
        }
        return result
    }

    private func resolvedDevice(
        uid: String?,
        defaultSelector: AudioObjectPropertySelector,
        role: String,
        name: String
    ) throws -> (id: AudioObjectID, uid: String) {
        let deviceID: AudioObjectID
        if let uid {
            guard let resolved = AudioDeviceCatalog.audioObjectID(forUID: uid) else {
                throw AudioGraphError.deviceUnavailable(name)
            }
            deviceID = resolved
        } else {
            guard let resolved = AudioDeviceCatalog.defaultDeviceID(
                selector: defaultSelector
            ) else {
                throw AudioGraphError.deviceUnavailable(name)
            }
            deviceID = resolved
        }
        guard let resolvedUID = AudioDeviceCatalog.deviceUID(for: deviceID) else {
            throw AudioGraphError.deviceSelection(
                role: role,
                name: name,
                detail: "Core Audio did not return a device UID."
            )
        }
        return (deviceID, resolvedUID)
    }

    private func installSignalTaps() {
        let probe = levelProbe
        if hardwareInputActive {
            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: nil
            ) { buffer, _ in
                probe.updateInput(buffer)
            }
            hasInputTap = true
        }

        if processingEngineOutputActive {
            engine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: nil
            ) { buffer, _ in
                probe.updateProcessed(buffer)
                probe.updateOutput(buffer)
            }
            hasOutputTap = true
        } else if outputEngineActive {
            outputEngine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: nil
            ) { buffer, _ in
                probe.updateOutput(buffer)
            }
            hasOutputTap = true
        }
    }

    private func startMeterUpdates() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let levels = self.levelProbe.levels()
                self.inputLevelDB = levels.input
                self.processedLevelDB = levels.processed
                self.outputLevelDB =
                    (self.processingEngineOutputActive
                     || self.outputEngineActive)
                    ? levels.output
                    : levels.processed
                for (nodeID, writer) in self.recorderWritersByNodeID {
                    let snapshot = writer.snapshot()
                    self.recordedDurationByNodeID[nodeID] = snapshot.duration
                    if let error = snapshot.errorMessage {
                        self.recorderErrorsByNodeID[nodeID] = error
                        self.activeRecorderNodeIDs.remove(nodeID)
                    }
                }
                if self.isFlowEnabled,
                   self.isRunning,
                   (!self.engine.isRunning
                    || (self.outputEngineActive
                        && !self.outputEngine.isRunning)
                    || self.additionalInputEngines.contains {
                        !$0.isRunning
                    }
                    || self.additionalOutputEngines.contains {
                        !$0.isRunning
                    }) {
                    self.handleUnexpectedConfigurationChange()
                }
            }
        }
    }

    private func instantiateConfiguredUnit(
        descriptor: AudioUnitDescriptor,
        node: AudioNode
    ) async throws -> AVAudioUnit {
        let audioUnit = try await AVAudioUnit.instantiate(
            with: descriptor.componentDescription,
            options: []
        )
        try Task.checkCancellation()

        applyNodeSettings(node, to: audioUnit, restoreFullState: true)
        return audioUnit
    }

    private func applyNodeSettings(
        _ node: AudioNode,
        to audioUnit: AVAudioUnit,
        restoreFullState: Bool
    ) {
        if restoreFullState,
           let stateData = node.audioUnitState,
           let state = try? PropertyListSerialization.propertyList(
            from: stateData,
            options: [],
            format: nil
           ) as? [String: Any] {
            audioUnit.auAudioUnit.fullState = state
        }
        for (addressString, value) in node.parameterValues {
            guard let address = AUParameterAddress(addressString),
                  let parameter = audioUnit.auAudioUnit
                    .parameterTree?
                    .parameter(withAddress: address) else {
                continue
            }
            parameter.value = AUValue(value)
        }
    }

    private func requestCustomViewController(
        nodeID: String,
        audioUnit: AVAudioUnit,
        generation: UUID
    ) {
        guard customViewsByNodeID[nodeID] == nil,
              !loadingCustomViewNodeIDs.contains(nodeID) else {
            return
        }

        loadingCustomViewNodeIDs.insert(nodeID)
        customViewErrorsByNodeID[nodeID] = nil
        let audioUnitIdentity = ObjectIdentifier(audioUnit)
        audioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor [weak self] in
                guard let self, generation == self.audioUnitGeneration else {
                    return
                }
                self.loadingCustomViewNodeIDs.remove(nodeID)
                guard self.hostedUnits[nodeID].map(ObjectIdentifier.init)
                    == audioUnitIdentity else {
                    return
                }
                if let viewController {
                    viewController.loadView()
                    let viewBundlePath = Bundle(
                        for: type(of: viewController.view)
                    ).bundleURL.path
                    if viewBundlePath.contains(
                        "/CoreAudioAUUI.bundle"
                    ) {
                        self.customViewErrorsByNodeID[nodeID] =
                            "Apple’s legacy Audio Unit interface cannot be "
                            + "embedded safely. Use the complete parameter "
                            + "controls below."
                        return
                    }
                    let intrinsicSize = self.intrinsicCustomViewSize(
                        viewController
                    )
                    self.customViewsByNodeID[nodeID] = HostedAUCustomView(
                        viewController: viewController,
                        intrinsicSize: intrinsicSize
                    )
                } else {
                    self.customViewErrorsByNodeID[nodeID] =
                        "The plug-in did not provide a custom interface."
                }
            }
        }
    }

    private func discardHostedUnitsMissing(from session: AudioSession) {
        let validNodeIDs = Set(session.nodes.compactMap { node -> String? in
            guard case .audioUnit = node.nodeType else { return nil }
            return node.id
        })
        let removedNodeIDs = Set(hostedUnits.keys).subtracting(validNodeIDs)
        guard !removedNodeIDs.isEmpty else { return }

        for nodeID in removedNodeIDs {
            hostedUnits[nodeID] = nil
            parametersByNodeID[nodeID] = nil
            inspectorErrorsByNodeID[nodeID] = nil
            loadingInspectorNodeIDs.remove(nodeID)
            customViewsByNodeID[nodeID] = nil
            customViewErrorsByNodeID[nodeID] = nil
            loadingCustomViewNodeIDs.remove(nodeID)
        }
    }

    private func intrinsicCustomViewSize(
        _ viewController: NSViewController
    ) -> CGSize {
        let preferred = viewController.preferredContentSize
        if preferred.width > 1, preferred.height > 1 {
            return preferred
        }

        let frame = viewController.view.frame.size
        if frame.width > 1, frame.height > 1 {
            return frame
        }

        let fitting = viewController.view.fittingSize
        if fitting.width > 1, fitting.height > 1 {
            return fitting
        }
        return CGSize(width: 320, height: 240)
    }

    private func parameterModels(for audioUnit: AVAudioUnit) -> [HostedAUParameter] {
        audioUnit.auAudioUnit.parameterTree?.allParameters.map { parameter in
            HostedAUParameter(
                address: parameter.address,
                name: parameter.displayName,
                minimum: parameter.minValue,
                maximum: parameter.maxValue,
                value: parameter.value,
                unit: parameter.unit,
                unitName: parameter.unitName ?? "",
                valueStrings: parameter.valueStrings ?? [],
                isWritable: parameter.flags.contains(.flag_IsWritable)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ?? []
    }

    private func graphPlan(in session: AudioSession) throws -> AudioGraphPlan {
        let inputs = session.nodes.filter {
            switch $0.nodeType {
            case .inputDevice, .applicationAudioInput, .systemAudioInput:
                return true
            default:
                return false
            }
        }
        guard !inputs.isEmpty else { throw AudioGraphError.missingEndpoints }

        let nodesByID = Dictionary(uniqueKeysWithValues: session.nodes.map {
            ($0.id, $0)
        })
        let audioConnections = session.connections.filter { !$0.isReference }
        guard audioConnections.allSatisfy({
            nodesByID[$0.from] != nil && nodesByID[$0.to] != nil
        }) else {
            throw AudioGraphError.invalidConnection
        }

        var reachable = Set(inputs.map(\.id))
        var changed = true
        while changed {
            changed = false
            for connection in audioConnections
            where reachable.contains(connection.from)
                && !reachable.contains(connection.to) {
                reachable.insert(connection.to)
                changed = true
            }
        }

        let reachableOutputs = session.nodes.filter { node in
            guard reachable.contains(node.id),
                  case .outputDevice = node.nodeType else {
                return false
            }
            return audioConnections.contains { $0.to == node.id }
        }
        let terminalRecorders = session.nodes.filter { node in
            guard reachable.contains(node.id),
                  node.isEnabled,
                  case .recorder = node.nodeType else {
                return false
            }
            return !audioConnections.contains {
                $0.from == node.id && reachable.contains($0.to)
            }
        }
        let sinks = Set(
            (reachableOutputs + terminalRecorders).map(\.id)
        )
        guard !sinks.isEmpty else {
            let disabledTerminal = session.nodes.contains { node in
                guard reachable.contains(node.id),
                      !node.isEnabled,
                      case .recorder = node.nodeType else {
                    return false
                }
                return !audioConnections.contains { $0.from == node.id }
            }
            throw disabledTerminal
                ? AudioGraphError.disabledRecorderDestination
                : AudioGraphError.missingDestination
        }

        var canReachSink = sinks
        changed = true
        while changed {
            changed = false
            for connection in audioConnections
            where canReachSink.contains(connection.to)
                && !canReachSink.contains(connection.from) {
                canReachSink.insert(connection.from)
                changed = true
            }
        }

        let activeIDs = reachable.intersection(canReachSink)
        let activeConnections = audioConnections.filter {
            activeIDs.contains($0.from) && activeIDs.contains($0.to)
        }
        for nodeID in activeIDs {
            guard let node = nodesByID[nodeID] else {
                throw AudioGraphError.invalidConnection
            }
            let incomingCount = activeConnections.filter {
                $0.to == nodeID
            }.count
            let acceptsMany: Bool
            if case .combine = node.nodeType {
                acceptsMany = true
            } else {
                acceptsMany = false
            }
            let isInput: Bool
            switch node.nodeType {
            case .inputDevice, .applicationAudioInput, .systemAudioInput:
                isInput = true
            default:
                isInput = false
            }
            if isInput {
                guard incomingCount == 0 else {
                    throw AudioGraphError.invalidConnection
                }
            } else if incomingCount != 1,
                      !(acceptsMany && incomingCount > 0) {
                throw AudioGraphError.combineRequired
            }
            if case .outputDevice = node.nodeType,
               activeConnections.contains(where: { $0.from == nodeID }) {
                throw AudioGraphError.invalidConnection
            }
        }

        var indegree = Dictionary(
            uniqueKeysWithValues: activeIDs.map { ($0, 0) }
        )
        for connection in activeConnections {
            indegree[connection.to, default: 0] += 1
        }
        var queue = indegree
            .filter { $0.value == 0 }
            .map(\.key)
        var orderedIDs: [String] = []
        while let nextID = queue.first {
            queue.removeFirst()
            orderedIDs.append(nextID)
            for connection in activeConnections where connection.from == nextID {
                indegree[connection.to, default: 0] -= 1
                if indegree[connection.to] == 0 {
                    queue.append(connection.to)
                }
            }
        }
        guard orderedIDs.count == activeIDs.count else {
            throw AudioGraphError.invalidConnection
        }

        let orderedNodes = orderedIDs.compactMap { nodesByID[$0] }
        return AudioGraphPlan(
            inputs: inputs.filter { activeIDs.contains($0.id) },
            outputs: reachableOutputs,
            nodes: orderedNodes,
            connections: activeConnections
        )
    }

}

private struct AudioGraphPlan {
    let inputs: [AudioNode]
    let outputs: [AudioNode]
    let nodes: [AudioNode]
    let connections: [GraphConnection]
}

private struct RecorderSnapshot {
    let url: URL
    let frameCount: AVAudioFramePosition
    let duration: TimeInterval
    let errorMessage: String?
}

private final class RecorderWriter: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private let sampleRate: Double
    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var errorMessage: String?

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        sampleRate = format.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard errorMessage == nil, let file else { return }

        do {
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            errorMessage = error.localizedDescription
            self.file = nil
        }
    }

    func snapshot() -> RecorderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    func finish() -> RecorderSnapshot {
        lock.lock()
        file = nil
        let result = makeSnapshot()
        lock.unlock()
        return result
    }

    private func makeSnapshot() -> RecorderSnapshot {
        RecorderSnapshot(
            url: url,
            frameCount: frameCount,
            duration: sampleRate > 0
                ? TimeInterval(frameCount) / sampleRate
                : 0,
            errorMessage: errorMessage
        )
    }
}

private enum AudioGraphError: LocalizedError {
    case missingEndpoints
    case missingDestination
    case disabledRecorderDestination
    case singleInputRequired
    case linearRoutingRequired
    case combineRequired
    case invalidConnection
    case unsupportedNode(String)
    case deviceUnavailable(String)
    case deviceSelection(role: String, name: String, detail: String)
    case routeVerificationFailed
    case invalidInputFormat
    case applicationAudioSourceRequired
    case invalidAudioUnitBusses(String)
    case formatNegotiationFailed([String], detail: String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoints:
            "Add an Input Device and connect a route."
        case .missingDestination:
            "End the route with an Output Device or an enabled Recorder."
        case .disabledRecorderDestination:
            "Enable the terminal Recorder or connect the route to an Output Device."
        case .singleInputRequired:
            "A running flow currently requires exactly one Input Device."
        case .linearRoutingRequired:
            "Audio processing currently requires one linear connection path."
        case .combineRequired:
            "Connect multiple signals through a Combine node."
        case .invalidConnection:
            "The graph contains a broken or circular connection."
        case .unsupportedNode(let name):
            "\(name) is not a supported processing node."
        case .deviceUnavailable(let name):
            "\(name) is not currently connected. Choose another device."
        case .deviceSelection(let role, let name, let detail):
            "Could not use \(role) device \(name): \(detail)"
        case .routeVerificationFailed:
            "Core Audio did not retain the selected input/output route."
        case .invalidInputFormat:
            "The selected input device did not provide a usable PCM format."
        case .applicationAudioSourceRequired:
            "Choose a running application in the Application Audio Input node."
        case .invalidAudioUnitBusses(let name):
            "\(name) does not expose a usable audio input and output bus."
        case .formatNegotiationFailed(let names, let detail):
            "No common PCM format is supported by \(names.joined(separator: ", ")). \(detail)"
        }
    }

    var shouldRetry: Bool {
        switch self {
        case .deviceUnavailable,
             .deviceSelection,
             .routeVerificationFailed,
             .invalidInputFormat:
            true
        case .missingEndpoints,
             .missingDestination,
             .disabledRecorderDestination,
             .singleInputRequired,
             .linearRoutingRequired,
             .combineRequired,
             .invalidConnection,
             .unsupportedNode,
             .applicationAudioSourceRequired,
             .invalidAudioUnitBusses,
             .formatNegotiationFailed:
            false
        }
    }
}

private final class AudioLevelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inputDB: Double = -96
    private var processedDB: Double = -96
    private var outputDB: Double = -96

    func updateInput(_ buffer: AVAudioPCMBuffer) {
        update(buffer, destination: \.inputDB)
    }

    func updateInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) {
        update(
            inputData,
            frameCount: frameCount,
            destination: \.inputDB
        )
    }

    func updateProcessed(_ buffer: AVAudioPCMBuffer) {
        update(buffer, destination: \.processedDB)
    }

    func updateOutput(_ buffer: AVAudioPCMBuffer) {
        update(buffer, destination: \.outputDB)
    }

    func updateProcessed(
        _ inputData: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) {
        update(
            inputData,
            frameCount: frameCount,
            destination: \.processedDB
        )
    }

    private func update(
        _ inputData: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        destination: ReferenceWritableKeyPath<AudioLevelProbe, Double>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard frameCount > 0, !buffers.isEmpty else { return }
        var sum: Double = 0
        var sampleCount = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let availableSampleCount =
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            let availableFrameCount = min(
                Int(frameCount),
                availableSampleCount / channelCount
            )
            for frame in 0..<availableFrameCount {
                for channel in 0..<channelCount {
                    let value = Double(
                        samples[frame * channelCount + channel]
                    )
                    sum += value * value
                }
            }
            sampleCount += availableFrameCount * channelCount
        }
        guard sampleCount > 0 else { return }
        let rms = sqrt(sum / Double(sampleCount))
        let decibels = max(
            20 * log10(max(rms, 0.000_015_848_9)),
            -96
        )
        lock.lock()
        self[keyPath: destination] = decibels
        lock.unlock()
    }

    func levels() -> (input: Double, processed: Double, output: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (inputDB, processedDB, outputDB)
    }

    private func update(
        _ buffer: AVAudioPCMBuffer,
        destination: ReferenceWritableKeyPath<AudioLevelProbe, Double>
    ) {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Double = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let value = Double(samples[frame])
                sum += value * value
            }
        }
        let sampleCount = max(frameCount * channelCount, 1)
        let rms = sqrt(sum / Double(sampleCount))
        let decibels = max(20 * log10(max(rms, 0.000_015_848_9)), -96)
        lock.lock()
        self[keyPath: destination] = decibels
        lock.unlock()
    }

}
