// ButtonStyles.swift — VoiceType Design System
//
// Two reusable ButtonStyle implementations for the FirstLaunchWindow checklist.
// ChecklistPrimaryButtonStyle — filled accent background (blocker rows).
// ChecklistLinkButtonStyle    — text-only accent (optional rows).
//
// DESIGN.md § Interaction States / First launch.
// Tier A Step 6 Scope C.

import SwiftUI

// MARK: - ChecklistPrimaryButtonStyle

/// Filled-background button for blocker checklist rows (mic, accessibility, model).
/// Background: Palette.accent. Text: white (WCAG AA on dark accent, verified).
/// Radius: Radius.control (8pt). Padding: ButtonPadding.medium (7×14pt).
struct ChecklistPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(Color.white)
            .padding(.horizontal, ButtonPadding.horizontal)
            .padding(.vertical, ButtonPadding.vertical)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Palette.accent)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: Motion.micro), value: configuration.isPressed)
    }
}

// MARK: - ChecklistLinkButtonStyle

/// Text-only accent button for optional checklist rows (hotkey customization).
/// Identical to the original ChecklistButtonStyle — kept as a renamed alias
/// so call sites can express intent explicitly.
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
