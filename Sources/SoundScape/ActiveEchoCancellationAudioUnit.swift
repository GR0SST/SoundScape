import AudioToolbox
import AVFAudio
import CAECProcessor
import Foundation

struct AECAlignmentStatus: Equatable, Sendable {
    var isEnabled = true
    var hasReliableEstimate = false
    var progress: Double = 0
    var lagMS: Double = 0
    var confidence: Double = 0
    var microphoneDelayMS: Double = 0
    var referenceDelayMS: Double = 0
    var windowsAnalyzed: UInt32 = 0
}

final class ActiveEchoCancellationAudioUnit: AUAudioUnit {
    private final class RenderState {
        var processor: OpaquePointer?
        var referenceBuffer: AVAudioPCMBuffer?
    }

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6165_6378, // "aecx"
        componentManufacturer: 0x5353_6370, // "SScp"
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var isRegistered = false
    private static let registrationLock = NSLock()

    private let microphoneBus: AUAudioUnitBus
    private let referenceBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private lazy var inputBusArray = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .input,
        busses: [microphoneBus, referenceBus]
    )
    private lazy var outputBusArray = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .output,
        busses: [outputBus]
    )

    private let renderState = RenderState()
    private var microphoneDelayMS: Float = 0
    private var autoAlignmentEnabled = true

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override var latency: TimeInterval {
        guard let processor = renderState.processor else { return 0.010 }
        return Double(SSAECGetLatencyFrames(processor))
            / outputBus.format.sampleRate
    }

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw ActiveEchoCancellationError.invalidFormat
        }
        microphoneBus = try AUAudioUnitBus(format: format)
        referenceBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(
            componentDescription: componentDescription,
            options: options
        )
        microphoneBus.shouldAllocateBuffer = false
        referenceBus.shouldAllocateBuffer = false
        maximumFramesToRender = 4_096
    }

    static func registerIfNeeded() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !isRegistered else { return }
        AUAudioUnit.registerSubclass(
            ActiveEchoCancellationAudioUnit.self,
            as: componentDescription,
            name: "SoundScape: Active Echo Cancellation",
            version: UInt32.max
        )
        isRegistered = true
    }

    func updateSettings(
        microphoneDelayMS: Double,
        autoAlignmentEnabled: Bool
    ) {
        self.microphoneDelayMS = Float(microphoneDelayMS)
        self.autoAlignmentEnabled = autoAlignmentEnabled
        guard let processor = renderState.processor else { return }
        SSAECSetMicrophoneDelay(processor, self.microphoneDelayMS)
        SSAECSetAutoAlignmentEnabled(processor, autoAlignmentEnabled)
    }

    func requestAlignment() {
        guard let processor = renderState.processor else { return }
        SSAECRequestAlignment(processor)
    }

    func alignmentStatus() -> AECAlignmentStatus {
        guard let processor = renderState.processor else {
            return AECAlignmentStatus(isEnabled: autoAlignmentEnabled)
        }
        var enabled = false
        var reliable = false
        var progress: Float = 0
        var lagMS: Float = 0
        var confidence: Float = 0
        var microphoneDelayMS: Float = 0
        var referenceDelayMS: Float = 0
        var windowsAnalyzed: UInt32 = 0
        SSAECGetAlignmentInfo(
            processor,
            &enabled,
            &reliable,
            &progress,
            &lagMS,
            &confidence,
            &microphoneDelayMS,
            &referenceDelayMS,
            &windowsAnalyzed
        )
        return AECAlignmentStatus(
            isEnabled: enabled,
            hasReliableEstimate: reliable,
            progress: Double(progress),
            lagMS: Double(lagMS),
            confidence: Double(confidence),
            microphoneDelayMS: Double(microphoneDelayMS),
            referenceDelayMS: Double(referenceDelayMS),
            windowsAnalyzed: windowsAnalyzed
        )
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0,
              microphoneBus.format == format,
              referenceBus.format == format,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: maximumFramesToRender
              ),
              let processor = SSAECCreate(
                format.sampleRate,
                maximumFramesToRender,
                format.channelCount,
                300
              ) else {
            super.deallocateRenderResources()
            throw ActiveEchoCancellationError.invalidFormat
        }

        renderState.referenceBuffer = buffer
        renderState.processor = processor
        SSAECSetMicrophoneDelay(processor, microphoneDelayMS)
        SSAECSetAutoAlignmentEnabled(processor, autoAlignmentEnabled)
    }

    override func deallocateRenderResources() {
        if let processor = renderState.processor {
            SSAECDestroy(processor)
        }
        renderState.processor = nil
        renderState.referenceBuffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let renderState = renderState
        return {
            actionFlags,
            timestamp,
            frameCount,
            _,
            outputData,
            _,
            pullInputBlock in
            guard let pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            let microphoneStatus = pullInputBlock(
                actionFlags,
                timestamp,
                frameCount,
                0,
                outputData
            )
            guard microphoneStatus == noErr else {
                return microphoneStatus
            }

            guard let processor = renderState.processor,
                  let referenceBuffer = renderState.referenceBuffer else {
                return noErr
            }
            referenceBuffer.frameLength = frameCount
            let referenceData = referenceBuffer.mutableAudioBufferList
            let referenceStatus = pullInputBlock(
                actionFlags,
                timestamp,
                frameCount,
                1,
                referenceData
            )

            // Missing reference audio is a safe bypass. This keeps the flow
            // alive while the user reconnects the second input.
            guard referenceStatus == noErr else {
                return noErr
            }
            return SSAECProcess(
                processor,
                outputData,
                UnsafePointer(referenceData),
                frameCount
            ) ? noErr : kAudioUnitErr_Uninitialized
        }
    }
}

enum ActiveEchoCancellationError: LocalizedError {
    case invalidFormat
    case instantiationFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "Active Echo Cancellation requires non-interleaved Float32 audio."
        case .instantiationFailed:
            "The Active Echo Cancellation processor could not be created."
        }
    }
}
