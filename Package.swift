// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SoundScape",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SoundScape", targets: ["SoundScape"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "CVST3Host",
            path: "Sources/CVST3Host",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Vendor"),
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation")
            ]
        ),
        .binaryTarget(
            name: "WebRTCAECBridge",
            path: "Vendor/WebRTCAECBridge.xcframework"
        ),
        .target(
            name: "CAECProcessor",
            dependencies: ["WebRTCAECBridge"],
            path: "Sources/CAECProcessor",
            sources: ["SoundScapeAEC.c"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++")
            ]
        ),
        .executableTarget(
            name: "SoundScape",
            dependencies: ["CSQLite", "CVST3Host", "CAECProcessor"],
            path: "Sources/SoundScape"
        )
    ],
    swiftLanguageModes: [.v5],
    cLanguageStandard: .c11
)
