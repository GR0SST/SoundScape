import AudioToolbox
import AVFAudio
import CVST3Host
import Foundation

final class VST3AudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7673_7433, // "vst3"
        componentManufacturer: 0x5353_6370, // "SScp"
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var isRegistered = false
    private static let registrationLock = NSLock()

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private lazy var inputBusArray = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .input,
        busses: [inputBus]
    )
    private lazy var outputBusArray = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .output,
        busses: [outputBus]
    )
    private var hostedPlugin: SSVST3Plugin?

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

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
            throw VST3HostError.invalidFormat
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(
            componentDescription: componentDescription,
            options: options
        )
        inputBus.shouldAllocateBuffer = false
        maximumFramesToRender = 4_096
    }

    static func registerIfNeeded() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !isRegistered else { return }
        AUAudioUnit.registerSubclass(
            VST3AudioUnit.self,
            as: componentDescription,
            name: "SoundScape: VST3",
            version: UInt32.max
        )
        isRegistered = true
    }

    func configure(plugin: SSVST3Plugin) {
        hostedPlugin = plugin
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard let hostedPlugin else {
            super.deallocateRenderResources()
            throw VST3HostError.missingPlugin
        }

        let format = outputBus.format
        do {
            try hostedPlugin.prepare(
                withSampleRate: format.sampleRate,
                maximumFrames: maximumFramesToRender,
                channels: format.channelCount
            )
        } catch {
            super.deallocateRenderResources()
            throw error
        }
    }

    override func deallocateRenderResources() {
        hostedPlugin?.unprepare()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let plugin = hostedPlugin
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

            let status = pullInputBlock(
                actionFlags,
                timestamp,
                frameCount,
                0,
                outputData
            )
            guard status == noErr else { return status }
            guard let plugin else { return noErr }

            return plugin.processAudioBufferList(
                outputData,
                frameCount: frameCount
            ) ? noErr : kAudioUnitErr_Uninitialized
        }
    }
}

enum VST3HostError: LocalizedError {
    case invalidFormat
    case missingPlugin
    case rejectedFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "Could not create the VST3 processing format."
        case .missingPlugin:
            "The VST3 processor was not configured."
        case .rejectedFormat:
            "The VST3 plug-in rejected the processing format."
        }
    }
}
