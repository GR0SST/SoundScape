import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

func allDeviceIDs() -> [AudioObjectID] {
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

    var ids = [AudioObjectID](
        repeating: 0,
        count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    let status = ids.withUnsafeMutableBytes { bytes in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            bytes.baseAddress!
        )
    }
    return status == noErr ? ids : []
}

func deviceName(_ id: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var byteCount = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(
            id,
            &address,
            0,
            nil,
            &byteCount,
            pointer
        )
    }
    return status == noErr ? (value as String? ?? "Unknown") : "Unknown"
}

func channelCount(
    _ id: AudioObjectID,
    scope: AudioObjectPropertyScope
) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        id,
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
        id,
        &address,
        0,
        nil,
        &byteCount,
        storage
    ) == noErr else {
        return 0
    }

    return UnsafeMutableAudioBufferListPointer(
        storage.assumingMemoryBound(to: AudioBufferList.self)
    ).reduce(0) {
        $0 + Int($1.mNumberChannels)
    }
}

func defaultDevice(
    selector: AudioObjectPropertySelector
) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(kAudioObjectUnknown)
    var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        &device
    ) == noErr else {
        return AudioObjectID(kAudioObjectUnknown)
    }
    return device
}

func sampleRate(_ id: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate = 0.0
    var byteCount = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(
        id,
        &address,
        0,
        nil,
        &byteCount,
        &rate
    ) == noErr else {
        return 0
    }
    return rate
}

var passed = 0
var failed = 0
let defaultInput = defaultDevice(
    selector: kAudioHardwarePropertyDefaultInputDevice
)
let defaultOutput = defaultDevice(
    selector: kAudioHardwarePropertyDefaultOutputDevice
)

for id in allDeviceIDs() {
    let name = deviceName(id)
    let inputs = channelCount(id, scope: kAudioObjectPropertyScopeInput)
    let outputs = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
    let rate = sampleRate(id)

    if inputs > 0 {
        do {
            let engine = AVAudioEngine()
            try engine.inputNode.auAudioUnit.setDeviceID(id)
            print(
                "OK\tINPUT\t\(name)\tchannels=\(inputs)"
                    + "\trate=\(rate)\tdefault=\(id == defaultInput)"
            )
            passed += 1
        } catch {
            print("FAIL\tINPUT\t\(name)\t\(error.localizedDescription)")
            failed += 1
        }
    }

    if outputs > 0 {
        do {
            let engine = AVAudioEngine()
            try engine.outputNode.auAudioUnit.setDeviceID(id)
            print(
                "OK\tOUTPUT\t\(name)\tchannels=\(outputs)"
                    + "\trate=\(rate)\tdefault=\(id == defaultOutput)"
            )
            passed += 1
        } catch {
            print("FAIL\tOUTPUT\t\(name)\t\(error.localizedDescription)")
            failed += 1
        }
    }
}

print("SUMMARY\tpassed=\(passed)\tfailed=\(failed)")
exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
