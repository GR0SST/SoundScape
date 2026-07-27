import AudioToolbox
import AVFAudio
import CVST3Host
import Foundation

@main
struct VST3AudioUnitSmokeTest {
    static func main() async throws {
        var scanError: NSError?
        let descriptors = SSVST3Descriptor.scanInstalledPlugins(&scanError)
        if let scanError {
            throw scanError
        }
        guard let descriptor = descriptors.first(where: {
            $0.name.localizedCaseInsensitiveContains("DeeGate")
        }) ?? descriptors.first else {
            throw TestError.noPlugins
        }

        let plugin = try SSVST3Plugin(
            modulePath: descriptor.modulePath,
            classID: descriptor.classID
        )
        VST3AudioUnit.registerIfNeeded()
        let audioUnit = try await AVAudioUnit.instantiate(
            with: VST3AudioUnit.componentDescription,
            options: [.loadInProcess]
        )
        guard let wrapper = audioUnit.auAudioUnit as? VST3AudioUnit else {
            throw TestError.wrongAudioUnit
        }
        wrapper.configure(plugin: plugin)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw TestError.invalidFormat
        }

        let engine = AVAudioEngine()
        var phase: Float = 0
        let source = AVAudioSourceNode(format: format) {
            _,
            _,
            frameCount,
            outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for frame in 0..<Int(frameCount) {
                let sample = sin(phase) * 0.1
                phase += 0.04
                for buffer in buffers {
                    buffer.mData?
                        .assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }

        engine.attach(source)
        engine.attach(audioUnit)
        engine.connect(source, to: audioUnit, format: format)
        engine.connect(audioUnit, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: 128
        )
        try engine.start()

        guard let rendered = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 128
        ) else {
            throw TestError.invalidFormat
        }
        let status = try engine.renderOffline(128, to: rendered)
        guard status == .success else {
            throw TestError.renderFailed(status)
        }
        print(
            "\(descriptor.name): rendered \(rendered.frameLength) frames "
                + "through SoundScape's VST3 Audio Unit adapter"
        )
    }
}

private enum TestError: LocalizedError {
    case noPlugins
    case wrongAudioUnit
    case invalidFormat
    case renderFailed(AVAudioEngineManualRenderingStatus)

    var errorDescription: String? {
        switch self {
        case .noPlugins:
            "No installed VST3 effects were found."
        case .wrongAudioUnit:
            "The registered Audio Unit adapter was not instantiated."
        case .invalidFormat:
            "The smoke-test format could not be created."
        case .renderFailed(let status):
            "Offline rendering failed with status \(status.rawValue)."
        }
    }
}
