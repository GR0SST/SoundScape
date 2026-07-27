import AudioToolbox
import AVFAudio
import Foundation

@MainActor
final class AudioUnitCatalog: ObservableObject {
    @Published private(set) var components: [AudioUnitDescriptor] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: AVAudioUnitComponentManager.registrationsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isScanning = true
        errorMessage = nil

        let manager = AVAudioUnitComponentManager.shared()
        let componentTypes: [OSType] = [
            kAudioUnitType_Effect,
            kAudioUnitType_MusicEffect
        ]

        var discovered: [String: AudioUnitDescriptor] = [:]
        for componentType in componentTypes {
            let query = AudioComponentDescription(
                componentType: componentType,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            for component in manager.components(matching: query) {
                let description = component.audioComponentDescription
                let descriptor = AudioUnitDescriptor(
                    componentType: description.componentType,
                    componentSubType: description.componentSubType,
                    componentManufacturer: description.componentManufacturer,
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    typeName: component.typeName,
                    hasCustomView: component.hasCustomView
                )
                discovered[descriptor.id] = descriptor
            }
        }

        components = discovered.values.sorted {
            let left = "\($0.manufacturerName) \($0.name)"
            let right = "\($1.manufacturerName) \($1.name)"
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        isScanning = false
    }
}
