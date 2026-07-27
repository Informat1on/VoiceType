// ButtonStyles.swift — VoiceType Design System
//
// Two reusable ButtonStyle implementations, shared across every filled/link
// button in the app (FirstLaunchWindow checklist, EvalEditorView footer, …).
// ChecklistPrimaryButtonStyle — filled accent background (primary actions).
// ChecklistLinkButtonStyle    — text-only accent (optional/secondary actions).
//
// DESIGN.md § Interaction States / First launch.
// Tier A Step 6 Scope C.
// 2026-07-27: promoted to the single source of "filled accent button" —
// EvalEditorView had its own copy (`VoiceTypePrimaryButtonStyle`) with the
// same white-on-accent WCAG AA failure this file already fixed once. Rather
// than fix the copy too, it was deleted in favor of this one. See
// DESIGN.md Decisions Log 2026-07-27.

import SwiftUI

// MARK: - ChecklistPrimaryButtonStyle

/// Filled-background button for primary actions (checklist blocker rows —
/// mic, accessibility, model — and EvalEditorView's "Save eval pair").
/// Background: Palette.accent. Text: black — white on accent is 1.90:1 dark /
/// 3.04:1 light, both fail WCAG AA. Black gives ~12:1 dark / ~9.8:1 light — AAA.
/// Found by code review P1-B.
/// Radius: Radius.control (8pt). Padding: ButtonPadding.medium (7×14pt).
/// Respects `.disabled()` via `@Environment(\.isEnabled)`: background falls
/// back to `Palette.strokeSubtle` and text to `Palette.textMuted` — added
/// 2026-07-27 when EvalEditorView's Save button (disabled until the
/// correction differs from the original) merged into this style; previously
/// only the FirstLaunchWindow download button used `.disabled()` here and the
/// gap in visual feedback went unnoticed because it stays enabled almost
/// immediately after appearing.
struct ChecklistPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// Exposed so TokensTests can assert the real contrast pair instead of
    /// re-declaring the colours next to the test, where they could drift out of
    /// sync with the style and still pass. Review finding, wave B.
    static let enabledForeground: Color = .black
    static let enabledBackground: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Self.enabledForeground : Palette.textMuted)
            .padding(.horizontal, ButtonPadding.horizontal)
            .padding(.vertical, ButtonPadding.vertical)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isEnabled ? Self.enabledBackground : Palette.strokeSubtle)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: Motion.micro), value: configuration.isPressed)
    }
}

// MARK: - ChecklistLinkButtonStyle

/// Text-only accent button for optional checklist rows (hotkey customization).
/// No background, no border — pressed state shifts to accentStrong.
struct ChecklistLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(
                configuration.isPressed ? Palette.accentStrong : Palette.accent
            )
            .padding(.horizontal, ButtonPadding.horizontal)
            .padding(.vertical, ButtonPadding.vertical)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: Motion.micro), value: configuration.isPressed)
    }
}
