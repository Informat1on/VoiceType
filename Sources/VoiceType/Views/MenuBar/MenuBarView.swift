// MenuBarView.swift — VoiceType Step 5 (Tier A)
//
// Three-state dropdown: Not Ready / Idle / Recording (+Transcribing).
// Width: 280pt per DESIGN.md § MenuBar dropdown layout.
// Requires MenuBarExtra(.window) style in VoiceTypeApp.swift.
//
// DESIGN.md § MenuBar dropdown layout.
// DESIGN.md § Implementation Plan Step 5.

import SwiftUI
import Combine

// MARK: - MenuBarState

/// Derived display state for the menubar dropdown.
/// Computed from AppDelegate.appState + permission/model booleans via
/// MenuBarStateMachine.derive(...). Kept as a separate type so the
/// derivation logic is pure and unit-testable without SwiftUI.
enum MenuBarState: Equatable {
    case notReady(missingMic: Bool, missingA11y: Bool, missingModel: Bool)
    case idle
    case recording(elapsed: TimeInterval)
    case transcribing
}

// MARK: - MenuBarStateMachine

/// Pure static helpers for deriving state and formatting elapsed time.
/// No side effects — safe to call from tests.
enum MenuBarStateMachine {

    /// Derive the display state from raw observed values.
    static func derive(
        appState: AppState,
        hasMic: Bool,
        hasA11y: Bool,
        hasModel: Bool,
        elapsed: TimeInterval
    ) -> MenuBarState {
        let allReady = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: hasMic,
            hasAccessibilityPermission: hasA11y,
            hasAnyDownloadedModel: hasModel
        )

        if !allReady {
            return .notReady(
                missingMic: !hasMic,
                missingA11y: !hasA11y,
                missingModel: !hasModel
            )
        }

        switch appState {
        case .idle, .injecting:
            return .idle
        case .recording:
            return .recording(elapsed: elapsed)
        case .transcribing:
            return .transcribing
        }
    }

    /// Format a TimeInterval as "M:SS" (no hour rollover — v1.1 max ~60 min).
    /// DESIGN.md § MenuBar status line: "Recording · 0:14" (Geist Mono tabular).
    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Count missing blockers for the "N SETUP STEPS REMAINING" sub-line.
    static func missingBlockerCount(missingMic: Bool, missingA11y: Bool, missingModel: Bool) -> Int {
        [missingMic, missingA11y, missingModel].filter { $0 }.count
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {

    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject private var permissionManager: PermissionManager
    @ObservedObject private var modelManager: ModelManager
    @ObservedObject private var settings = AppSettings.shared

    // 1-Hz ticker for the live recording timer display
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsed: TimeInterval = 0

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.permissionManager = appDelegate.permissionManager
        self.modelManager = ModelManager.shared
    }

    // MARK: Derived booleans

    private var hasMic: Bool { permissionManager.hasMicrophonePermission }
    private var hasA11y: Bool { permissionManager.hasAccessibilityPermission }
    private var hasModel: Bool { !modelManager.downloadedModels().isEmpty }

    private var menuBarState: MenuBarState {
        MenuBarStateMachine.derive(
            appState: appDelegate.appState,
            hasMic: hasMic,
            hasA11y: hasA11y,
            hasModel: hasModel,
            elapsed: elapsed
        )
    }

    // MARK: Body

    var body: some View {
        // Width 280pt — DESIGN.md § MenuBar dropdown layout: "280px wide".
        VStack(spacing: 0) {
            StatusLine(state: menuBarState, settings: settings)
                .padding(.horizontal, MenuBar.statusHorizontalPadding)
                .padding(.top, MenuBar.statusTopPadding)
                .padding(.bottom, MenuBar.statusBottomPadding)

            // 1px divider below status line. DESIGN.md § MenuBar dropdown layout.
            Palette.divider.frame(height: 1)

            stateContent
        }
        .frame(width: MenuBar.width) // off-scale: DESIGN.md § MenuBar dropdown layout
        .background(Palette.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: MenuBar.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: MenuBar.cornerRadius).stroke(Palette.strokeSubtle, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.30), radius: 20, x: 0, y: 8)
        .onReceive(ticker) { _ in
            guard appDelegate.appState == .recording,
                  let start = appDelegate.recordingStartedAt else {
                elapsed = 0
                return
            }
            elapsed = Date().timeIntervalSince(start)
        }
        // NOTE: single-parameter onChange is the macOS 13 API. The two-parameter
        // form (onChange(of:initial:_:)) requires macOS 14+. Deployment target
        // is macOS 13 (Package.swift), so keep this form until the target bumps.
        .onChange(of: appDelegate.appState) { newState in
            if newState != .recording {
                elapsed = 0
            }
        }
    }

    // MARK: State content

    @ViewBuilder
    private var stateContent: some View {
        switch menuBarState {
        case let .notReady(missingMic, missingA11y, missingModel):
            notReadyContent(missingMic: missingMic, missingA11y: missingA11y, missingModel: missingModel)
        case .idle:
            idleContent
        case .recording:
            recordingContent
        case .transcribing:
            // Transcribing is short-lived (1-8s); status line sub-line carries the signal.
            // No stop action — audio already captured, waiting on whisper.
            EmptyView()
        }
    }

    // MARK: Recording content

    /// Dropdown body while recording: a single "Stop recording" action mirroring
    /// the hotkey stop path. Required for UX symmetry — if the user can start
    /// from the menu, they must also be able to stop from the menu.
    private var recordingContent: some View {
        VStack(spacing: 0) {
            MenuActionRow(label: "Stop recording", trailingHint: currentHotkeyString) {
                appDelegate.stopRecordingFromMenu()
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: Not Ready content

    @ViewBuilder
    private func notReadyContent(missingMic: Bool, missingA11y: Bool, missingModel: Bool) -> some View {
        // Task rows flow without inter-row dividers per MenuBar IA: dropdown is
        // compact, rows are visually distinct via the "→" prefix + padding.
        VStack(spacing: 0) {
            if missingMic {
                SetupTaskRow(label: "Grant microphone access") {
                    permissionManager.requestMicrophonePermission()
                }
            }
            if missingA11y {
                SetupTaskRow(label: "Grant accessibility access") {
                    permissionManager.requestAccessibilityPermission(prompt: true)
                }
            }
            if missingModel {
                // openFirstLaunchWindow chosen over openSettings: the FirstLaunchWindow
                // shows a Download button directly; openSettings requires tab navigation.
                SetupTaskRow(label: "Download model") {
                    appDelegate.openFirstLaunchWindow()
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: Idle content

    private var idleContent: some View {
        // IA per DESIGN.md Decisions Log: "Start · Settings · About · divider · Quit".
        // "Run setup checklist" is required by DESIGN.md § First launch:
        // "Reopenable via menubar → Run setup checklist". Placed before the
        // Quit-divider so the one canonical separator stays on the destructive action.
        VStack(spacing: 0) {
            MenuActionRow(label: "Start recording", trailingHint: currentHotkeyString) {
                appDelegate.startRecordingFromMenu()
            }

            MenuActionRow(label: "Open Settings\u{2026}", keyboardShortcut: (",", .command)) {
                appDelegate.openSettings()
            }

            MenuActionRow(label: "About") {
                appDelegate.openAbout()
            }

            MenuActionRow(label: "Run setup checklist") {
                appDelegate.openFirstLaunchWindow()
            }

            // Canonical IA separator — DESIGN.md "About · divider · Quit".
            Palette.divider.frame(height: 1)
                .padding(.vertical, MenuBar.dividerGap)

            MenuActionRow(label: "Quit VoiceType", keyboardShortcut: ("q", .command)) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: Hotkey string

    private var currentHotkeyString: String {
        modifiersToString(AppSettings.shared.hotkeyModifiers)
            + keyCodeToString(AppSettings.shared.hotkeyKey)
    }
}

// MARK: - StatusLine

/// Top status row: tally dot (8x8) + two-line readout (title + mono sub-line).
private struct StatusLine: View {

    let state: MenuBarState
    let settings: AppSettings

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Tally dot — MenuBar.tallyDotSize (8pt) per DESIGN.md § MenuBar status line
            Circle()
                .fill(tallyColor)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                .accessibilityLabel(tallyAccessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Text(subLineText)
                    .font(Typography.mono)
                    .foregroundStyle(subLineColor)
                    .textCase(subLineUppercase ? .uppercase : nil)
                    .tracking(subLineUppercase ? Typography.metaLabelTracking : 0)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: Tally color

    private var tallyColor: Color {
        switch state {
        case .idle, .transcribing:
            return Palette.textMuted
        case .recording:
            // Recording tally stays capsule-world red (camera tally reference).
            return Palette.Capsule.recording
        case .notReady:
            // Surface-level error red — consistent with subLineColor semantic token.
            return Palette.error
        }
    }

    private var tallyAccessibilityLabel: String {
        switch state {
        case .idle:         return "Idle"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing"
        case .notReady:     return "Setup required"
        }
    }

    // MARK: Title

    private var titleText: String {
        switch state {
        case .idle:
            // "Ready to dictate" — action-oriented phrasing per DESIGN.md compass
            // "a tool for people who just build things". Step 5 brief: designer's call.
            return "Ready to dictate"
        case .recording(let elapsed):
            return "Recording \u{00B7} \(MenuBarStateMachine.formatElapsed(elapsed))"
        case .transcribing:
            return "VoiceType"
        case .notReady:
            return "VoiceType"
        }
    }

    // MARK: Sub-line

    private var subLineText: String {
        switch state {
        case .idle, .recording:
            return "\(settings.selectedModel.rawValue) \u{00B7} \(settings.language.displayName)"
        case .transcribing:
            return "Transcribing\u{2026}"
        case let .notReady(missingMic, missingA11y, missingModel):
            let n = MenuBarStateMachine.missingBlockerCount(
                missingMic: missingMic,
                missingA11y: missingA11y,
                missingModel: missingModel
            )
            return "\(n) SETUP STEPS REMAINING"
        }
    }

    private var subLineColor: Color {
        // Use Palette.error (semantic surface-level red) for notReady sub-line.
        // Palette.Capsule.recording is capsule-world-only; surface errors use Palette.error.
        // DESIGN.md § Color / MenuBar dropdown layout.
        if case .notReady = state { return Palette.error }
        return Palette.textMuted
    }

    private var subLineUppercase: Bool {
        if case .notReady = state { return true }
        return false
    }
}

// MARK: - SetupTaskRow

/// Tappable row for Not Ready state: "-> label" styled in accent color.
private struct SetupTaskRow: View {

    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Text("\u{2192}")  // rightwards arrow
                    .font(Typography.body)
                    .foregroundStyle(Palette.accent)

                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.accent)

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 32)
            .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: Motion.micro), value: isHovered)
    }
}

// MARK: - MenuActionRow

/// Standard idle-state action row with optional trailing hint and keyboard shortcut.
private struct MenuActionRow: View {

    let label: String
    var trailingHint: String?
    var keyboardShortcut: (KeyEquivalent, EventModifiers)?
    let action: () -> Void
    @State private var isHovered = false

    init(
        label: String,
        trailingHint: String? = nil,
        keyboardShortcut: (KeyEquivalent, EventModifiers)? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.trailingHint = trailingHint
        self.keyboardShortcut = keyboardShortcut
        self.action = action
    }

    var body: some View {
        let row = Button(action: action) {
            HStack {
                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                if let hint = trailingHint {
                    Text(hint)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textMuted)
                        .monospacedDigit()
                        .tracking(Typography.metaLabelTracking)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 32)
            .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: Motion.micro), value: isHovered)

        if let (key, mods) = keyboardShortcut {
            row.keyboardShortcut(key, modifiers: mods)
        } else {
            row
        }
    }
}
