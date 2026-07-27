import AudioToolbox
import AVFAudio
import CAECProcessor
import Foundation

@main
struct AECAudioUnitSmokeTest {
    static func main() async throws {
        ActiveEchoCancellationAudioUnit.registerIfNeeded()
        let audioUnit = try await AVAudioUnit.instantiate(
            with: ActiveEchoCancellationAudioUnit.componentDescription,
            options: [.loadInProcess]
        )
        guard let aec =
            audioUnit.auAudioUnit as? ActiveEchoCancellationAudioUnit else {
            throw TestError.wrongAudioUnit
        }
        aec.updateSettings(
            microphoneDelayMS: 0,
            autoAlignmentEnabled: false
        )

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw TestError.invalidFormat
        }

        let frameTotal = 48_000 * 5
        let echoDelay = 2_880
        var randomState: UInt32 = 0x93A5_17F1
        var referenceSamples = [Float](repeating: 0, count: frameTotal)
        var microphoneSamples = [Float](repeating: 0, count: frameTotal)
        for frame in 0..<frameTotal {
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let noise =
                Float(randomState >> 8) / Float(1 << 23) - 1
            let reference =
                noise * 0.18
                + sin(Float(frame) * 0.0564) * 0.10
            referenceSamples[frame] = reference
            if frame >= echoDelay {
                microphoneSamples[frame] =
                    referenceSamples[frame - echoDelay] * 0.58
            }
        }

        let microphoneCursor = SampleCursor(samples: microphoneSamples)
        let referenceCursor = SampleCursor(samples: referenceSamples)
        let microphoneSource = AVAudioSourceNode(format: format) {
            _, _, frameCount, outputData in
            microphoneCursor.render(
                frameCount: Int(frameCount),
                outputData: outputData
            )
            return noErr
        }
        let referenceSource = AVAudioSourceNode(format: format) {
            _, _, frameCount, outputData in
            referenceCursor.render(
                frameCount: Int(frameCount),
                outputData: outputData
            )
            return noErr
        }

        let engine = AVAudioEngine()
        engine.attach(microphoneSource)
        engine.attach(referenceSource)
        engine.attach(audioUnit)
        engine.connect(
            microphoneSource,
            to: audioUnit,
            fromBus: 0,
            toBus: 0,
            format: format
        )
        engine.connect(
            referenceSource,
            to: audioUnit,
            fromBus: 0,
            toBus: 1,
            format: format
        )
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

        var energy = 0.0
        var measuredFrames = 0
        var renderedFrames = 0
        while renderedFrames < frameTotal {
            let requested = min(128, frameTotal - renderedFrames)
            let status = try engine.renderOffline(
                AVAudioFrameCount(requested),
                to: rendered
            )
            guard status == .success else {
                throw TestError.renderFailed(status)
            }
            if renderedFrames >= 48_000 * 3,
               let channel = rendered.floatChannelData?[0] {
                for frame in 0..<Int(rendered.frameLength) {
                    energy += Double(channel[frame] * channel[frame])
                    measuredFrames += 1
                }
            }
            renderedFrames += requested
        }

        let outputRMS = sqrt(energy / Double(max(measuredFrames, 1)))
        print(
            "AEC Audio Unit rendered two synchronized inputs; "
                + String(format: "residual RMS %.5f", outputRMS)
        )
        guard outputRMS < 0.025 else {
            throw TestError.insufficientReduction(outputRMS)
        }
    }
}

private final class SampleCursor: @unchecked Sendable {
    private let samples: [Float]
    private var position = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func render(
        frameCount: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for frame in 0..<frameCount {
            let sample = position < samples.count ? samples[position] : 0
            for buffer in buffers {
                buffer.mData?
                    .assumingMemoryBound(to: Float.self)[frame] = sample
            }
            position += 1
        }
    }
}

private enum TestError: LocalizedError {
    case wrongAudioUnit
    case invalidFormat
    case renderFailed(AVAudioEngineManualRenderingStatus)
    case insufficientReduction(Double)

    var errorDescription: String? {
        switch self {
        case .wrongAudioUnit:
            "The registered AEC Audio Unit was not instantiated."
        case .invalidFormat:
            "The AEC test format could not be created."
        case .renderFailed(let status):
            "Offline rendering failed with status \(status.rawValue)."
        case .insufficientReduction(let rms):
            "The residual echo RMS was too high: \(rms)."
        }
    }
}
