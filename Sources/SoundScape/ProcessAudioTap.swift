import AVFAudio
import CoreAudio
import Foundation

/// Audio-only capture. No display, window enumeration, or ScreenCaptureKit session.
final class ProcessAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "dev.soundscape.tap-format")

    @available(macOS 14.2, *)
    func start(
        bundleIdentifier: String?,
        excludesCurrentProcess: Bool,
        format: AVAudioFormat,
        failureHandler: @escaping @Sendable () -> Void,
        bufferHandler: @escaping (UnsafePointer<AudioBufferList>, AVAudioFrameCount) -> Void
    ) throws {
        stop()
        do {
            let description: CATapDescription
            if let bundleIdentifier {
                if #available(macOS 26.0, *) {
                    description = CATapDescription(stereoMixdownOfProcesses: [])
                    description.bundleIDs = [bundleIdentifier]
                    description.isProcessRestoreEnabled = true
                } else {
                    let processes = try Self.processes(bundleIdentifier: bundleIdentifier)
                    guard !processes.isEmpty else {
                        throw NSError(domain: "SoundScape.AudioTap", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "The selected application has no audio process yet. Waiting for it to play audio…"
                        ])
                    }
                    description = CATapDescription(stereoMixdownOfProcesses: processes)
                }
            } else {
                let excluded = excludesCurrentProcess ? try [Self.currentProcessObject()] : []
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            }
            description.name = "SoundScape Audio"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "Create audio-only capture")

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundScape Audio Capture",
                kAudioAggregateDeviceUIDKey: "dev.soundscape.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create audio capture device")

            var streamFormat = AudioStreamBasicDescription()
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &streamFormat), "Read capture format")
            guard let inputFormat = AVAudioFormat(streamDescription: &streamFormat),
                  let converter = TapPCMConverter(inputFormat: inputFormat, outputFormat: format, bufferHandler: bufferHandler) else {
                throw NSError(domain: "SoundScape.AudioTap", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "System audio capture has no usable audio format yet."
                ])
            }
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) {
                _, input, _, _, _ in converter.consume(input)
            }, "Connect audio-only capture")
            try Self.check(AudioDeviceStart(aggregateID, ioProc), "Start audio-only capture")
            let listener: AudioObjectPropertyListenerBlock = { _, _ in failureHandler() }
            try Self.check(AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, listenerQueue, listener), "Observe audio capture format")
            formatListener = listener
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if #available(macOS 14.2, *), let formatListener {
            var property = Self.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &property, listenerQueue, formatListener)
            self.formatListener = nil
        }
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "SoundScape.AudioTap", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed (\(status)). Check SoundScape's System Audio Recording permission in System Settings."
            ])
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    @available(macOS 14.2, *)
    private static func currentProcessObject() throws -> AudioObjectID {
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "Resolve SoundScape audio process")
        guard object != kAudioObjectUnknown else {
            throw NSError(domain: "SoundScape.AudioTap", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "SoundScape's audio process is not ready."
            ])
        }
        return object
    }

    @available(macOS 14.2, *)
    private static func processes(bundleIdentifier: String) throws -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "List audio processes")
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Read audio processes")
        return objects.filter { object in
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            var bundle: CFString?
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            let result = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(object, &bundleProperty, 0, nil, &bundleSize, $0)
            }
            return result == noErr && bundle as String? == bundleIdentifier
        }
    }
}

/// Owns conversion buffers for the tap's serial real-time callback.
final class TapPCMConverter {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let bytesPerFrame: Int
    private let handler: (UnsafePointer<AudioBufferList>, AVAudioFrameCount) -> Void

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
          bufferHandler: @escaping (UnsafePointer<AudioBufferList>, AVAudioFrameCount) -> Void) {
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(16_384 * outputFormat.sampleRate / inputFormat.sampleRate)) + 64) else { return nil }
        self.converter = converter
        self.input = input
        self.output = output
        bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        handler = bufferHandler
    }

    func consume(_ data: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = buffers.first, bytesPerFrame > 0 else { return }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0, frames <= Int(input.frameCapacity) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard buffers.count == destination.count else { return }
        for index in destination.indices {
            guard let source = buffers[index].mData, let target = destination[index].mData,
                  buffers[index].mDataByteSize >= destination[index].mDataByteSize else { return }
            memcpy(target, source, Int(destination[index].mDataByteSize))
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return self.input
        }
        if status != .error, output.frameLength > 0 {
            handler(output.audioBufferList, output.frameLength)
        }
    }
}
