// FirstLaunchWindow.swift — VoiceType Step 4 (Tier A)
//
// Surface: 480px-wide titlebar-less window, 4-step checklist.
// Auto-closes when the three blocker steps (mic, accessibility, model) are all done.
// Re-openable from menubar via AppDelegate.openFirstLaunchWindow().
//
// DESIGN.md § Interaction States / First launch arc.
// DESIGN.md § Implementation Plan Step 4.
// Decisions Log D8: FirstLaunchWindow replaces requestInitialPermissionsIfNeeded().
//
// Hotkey step (step 4) interpretation: rendered with muted badge
// (Palette.textMuted number, Palette.surfaceInset background) to visually signal
// "optional / not a blocker". Auto-close fires when steps 1-3 are done regardless
// of whether the user customised their hotkey.

import AppKit
import SwiftUI

// MARK: - OnboardingState

/// Pure UserDefaults gate — internal first-run flag, not a user-tunable setting.
/// Kept here alongside FirstLaunchWindow to keep onboarding logic co-located.
enum OnboardingState {
    static let hasCompletedKey = "hasCompletedOnboarding"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedKey) }
    }

    /// Pure function — no side effects. Extracted for testability.
    /// DESIGN.md § First launch: blockers are mic + accessibility + at-least-one model.
    static func allBlockersSatisfied(
        hasMicrophonePermission: Bool,
        hasAccessibilityPermission: Bool,
        hasAnyDownloadedModel: Bool
    ) -> Bool {
        hasMicrophonePermission && hasAccessibilityPermission && hasAnyDownloadedModel
    }
}

// MARK: - FirstLaunchWindow

final class FirstLaunchWindow: NSWindow {

    private var hostingView: NSHostingView<FirstLaunchView>?

    init(permissionManager: PermissionManager) {
        // Width 480 per spec. Height is content-driven; start with a sensible default
        // and let SwiftUI auto-size via the hosting view's fittingSize.
        let initialRect = NSRect(
            origin: .zero,
            size: WindowSize.firstLaunch
        )

        super.init(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .clear

        let view = FirstLaunchView(permissionManager: permissionManager) { [weak self] in
            self?.handleAutoClose()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting
        hostingView = hosting

        // Size to content after the hosting view is attached
        setContentSize(hosting.fittingSize)
        center()
    }

    private func handleAutoClose() {
        OnboardingState.hasCompleted = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.short
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.close()
            self?.alphaValue = 1
        })
    }
}

// MARK: - FirstLaunchView

struct FirstLaunchView: View {

    @ObservedObject var permissionManager: PermissionManager
    let onAllBlockersDone: () -> Void

    // Model download state
    @State private var isDownloadingModel = false
    @State private var downloadFailed = false

    private var modelManager: ModelManager { ModelManager.shared }

    // Derived booleans — computed fresh each render
    private var hasMic: Bool { permissionManager.hasMicrophonePermission }
    private var hasA11y: Bool { permissionManager.hasAccessibilityPermission }
    private var hasModel: Bool { !modelManager.downloadedModels().isEmpty }

    // Observe ModelManager reactively via @ObservedObject
    @ObservedObject private var _modelManager = ModelManager.shared

    var body: some View {
        // MARK: First-launch prototype CSS values
        // .fl-body { padding: 36px 32px; gap: 20px }
        // .fl-steps { gap: 10px } — no Dividers between step rows per prototype
        VStack(alignment: .center, spacing: 20) {
            // .fl-body h2 { font-size: 17px; font-weight: 500 }
            // No Typography token for 17pt Medium; use PostScript name per project pattern.
            Text("Four steps and you're typing with your voice")
                .font(Font.custom("Geist-Medium", size: 17))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // .fl-steps { display:flex; flex-direction:column; gap:10px }
            // Matches .fl-steps { margin-top: 8px } in v4-revisions.html — layered on top
            // of the outer VStack(spacing: 20) for a total 28pt gap.
            VStack(spacing: 10) {
                stepRow(StepRowConfig(
                    number: 1,
                    title: "Grant microphone access",
                    subtitle: hasMic
                        ? "Microphone access granted"
                        : "Required to capture your voice",
                    isDone: hasMic,
                    isNeutral: false,
                    actionLabel: hasMic ? nil : "Grant microphone access",
                    action: { permissionManager.requestMicrophonePermission() }
                ))

                stepRow(StepRowConfig(
                    number: 2,
                    title: "Grant accessibility access",
                    subtitle: hasA11y
                        ? "Accessibility access granted"
                        : "Required to insert transcribed text",
                    isDone: hasA11y,
                    isNeutral: false,
                    actionLabel: hasA11y ? nil : "Grant accessibility access",
                    action: { permissionManager.requestAccessibilityPermission(prompt: true) }
                ))

                modelStepRow()

                hotkeyStepRow()
            }
            // Matches .fl-steps { margin-top: 8px } in v4-revisions.html — layered on top
            // of the outer VStack(spacing: 20) for a total 28pt gap.
            .padding(.top, 8)
        }
        // .fl-body { padding: 36px 32px }
        // 36pt vertical: no token exists (Spacing.xxxl=48, Spacing.xxl=32) → inline literal.
        // 32pt horizontal: Spacing.xxl (32pt) matches exactly.
        .padding(.vertical, 36)
        .padding(.horizontal, Spacing.xxl)
        .frame(width: WindowSize.firstLaunch.width)
        .background(Palette.bgWindow)
        // NOTE: single-parameter onChange is the macOS 13 API. The two-parameter
        // form (onChange(of:initial:_:)) requires macOS 14+. Deployment target
        // is macOS 13 (Package.swift), so keep this form until the target bumps.
        // Review P3-F7 acknowledged as deferred time-bomb.
        .onChange(of: hasMic) { _ in checkBlockers() }
        .onChange(of: hasA11y) { _ in checkBlockers() }
        .onChange(of: _modelManager.isDownloading) { downloading in
            if !downloading {
                isDownloadingModel = false
                checkBlockers()
            }
        }
        .onAppear { checkBlockers() }
    }

    // MARK: - Step Rows

    @ViewBuilder
    private func modelStepRow() -> some View {
        let modelDone = hasModel && !isDownloadingModel

        // .fl-step container — same chrome as stepRow()
        HStack(alignment: .center, spacing: Spacing.md) {
            StepBadge(number: 3, isDone: modelDone, isNeutral: false)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // .step-title { font-size:12px; font-weight:500 }
                Text("Download a model")
                    .font(Typography.buttonLabel)
                    .foregroundStyle(Palette.textPrimary)

                if isDownloadingModel {
                    Text("Downloading\u{2026}")
                        .font(Typography.caption)
                        // Palette.textMuted == CSS --text-muted (dark #7F90A1 / light #6E7F90).
                        .foregroundStyle(Palette.textMuted)
                } else if downloadFailed {
                    Text("Download failed — tap to retry")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.error)
                } else if modelDone {
                    Text("Model ready")
                        .font(Typography.caption)
                        // Palette.textMuted == CSS --text-muted (dark #7F90A1 / light #6E7F90).
                        .foregroundStyle(Palette.textMuted)
                } else {
                    Text("Required to transcribe speech")
                        .font(Typography.caption)
                        // Palette.textMuted == CSS --text-muted (dark #7F90A1 / light #6E7F90).
                        .foregroundStyle(Palette.textMuted)
                }
            }

            Spacer()

            if !modelDone || downloadFailed {
                Button(isDownloadingModel ? "Downloading\u{2026}" : "Download model") {
                    startModelDownload()
                }
                .buttonStyle(ChecklistPrimaryButtonStyle())
                .disabled(isDownloadingModel)
                .accessibilityLabel(
                    isDownloadingModel
                        ? "Downloading model, please wait"
                        : "Download transcription model"
                )
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.capsuleHorizontal)
        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    @ViewBuilder
    private func hotkeyStepRow() -> some View {
        // .fl-step container — same chrome as stepRow()
        HStack(alignment: .center, spacing: Spacing.md) {
            StepBadge(number: 4, isDone: false, isNeutral: true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // .step-title { font-size:12px; font-weight:500 }
                Text("Set a custom hotkey")
                    .font(Typography.buttonLabel)
                    .foregroundStyle(Palette.textPrimary)
                Text("Default ⌥ Space works out of the box — optional")
                    .font(Typography.caption)
                    // Palette.textMuted == CSS --text-muted (dark #7F90A1 / light #6E7F90).
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer()

            Button("Customize hotkey") {
                openShortcutsSettings()
            }
            .buttonStyle(ChecklistLinkButtonStyle())
            .accessibilityLabel("Open settings to customize your recording hotkey")
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.capsuleHorizontal)
        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Configuration bundle for a generic step row (keeps parameter count ≤ 5).
    private struct StepRowConfig {
        let number: Int
        let title: String
        let subtitle: String
        let isDone: Bool
        let isNeutral: Bool
        let actionLabel: String?
        let action: () -> Void
    }

    @ViewBuilder
    private func stepRow(_ config: StepRowConfig) -> some View {
        // .fl-step { padding:12px 14px; background:var(--surface-inset); border-radius:8px; gap:12px }
        // Spacing.md (12pt) vertical, Spacing.capsuleHorizontal (14pt) horizontal, Radius.control (8pt).
        HStack(alignment: .center, spacing: Spacing.md) {
            StepBadge(number: config.number, isDone: config.isDone, isNeutral: config.isNeutral)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // .step-title { font-size:12px; font-weight:500 } — Typography.buttonLabel matches exactly.
                Text(config.title)
                    .font(Typography.buttonLabel)
                    .foregroundStyle(Palette.textPrimary)
                // .step-sub { font-size:11px; color:var(--text-muted) }
                // Palette.textMuted == CSS --text-muted (dark #7F90A1 / light #6E7F90); NOT textSecondary.
                Text(config.subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer()

            if let label = config.actionLabel {
                // Blocker rows (isNeutral=false) use primary filled style.
                // Optional rows (isNeutral=true) use link style.
                if config.isNeutral {
                    Button(label) { config.action() }
                        .buttonStyle(ChecklistLinkButtonStyle())
                        .accessibilityLabel(label)
                } else {
                    Button(label) { config.action() }
                        .buttonStyle(ChecklistPrimaryButtonStyle())
                        .accessibilityLabel(label)
                }
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.capsuleHorizontal)
        .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: - Actions

    private func startModelDownload() {
        guard !isDownloadingModel else { return }
        // If already downloading via AppDelegate preload, just reflect that state
        if modelManager.isDownloading {
            isDownloadingModel = true
            return
        }
        isDownloadingModel = true
        downloadFailed = false
        let model = AppSettings.shared.selectedModel
        Task {
            do {
                try await modelManager.downloadModel(model: model)
                await MainActor.run {
                    isDownloadingModel = false
                    downloadFailed = false
                    checkBlockers()
                }
            } catch {
                await MainActor.run {
                    isDownloadingModel = false
                    downloadFailed = true
                }
            }
        }
    }

    private func openShortcutsSettings() {
        // Opens Settings to the Shortcuts tab (Step 5 will wire the tab index).
        // For now, call AppDelegate openSettings() — the user can navigate to Shortcuts.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openSettings()
        }
    }

    private func checkBlockers() {
        // Guard against re-firing auto-close when the window is reopened from
        // the menubar after onboarding has already completed. Without this,
        // the reopen path triggers onAppear → checkBlockers → onAllBlockersDone
        // → handleAutoClose immediately, producing a jarring show-then-fade flash.
        // Review P1-F2.
        guard !OnboardingState.hasCompleted else { return }

        let ready = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: hasMic,
            hasAccessibilityPermission: hasA11y,
            hasAnyDownloadedModel: hasModel
        )
        if ready {
            onAllBlockersDone()
        }
    }
}

// MARK: - StepBadge

struct StepBadge: View {
    let number: Int
    let isDone: Bool
    /// Neutral steps (hotkey) render with muted styling to signal "optional".
    let isNeutral: Bool

    // MARK: First-launch prototype CSS values
    // .num { width:20px; height:20px; border-radius:50% } — Circle, not rounded-rect.
    // Previous: 24pt RoundedRectangle(cornerRadius: Radius.control).
    private let size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(badgeBackground)
                .frame(width: size, height: size)

            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.success)
            } else {
                Text("\(number)")
                    .font(Typography.badge)
                    .foregroundStyle(badgeForeground)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(isDone ? "Step \(number) complete" : "Step \(number)")
    }

    private var badgeBackground: Color {
        // Prototype CSS: .fl-step .num { background:var(--accent-soft) } — applies to ALL badge states,
        // including neutral/optional steps. surfaceInset was previously used here but blends into the
        // surfaceInset row background, making the circle invisible (codex P3).
        Palette.accentSoft
    }

    private var badgeForeground: Color {
        if isNeutral { return Palette.textMuted }
        return Palette.accent
    }
}
