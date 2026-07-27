import AVFAudio
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CapturableAudioApplication: Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let processID: pid_t

    var id: String { bundleIdentifier }
}

@MainActor
final class SystemAudioApplicationCatalog: ObservableObject {
    @Published private(set) var applications: [CapturableAudioApplication] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                var seenBundleIdentifiers: Set<String> = []
                applications = content.applications
                    .compactMap { application in
                        let bundleIdentifier = application.bundleIdentifier
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !bundleIdentifier.isEmpty,
                              bundleIdentifier != Bundle.main.bundleIdentifier,
                              seenBundleIdentifiers.insert(bundleIdentifier).inserted else {
                            return nil
                        }
                        return CapturableAudioApplication(
                            bundleIdentifier: bundleIdentifier,
                            name: application.applicationName,
                            processID: application.processID
                        )
                    }
                    .sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
                isLoading = false
            } catch {
                applications = []
                errorMessage = Self.readableError(error)
                isLoading = false
            }
        }
    }

    func application(
        withBundleIdentifier bundleIdentifier: String?
    ) -> CapturableAudioApplication? {
        guard let bundleIdentifier else { return nil }
        return applications.first {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    private static func readableError(_ error: Error) -> String {
        if CGPreflightScreenCaptureAccess() == false {
            return "Allow Screen & System Audio Recording in System Settings."
        }
        return error.localizedDescription
    }
}

final class ScreenAudioCaptureSource: NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    let sourceNode: AVAudioSourceNode

    private let bridge: AudioRingBuffer
    private let sampleQueue = DispatchQueue(
        label: "dev.soundscape.screen-audio",
        qos: .userInteractive
    )
    private let inputBufferHandler: (
        UnsafePointer<AudioBufferList>,
        AVAudioFrameCount
    ) -> Void
    private var stream: SCStream?

    init(
        format: AVAudioFormat,
        inputBufferHandler: @escaping (
            UnsafePointer<AudioBufferList>,
            AVAudioFrameCount
        ) -> Void
    ) {
        let bridge = AudioRingBuffer(
            channelCount: Int(format.channelCount)
        )
        self.bridge = bridge
        self.inputBufferHandler = inputBufferHandler
        sourceNode = AVAudioSourceNode(
            format: format
        ) { isSilence, _, frameCount, outputData in
            let hasAudio = bridge.read(
                into: outputData,
                frameCount: frameCount
            )
            isSilence.pointee = ObjCBool(!hasAudio)
            return noErr
        }
        super.init()
    }

    func start(for node: AudioNode, format: AVAudioFormat) async throws {
        try Task.checkCancellation()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            try Task.checkCancellation()
        } catch {
            if error is CancellationError {
                throw error
            }
            if !CGPreflightScreenCaptureAccess() {
                throw SystemAudioCaptureError.permissionDenied
            }
            throw error
        }
        guard let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter: SCContentFilter
        switch node.nodeType {
        case .applicationAudioInput:
            guard let bundleIdentifier = node.applicationBundleIdentifier,
                  let application = content.applications.first(where: {
                      $0.bundleIdentifier == bundleIdentifier
                  }) else {
                throw SystemAudioCaptureError.applicationUnavailable(
                    node.subtitle
                )
            }
            filter = SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        case .systemAudioInput:
            filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
        default:
            throw SystemAudioCaptureError.unsupportedSource
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio =
            node.excludesCurrentProcessAudio
        configuration.sampleRate = Int(format.sampleRate.rounded())
        configuration.channelCount = Int(
            min(max(format.channelCount, 1), 2)
        )
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: 1
        )

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: sampleQueue
        )
        self.stream = stream
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            self.stream = nil
            try? await stream.stopCapture()
            if error is CancellationError {
                throw error
            }
            if !CGPreflightScreenCaptureAccess() {
                throw SystemAudioCaptureError.permissionDenied
            }
            throw error
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            let frameCount = AVAudioFrameCount(
                CMSampleBufferGetNumSamples(sampleBuffer)
            )
            guard frameCount > 0 else { return }
            guard let description = sampleBuffer.formatDescription?
                    .audioStreamBasicDescription,
                  description.mFormatID == kAudioFormatLinearPCM,
                  description.mBitsPerChannel == 32,
                  description.mFormatFlags
                    & kAudioFormatFlagIsFloat != 0 else {
                return
            }
            bridge.write(
                audioBufferList.unsafePointer,
                frameCount: frameCount
            )
            inputBufferHandler(
                audioBufferList.unsafePointer,
                frameCount
            )
        }
    }
}

enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case applicationUnavailable(String)
    case unsupportedSource

    var shouldRetry: Bool {
        switch self {
        case .permissionDenied,
             .noDisplay,
             .applicationUnavailable,
             .unsupportedSource:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Screen & System Audio Recording in System Settings, then restart SoundScape."
        case .noDisplay:
            "No display is available for system audio capture."
        case .applicationUnavailable(let name):
            "\(name) is not running. Choose an available application."
        case .unsupportedSource:
            "This node is not a system audio source."
        }
    }
}
