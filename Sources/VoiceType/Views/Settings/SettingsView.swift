import SwiftUI
import AppKit

// MARK: - Row Primitives

/// Uppercase meta-label group header.
/// DESIGN.md line 180: 11/14 Medium, letter-spacing 0.08em, textMuted. 8px gap below.
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
/// Prototype: `.prefs-row { padding: 12px 0; min-height: 40px; }`
// internal: used by HistorySection (same module)
struct PrefsRow<Control: View>: View {
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
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
    }
}

/// Vertical gap between row-groups. DESIGN.md § Spacing line 155.
struct SectionGap: View {
    var body: some View {
        Color.clear.frame(height: Spacing.sectionGap)
    }
}

/// Colored dot for permission state rows. DESIGN.md lines 256-258.
struct PermissionDot: View {
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

// MARK: - Custom Segmented Control
//
// Replaces native Picker(.segmented). Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 273-287:
//   .seg { background:var(--surface-inset); border-radius:8px;
//          padding:2px; border:1px solid var(--stroke-subtle); }
//   .seg button { padding:4px 10px; font-size:12px; font-weight:500;
//                 color:var(--text-muted); border-radius:6px; transition:all 120ms; }
//   .seg button[aria-pressed="true"] { background:var(--bg-window);
//                                      color:var(--text-primary);
//                                      box-shadow:0 1px 2px rgba(0,0,0,0.12); }

private struct SegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segButton(option)
            }
        }
        // Outer container: surfaceInset bg, 8pt radius, 2px inner padding, strokeSubtle border
        .padding(2)
        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.strokeSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func segButton(_ option: (label: String, value: T)) -> some View {
        let isSelected = selection == option.value
        Button {
            selection = option.value
        } label: {
            Text(option.label)
                .font(Typography.buttonLabel)  // 12pt Medium — prototype font-size:12px weight:500
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textMuted)
                .padding(.horizontal, 10)  // prototype: padding 4px 10px
                .padding(.vertical, 4)
                .background(
                    Group {
                        if isSelected {
                            // Selected: bg-window + subtle shadow
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.bgWindow)
                                .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.clear)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isSelected)  // transition:120ms per prototype
    }
}

// MARK: - Permission Hint Panel
//
// Replaces plain PrefsRow for permission rows. Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 325-337:
//   .perm-hint { margin-top:6px; padding:10px 12px;
//                background:var(--accent-soft); border-radius:8px;
//                font-size:12px; color:var(--text-secondary);
//                display:flex; align-items:center; gap:10px;
//                border-left:2px solid var(--accent); }
//   .perm-hint.denied { background:rgba(255,122,107,0.10);
//                       border-left-color:var(--error); }
//   .perm-hint .perm-action { margin-left:auto; color:var(--accent);
//                             font-weight:500; cursor:pointer; }

private struct PermHintPanel: View {
    enum PermState { case granted, denied, notRequested }
    let state: PermState
    let title: String
    let actionLabel: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {  // gap:10px per prototype
            PermissionDot(state: dotState)

            Text(title)
                .font(Typography.caption)  // 12pt — matches prototype font-size:12px
                .foregroundStyle(Palette.textSecondary)

            Spacer()

            // .perm-action: margin-left:auto; color:var(--accent); font-weight:500
            Button(action: onAction) {
                Text(actionLabel)
                    .font(Typography.buttonLabel)  // 12pt Medium — font-weight:500
                    .foregroundStyle(actionColor)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 10)   // prototype: padding 10px 12px
        .padding(.horizontal, 12)
        .background(panelBg, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .leading) {
            // 2pt left accent bar — prototype border-left:2px solid var(--accent)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(borderColor)
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.top, 6)  // prototype: margin-top:6px
    }

    private var dotState: PermissionDot.DotState {
        switch state {
        case .granted:      return .granted
        case .denied:       return .denied
        case .notRequested: return .notRequested
        }
    }

    // granted/notRequested = accentSoft; denied = error-tinted rgba(255,122,107,0.10)
    // Prototype line 336: .perm-hint.denied { background: rgba(255,122,107,0.10) }
    // Uses Color.dynamic (Tokens.swift) — no new literal color values beyond Tokens.swift pattern.
    // Light: #D95C4F@0.10 = sRGB(0.850,0.361,0.310,0.10)
    // Dark:  #FF7A6B@0.10 = sRGB(1.000,0.478,0.420,0.10)
    // swiftlint:disable inline_nscolor_rgb
    private var panelBg: Color {
        switch state {
        case .granted, .notRequested:
            return Palette.accentSoft
        case .denied:
            return Color.dynamic(
                light: NSColor(srgbRed: 0.850196, green: 0.360784, blue: 0.309804, alpha: 0.10),
                dark: NSColor(srgbRed: 1.000000, green: 0.478431, blue: 0.419608, alpha: 0.10)
            )
        }
    }
    // swiftlint:enable inline_nscolor_rgb

    private var borderColor: Color {
        switch state {
        case .granted, .notRequested: return Palette.accent
        case .denied:                 return Palette.error
        }
    }

    private var actionColor: Color {
        switch state {
        case .granted, .notRequested: return Palette.accent
        case .denied:                 return Palette.error
        }
    }
}

// MARK: - Sidebar Item
//
// Replaces NavigationSplitView List rows. Matches prototype CSS exactly:
// v1-cool-inksteel.html lines 227-243:
//   .sidebar-item { display:flex; align-items:center; gap:8px;
//                   padding:6px 10px; border-radius:6px;
//                   font-size:13px; color:var(--text-secondary);
//                   transition:background-color 120ms; }
//   .sidebar-item:hover { background:var(--sidebar-hover); }
//   .sidebar-item.active { background:var(--sidebar-active);
//                          color:var(--text-primary); font-weight:500; }
//   .sidebar-item.active::before { content:""; width:2px; height:16px;
//                                  background:var(--accent); border-radius:1px;
//                                  margin-left:-10px; margin-right:4px; }

private struct SidebarItem: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                // Active indicator bar — CSS ::before pseudo-element equivalent.
                // width:2px; height:16px; accent color; border-radius:1px;
                // Offset to leading edge of padding zone.
                if isActive {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Palette.accent)
                        .frame(width: 2, height: 16)
                        .offset(x: -6)
                        .padding(.trailing, -2)
                } else {
                    Color.clear.frame(width: 2, height: 16)
                        .offset(x: -6)
                        .padding(.trailing, -2)
                }

                HStack(alignment: .center, spacing: 8) {  // gap:8px per prototype
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 14, height: 14)  // svg 14x14 per prototype line 243
                        .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)

                    Text(label)
                        .font(isActive
                              ? Font.custom("Geist", size: 13).weight(.medium)  // font-weight:500
                              : Typography.body)
                        .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)

                    Spacer()
                }
            }
            .padding(.horizontal, 10)  // prototype: padding:6px 10px
            .padding(.vertical, 6)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.sidebarActive)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.sidebarHover)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                    }
                }
            )
            .animation(.easeInOut(duration: 0.12), value: isActive)   // transition:120ms
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
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
                         subtitle: "Promoted to first-class: code-switching is why this exists.") {
                    SegmentedControl(
                        options: Language.allCases.map { (label: $0.displayName, value: $0) },
                        selection: $settings.language
                    )
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

                // MARK: MICROPHONE group — perm-hint panel per prototype lines 644-661
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

                // MARK: ACCESSIBILITY group — perm-hint panel per prototype pattern
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

    // MARK: - Permission Rows
    //
    // Prototype lines 644-661: perm-hint panel replaces plain PrefsRow for permissions.

    /// Microphone permission row — General tab. DESIGN.md lines 254-258.
    private var microphonePermissionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefsRow("Microphone access", subtitle: nil) {
                EmptyView()
            }
            // perm-hint panel per prototype lines 325-337, 656-660
            PermHintPanel(
                state: microphonePermState,
                title: microphonePermTitle,
                actionLabel: permissionManager.hasMicrophonePermission ? "Open Privacy…" : "Grant Access",
                onAction: {
                    if permissionManager.hasMicrophonePermission {
                        openMicrophonePrivacySettings()
                    } else {
                        permissionManager.requestMicrophonePermission()
                    }
                }
            )
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.bottom, Spacing.prefsRowVertical)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            permissionManager.hasMicrophonePermission
                ? "Microphone access: Granted"
                : "Microphone access: Not granted. Tap to request."
        )
    }

    /// Accessibility permission row — Shortcuts tab. DESIGN.md lines 254-258 / line 193.
    private var accessibilityPermissionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefsRow("Accessibility access",
                     subtitle: "Required for synthesized ⌘V") {
                EmptyView()
            }
            // perm-hint panel per prototype lines 325-337
            PermHintPanel(
                state: accessibilityPermState,
                title: accessibilityPermTitle,
                actionLabel: permissionManager.hasAccessibilityPermission ? "Open Privacy…" : "Grant Access",
                onAction: {
                    if permissionManager.hasAccessibilityPermission {
                        permissionManager.openAccessibilitySettings()
                    } else {
                        permissionManager.requestAccessibilityPermission()
                    }
                }
            )
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.bottom, Spacing.prefsRowVertical)

            // Refresh + Restart App buttons — only when permission not granted
            if !permissionManager.hasAccessibilityPermission {
                HStack(spacing: Spacing.sm) {
                    Button("Refresh") {
                        permissionManager.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    // macOS caches Accessibility state per-process. Full restart needed.
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            permissionManager.hasAccessibilityPermission
                ? "Accessibility access: Granted"
                : "Accessibility access: Not granted. Required for synthesized ⌘V. Tap to grant."
        )
    }

    // MARK: - Permission State Helpers

    // TODO(perm-3-state): PermissionManager currently exposes Bool (granted | not),
    // collapsing `notDetermined` into `.denied`. The prototype's `.perm-hint`
    // (v1-cool-inksteel.html line ~325) renders accent-soft for the not-yet-asked
    // state vs error-tinted for explicit denial. Three-state requires extending
    // PermissionManager.checkMicrophonePermission to return an enum. Tracked as
    // follow-up chunk; first-launch UX is functionally equivalent to the prior
    // modal-alert behavior, just visually red instead of system alert.
    private var microphonePermState: PermHintPanel.PermState {
        // hasMicrophonePermission is Bool — .notRequested not surfaced at this level.
        permissionManager.hasMicrophonePermission ? .granted : .denied
    }

    private var microphonePermTitle: String {
        permissionManager.hasMicrophonePermission
            ? "Microphone access granted"
            : "Microphone access required to capture your voice"
    }

    // TODO(perm-3-state): PermissionManager currently exposes Bool (granted | not),
    // collapsing `notDetermined` into `.denied`. The prototype's `.perm-hint`
    // (v1-cool-inksteel.html line ~325) renders accent-soft for the not-yet-asked
    // state vs error-tinted for explicit denial. Three-state requires extending
    // PermissionManager.checkAccessibilityPermission to return an enum. Tracked as
    // follow-up chunk; first-launch UX is functionally equivalent to the prior
    // modal-alert behavior, just visually red instead of system alert.
    private var accessibilityPermState: PermHintPanel.PermState {
        permissionManager.hasAccessibilityPermission ? .granted : .denied
    }

    private var accessibilityPermTitle: String {
        permissionManager.hasAccessibilityPermission
            ? "Accessibility access granted"
            : "Accessibility access required for synthesized ⌘V"
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
