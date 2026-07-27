import Foundation

@MainActor
final class AudioEnginePool: ObservableObject {
    private var enginesBySessionID: [UUID: AudioEngineController] = [:]

    func engine(for sessionID: UUID) -> AudioEngineController {
        if let existing = enginesBySessionID[sessionID] {
            return existing
        }

        let engine = AudioEngineController()
        enginesBySessionID[sessionID] = engine
        return engine
    }

    func stopAndRemoveEngine(for sessionID: UUID) {
        enginesBySessionID.removeValue(forKey: sessionID)?.stop()
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
