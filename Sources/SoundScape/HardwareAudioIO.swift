import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import os

/// One raw AUHAL bound to one Core Audio device.
///
/// AVAudioEngine's input and output nodes silently follow the macOS default device even
/// after `setDeviceID`. Connecting AirPods made them the default, so the selected microphone
/// was swapped for the AirPods mic, which also forced the AirPods into low-quality headset
/// mode and caused an endless reconnect loop. A plain AUHAL keeps the device it was given.
final class HALAudioUnit: @unchecked Sendable {
    typealias Handler = (UnsafeMutablePointer<AudioBufferList>, AVAudioFrameCount) -> Void

    /// Client-side PCM format: what the handler reads (input) or writes (output).
    let format: AVAudioFormat
    let deviceID: AudioObjectID

    private let unit: AudioUnit
    private let isInput: Bool
    private let handler: Handler
    private var inputBuffer: AVAudioPCMBuffer?
    private var isStarted = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var observedSelectors: [AudioObjectPropertySelector] = []
    private let listenerQueue = DispatchQueue(label: "dev.soundscape.hal-device")

    /// Captures `deviceID` in its native sample rate and channel count, as deinterleaved Float32.
    static func input(
        deviceID: AudioObjectID,
        handler: @escaping Handler
    ) throws -> HALAudioUnit {
        try HALAudioUnit(deviceID: deviceID, outputFormat: nil, handler: handler)
    }

    /// Plays to `deviceID`; the AUHAL converts `format` to the hardware format.
    static func output(
        deviceID: AudioObjectID,
        format: AVAudioFormat,
        handler: @escaping Handler
    ) throws -> HALAudioUnit {
        try HALAudioUnit(deviceID: deviceID, outputFormat: format, handler: handler)
    }

    private init(
        deviceID: AudioObjectID,
        outputFormat: AVAudioFormat?,
        handler: @escaping Handler
    ) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HALAudioError.failed("Find the Core Audio device unit", kAudioUnitErr_InvalidElement)
        }
        var instance: AudioUnit?
        try HALAudioError.check(
            AudioComponentInstanceNew(component, &instance),
            "Open the audio device"
        )
        guard let instance else {
            throw HALAudioError.failed("Open the audio device", kAudioUnitErr_FailedInitialization)
        }

        let isInput = outputFormat == nil
        do {
            var enableInput: UInt32 = isInput ? 1 : 0
            var enableOutput: UInt32 = isInput ? 0 : 1
            try HALAudioError.check(AudioUnitSetProperty(
                instance, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1,
                &enableInput, UInt32(MemoryLayout<UInt32>.size)
            ), "Enable audio input")
            try HALAudioError.check(AudioUnitSetProperty(
                instance, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0,
                &enableOutput, UInt32(MemoryLayout<UInt32>.size)
            ), "Enable audio output")
            var device = deviceID
            try HALAudioError.check(AudioUnitSetProperty(
                instance, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioObjectID>.size)
            ), "Select the audio device")

            let clientFormat: AVAudioFormat
            if let outputFormat {
                clientFormat = outputFormat
                var description = outputFormat.streamDescription.pointee
                try HALAudioError.check(AudioUnitSetProperty(
                    instance, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input, 0,
                    &description,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ), "Set the output format")
            } else {
                // AUHAL cannot resample input, so keep the device's own rate.
                var hardware = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try HALAudioError.check(AudioUnitGetProperty(
                    instance, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input, 1,
                    &hardware, &size
                ), "Read the input format")
                guard hardware.mSampleRate > 0,
                      hardware.mChannelsPerFrame > 0,
                      let format = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: hardware.mSampleRate,
                        channels: hardware.mChannelsPerFrame,
                        interleaved: false
                      ) else {
                    throw HALAudioError.failed("Read the input format", kAudioUnitErr_FormatNotSupported)
                }
                clientFormat = format
                var description = format.streamDescription.pointee
                try HALAudioError.check(AudioUnitSetProperty(
                    instance, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, 1,
                    &description,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ), "Set the input format")
            }

            self.format = clientFormat
            self.deviceID = deviceID
            self.unit = instance
            self.isInput = isInput
            self.handler = handler
        } catch {
            AudioComponentInstanceDispose(instance)
            throw error
        }

        // Fully initialized from here on, so a throw runs deinit, which disposes the unit.
        try installCallback()
        try HALAudioError.check(AudioUnitInitialize(unit), "Initialize the audio device")
    }

    deinit {
        stop()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func start() throws {
        guard !isStarted else { return }
        try HALAudioError.check(AudioOutputUnitStart(unit), "Start the audio device")
        isStarted = true
    }

    /// Blocks until the device's I/O thread has left the callback.
    func stop() {
        removeDeviceListener()
        guard isStarted else { return }
        AudioOutputUnitStop(unit)
        isStarted = false
    }

    /// Reports disconnection and, for inputs, hardware sample-rate changes. Output units
    /// resample internally, so an output's rate change (e.g. AirPods entering headset mode)
    /// does not need a rebuild.
    func observeDeviceChanges(_ onChange: @escaping @Sendable () -> Void) {
        removeDeviceListener()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let selectors = isInput
            ? [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate]
            : [kAudioDevicePropertyDeviceIsAlive]
        for selector in selectors {
            var address = Self.address(selector)
            if AudioObjectAddPropertyListenerBlock(
                deviceID, &address, listenerQueue, listener
            ) == noErr {
                observedSelectors.append(selector)
            }
        }
        deviceListener = listener
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        for selector in observedSelectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                deviceID, &address, listenerQueue, deviceListener
            )
        }
        observedSelectors.removeAll()
        self.deviceListener = nil
    }

    private func installCallback() throws {
        var callback = AURenderCallbackStruct(
            inputProc: isInput ? Self.inputCallback : Self.outputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        if isInput {
            var maximumFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximumFrames, &size
            )
            inputBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: max(maximumFrames, 8_192)
            )
            try HALAudioError.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "Connect audio input")
        } else {
            try HALAudioError.check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "Connect audio output")
        }
    }

    private static let inputCallback: AURenderCallback = {
        refCon, flags, timestamp, bus, frameCount, _ in
        let io = Unmanaged<HALAudioUnit>.fromOpaque(refCon).takeUnretainedValue()
        guard let buffer = io.inputBuffer,
              frameCount <= buffer.frameCapacity else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        buffer.frameLength = frameCount
        let data = buffer.mutableAudioBufferList
        let status = AudioUnitRender(io.unit, flags, timestamp, bus, frameCount, data)
        guard status == noErr else { return status }
        io.handler(data, frameCount)
        return noErr
    }

    private static let outputCallback: AURenderCallback = {
        refCon, _, _, _, frameCount, data in
        guard let data else { return noErr }
        let io = Unmanaged<HALAudioUnit>.fromOpaque(refCon).takeUnretainedValue()
        io.handler(data, frameCount)
        return noErr
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

enum HALAudioError: LocalizedError {
    case failed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .failed(let operation, let status):
            "\(operation) failed (\(status))."
        }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw failed(operation, status) }
    }
}

/// Pass-through node whose rendered output is handed to `handler` on the render thread.
/// In manual rendering mode AVAudioSinkNode is never pulled, so every graph endpoint feeds
/// one of these, and all of them feed the muted main mixer that the pump renders.
final class RenderTerminal: @unchecked Sendable {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    private let handler: (UnsafePointer<AudioBufferList>, AVAudioFrameCount) -> Void
    private var isObserving = false

    init(handler: @escaping (UnsafePointer<AudioBufferList>, AVAudioFrameCount) -> Void) {
        self.handler = handler
        isObserving = AudioUnitAddRenderNotify(
            node.audioUnit,
            Self.renderNotify,
            Unmanaged.passUnretained(self).toOpaque()
        ) == noErr
    }

    deinit { invalidate() }

    func invalidate() {
        guard isObserving else { return }
        AudioUnitRemoveRenderNotify(
            node.audioUnit,
            Self.renderNotify,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isObserving = false
    }

    private static let renderNotify: AURenderCallback = {
        refCon, flags, _, _, frameCount, data in
        guard flags.pointee.contains(.unitRenderAction_PostRender),
              let data else {
            return noErr
        }
        let terminal = Unmanaged<RenderTerminal>.fromOpaque(refCon)
            .takeUnretainedValue()
        terminal.handler(data, frameCount)
        return noErr
    }
}

/// Renders a manual-rendering engine from the clock of one capture callback.
final class ManualRenderPump: @unchecked Sendable {
    private let block: AVAudioEngineManualRenderingBlock
    private let buffer: AVAudioPCMBuffer
    private let maximumFrames: AVAudioFrameCount
    // Held while rendering, so invalidate() returns only once no render is in flight.
    private let isActive = OSAllocatedUnfairLock(initialState: false)

    init?(engine: AVAudioEngine) {
        maximumFrames = engine.manualRenderingMaximumFrameCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrames
        ) else {
            return nil
        }
        self.buffer = buffer
        block = engine.manualRenderingBlock
    }

    func activate() {
        isActive.withLock { $0 = true }
    }

    func invalidate() {
        isActive.withLock { $0 = false }
    }

    func render(_ frameCount: AVAudioFrameCount) {
        isActive.withLock { active in
            guard active else { return }
            var remaining = frameCount
            var status = noErr
            while remaining > 0 {
                let chunk = min(remaining, maximumFrames)
                buffer.frameLength = chunk
                _ = block(chunk, buffer.mutableAudioBufferList, &status)
                remaining -= chunk
            }
        }
    }
}
