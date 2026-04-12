import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject var permissionManager: PermissionManager
    @State private var isRecordingHotkey = false
    @State private var recordedModifiers = 0
    @State private var recordedKey = 0

    var body: some View {
        TabView {
            settingsPane(
                title: "Keyboard Shortcut",
                subtitle: "Tune how recording starts, confirm the current shortcut, and keep the trigger easy to reach without clashing with other apps.",
                symbol: "keyboard",
                chips: ["Global shortcut", "Low friction"]
            ) {
                hotkeyTab
            }
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
                }

            settingsPane(
                title: "Model & Performance",
                subtitle: "Choose the transcription model, keep CoreML ready, and make the local pipeline fit your speed and quality target.",
                symbol: "brain",
                chips: ["CoreML aware", "On-device"]
            ) {
                modelTab
            }
                .tabItem {
                    Label("Model", systemImage: "brain")
                }

            settingsPane(
                title: "Behavior & Permissions",
                subtitle: "Control language detection, insertion behavior, and the macOS permissions that keep VoiceType responsive.",
                symbol: "slider.horizontal.3",
                chips: ["Local only", "macOS native"]
            ) {
                generalTab
            }
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
        }
        .frame(width: 620, height: 520)
    }

    // MARK: - Hotkey Tab

    private var hotkeyTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionCard(title: "Current Shortcut", description: "This is the global trigger VoiceType listens for while the app is running.") {
                SettingsValueRow("Shortcut") {
                    Text("\(modifiersToString(settings.hotkeyModifiers))\(keyCodeToString(settings.hotkeyKey))")
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                }

                SettingsValueRow("Mode") {
                    Text(settings.activationMode.displayName)
                }
            }

            SettingsSectionCard(title: "Recorder", description: "Capture a new shortcut directly from the keyboard without leaving the app.") {
                if isRecordingHotkey {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Press your desired hotkey combination now.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HotkeyRecorderView(
                            isRecording: $isRecordingHotkey,
                            recordedModifiers: $recordedModifiers,
                            recordedKey: $recordedKey
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        )

                        HStack {
                            StatusBadge("Listening for keys", tone: .accent)
                            Spacer()
                            Button("Cancel") {
                                isRecordingHotkey = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    HStack {
                        Text("Record a new shortcut whenever you want to change the global trigger.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Record New Hotkey") {
                            recordedModifiers = 0
                            recordedKey = 0
                            isRecordingHotkey = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: - Model Tab

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionCard(title: "Transcription Model", description: "Pick the model that matches your preferred tradeoff between speed, size, and accuracy.") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Model", selection: $settings.selectedModel) {
                        ForEach(TranscriptionModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }

                    SettingsValueRow("Size") {
                        Text(settings.selectedModel.estimatedSize)
                    }

                    SettingsValueRow("Speed") {
                        Text(settings.selectedModel.speedRating)
                    }

                    SettingsValueRow("Quality") {
                        Text(settings.selectedModel.qualityRating)
                    }

                    SettingsValueRow("Best for") {
                        Text(settings.selectedModel.recommendedFor)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSectionCard(title: "Downloads & Acceleration", description: "Keep the base model and CoreML encoder ready for the fastest local inference path available.") {
                SettingsValueRow("Main model") {
                    modelStatusBadge
                }

                SettingsValueRow("CoreML") {
                    coreMLStatusBadge
                }

                if modelManager.isDownloading {
                    ProgressView(value: modelManager.downloadProgress)
                        .progressViewStyle(.linear)
                }

                Text(modelFootnote)
                    .font(.caption)
                    .foregroundStyle(modelFootnoteTone)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()

                    if modelManager.isModelDownloaded(model: settings.selectedModel) && !modelManager.isDownloading {
                        Button("Delete") {
                            try? modelManager.deleteModel(model: settings.selectedModel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !modelManager.isModelDownloaded(model: settings.selectedModel) && !modelManager.isDownloading {
                        Button("Download (with CoreML)") {
                            Task {
                                try? await modelManager.downloadModel(model: settings.selectedModel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionCard(title: "Behavior", description: "These options shape how recording starts, which language is expected, and how text is delivered back into the current app.") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Activation Mode", selection: $settings.activationMode) {
                        ForEach(ActivationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("Language", selection: $settings.preferredLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("Russian").tag("ru")
                        Text("English").tag("en")
                    }

                    Picker("Recording Indicator", selection: $settings.indicatorStyle) {
                        ForEach(IndicatorStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }

                    Picker("Text Injection", selection: $settings.textInjectionMode) {
                        ForEach(TextInjectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle("Press Enter after insertion", isOn: $settings.autoEnterAfterInsert)
                }
            }

            SettingsSectionCard(title: "Permissions", description: "VoiceType needs microphone and accessibility access to capture speech and insert text back into your focused app.") {
                SettingsValueRow("Microphone") {
                    permissionStatus(permissionManager.hasMicrophonePermission)
                }

                SettingsValueRow("Accessibility") {
                    permissionStatus(permissionManager.hasAccessibilityPermission)
                }

                HStack {
                    Button("Open Microphone Settings") {
                        permissionManager.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Accessibility Settings") {
                        permissionManager.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
    }

    private func settingsPane<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        chips: [String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        WindowSurface(title: title, subtitle: subtitle, symbol: symbol, chips: chips) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var modelStatusBadge: some View {
        Group {
            if modelManager.isDownloading {
                StatusBadge("Downloading", tone: .accent)
            } else if modelManager.isModelDownloaded(model: settings.selectedModel) {
                StatusBadge("Downloaded", tone: .positive)
            } else {
                StatusBadge("Not downloaded")
            }
        }
    }

    private var coreMLStatusBadge: some View {
        Group {
            if !settings.selectedModel.hasCoreMLSupport {
                StatusBadge("Not supported")
            } else if modelManager.isDownloading {
                StatusBadge("Downloading", tone: .accent)
            } else if modelManager.isCoreMLModelDownloaded(model: settings.selectedModel) {
                StatusBadge("Ready", tone: .positive)
            } else {
                StatusBadge("Not available", tone: .warning)
            }
        }
    }

    private var modelFootnote: String {
        if settings.selectedModel.hasCoreMLSupport && modelManager.isCoreMLModelDownloaded(model: settings.selectedModel) {
            return "GPU acceleration is enabled via CoreML for this model."
        }

        if let explanation = settings.selectedModel.coreMLExplanation {
            return explanation
        }

        if modelManager.isModelDownloaded(model: settings.selectedModel) {
            return "Download the matching CoreML encoder to unlock faster local inference on Apple Silicon."
        }

        return "Download the selected model bundle before starting transcription."
    }

    private var modelFootnoteTone: Color {
        if settings.selectedModel.hasCoreMLSupport && modelManager.isCoreMLModelDownloaded(model: settings.selectedModel) {
            return .green
        }

        if settings.selectedModel.coreMLExplanation != nil {
            return .secondary
        }

        if modelManager.isModelDownloaded(model: settings.selectedModel) {
            return .orange
        }

        return .secondary
    }

    private func permissionStatus(_ isGranted: Bool) -> some View {
        StatusBadge(isGranted ? "Granted" : "Needs attention", tone: isGranted ? .positive : .warning)
    }
}

// MARK: - Hotkey Recorder View

struct HotkeyRecorderView: View {
    @Binding var isRecording: Bool
    @Binding var recordedModifiers: Int
    @Binding var recordedKey: Int

    var body: some View {
        HotkeyRecorderRepresentable(
            isRecording: $isRecording,
            recordedModifiers: $recordedModifiers,
            recordedKey: $recordedKey
        )
    }
}

struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedModifiers: Int
    @Binding var recordedKey: Int

    final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            
            var carbonModifiers = 0
            if event.modifierFlags.contains(.command) { carbonModifiers |= cmdKey }
            if event.modifierFlags.contains(.option) { carbonModifiers |= optionKey }
            if event.modifierFlags.contains(.shift) { carbonModifiers |= shiftKey }
            if event.modifierFlags.contains(.control) { carbonModifiers |= controlKey }
            
            recordedModifiers = carbonModifiers
            recordedKey = Int(event.keyCode)
            isRecording = false
            AppSettings.shared.hotkeyModifiers = recordedModifiers
            AppSettings.shared.hotkeyKey = recordedKey
            
            print("[HotkeyRecorder] Recorded: modifiers=\(carbonModifiers) (\(modifiersToString(carbonModifiers))), keyCode=\(recordedKey) (\(keyCodeToString(recordedKey)))")
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
}
