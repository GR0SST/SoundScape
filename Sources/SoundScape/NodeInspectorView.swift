import AppKit
import AudioToolbox
import SwiftUI

struct NodeInspectorView: View {
    @Binding var node: AudioNode
    @ObservedObject var audioEngine: AudioEngineController
    @ObservedObject var audioDevices: AudioDeviceCatalog
    @ObservedObject var systemAudioApplications:
        SystemAudioApplicationCatalog
    let graphNodes: [AudioNode]
    let graphConnections: [GraphConnection]
    let focusedField: FocusState<WorkspaceTextFocus?>.Binding
    let close: () -> Void
    let delete: () -> Void

    @State private var parameterSearch = ""
    @State private var pluginViewExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader

            Rectangle()
                .fill(AppTheme.line)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch node.nodeType {
                    case .inputDevice:
                        inputControls
                    case .applicationAudioInput:
                        applicationAudioControls
                    case .systemAudioInput:
                        systemAudioControls
                    case .activeEchoCancellation:
                        activeEchoCancellationControls
                    case .outputDevice:
                        outputControls
                    case .recorder:
                        recorderControls
                    case .combine:
                        combineControls
                    case .builtInEffect(let effect):
                        builtInControls(effect)
                    case .audioUnit(let descriptor):
                        audioUnitControls(descriptor)
                    case .vst3(let descriptor):
                        vst3Controls(descriptor)
                    }

                    if case .recorder = node.nodeType {
                        EmptyView()
                    } else {
                        runtimeCard
                    }
                    removeButton
                }
                .padding(16)
            }
        }
        .background(Color.black.opacity(0.12))
        .task(id: node.id) {
            audioDevices.refresh()
            switch node.nodeType {
            case .applicationAudioInput, .systemAudioInput:
                systemAudioApplications.refresh()
            default:
                break
            }
            await audioEngine.prepareForInspection(node)
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DemoContent.cyan.opacity(0.10))

                Image(systemName: node.displayIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DemoContent.cyan)
            }
            .frame(width: 38, height: 38)

            Text(node.title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.055))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Inspector")
        }
        .padding(.horizontal, 15)
        .frame(height: 62)
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("INPUT DEVICE")
            deviceSelector(isInput: true)

            if effectiveInputChannelCount == 1 {
                HStack {
                    Text("Mono to stereo")
                        .font(.system(size: 11, weight: .semibold))

                    Spacer()

                    Toggle("", isOn: $node.upmixMonoToStereo)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(DemoContent.cyan)
                }
                .cardStyle()
            }
        }
    }

    private var effectiveInputChannelCount: Int? {
        let selected = audioDevices.device(withUID: node.deviceUID)
        let systemDefault = audioDevices.inputDevices.first {
            $0.isDefaultInput
        }
        return node.deviceUID == nil
            ? systemDefault?.inputChannels
            : selected?.inputChannels
    }

    private var applicationAudioControls: some View {
        let selected = systemAudioApplications.application(
            withBundleIdentifier: node.applicationBundleIdentifier
        )

        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("APPLICATION AUDIO")

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Application")
                        .font(.system(size: 11, weight: .semibold))

                    Spacer()

                    Button {
                        systemAudioApplications.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondaryText)
                    .help("Refresh running applications")
                    .accessibilityLabel("Refresh applications")
                }

                Menu {
                    if systemAudioApplications.applications.isEmpty {
                        Text(
                            systemAudioApplications.isLoading
                                ? "Loading…"
                                : "No applications available"
                        )
                    } else {
                        ForEach(systemAudioApplications.applications) {
                            application in
                            Button {
                                node.applicationBundleIdentifier =
                                    application.bundleIdentifier
                                node.subtitle = application.name
                            } label: {
                                if node.applicationBundleIdentifier
                                    == application.bundleIdentifier {
                                    Label(
                                        application.name,
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text(application.name)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "app.badge.waveform")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DemoContent.cyan)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected?.name ?? node.subtitle)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(
                                selected == nil
                                    ? "Choose a running application"
                                    : "Stereo application audio"
                            )
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select application audio source")

                if let error = systemAudioApplications.errorMessage {
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Privacy Settings") {
                        openSystemAudioPrivacySettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .cardStyle()
        }
    }

    private var systemAudioControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("SYSTEM AUDIO")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DemoContent.cyan)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("All system audio")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Stereo · all running applications")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                    }
                }

                Divider().overlay(AppTheme.line)

                HStack {
                    Text("Exclude SoundScape audio")
                        .font(.system(size: 11, weight: .semibold))

                    Spacer()

                    Toggle(
                        "",
                        isOn: $node.excludesCurrentProcessAudio
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DemoContent.cyan)
                }

                if let error = systemAudioApplications.errorMessage {
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Privacy Settings") {
                        openSystemAudioPrivacySettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .cardStyle()
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("OUTPUT DEVICE")
            deviceSelector(isInput: false)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Output level")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(node.gain * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DemoContent.cyan)
                }

                Slider(
                    value: Binding(
                        get: { node.gain },
                        set: { value in
                            node.gain = value
                            audioEngine.setOutputGain(
                                nodeID: node.id,
                                value
                            )
                        }
                    ),
                    in: 0...1
                )
                .tint(DemoContent.cyan)
            }
            .cardStyle()
        }
    }

    private func deviceSelector(isInput: Bool) -> some View {
        let devices = isInput
            ? audioDevices.inputDevices
            : audioDevices.outputDevices
        let selected = audioDevices.device(withUID: node.deviceUID)
        let systemDefault = devices.first {
            isInput ? $0.isDefaultInput : $0.isDefaultOutput
        }
        let channelCount = selected.map {
            isInput ? $0.inputChannels : $0.outputChannels
        }

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(isInput ? "Source" : "Destination")
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                Button {
                    audioDevices.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
                .help("Rescan Core Audio devices")
                .accessibilityLabel("Rescan audio devices")
            }

            Menu {
                Button {
                    selectDevice(nil, isInput: isInput)
                } label: {
                    if node.deviceUID == nil {
                        Label("System Default", systemImage: "checkmark")
                    } else {
                        Text("System Default")
                    }
                }

                Divider()

                ForEach(devices) { device in
                    Button {
                        selectDevice(device, isInput: isInput)
                    } label: {
                        if node.deviceUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isInput ? "mic.fill" : "speaker.wave.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DemoContent.cyan)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            selected?.name
                                ?? (node.deviceUID == nil
                                    ? "System Default"
                                    : node.subtitle)
                        )
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(deviceDetail(
                            selected: selected,
                            systemDefault: systemDefault,
                            channelCount: channelCount
                        ))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isInput ? "Select input device" : "Select output device")

            if let error = audioDevices.errorMessage {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.82))
            }
        }
        .cardStyle()
    }

    private func deviceDetail(
        selected: CoreAudioDevice?,
        systemDefault: CoreAudioDevice?,
        channelCount: Int?
    ) -> String {
        if node.deviceUID != nil, selected == nil {
            return "Disconnected · waiting for this device"
        }
        if let channelCount {
            return "\(channelCount) channel\(channelCount == 1 ? "" : "s")"
        }
        if let systemDefault {
            return "Currently \(systemDefault.name)"
        }
        return "Follows the macOS Sound setting"
    }

    private func selectDevice(_ device: CoreAudioDevice?, isInput: Bool) {
        node.deviceUID = device?.uid
        node.subtitle = device?.name
            ?? (isInput ? "Default macOS input" : "Default macOS output")
    }

    private func openSystemAudioPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var recorderControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("RECORDER")

            HStack {
                Text("Record during Run Flow")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("", isOn: $node.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DemoContent.cyan)
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 11) {
                Text("Destination")
                    .font(.system(size: 11, weight: .semibold))

                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DemoContent.cyan)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recordingDirectoryURL.lastPathComponent)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text(recordingDirectoryURL.deletingLastPathComponent().path)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose") {
                        chooseRecordingDirectory()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                    .disabled(audioEngine.isFlowEnabled)
                }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Format")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { node.recordingFormat },
                            set: { format in
                                node.recordingFormat = format
                                updateRecorderSubtitle()
                            }
                        )
                    ) {
                        ForEach(RecorderFileFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)
                    .disabled(audioEngine.isFlowEnabled)
                }

                Divider().overlay(AppTheme.line)

                VStack(alignment: .leading, spacing: 7) {
                    Text("File name")
                        .font(.system(size: 11, weight: .semibold))

                    TextField(
                        "SoundScape",
                        text: Binding(
                            get: { node.recordingFilePrefix },
                            set: { node.recordingFilePrefix = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused(focusedField, equals: .recorderFileName)
                    .onSubmit {
                        focusedField.wrappedValue = nil
                        dismissTextInputFocus()
                    }
                    .onExitCommand {
                        focusedField.wrappedValue = nil
                        dismissTextInputFocus()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.045))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 6,
                            style: .continuous
                        )
                    )
                    .disabled(audioEngine.isFlowEnabled)
                }
            }
            .cardStyle()

            recorderRuntimeCard
        }
    }

    private var recorderRuntimeCard: some View {
        let error = audioEngine.recorderErrorsByNodeID[node.id]
        let isRecording = audioEngine.isRunning
            && audioEngine.activeRecorderNodeIDs.contains(node.id)
        let recordingURL = audioEngine.recordingURLsByNodeID[node.id]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("RECORDING")
                Spacer()
                Circle()
                    .fill(
                        error != nil
                            ? Color.red.opacity(0.82)
                            : (isRecording
                                ? DemoContent.mint
                                : AppTheme.tertiaryText)
                    )
                    .frame(width: 7, height: 7)
            }

            Text(
                recorderStatusText(
                    error: error,
                    isRecording: isRecording,
                    recordingURL: recordingURL
                )
            )
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(
                error == nil
                    ? AppTheme.secondaryText
                    : Color.red.opacity(0.82)
            )
            .fixedSize(horizontal: false, vertical: true)

            if let recordingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [recordingURL]
                    )
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Color.white.opacity(0.045))
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 6,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private var recordingDirectoryURL: URL {
        guard let path = node.recordingDirectoryPath, !path.isEmpty else {
            return RecorderDestination.defaultDirectoryURL
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func chooseRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recording Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        node.recordingDirectoryPath = url.path
        updateRecorderSubtitle()
    }

    private func updateRecorderSubtitle() {
        node.subtitle = "\(node.recordingFormat.label) · "
            + recordingDirectoryURL.lastPathComponent
    }

    private func recorderStatusText(
        error: String?,
        isRecording: Bool,
        recordingURL: URL?
    ) -> String {
        if let error {
            return error
        }
        if !node.isEnabled {
            return "Disabled"
        }
        if isRecording {
            let duration = audioEngine.recordedDurationByNodeID[node.id] ?? 0
            return "Recording \(formattedDuration(duration))"
        }
        if let recordingURL {
            return "Saved \(recordingURL.lastPathComponent)"
        }
        return audioEngine.isFlowEnabled ? "Preparing…" : "Ready"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var combineControls: some View {
        let inputs = graphConnections.filter {
            $0.to == node.id && !$0.isReference
        }

        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("COMBINE")

            HStack {
                Text("Output")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { node.combineOutputMode },
                        set: {
                            node.combineOutputMode = $0
                        }
                    )
                ) {
                    ForEach(ChannelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
            .cardStyle()

            sectionTitle("INPUTS")

            if inputs.isEmpty {
                Text("Connect a signal to the free input.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .cardStyle()
            }

            ForEach(Array(inputs.enumerated()), id: \.element.id) { index, connection in
                combineInputCard(
                    connection: connection,
                    index: index
                )
            }
        }
    }

    private func combineInputCard(
        connection: GraphConnection,
        index: Int
    ) -> some View {
        let sourceName = graphNodes.first {
            $0.id == connection.from
        }?.title ?? "Input \(index + 1)"
        let key = connection.id.uuidString

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sourceName)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { combineSettings(key).channelMode },
                        set: { newMode in
                            updateCombineSettings(key) {
                                $0.channelMode = newMode
                            }
                        }
                    )
                ) {
                    ForEach(ChannelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 88)
            }

            compactSlider(
                title: "Level",
                value: Binding(
                    get: { combineSettings(key).gainDB },
                    set: { value in
                        updateCombineSettings(key) {
                            $0.gainDB = value
                        }
                    }
                ),
                range: -60...0,
                valueText: "\(format(combineSettings(key).gainDB, digits: 1)) dB"
            )

            compactSlider(
                title: "Pan",
                value: Binding(
                    get: { combineSettings(key).pan },
                    set: { value in
                        updateCombineSettings(key) {
                            $0.pan = value
                        }
                    }
                ),
                range: -1...1,
                valueText: panLabel(combineSettings(key).pan)
            )
        }
        .cardStyle()
    }

    private func combineSettings(_ key: String) -> CombineInputSettings {
        node.combineInputSettings[key] ?? CombineInputSettings()
    }

    private var activeEchoCancellationControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("ACTIVE ECHO CANCELLATION")

            VStack(alignment: .leading, spacing: 11) {
                aecInputRow(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    isReference: false
                )
                Divider().overlay(AppTheme.line)
                aecInputRow(
                    title: "Echo reference",
                    systemImage: "desktopcomputer",
                    isReference: true
                )
                Divider().overlay(AppTheme.line)
                hostBypassControl
            }
            .cardStyle()

            aecAlignmentCard

            compactSlider(
                title: aecAutoAlignmentEnabled
                    ? "Manual fine adjustment"
                    : "Microphone alignment",
                value: aecParameterBinding(
                    "aec.microphoneDelayMS",
                    defaultValue: 0
                ),
                range: 0...500,
                valueText: format(aecParameter(
                    "aec.microphoneDelayMS",
                    defaultValue: 0
                ), digits: 0) + " ms"
            )
            .cardStyle()
        }
    }

    private var aecAlignmentCard: some View {
        let status = audioEngine.aecAlignmentByNodeID[node.id]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto alignment")
                        .font(.system(size: 11, weight: .semibold))
                    Text(aecAlignmentSummary(status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Toggle("", isOn: aecAutoAlignmentBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DemoContent.cyan)
            }

            if aecAutoAlignmentEnabled,
               audioEngine.isRunning,
               status?.hasReliableEstimate != true {
                ProgressView(value: status?.progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(DemoContent.cyan)
            }

            if aecAutoAlignmentEnabled {
                Button {
                    audioEngine.recalibrateActiveEchoCancellation(
                        nodeID: node.id
                    )
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "scope")
                        Text("Calibrate Now")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.055))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 6,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!audioEngine.isRunning)
                .opacity(audioEngine.isRunning ? 1 : 0.45)
            }
        }
        .cardStyle()
    }

    private var aecAutoAlignmentEnabled: Bool {
        aecParameter("aec.autoAlignment", defaultValue: 1) >= 0.5
    }

    private var aecAutoAlignmentBinding: Binding<Bool> {
        Binding(
            get: { aecAutoAlignmentEnabled },
            set: { enabled in
                node.parameterValues["aec.autoAlignment"] =
                    enabled ? 1 : 0
                audioEngine.updateActiveEchoCancellationNode(node)
            }
        )
    }

    private func aecAlignmentSummary(
        _ status: AECAlignmentStatus?
    ) -> String {
        guard aecAutoAlignmentEnabled else {
            return "Manual"
        }
        guard audioEngine.isRunning else {
            return "Starts with flow"
        }
        guard let status, status.hasReliableEstimate else {
            if status?.windowsAnalyzed ?? 0 >= 2 {
                return "Echo not detected · use speakers"
            }
            return "Play system audio through speakers"
        }

        if status.microphoneDelayMS >= 0.5 {
            return "Mic +\(format(status.microphoneDelayMS, digits: 0)) ms"
        }
        if status.referenceDelayMS >= 0.5 {
            return "Reference +\(format(status.referenceDelayMS, digits: 0)) ms"
        }
        return "Aligned"
    }

    private func aecInputRow(
        title: String,
        systemImage: String,
        isReference: Bool
    ) -> some View {
        let connection = graphConnections.first {
            $0.to == node.id && $0.isReference == isReference
        }
        let sourceName = connection.flatMap { connection in
            graphNodes.first { $0.id == connection.from }?.title
        } ?? "Not connected"

        return HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 15)
                .foregroundStyle(
                    connection == nil
                        ? AppTheme.tertiaryText
                        : DemoContent.cyan
                )
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(sourceName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private func aecParameter(
        _ key: String,
        defaultValue: Double
    ) -> Double {
        node.parameterValues[key] ?? defaultValue
    }

    private func aecParameterBinding(
        _ key: String,
        defaultValue: Double
    ) -> Binding<Double> {
        Binding(
            get: { aecParameter(key, defaultValue: defaultValue) },
            set: { value in
                node.parameterValues[key] = value
                audioEngine.updateActiveEchoCancellationNode(node)
            }
        )
    }

    private func updateCombineSettings(
        _ key: String,
        _ update: (inout CombineInputSettings) -> Void
    ) {
        var settings = combineSettings(key)
        update(&settings)
        node.combineInputSettings[key] = settings
        audioEngine.updateCombineInput(
            connectionID: key,
            settings: settings
        )
    }

    private func builtInControls(
        _ effect: BuiltInEffectType
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("BUILT-IN")
                Spacer()
                Toggle("Enabled", isOn: $node.isEnabled)
                    .toggleStyle(.switch)
                    .tint(DemoContent.cyan)
                    .font(.system(size: 10, weight: .semibold))
            }

            switch effect {
            case .tenBandEQ:
                ForEach(
                    BuiltInEffectType.graphicEQFrequencies,
                    id: \.self
                ) { frequency in
                    builtInSlider(
                        title: frequencyLabel(frequency),
                        key: "eq.\(Int(frequency))",
                        range: -24...24,
                        unit: "dB"
                    )
                }

            case .balance:
                builtInSlider(
                    title: "Balance",
                    key: "balance",
                    range: -1...1,
                    display: panLabel
                )

            case .lowPassFilter:
                builtInSlider(
                    title: "Cutoff",
                    key: "cutoff",
                    range: 20...20_000,
                    display: frequencyLabel
                )
                builtInSlider(
                    title: "Resonance",
                    key: "resonance",
                    range: 0.1...12,
                    digits: 2
                )

            case .magicBoost:
                builtInSlider(
                    title: "Boost",
                    key: "amount",
                    range: 0...1,
                    display: { "\(Int($0 * 100))%" }
                )

            case .pan:
                builtInSlider(
                    title: "Pan",
                    key: "pan",
                    range: -1...1,
                    display: panLabel
                )

            case .simpleCompressor:
                builtInSlider(
                    title: "Threshold",
                    key: "threshold",
                    range: -60...0,
                    unit: "dB"
                )
                builtInSlider(
                    title: "Ratio",
                    key: "ratio",
                    range: 1...20,
                    display: { "\(format($0, digits: 1)):1" }
                )
                builtInSlider(
                    title: "Attack",
                    key: "attack",
                    range: 0.001...0.2,
                    display: { "\(Int($0 * 1_000)) ms" }
                )
                builtInSlider(
                    title: "Release",
                    key: "release",
                    range: 0.02...1,
                    display: { "\(Int($0 * 1_000)) ms" }
                )
                builtInSlider(
                    title: "Makeup gain",
                    key: "makeupGain",
                    range: 0...24,
                    unit: "dB"
                )

            case .volume:
                builtInSlider(
                    title: "Volume",
                    key: "gainDB",
                    range: -60...12,
                    unit: "dB"
                )

            case .parametricEQ:
                parametricEQControls
            }
        }
    }

    private var parametricEQControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(node.parametricEQBands.indices), id: \.self) { index in
                parametricBandCard(index)
            }

            Button {
                node.parametricEQBands.append(ParametricEQBand())
            } label: {
                Label("Add Band", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func parametricBandCard(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(
                    "Band \(index + 1)",
                    isOn: Binding(
                        get: { node.parametricEQBands[index].isEnabled },
                        set: {
                            node.parametricEQBands[index].isEnabled = $0
                            audioEngine.updateBuiltInNode(node)
                        }
                    )
                )
                .toggleStyle(.switch)
                .tint(DemoContent.cyan)
                .font(.system(size: 11, weight: .bold))

                Spacer()

                Button(role: .destructive) {
                    node.parametricEQBands.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            Picker(
                "Type",
                selection: Binding(
                    get: { node.parametricEQBands[index].type },
                    set: {
                        node.parametricEQBands[index].type = $0
                        audioEngine.updateBuiltInNode(node)
                    }
                )
            ) {
                ForEach(ParametricFilterType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))

            compactSlider(
                title: "Frequency",
                value: Binding(
                    get: { node.parametricEQBands[index].frequency },
                    set: {
                        node.parametricEQBands[index].frequency = $0
                        audioEngine.updateBuiltInNode(node)
                    }
                ),
                range: 20...20_000,
                valueText: frequencyLabel(
                    node.parametricEQBands[index].frequency
                )
            )
            compactSlider(
                title: "Q",
                value: Binding(
                    get: { node.parametricEQBands[index].q },
                    set: {
                        node.parametricEQBands[index].q = $0
                        audioEngine.updateBuiltInNode(node)
                    }
                ),
                range: 0.1...12,
                valueText: format(
                    node.parametricEQBands[index].q,
                    digits: 2
                )
            )
            compactSlider(
                title: "Gain",
                value: Binding(
                    get: { node.parametricEQBands[index].gainDB },
                    set: {
                        node.parametricEQBands[index].gainDB = $0
                        audioEngine.updateBuiltInNode(node)
                    }
                ),
                range: -24...24,
                valueText: "\(format(node.parametricEQBands[index].gainDB, digits: 1)) dB"
            )
        }
        .cardStyle()
    }

    private func builtInSlider(
        title: String,
        key: String,
        range: ClosedRange<Double>,
        unit: String = "",
        digits: Int = 1,
        display: ((Double) -> String)? = nil
    ) -> some View {
        let value = node.parameterValues[key]
            ?? builtInDefaultValue(key)
        return compactSlider(
            title: title,
            value: Binding(
                get: {
                    node.parameterValues[key]
                        ?? builtInDefaultValue(key)
                },
                set: { newValue in
                    node.parameterValues[key] = newValue
                    audioEngine.updateBuiltInNode(node)
                }
            ),
            range: range,
            valueText: display?(value)
                ?? "\(format(value, digits: digits))\(unit.isEmpty ? "" : " \(unit)")"
        )
        .cardStyle()
    }

    private func builtInDefaultValue(_ key: String) -> Double {
        guard case .builtInEffect(let effect) = node.nodeType else {
            return 0
        }
        return effect.defaultParameters[key] ?? 0
    }

    private func compactSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DemoContent.cyan)
            }
            Slider(value: value, in: range)
                .tint(DemoContent.cyan)
        }
    }

    private func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func frequencyLabel(_ value: Double) -> String {
        if value >= 1_000 {
            return "\(format(value / 1_000, digits: value >= 10_000 ? 0 : 1)) kHz"
        }
        return "\(Int(value.rounded())) Hz"
    }

    private func panLabel(_ value: Double) -> String {
        if abs(value) < 0.01 { return "Center" }
        return value < 0
            ? "L \(Int(abs(value) * 100))"
            : "R \(Int(value * 100))"
    }

    private func audioUnitControls(
        _ descriptor: AudioUnitDescriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("AUDIO UNIT")

            VStack(alignment: .leading, spacing: 11) {
                detailRow("Manufacturer", descriptor.manufacturerName)
                detailRow("Type", descriptor.typeName)
                detailRow("Component", descriptor.id)

                Divider().overlay(AppTheme.line)
                hostBypassControl
            }
            .cardStyle()

            if descriptor.hasCustomView {
                embeddedPluginSection
            }

            parameterControls
        }
    }

    private func vst3Controls(
        _ descriptor: VST3Descriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("VST3")

            VStack(alignment: .leading, spacing: 11) {
                detailRow(
                    "Manufacturer",
                    descriptor.vendor.isEmpty ? "Unknown" : descriptor.vendor
                )
                if !descriptor.version.isEmpty {
                    detailRow("Version", descriptor.version)
                }
                detailRow("Component", descriptor.classID)

                Divider().overlay(AppTheme.line)
                hostBypassControl
            }
            .cardStyle()

            embeddedPluginSection
            parameterControls
        }
    }

    private var hostBypassControl: some View {
        HStack {
            Text("Node enabled")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { node.isEnabled },
                    set: { enabled in
                        node.isEnabled = enabled
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DemoContent.cyan)
        }
    }

    private var embeddedPluginSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    pluginViewExpanded.toggle()
                }
            } label: {
                HStack {
                    sectionTitle("PLUG-IN INTERFACE")
                    Spacer()
                    Image(
                        systemName: pluginViewExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(13)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(
                pluginViewExpanded
                    ? "Collapse plug-in interface"
                    : "Expand plug-in interface"
            )

            if pluginViewExpanded {
                Divider().overlay(AppTheme.line)

                if let customView =
                    audioEngine.customViewsByNodeID[node.id] {
                    EmbeddedAudioUnitView(
                        viewController: customView.viewController,
                        intrinsicSize: customView.intrinsicSize
                    )
                        .frame(height: embeddedViewHeight(customView))
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else if audioEngine.loadingCustomViewNodeIDs.contains(node.id) {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading plug-in interface…")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    Text(
                        audioEngine.customViewErrorsByNodeID[node.id]
                            ?? "The plug-in interface is unavailable."
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .padding(.horizontal, 13)
                }
            }
        }
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        }
    }

    private func embeddedViewHeight(_ customView: HostedAUCustomView) -> CGFloat {
        let size = customView.intrinsicSize
        guard size.width > 1, size.height > 1 else { return 240 }

        // Inspector width (310) minus its horizontal padding (32). Keeping
        // the plug-in's aspect ratio gives fixed-size AUv2 interfaces enough
        // vertical room instead of asking AppKit to crop their view.
        let fittedHeight = 278 * size.height / size.width
        return min(max(fittedHeight, 160), 720)
    }

    @ViewBuilder
    private var parameterControls: some View {
        let parameters = filteredParameters

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("PARAMETERS")
                Spacer()
                Text("\(audioEngine.parametersByNodeID[node.id]?.count ?? 0)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            if let allParameters = audioEngine.parametersByNodeID[node.id],
               !allParameters.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.tertiaryText)
                    TextField("Filter parameters", text: $parameterSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .focused(focusedField, equals: .parameterSearch)
                        .onSubmit {
                            focusedField.wrappedValue = nil
                            dismissTextInputFocus()
                        }
                        .onExitCommand {
                            focusedField.wrappedValue = nil
                            dismissTextInputFocus()
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                ForEach(parameters) { parameter in
                    parameterControl(parameter)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(
                        audioEngine.loadingInspectorNodeIDs.contains(node.id)
                            ? "Loading plug-in parameters…"
                            : (audioEngine.hasLoadedUnit(for: node.id)
                                ? "This plug-in exposes no generic parameters. Use its plug-in window if available."
                                : "The plug-in could not be loaded for inspection.")
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    if let error = audioEngine.inspectorErrorsByNodeID[node.id] {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red.opacity(0.78))
                    }
                }
                .cardStyle()
            }
        }
    }

    private var filteredParameters: [HostedAUParameter] {
        let parameters = audioEngine.parametersByNodeID[node.id] ?? []
        guard !parameterSearch.isEmpty else { return parameters }
        return parameters.filter {
            $0.name.localizedCaseInsensitiveContains(parameterSearch)
        }
    }

    @ViewBuilder
    private func parameterControl(_ parameter: HostedAUParameter) -> some View {
        if !parameter.isWritable || parameter.maximum <= parameter.minimum {
            parameterReadout(parameter)
        } else if parameter.unit == .boolean {
            parameterToggle(parameter)
        } else if !parameter.valueStrings.isEmpty {
            parameterMenu(parameter)
        } else {
            parameterSlider(parameter)
        }
    }

    private func parameterReadout(_ parameter: HostedAUParameter) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(parameterDisplayName(parameter))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Text(parameterValueText(parameter))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .cardStyle()
    }

    private func parameterToggle(_ parameter: HostedAUParameter) -> some View {
        HStack {
            Text(parameterDisplayName(parameter))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { parameterValue(parameter) >= 0.5 },
                    set: { setParameter(parameter, value: $0 ? 1 : 0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DemoContent.cyan)
        }
        .cardStyle()
    }

    private func parameterMenu(_ parameter: HostedAUParameter) -> some View {
        HStack(spacing: 12) {
            Text(parameterDisplayName(parameter))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Picker(
                "",
                selection: Binding(
                    get: { Int(parameterValue(parameter).rounded()) },
                    set: { setParameter(parameter, value: Double($0)) }
                )
            ) {
                ForEach(parameter.valueStrings.indices, id: \.self) { index in
                    let value = Int(parameter.minimum) + index
                    Text(parameter.valueStrings[index]).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 145)
        }
        .cardStyle()
    }

    private func parameterSlider(_ parameter: HostedAUParameter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(parameterDisplayName(parameter))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                Text(parameterValueText(parameter))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DemoContent.cyan)
            }

            Slider(
                value: Binding(
                    get: { parameterValue(parameter) },
                    set: { setParameter(parameter, value: $0) }
                ),
                in: Double(parameter.minimum)...Double(parameter.maximum)
            )
            .tint(DemoContent.cyan)
        }
        .cardStyle()
    }

    private func parameterValue(_ parameter: HostedAUParameter) -> Double {
        node.parameterValues[String(parameter.address)]
            ?? Double(parameter.value)
    }

    private func setParameter(_ parameter: HostedAUParameter, value: Double) {
        node.parameterValues[String(parameter.address)] = value
        audioEngine.setParameter(
            nodeID: node.id,
            address: parameter.address,
            value: AUValue(value)
        )
    }

    private func parameterValueText(_ parameter: HostedAUParameter) -> String {
        let value = parameterValue(parameter)
        if isDeeGateLevel(parameter) {
            return "\(Int((-60 + value * 60).rounded())) dB"
        }
        if !parameter.valueStrings.isEmpty {
            let index = Int(value.rounded() - Double(parameter.minimum))
            if parameter.valueStrings.indices.contains(index) {
                return parameter.valueStrings[index]
            }
        }
        if parameter.unitName.isEmpty {
            return String(format: "%.2f", value)
        }
        return "\(String(format: "%.2f", value)) \(parameter.unitName)"
    }

    private func parameterDisplayName(_ parameter: HostedAUParameter) -> String {
        isDeeGateLevel(parameter) ? "Threshold" : parameter.name
    }

    private func isDeeGateLevel(_ parameter: HostedAUParameter) -> Bool {
        guard parameter.name.localizedCaseInsensitiveCompare("Level") == .orderedSame,
              case .audioUnit(let descriptor) = node.nodeType else {
            return false
        }
        return descriptor.name.localizedCaseInsensitiveCompare("DeeGate")
            == .orderedSame
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("RUNTIME")
                Spacer()
                Circle()
                    .fill(audioEngine.isRunning ? DemoContent.mint : AppTheme.tertiaryText)
                    .frame(width: 7, height: 7)
            }

            Text(audioEngine.errorMessage ?? audioEngine.statusMessage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(
                    audioEngine.errorMessage == nil
                        ? AppTheme.secondaryText
                        : Color.red.opacity(0.82)
                )
                .fixedSize(horizontal: false, vertical: true)

        }
        .cardStyle()
    }

    private var removeButton: some View {
        Button(role: .destructive, action: delete) {
            Label("Remove from Flow", systemImage: "trash")
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red.opacity(0.82))
        .accessibilityLabel("Remove \(node.title)")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .black))
            .tracking(0.9)
            .foregroundStyle(AppTheme.tertiaryText)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func infoCard(title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DemoContent.cyan)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }
}

private struct EmbeddedAudioUnitView: NSViewControllerRepresentable {
    let viewController: NSViewController
    let intrinsicSize: CGSize

    func makeNSViewController(context: Context) -> NSViewController {
        EmbeddedAudioUnitHostController(
            contentViewController: viewController,
            intrinsicSize: intrinsicSize
        )
    }

    func updateNSViewController(
        _ nsViewController: NSViewController,
        context: Context
    ) {
        guard let host = nsViewController as? EmbeddedAudioUnitHostController
        else { return }
        host.update(
            contentViewController: viewController,
            intrinsicSize: intrinsicSize
        )
    }
}

private final class EmbeddedAudioUnitHostController: NSViewController {
    private var contentViewController: NSViewController
    private var intrinsicSize: CGSize

    init(
        contentViewController: NSViewController,
        intrinsicSize: CGSize
    ) {
        self.contentViewController = contentViewController
        self.intrinsicSize = intrinsicSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = AspectFitAudioUnitContainerView()
        attachContentView()
    }

    func update(
        contentViewController: NSViewController,
        intrinsicSize: CGSize
    ) {
        if self.contentViewController !== contentViewController {
            detachContentView()
            self.contentViewController = contentViewController
            attachContentView()
        }
        self.intrinsicSize = intrinsicSize
        (view as? AspectFitAudioUnitContainerView)?.sourceSize =
            intrinsicSize
        view.needsLayout = true
    }

    private func attachContentView() {
        guard let container = view as? AspectFitAudioUnitContainerView else {
            return
        }
        addChild(contentViewController)
        container.contentView = contentViewController.view
        container.sourceSize = intrinsicSize
    }

    private func detachContentView() {
        contentViewController.view.removeFromSuperview()
        contentViewController.removeFromParent()
    }

    deinit {
        detachContentView()
    }
}

private final class AspectFitAudioUnitContainerView: NSView {
    weak var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let contentView {
                contentView.translatesAutoresizingMaskIntoConstraints = true
                addSubview(contentView)
            }
            needsLayout = true
        }
    }

    var sourceSize = CGSize(width: 320, height: 240) {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let contentView,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return
        }

        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        contentView.frame = CGRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        contentView.bounds = CGRect(
            origin: .zero,
            size: sourceSize
        )
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(13)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            }
    }
}
