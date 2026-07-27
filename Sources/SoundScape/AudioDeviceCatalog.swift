import CoreAudio
import Foundation

struct CoreAudioDevice: Identifiable, Hashable {
    let audioObjectID: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let isDefaultInput: Bool
    let isDefaultOutput: Bool

    var id: String { uid }
}

@MainActor
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var devices: [CoreAudioDevice] = []
    @Published private(set) var errorMessage: String?
    private var hardwarePropertyListener: AudioObjectPropertyListenerBlock?

    var inputDevices: [CoreAudioDevice] {
        devices.filter { $0.inputChannels > 0 }
    }

    var outputDevices: [CoreAudioDevice] {
        devices.filter { $0.outputChannels > 0 }
    }

    init() {
        refresh()
        installDeviceListListener()
    }

    deinit {
        guard let hardwarePropertyListener else { return }
        for var address in Self.observedHardwareAddresses {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                hardwarePropertyListener
            )
        }
    }

    func refresh() {
        let defaultInput = Self.defaultDeviceID(
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        let defaultOutput = Self.defaultDeviceID(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )

        var discovered: [CoreAudioDevice] = []
        for deviceID in Self.allDeviceIDs() {
            guard let uid = Self.stringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                  ),
                  let name = Self.stringProperty(
                    deviceID,
                    selector: kAudioObjectPropertyName
                  ) else {
                continue
            }

            let inputChannels = Self.channelCount(
                deviceID,
                scope: kAudioObjectPropertyScopeInput
            )
            let outputChannels = Self.channelCount(
                deviceID,
                scope: kAudioObjectPropertyScopeOutput
            )
            guard inputChannels > 0 || outputChannels > 0 else { continue }

            discovered.append(CoreAudioDevice(
                audioObjectID: deviceID,
                uid: uid,
                name: name,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                isDefaultInput: deviceID == defaultInput,
                isDefaultOutput: deviceID == defaultOutput
            ))
        }

        discovered.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        devices = discovered
        errorMessage = discovered.isEmpty
            ? "Core Audio did not report any available devices."
            : nil
    }

    func device(withUID uid: String?) -> CoreAudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    private func installDeviceListListener() {
        let listener: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        var installed = false
        for var address in Self.observedHardwareAddresses {
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            ) == noErr {
                installed = true
            }
        }
        if installed {
            hardwarePropertyListener = listener
        }
    }

    nonisolated private static var observedHardwareAddresses:
        [AudioObjectPropertyAddress] {
        [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ].map { selector in
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        }
    }

    static func audioObjectID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    static func deviceUID(for deviceID: AudioObjectID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        return status == noErr ? deviceIDs : []
    }

    static func defaultDeviceID(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func stringProperty(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func channelCount(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr,
        byteCount > 0 else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            storage
        ) == noErr else {
            return 0
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }
}
