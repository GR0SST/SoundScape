import Combine
import Foundation

@MainActor
final class AudioEnginePool: ObservableObject {
    let menuBarMeter = MenuBarAudioMeter()
    private var enginesBySessionID: [UUID: AudioEngineController] = [:]
    private var meterSubscriptions: [UUID: AnyCancellable] = [:]
    private var outputLevels: [UUID: Double] = [:]

    func engine(for sessionID: UUID) -> AudioEngineController {
        if let existing = enginesBySessionID[sessionID] {
            return existing
        }

        let engine = AudioEngineController()
        enginesBySessionID[sessionID] = engine
        meterSubscriptions[sessionID] = engine.$outputLevelDB
            .combineLatest(engine.$isRunning)
            .receive(on: RunLoop.main)
            .sink { [weak self] level, running in
                guard let self else { return }
                self.outputLevels[sessionID] = running ? level : -96
                self.menuBarMeter.setLevel(self.outputLevels.values.max() ?? -96)
            }
        return engine
    }

    func stopAndRemoveEngine(for sessionID: UUID) {
        meterSubscriptions.removeValue(forKey: sessionID)?.cancel()
        outputLevels.removeValue(forKey: sessionID)
        enginesBySessionID.removeValue(forKey: sessionID)?.stop()
        menuBarMeter.setLevel(outputLevels.values.max() ?? -96)
    }

    func toggleFlow(
        sessionID: UUID,
        in store: SessionStore
    ) async {
        guard let index = store.sessions.firstIndex(where: {
            $0.id == sessionID
        }) else {
            return
        }

        let audioEngine = engine(for: sessionID)
        if audioEngine.isFlowEnabled {
            let states = audioEngine.capturedAudioUnitStates()
            for nodeIndex in store.sessions[index].nodes.indices {
                let nodeID = store.sessions[index].nodes[nodeIndex].id
                if let state = states[nodeID] {
                    store.sessions[index].nodes[nodeIndex].audioUnitState = state
                }
            }
            audioEngine.stop()
            store.sessions[index].status = .ready
            return
        }

        let session = store.sessions[index]
        await audioEngine.start(session: session)
        guard let currentIndex = store.sessions.firstIndex(where: {
            $0.id == sessionID
        }) else {
            return
        }
        store.sessions[currentIndex].status = audioEngine.isFlowEnabled
            ? .running
            : .ready
        if let sampleRate = audioEngine.sampleRate {
            store.sessions[currentIndex].sampleRate = String(
                format: "%.1f kHz",
                sampleRate / 1_000
            )
        }
    }
}
