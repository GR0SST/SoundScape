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
        .executableTarget(
            name: "SoundScape",
            dependencies: ["CSQLite"],
            path: "Sources/SoundScape"
        )
    ],
    swiftLanguageModes: [.v5]
)
