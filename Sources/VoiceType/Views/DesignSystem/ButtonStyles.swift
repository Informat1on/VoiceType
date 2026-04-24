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
/// Background: Palette.accent. Text: black — white on accent is 1.90:1 dark /
/// 3.04:1 light, both fail WCAG AA. Black gives ~12:1 dark / ~9.8:1 light — AAA.
/// Found by code review P1-B.
/// Radius: Radius.control (8pt). Padding: ButtonPadding.medium (7×14pt).
struct ChecklistPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(Color.black)
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
