# SoundScape

SoundScape is a native node-based audio routing and processing app for macOS,
built with SwiftUI, AVFAudio, Core Audio, ScreenCaptureKit, and SQLite.

## Features

- Persistent audio-flow projects backed by SQLite
- Node-based routing with connection editing and multi-selection
- Hardware microphone and output-device selection
- Per-application and system-wide audio capture
- Audio Unit discovery, hosting, parameters, and custom plug-in interfaces
- VST® 3 effect discovery, hosting, parameters, and realtime processing
- Built-in EQ, balance, filters, compression, volume, pan, and combining
- Recorder nodes for WAV and CAF output
- Multiple inputs and outputs
- Menu-bar controls and background operation
- Copy, paste, duplicate, undo, deletion, and drag-and-drop block creation

SoundScape is under active development. Save work before testing third-party
Audio Units or VST3 plug-ins, as plug-ins run inside the application process.

## Requirements

- macOS 14 or newer
- Xcode with the macOS SDK and Swift 6 toolchain
- Microphone permission for Input Device nodes
- Screen & System Audio Recording permission for application or system capture

## Build and run

Open `Package.swift` in Xcode and run the `SoundScape` executable target, or:

```sh
swift run SoundScape
```

To create a local macOS app bundle:

```sh
sh Scripts/package-app.sh
open .build/SoundScape.app
```

The packaging script creates an ad-hoc signed development build. macOS can ask
for Screen & System Audio Recording permission again after rebuilding because
the executable's code signature changes.

## Project layout

- `Sources/SoundScape` — application UI, graph model, audio engine, and storage
- `Sources/CSQLite` — SQLite system-library shim
- `Sources/CVST3Host` — VST3 scanner, host bridge, and Steinberg C API
- `Resources` — application icon assets
- `Scripts` — packaging, device auditing, and audio-render diagnostics
- `Support` — application metadata and entitlements

VST is a registered trademark of Steinberg Media Technologies GmbH.
