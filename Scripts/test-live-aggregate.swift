import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

func propertyString(
    _ deviceID: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value as String? : nil
}

func allDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
    ) == noErr else { return [] }
    var result = [AudioObjectID](
        repeating: 0,
        count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    let status = result.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            $0.baseAddress!
        )
    }
    return status == noErr ? result : []
}

func channelCount(
    _ deviceID: AudioObjectID,
    _ scope: AudioObjectPropertyScope
) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        deviceID,
        &address,
        0,
        nil,
        &size
    ) == noErr else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        raw
    ) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func uid(named name: String) -> String {
    for device in allDevices()
    where propertyString(device, kAudioObjectPropertyName) == name {
        if let uid = propertyString(device, kAudioDevicePropertyDeviceUID) {
            return uid
        }
    }
    fatalError("Missing device \(name)")
}

let inputUID = uid(named: "HyperX QuadCast S")
let outputUID = uid(named: "BlackHole 2ch")
let inputID = allDevices().first {
    propertyString($0, kAudioDevicePropertyDeviceUID) == inputUID
}!
let aggregateUID = "com.soundscape.live-test.\(UUID().uuidString)"
let description: [String: Any] = [
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceNameKey: "SoundScape Live Test",
    kAudioAggregateDeviceSubDeviceListKey: [
        [
            kAudioSubDeviceUIDKey: inputUID,
            kAudioSubDeviceDriftCompensationKey: 1
        ],
        [
            kAudioSubDeviceUIDKey: outputUID,
            kAudioSubDeviceDriftCompensationKey: 0
        ]
    ],
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceIsStackedKey: 0
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
let createStatus = AudioHardwareCreateAggregateDevice(
    description as CFDictionary,
    &aggregateID
)
guard createStatus == noErr else {
    fatalError("Aggregate create failed: \(createStatus)")
}
defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

let engine = AVAudioEngine()
try engine.outputNode.auAudioUnit.setDeviceID(aggregateID)
print("permission=\(AVAudioApplication.shared.recordPermission.rawValue)")
print("device=\(engine.outputNode.auAudioUnit.deviceID)")
print("inputFormat=\(engine.inputNode.outputFormat(forBus: 0))")
print("outputFormat=\(engine.outputNode.outputFormat(forBus: 0))")

let lock = NSLock()
var peak: Float = 0
var processedPeak: Float = 0
engine.inputNode.installTap(
    onBus: 0,
    bufferSize: 1024,
    format: nil
) { buffer, _ in
    guard let channels = buffer.floatChannelData else { return }
    var localPeak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            localPeak = max(localPeak, abs(channels[channel][frame]))
        }
    }
    lock.lock()
    peak = max(peak, localPeak)
    lock.unlock()
}
engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
engine.mainMixerNode.outputVolume = 1
engine.mainMixerNode.installTap(
    onBus: 0,
    bufferSize: 1024,
    format: nil
) { buffer, _ in
    guard let channels = buffer.floatChannelData else { return }
    var localPeak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            localPeak = max(localPeak, abs(channels[channel][frame]))
        }
    }
    lock.lock()
    processedPeak = max(processedPeak, localPeak)
    lock.unlock()
}
let hardwareOutputChannels = channelCount(
    aggregateID,
    kAudioObjectPropertyScopeOutput
)
let hardwareInputChannels = channelCount(
    aggregateID,
    kAudioObjectPropertyScopeInput
)
let precedingOutputChannels = channelCount(
    inputID,
    kAudioObjectPropertyScopeOutput
)
var outputMap = [Int32](repeating: -1, count: hardwareOutputChannels)
for channel in outputMap.indices {
    outputMap[channel] = Int32(channel % 2)
}
let mapStatus = outputMap.withUnsafeBytes {
    AudioUnitSetProperty(
        engine.outputNode.audioUnit!,
        kAudioOutputUnitProperty_ChannelMap,
        kAudioUnitScope_Input,
        0,
        $0.baseAddress,
        UInt32($0.count)
    )
}
print(
    "hardwareInputs=\(hardwareInputChannels) "
        + "hardwareOutputs=\(hardwareOutputChannels) "
        + "map=\(outputMap) status=\(mapStatus)"
)
print("channelMapBeforePrepare=\(String(describing: engine.outputNode.auAudioUnit.channelMap))")
engine.prepare()
print("channelMapAfterPrepare=\(String(describing: engine.outputNode.auAudioUnit.channelMap))")
try engine.start()
RunLoop.current.run(until: Date().addingTimeInterval(5))
engine.stop()
lock.lock()
print("peak=\(peak)")
print("processedPeak=\(processedPeak)")
lock.unlock()
