import SwiftUI

// MARK: - AboutView
// Native-row layout per v1-cool-inksteel.html prototype (.about-window, .about-head,
// .about-groups CSS). Glassmorphism wrappers (WindowSurface / WindowHeroHeader /
// SettingsSectionCard) removed as mandated by DESIGN.md "no glassmorphism" rule.
// Artwork 86 → 64pt; title 22 → 18pt; hotkey chip Capsule → RoundedRectangle(5pt).

struct AboutView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Head — artwork + title block
                // Prototype: .about-head { display:flex; align-items:flex-start; gap:16px; margin-bottom:24px }
                HStack(alignment: .top, spacing: Spacing.lg) {
                    VoiceTypeArtwork(size: 64)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("VoiceType")
                            .font(Font.custom("Geist-Medium", size: 18))
                            .foregroundStyle(Palette.textPrimary)

                        // Prototype: .about-version { font-family: 'Geist Mono'; font-size: 11px;
                        //   color: var(--text-muted); letter-spacing: 0.04em }
                        Text(aboutVersionLine)
                            .font(Typography.monoSmall)
                            .tracking(Typography.metaLabelTracking)
                            .foregroundStyle(Palette.textMuted)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.bottom, Spacing.xl)   // margin-bottom: 24px

                // MARK: Description paragraph
                // Prototype: .about-body p { font-size: 13px; line-height: 1.5; color: var(--text-secondary) }
                Text("100% local transcription via whisper.cpp and CoreML on Apple Silicon. No cloud, no account, no data leaves your Mac.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.xl)

                // MARK: Groups — native rows
                // Prototype: .about-groups { margin-top: 20px; gap: 20px }
                VStack(alignment: .leading, spacing: Spacing.xl) {

                    // BUILD group
                    aboutGroup(title: "Build") {
                        aboutRow("Version") {
                            Text(appVersion)
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        RowDivider()
                        aboutRow("Bundle") {
                            Text(Bundle.main.bundleIdentifier ?? "VoiceType")
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        RowDivider()
                        aboutRow("Platform") {
                            Text("macOS 13+")
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    // CURRENT SETUP group
                    aboutGroup(title: "Current Setup") {
                        aboutRow("Hotkey") {
                            hotkeyChip
                        }
                        RowDivider()
                        aboutRow("Model") {
                            Text(settings.selectedModel.displayName)
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        RowDivider()
                        aboutRow("Language") {
                            Text(languageLabel)
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        RowDivider()
                        aboutRow("Insertion") {
                            Text(settings.textInjectionMode.displayName)
                                .font(Typography.mono)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    // PERMISSIONS group
                    aboutGroup(title: "Permissions") {
                        aboutRow("Microphone") {
                            permissionBadge(permissionManager.hasMicrophonePermission)
                        }
                        RowDivider()
                        aboutRow("Accessibility") {
                            permissionBadge(permissionManager.hasAccessibilityPermission)
                        }
                    }

                    // PRIVACY group — full-width description, no right control
                    aboutGroup(title: "Privacy") {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: Spacing.md) {
                                Text("Your voice never leaves this Mac")
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.prefsRowHorizontal)
                            .padding(.vertical, Spacing.prefsRowVertical)
                            .frame(minHeight: Spacing.prefsRowMinHeight)

                            // swiftlint:disable:next line_length
                            Text("Audio is transcribed locally on your Mac and the resulting text is only inserted into the active field after you explicitly trigger recording.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Spacing.prefsRowHorizontal)
                                .padding(.bottom, Spacing.prefsRowVertical)
                        }
                    }
                }
            }
            // Prototype: .about-content { padding: 28px 28px 24px }
            // aboutContentTop=28 (top), windowPadding=24 (horizontal), xl=24 (bottom).
            .padding(.horizontal, Spacing.windowPadding)
            .padding(.top, Spacing.aboutContentTop)   // was Spacing.xxl (32)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(Palette.bgWindow)
        .frame(width: WindowSize.about.width, height: WindowSize.about.height)
    }

    // MARK: - Group / row helpers

    /// Uppercase meta-label group header + top-border rows block.
    /// Prototype: .group-label meta-label + .group-rows { border-top: 1px solid var(--divider) }
    @ViewBuilder
    private func aboutGroup<Content: View>(
        title: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.metaLabel)
                .tracking(Typography.metaLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textMuted)
                .padding(.bottom, Spacing.sm)   // group-label: margin-bottom 8px

            RowDivider()   // top border per prototype .group-rows
            rows()
        }
    }

    /// Single about-row: label left, control right. Matches .prefs-row layout.
    @ViewBuilder
    private func aboutRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.md)
            control()
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Spacing.prefsRowHorizontal)
        .padding(.vertical, Spacing.prefsRowVertical)
        .frame(minHeight: Spacing.prefsRowMinHeight)
    }

    /// Hotkey display chip — RoundedRectangle 5pt per prototype.
    /// Prototype: .hotkey-chip { border-radius: 5px; background: var(--surface-inset);
    ///   border: 1px solid var(--stroke-subtle); font-family: 'Geist Mono';
    ///   font-size: 11px; padding: 3px 8px; letter-spacing: 0.04em }
    private var hotkeyChip: some View {
        Text("\(modifiersToString(settings.hotkeyModifiers))\(keyCodeToString(settings.hotkeyKey))")
            .font(Typography.monoSmall)
            .tracking(Typography.metaLabelTracking)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Spacing.sm)   // 8px
            .padding(.vertical, Spacing.xs)     // 4px (nearest token to prototype 3px)
            .background(Palette.surfaceInset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.strokeSubtle, lineWidth: 1)
            )
    }

    private func permissionBadge(_ isGranted: Bool) -> some View {
        StatusBadge(isGranted ? "Granted" : "Needs attention", tone: isGranted ? .positive : .warning)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    /// Compact version line for the about-head sub-title.
    private var aboutVersionLine: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private var languageLabel: String {
        settings.language.displayName
    }
}
