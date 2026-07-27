import AudioToolbox
import AppKit
import AVFAudio
import CoreAudioKit
import Darwin
import Foundation

let manager = AVAudioUnitComponentManager.shared()
let componentTypes: [OSType] = [
    kAudioUnitType_Effect,
    kAudioUnitType_MusicEffect
]

var componentsByID: [String: AVAudioUnitComponent] = [:]
for componentType in componentTypes {
    let query = AudioComponentDescription(
        componentType: componentType,
        componentSubType: 0,
        componentManufacturer: 0,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    for component in manager.components(matching: query) {
        let description = component.audioComponentDescription
        let id = [
            String(format: "%08X", description.componentType),
            String(format: "%08X", description.componentSubType),
            String(format: "%08X", description.componentManufacturer)
        ].joined(separator: "-")
        componentsByID[id] = component
    }
}

let nameFilter = CommandLine.arguments.dropFirst().first
let components = componentsByID.values.filter {
    guard let nameFilter else { return true }
    return $0.name.localizedCaseInsensitiveContains(nameFilter)
}.sorted {
    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
}

Task { @MainActor in
    var passed = 0
    var failed = 0

    for component in components {
        do {
            let audioUnit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription,
                options: []
            )
            let parameters = audioUnit.auAudioUnit.parameterTree?.allParameters ?? []
            let writable = parameters.filter {
                $0.flags.contains(.flag_IsWritable)
            }.count
            print(
                "OK\t\(component.name)\tparameters=\(parameters.count)"
                    + "\twritable=\(writable)\tcustomView=\(component.hasCustomView)"
            )
            if nameFilter != nil {
                for parameter in parameters {
                    print(
                        "PARAM\t\(parameter.displayName)"
                            + "\taddress=\(parameter.address)"
                            + "\tmin=\(parameter.minValue)"
                            + "\tmax=\(parameter.maxValue)"
                            + "\tvalue=\(parameter.value)"
                            + "\tunit=\(parameter.unit.rawValue)"
                    )
                }
                let inputBusses = audioUnit.auAudioUnit.inputBusses
                for index in 0..<inputBusses.count {
                    let bus = inputBusses[index]
                    print("INPUT BUS\t\(bus.index)\t\(bus.format)")
                }
                let outputBusses = audioUnit.auAudioUnit.outputBusses
                for index in 0..<outputBusses.count {
                    let bus = outputBusses[index]
                    print("OUTPUT BUS\t\(bus.index)\t\(bus.format)")
                }
                print(
                    "CHANNEL CAPABILITIES\t"
                        + "\(audioUnit.auAudioUnit.channelCapabilities?.description ?? "nil")"
                )
                if component.hasCustomView {
                    let viewController = await withCheckedContinuation {
                        continuation in
                        audioUnit.auAudioUnit.requestViewController {
                            continuation.resume(returning: $0)
                        }
                    }
                    if let viewController {
                        viewController.loadView()
                        print(
                            "CUSTOM VIEW\tpreferred="
                                + "\(viewController.preferredContentSize)"
                                + "\tframe=\(viewController.view.frame.size)"
                                + "\tfitting=\(viewController.view.fittingSize)"
                                + "\tclass=\(NSStringFromClass(type(of: viewController)))"
                                + "\tbundle=\(Bundle(for: type(of: viewController)).bundleURL.path)"
                                + "\tviewClass=\(NSStringFromClass(type(of: viewController.view)))"
                                + "\tviewBundle=\(Bundle(for: type(of: viewController.view)).bundleURL.path)"
                        )
                    } else {
                        print("CUSTOM VIEW\tunavailable")
                    }
                }
            }
            passed += 1
        } catch {
            print("FAIL\t\(component.name)\t\(error.localizedDescription)")
            failed += 1
        }
    }

    print("SUMMARY\ttotal=\(components.count)\tpassed=\(passed)\tfailed=\(failed)")
    exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
}

dispatchMain()
