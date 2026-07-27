import AudioToolbox
import AVFAudio
import Foundation

let target = CommandLine.arguments.dropFirst().first ?? "DeeGate"
let manager = AVAudioUnitComponentManager.shared()
let componentTypes: [OSType] = [
    kAudioUnitType_Effect,
    kAudioUnitType_MusicEffect
]

let components = componentTypes.flatMap { type in
    manager.components(matching: AudioComponentDescription(
        componentType: type,
        componentSubType: 0,
        componentManufacturer: 0,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
}

guard let component = components.first(where: {
    $0.name.localizedCaseInsensitiveContains(target)
}) else {
    fputs("Audio Unit matching '\(target)' was not found.\n", stderr)
    exit(EXIT_FAILURE)
}

let done = DispatchSemaphore(value: 0)
var exitCode = EXIT_FAILURE

Task { @MainActor in
    defer { done.signal() }

    do {
        let audioUnit = try await AVAudioUnit.instantiate(
            with: component.audioComponentDescription,
            options: []
        )
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!

        engine.attach(player)
        engine.attach(audioUnit)
        engine.connect(player, to: audioUnit, format: renderFormat)
        engine.connect(audioUnit, to: engine.mainMixerNode, format: renderFormat)

        for parameter in audioUnit.auAudioUnit.parameterTree?.allParameters ?? [] {
            let name = parameter.displayName.lowercased()
            if component.name.localizedCaseInsensitiveContains("DeeGate") {
                if name == "level" {
                    parameter.value = 0
                } else if name == "enable" {
                    parameter.value = 1
                }
            }
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: 512
        )
        engine.prepare()
        try engine.start()

        let sourceFrames: AVAudioFrameCount = 48_000
        let source = AVAudioPCMBuffer(
            pcmFormat: renderFormat,
            frameCapacity: sourceFrames
        )!
        source.frameLength = sourceFrames

        for channel in 0..<Int(renderFormat.channelCount) {
            let data = source.floatChannelData![channel]
            for frame in 0..<Int(sourceFrames) {
                data[frame] = 0.25 * sin(
                    2 * .pi * 440 * Float(frame) / 48_000
                )
            }
        }

        let output = AVAudioPCMBuffer(
            pcmFormat: renderFormat,
            frameCapacity: 512
        )!
        player.scheduleBuffer(source, completionHandler: nil)
        player.play()

        var sumSquares: Double = 0
        var sampleCount = 0
        var remaining = Int(sourceFrames) + 48_000

        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, 512))
            let status = try engine.renderOffline(frames, to: output)
            guard status == .success else {
                if status == .cannotDoInCurrentContext {
                    continue
                }
                throw NSError(
                    domain: "SoundScapeAudioUnitRenderTest",
                    code: Int(status.rawValue),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Offline render returned status \(status.rawValue)"
                    ]
                )
            }

            for channel in 0..<Int(output.format.channelCount) {
                let data = output.floatChannelData![channel]
                for frame in 0..<Int(output.frameLength) {
                    let sample = Double(data[frame])
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
            remaining -= Int(output.frameLength)
        }

        let rms = sampleCount > 0
            ? sqrt(sumSquares / Double(sampleCount))
            : 0
        print("UNIT\t\(component.name)")
        print("INPUT\t\(audioUnit.inputFormat(forBus: 0))")
        print("OUTPUT\t\(audioUnit.outputFormat(forBus: 0))")
        print("RMS\t\(String(format: "%.6f", rms))")

        engine.stop()
        exitCode = rms > 0.000_1 ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
        fputs("FAIL\t\(error.localizedDescription)\n", stderr)
    }
}

while done.wait(timeout: .now() + 0.01) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
}
exit(exitCode)
