import SwiftUI
import AppKit

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var transcriptionService: TranscriptionService
    @State private var isRecordingHotkey = false
    @State private var recordedModifiers = 0
    @State private var recordedKey = 0

    /// Sidebar tab enum — order is tab order per DESIGN.md line 176 / prototype line 574.
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
        // Flat HStack layout per prototype .settings-window { display:flex }
        // Replaces NavigationSplitView + List (codex audit P1).
        HStack(alignment: .top, spacing: 0) {
            sidebar
            // 1px border-right: prototype line 224 border-right:1px solid var(--divider)
            Rectangle()
                .fill(Palette.divider)
                .frame(width: 1)
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: WindowSize.settings.width, height: WindowSize.settings.height)
        .background(Palette.bgWindow)
    }

    // MARK: - Sidebar
    //
    // Prototype .settings-sidebar: width:160px; flex-shrink:0; padding:12px 8px;
    // border-right:1px solid var(--divider); background:var(--bg-window).

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { tab in
                SidebarItem(
                    label: tab.displayName,
                    systemImage: tab.symbolName,
                    isActive: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)   // prototype: padding:12px 8px
        .padding(.vertical, 12)
        .frame(width: 160)          // prototype: width:160px
        .background(Palette.bgWindow)
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
                // SegmentedControl replaces Picker(.segmented) — codex audit P1.
                // Prototype lines 606-614: custom .seg inside .prefs-row.
                PrefsRow("Preferred language",
                         subtitle: "Auto detects per recording. RU/EN pin a single language. RU+EN enables bilingual mode for code-switched speech.") {
                    SegmentedControl(
                        // VT-REV-002: pass longDisplayName as per-segment accessibilityLabel so
                        // VoiceOver reads "Russian" / "English" / "Russian + English (bilingual)"
                        // instead of the compact visible text "RU" / "EN" / "RU+EN".
                        options: Language.allCases.map {
                            (label: $0.displayName, value: $0, accessibilityLabel: $0.longDisplayName)
                        },
                        selection: $settings.language
                    )
                    .accessibilityLabel("Preferred language")
                    .accessibilityValue(settings.language.longDisplayName)
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
                    // NOTE P2: Prototype shows "Insert into focused app" toggle (switch)
                    // but spec has ActivationMode enum Picker. Per task constraints:
                    // keep existing ActivationMode Picker — flag as P2 follow-up.
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

                // MARK: PERMISSIONS group — compact dual-permission block
                GroupHeader(title: "Permissions")
                RowDivider()
                permissionsSectionGeneral
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
                    // VT-REV-001: status dot must only reflect the LOADED model, not the
                    // selected model.  After the user taps a new model row, selectedModel
                    // updates immediately but the old model is still loaded (and still
                    // .ready).  Forwarding modelStatus to the newly-selected row would show
                    // a misleading green dot before loading actually completes.
                    // Fix: compare against loadedModelName — the authoritative identity of
                    // whatever model TranscriptionService has in memory right now.
                    // When loadedModelName is nil (no model loaded yet) every row gets
                    // .notLoaded, which is also correct.
                    let isActuallyLoaded = transcriptionService.loadedModelName == model.rawValue
                    ModelRow(
                        model: model,
                        isSelected: settings.selectedModel == model,
                        onSelect: { settings.selectedModel = model },
                        activeModelStatus: isActuallyLoaded
                            ? transcriptionService.modelStatus
                            : .notLoaded
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

                // VT-REV-004: actionable hint row — tapping "Go to General → Permissions"
                // switches the tab, making it focusable by VoiceOver as a real Button.
                if accessibilityPermState != .granted {
                    SectionGap()
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                            .font(.system(size: 12))
                        Text("Hotkey requires Accessibility permission")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Button("Go to General → Permissions") {
                            selectedTab = .general
                        }
                        .font(Typography.buttonLabel)
                        .foregroundStyle(Palette.accent)
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Open General tab to grant Accessibility permission")
                    }
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.vertical, Spacing.prefsRowVertical)
                    .frame(minHeight: Spacing.prefsRowMinHeight)
                    RowDivider()
                }
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

                // MARK: TRANSCRIPTION HISTORY group — Step 9
                GroupHeader(title: "Transcription History")
                RowDivider()
                HistorySection()
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

    // MARK: - Permissions Section (General tab)
    //
    // Compact dual-row block — replaces separate MICROPHONE and ACCESSIBILITY groups.
    // Happy path: one tight row per permission (dot + name + status + button).
    // Denied path: expands the affected permission with description + action buttons.
    // General tab is the single source of truth; Shortcuts tab shows a read-only hint.

    private var permissionsSectionGeneral: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Microphone row ---
            CompactPermissionRow(
                name: "Microphone",
                state: microphonePermState,
                onPrivacy: {
                    if permissionManager.hasMicrophonePermission {
                        openMicrophonePrivacySettings()
                    } else {
                        permissionManager.requestMicrophonePermission()
                    }
                }
            )

            // Expanded block for microphone — only shown when denied / not requested
            if microphonePermState != .granted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    PermHintPanel(
                        state: microphonePermState,
                        title: microphonePermTitle,
                        actionLabel: microphoneActionLabel,
                        onAction: {
                            if permissionManager.hasMicrophonePermission {
                                openMicrophonePrivacySettings()
                            } else {
                                permissionManager.requestMicrophonePermission()
                            }
                        }
                    )
                }
                .padding(.horizontal, Spacing.prefsRowHorizontal)
                .padding(.bottom, Spacing.prefsRowVertical)
            }

            RowDivider()

            // --- Accessibility row ---
            CompactPermissionRow(
                name: "Accessibility",
                state: accessibilityPermState,
                onPrivacy: {
                    if permissionManager.hasAccessibilityPermission {
                        permissionManager.openAccessibilitySettings()
                    } else {
                        permissionManager.requestAccessibilityPermission()
                    }
                }
            )

            // Expanded block for accessibility — only shown when denied / not requested
            if accessibilityPermState != .granted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Required for VoiceType to insert transcribed text into other apps.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Spacing.prefsRowHorizontal)

                    PermHintPanel(
                        state: accessibilityPermState,
                        title: accessibilityPermTitle,
                        actionLabel: accessibilityActionLabel,
                        onAction: {
                            if permissionManager.hasAccessibilityPermission {
                                permissionManager.openAccessibilitySettings()
                            } else {
                                permissionManager.requestAccessibilityPermission()
                            }
                        }
                    )
                    .padding(.horizontal, Spacing.prefsRowHorizontal)

                    HStack(spacing: Spacing.sm) {
                        Button("Refresh") {
                            permissionManager.refreshPermissions()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Restart App") {
                            permissionManager.restartAppForAccessibility()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, Spacing.prefsRowHorizontal)
                    .padding(.bottom, Spacing.prefsRowVertical)
                }
            }
        }
        // VT-REV-002: use .contain instead of .combine so VoiceOver can individually
        // reach each button (Refresh, Restart App, Open Privacy…) inside this section.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Permission State Helpers

    private var microphonePermState: PermHintPanel.PermState {
        switch permissionManager.microphonePermission {
        case .granted:       return .granted
        case .notDetermined: return .notRequested
        case .denied:        return .denied
        }
    }

    private var microphonePermTitle: String {
        switch permissionManager.microphonePermission {
        case .granted:       return "Microphone access granted"
        case .notDetermined: return "Allow microphone access for dictation"
        case .denied:        return "Microphone access required to capture your voice"
        }
    }

    private var accessibilityPermState: PermHintPanel.PermState {
        switch permissionManager.accessibilityPermission {
        case .granted:       return .granted
        case .notDetermined: return .notRequested
        case .denied:        return .denied
        }
    }

    private var accessibilityPermTitle: String {
        switch permissionManager.accessibilityPermission {
        case .granted:       return "Accessibility access granted"
        case .notDetermined: return "Allow accessibility access for ⌘V insertion"
        case .denied:        return "Accessibility access required for synthesized ⌘V"
        }
    }

    private var microphoneActionLabel: String {
        switch permissionManager.microphonePermission {
        case .granted:       return "Open Privacy…"
        case .notDetermined: return "Allow Access"
        case .denied:        return "Open Privacy…"
        }
    }

    private var accessibilityActionLabel: String {
        switch permissionManager.accessibilityPermission {
        case .granted:       return "Open Privacy…"
        case .notDetermined: return "Allow Access"
        case .denied:        return "Open Privacy…"
        }
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
