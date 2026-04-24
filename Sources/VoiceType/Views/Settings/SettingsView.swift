import SwiftUI
import AppKit

// MARK: - Row Primitives

/// Uppercase meta-label group header.
/// DESIGN.md line 180: 11/14 Medium, letter-spacing 0.04em, textMuted. 8px gap below.
private struct GroupHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Typography.metaLabel)
            .tracking(Typography.metaLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textMuted)
            .padding(.bottom, Spacing.sm)  // 8px per DESIGN.md line 180
    }
}

/// Native prefs row: left label + optional subtitle, right control.
/// Min-height 40, horizontal padding lg, vertical padding md. DESIGN.md line 181.
private struct PrefsRow<Control: View>: View {
    let label: String
    let subtitle: String?
    let control: Control

    init(_ label: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)  // non-uppercase regular caption per FIX 8
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: Spacing.md)
            control
        }
        .padding(.horizontal, Spacing.prefsRowHorizontal)
        .padding(.vertical, Spacing.prefsRowVertical)
        .frame(minHeight: Spacing.prefsRowMinHeight)
    }
}

/// 1px divider. DESIGN.md line 182 / Palette.divider.
private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
    }
}

/// Vertical gap between row-groups. DESIGN.md § Spacing line 155.
private struct SectionGap: View {
    var body: some View {
        Color.clear.frame(height: Spacing.sectionGap)
    }
}

/// Colored dot for permission state rows. DESIGN.md lines 256-258.
private struct PermissionDot: View {
    enum DotState { case granted, denied, notRequested }
    let state: DotState

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        switch state {
        case .granted:      return Palette.success
        case .denied:       return Palette.error
        case .notRequested: return Palette.textMuted
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject var permissionManager: PermissionManager
    @State private var isRecordingHotkey = false
    @State private var recordedModifiers = 0
    @State private var recordedKey = 0

    /// Sidebar tab enum — order is tab order per DESIGN.md line 176.
    private enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general, models, shortcuts, advanced
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .general:   return "General"
            case .models:    return "Models"
            case .shortcuts: return "Shortcuts"
            case .advanced:  return "Advanced"
            }
        }
        var symbolName: String {
            switch self {
            case .general:   return "gearshape"
            case .models:    return "brain"
            case .shortcuts: return "keyboard"
            case .advanced:  return "slider.horizontal.3"
            }
        }
    }

    /// Default tab per DESIGN.md line 176.
    @State private var selectedTab: Tab = .general

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.displayName, systemImage: tab.symbolName)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(160)  // off-scale: sidebar column width per DESIGN.md line 177
        } detail: {
            tabContent
        }
        .frame(width: WindowSize.settings.width, height: WindowSize.settings.height)
    }

    // MARK: - Tab Router

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:   generalTab
        case .models:    modelsTab
        case .shortcuts: shortcutsTab
        case .advanced:  advancedTab
        }
    }

    // MARK: - Tab 1: General

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: LANGUAGE group
                GroupHeader(title: "Language")
                RowDivider()
                PrefsRow("Language") {
                    Picker("Language", selection: $settings.language) {
                        ForEach(Language.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Preferred language")
                    .accessibilityValue(settings.language.displayName)
                }
                RowDivider()

                SectionGap()

                // MARK: INSERTION group
                GroupHeader(title: "Insertion")
                RowDivider()
                PrefsRow("Mode") {
                    Picker("Activation Mode", selection: $settings.activationMode) {
                        ForEach(ActivationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
                RowDivider()
                PrefsRow("Press Enter after insertion") {
                    Toggle("", isOn: $settings.autoEnterAfterInsert)
                        .labelsHidden()
                }
                RowDivider()
                PrefsRow("Trim whitespace",
                         subtitle: "Remove leading/trailing whitespace before insertion") {
                    Toggle("", isOn: $settings.trimWhitespaceAfterInsert)
                        .labelsHidden()
                }
                RowDivider()
                PrefsRow("Paste method") {
                    Picker("Paste method", selection: $settings.textInjectionMode) {
                        ForEach(TextInjectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                RowDivider()

                SectionGap()

                // MARK: MICROPHONE group — inline permission hint per DESIGN.md line 185 / 256-258
                GroupHeader(title: "Microphone")
                RowDivider()
                microphonePermissionRow
                RowDivider()
            }
            .padding(Spacing.windowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Tab 2: Models

    private var modelsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: MODEL group
                GroupHeader(title: "Model")
                RowDivider()
                ForEach(TranscriptionModel.allCases, id: \.self) { model in
                    ModelRow(
                        model: model,
                        isSelected: settings.selectedModel == model,
                        onSelect: { settings.selectedModel = model }
                    )
                    RowDivider()
                }

                SectionGap()

                // MARK: CORE ML group
                GroupHeader(title: "Core ML")
                RowDivider()
                PrefsRow("Main model") {
                    modelStatusBadge
                }
                RowDivider()
                PrefsRow("CoreML encoder") {
                    coreMLStatusBadge
                }

                // Inline progress / action under CoreML row per brief
                if modelManager.isDownloading {
                    ProgressView(value: modelManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, Spacing.prefsRowHorizontal)
                        .padding(.bottom, Spacing.sm)
                } else if modelManager.isModelDownloaded(model: settings.selectedModel) {
                    HStack {
                        Spacer()
                        Button("Delete") {
                            try? modelManager.deleteModel(model: settings.selectedModel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.bottom, Spacing.sm)
                } else {
                    HStack {
                        Spacer()
                        Button("Download (with CoreML)") {
                            Task {
                                try? await modelManager.downloadModel(model: settings.selectedModel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.bottom, Spacing.sm)
                }

                RowDivider()

                // CoreML footnote caption — below group, styled per tone
                Text(modelFootnote)
                    .font(Typography.metaLabel)
                    .foregroundStyle(modelFootnoteToneColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.top, Spacing.sm)
            }
            .padding(Spacing.windowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Tab 3: Shortcuts

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: RECORDING group
                GroupHeader(title: "Recording")
                RowDivider()

                // Hotkey chip row
                PrefsRow("Shortcut") {
                    HStack(spacing: Spacing.sm) {
                        // Hotkey chip — Geist Mono, surfaceInset Capsule background
                        Text("\(modifiersToString(settings.hotkeyModifiers))\(keyCodeToString(settings.hotkeyKey))")
                            .font(Typography.mono)
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(Palette.surfaceInset, in: Capsule(style: .continuous))
                        Button("Record New Shortcut") {
                            recordedModifiers = 0
                            recordedKey = 0
                            isRecordingHotkey = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                RowDivider()
                PrefsRow("Mode") {
                    Text(settings.activationMode.displayName)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                RowDivider()

                // Record New Shortcut / HotkeyRecorderView flow
                if isRecordingHotkey {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Press your desired hotkey combination now.")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)

                        HotkeyRecorderView(
                            isRecording: $isRecordingHotkey,
                            recordedModifiers: $recordedModifiers,
                            recordedKey: $recordedKey
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Palette.strokeStrong, lineWidth: 1)
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
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.vertical, Spacing.prefsRowVertical)
                }

                SectionGap()

                // MARK: ACCESSIBILITY group — inline permission per DESIGN.md line 193 / 256-258
                GroupHeader(title: "Accessibility")
                RowDivider()
                accessibilityPermissionRow
                RowDivider()
            }
            .padding(Spacing.windowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Tab 4: Advanced

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: CUSTOM VOCABULARY group — moved from General per DESIGN.md D3
                GroupHeader(title: "Custom Vocabulary")
                RowDivider()
                PrefsRow("Custom vocabulary",
                         subtitle: "Comma- or newline-separated: tool names, APIs, jargon, names. Applied on the next recording.") {
                    EmptyView()
                }
                // Full-width TextEditor below the row — vocab needs vertical space
                TextEditor(text: $settings.customVocabulary)
                    .font(Typography.mono)
                    .frame(minHeight: 80, maxHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Palette.strokeSubtle, lineWidth: 1)
                    )
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.bottom, Spacing.prefsRowVertical)
                RowDivider()

                SectionGap()

                // TODO Tier A Step 9 / W2: wire HistoryStore here (DESIGN.md line 191).
                // MARK: TRANSCRIPTION HISTORY group
                GroupHeader(title: "Transcription History")
                RowDivider()
                PrefsRow("Open history", subtitle: "Coming in a later update") {
                    Button("Open history") {}
                        .disabled(true)
                }
                RowDivider()
                PrefsRow("Entries") {
                    Text("0")
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textSecondary)
                }
                RowDivider()

                SectionGap()

                // TODO Step 7: wire ErrorLogger here (DESIGN.md line 191).
                // MARK: DIAGNOSTICS group
                GroupHeader(title: "Diagnostics")
                RowDivider()
                PrefsRow("Error log", subtitle: "~/Library/Logs/VoiceType/errors.log") {
                    Button("Open Log") {}
                        .disabled(true)
                }
                RowDivider()
                PrefsRow("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textSecondary)
                }
                RowDivider()
            }
            .padding(Spacing.windowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Permission Rows

    /// Microphone permission row — inline in General tab. DESIGN.md lines 254-258.
    private var microphonePermissionRow: some View {
        PrefsRow("Microphone access",
                 subtitle: permissionManager.hasMicrophonePermission ? nil : "Required to capture your voice") {
            HStack(spacing: Spacing.sm) {
                PermissionDot(state: microphoneDotState)
                if permissionManager.hasMicrophonePermission {
                    Text("Granted")
                        .font(Typography.body)
                        .foregroundStyle(Palette.success)
                    Button("Open Privacy") {
                        openMicrophonePrivacySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant Access") {
                        permissionManager.requestMicrophonePermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            permissionManager.hasMicrophonePermission
                ? "Microphone access: Granted"
                : "Microphone access: Not granted. Tap to request."
        )
    }

    /// Accessibility permission row — inline in Shortcuts tab. DESIGN.md lines 254-258 / line 193.
    private var accessibilityPermissionRow: some View {
        PrefsRow("Accessibility access",
                 subtitle: "Required for synthesized ⌘V") {
            HStack(spacing: Spacing.sm) {
                PermissionDot(state: accessibilityDotState)
                if permissionManager.hasAccessibilityPermission {
                    Text("Granted")
                        .font(Typography.body)
                        .foregroundStyle(Palette.success)
                    Button("Open Privacy") {
                        permissionManager.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant Access") {
                        permissionManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Refresh") {
                        permissionManager.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    // macOS caches Accessibility state per-process. Full restart needed
                    // when user granted in System Settings but app was running before.
                    Button("Restart App") {
                        permissionManager.restartAppForAccessibility()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            permissionManager.hasAccessibilityPermission
                ? "Accessibility access: Granted"
                : "Accessibility access: Not granted. Required for synthesized ⌘V. Tap to grant."
        )
    }

    // MARK: - Permission Dot State Helpers

    private var microphoneDotState: PermissionDot.DotState {
        permissionManager.hasMicrophonePermission ? .granted : .denied
    }

    private var accessibilityDotState: PermissionDot.DotState {
        permissionManager.hasAccessibilityPermission ? .granted : .denied
    }

    // MARK: - Model Status Badges (logic preserved verbatim)

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

    // MARK: - Model Footnote (logic preserved, colors migrated to Palette tokens)

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

    /// Migrated from `.green` / `.orange` / `.secondary` to Palette tokens.
    private var modelFootnoteToneColor: Color {
        if settings.selectedModel.hasCoreMLSupport && modelManager.isCoreMLModelDownloaded(model: settings.selectedModel) {
            return Palette.success
        }
        if settings.selectedModel.coreMLExplanation != nil {
            return Palette.textSecondary
        }
        if modelManager.isModelDownloaded(model: settings.selectedModel) {
            return Palette.warning
        }
        return Palette.textSecondary
    }

    // MARK: - Helpers

    private func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textMuted)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(model.estimatedSize) · Speed \(model.speedRating) · Quality \(model.qualityRating)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(model.recommendedFor)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                }

                Spacer(minLength: Spacing.md)

                downloadStateBadge
            }
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.vertical, Spacing.prefsRowVertical)
            .frame(minHeight: Spacing.prefsRowMinHeight)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(model.displayName)
        .accessibilityValue("\(downloadStateAccessibilityValue), \(model.estimatedSize), Speed \(model.speedRating), Quality \(model.qualityRating)")
    }

    @ViewBuilder
    private var downloadStateBadge: some View {
        if modelManager.isModelDownloaded(model: model) {
            StatusBadge("Downloaded", tone: .positive)
        } else {
            StatusBadge("Not downloaded")
        }
    }

    private var downloadStateAccessibilityValue: String {
        modelManager.isModelDownloaded(model: model) ? "Downloaded" : "Not downloaded"
    }
}

// MARK: - Hotkey Recorder View (preserved verbatim — do NOT modify)

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
