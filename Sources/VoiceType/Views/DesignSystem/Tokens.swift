// Tokens.swift — VoiceType Design System
// Canonical source of truth for every visual constant.
// Values must match DESIGN.md exactly. Do NOT deviate without updating DESIGN.md
// and recording the change in its Decisions Log.
//
// Consumers: WindowChrome, SettingsView, FirstLaunchWindow, MenuBarView,
//            RecordingWindow (capsule), VoiceTypeArtwork. Migrated in Tier A Steps 2-8.

import AppKit
import SwiftUI

// swiftlint:disable inline_color_rgb inline_color_hex inline_nscolor_rgb

// MARK: - NSColor hex convenience

extension NSColor {
    /// Accepts exactly "#RRGGBB" or "#RRGGBBAA". No 0x prefix, no shorthand, no whitespace.
    /// Crashes (fatalError) on invalid input in both debug and release — caller guarantees correctness.
    convenience init(hex: String) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = UInt64(trimmed, radix: 16) else {
            fatalError("Invalid hex color: \(hex)")
        }
        let red, green, blue, alpha: CGFloat
        if trimmed.count == 8 {
            red = CGFloat((value & 0xFF000000) >> 24) / 255
            green = CGFloat((value & 0x00FF0000) >> 16) / 255
            blue = CGFloat((value & 0x0000FF00) >> 8) / 255
            alpha = CGFloat(value & 0x000000FF) / 255
        } else if trimmed.count == 6 {
            red = CGFloat((value & 0xFF0000) >> 16) / 255
            green = CGFloat((value & 0x00FF00) >> 8) / 255
            blue = CGFloat(value & 0x0000FF) / 255
            alpha = 1
        } else {
            fatalError("Unsupported hex length (expected 6 or 8 hex digits): \(hex)")
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Color dynamic helper (D4 — NSColor(name:dynamicProvider:), no asset catalog)

extension Color {
    /// Adaptive SwiftUI Color that switches on macOS appearance.
    /// Backed by NSColor(name:dynamicProvider:) per decision D4.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

// MARK: - Spacing
// Base unit: 4px. DESIGN.md § Spacing.

enum Spacing {
    // --- scale ---
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    /// DESIGN.md "2xl"
    static let xxl: CGFloat = 32
    /// DESIGN.md "3xl"
    static let xxxl: CGFloat = 48
    /// DESIGN.md "4xl"
    static let xxxxl: CGFloat = 64

    // --- derived convenience ---
    /// Window padding = xl (24). DESIGN.md § Spacing line 153.
    static let windowPadding: CGFloat = xl
    /// Prefs-row horizontal padding = lg (16). DESIGN.md § Spacing line 154.
    static let prefsRowHorizontal: CGFloat = lg
    /// Prefs-row vertical padding = md (12). DESIGN.md § Spacing line 154.
    static let prefsRowVertical: CGFloat = md
    /// Prefs-row minimum height. DESIGN.md § Spacing line 154.
    static let prefsRowMinHeight: CGFloat = 40
    /// Section gap between prefs-groups = xxl (32). DESIGN.md § Spacing line 155.
    static let sectionGap: CGFloat = xxl
    /// Capsule horizontal padding — locked off-scale. DESIGN.md § Spacing line 157.
    static let capsuleHorizontal: CGFloat = 14
}

// MARK: - Radius
// DESIGN.md § Layout — Border radius scale.

enum Radius {
    /// Recording capsule corner radius. DESIGN.md line 168.
    static let capsule: CGFloat = 14
    /// Buttons, pickers, inputs. DESIGN.md line 169.
    static let control: CGFloat = 8
    /// Window surfaces. DESIGN.md line 170.
    static let window: CGFloat = 12
    /// App artwork: 28% of width. DESIGN.md line 172.
    static let artworkPercent: CGFloat = 0.28
}

// MARK: - ButtonPadding
// Locked off-scale exception. DESIGN.md § Spacing line 156.

enum ButtonPadding {
    static let horizontal: CGFloat = 14
    static let vertical: CGFloat = 7
}

// MARK: - WindowSize
// DESIGN.md § Layout line 166.

enum WindowSize {
    static let settings = CGSize(width: 620, height: 520)
    static let about = CGSize(width: 460, height: 560)
    /// First-launch checklist window. DESIGN.md § First launch: "480px wide".
    /// Height is a sensible initial guess — SwiftUI auto-sizes the window via
    /// hosting view's fittingSize at init.
    static let firstLaunch = CGSize(width: 480, height: 400)
}

// MARK: - CapsuleSize
// DESIGN.md § Layout line 166 / Recording capsule.

enum CapsuleSize {
    static let width: CGFloat = 300
    static let height: CGFloat = 44
}

// MARK: - MenuBar
// DESIGN.md § MenuBar dropdown layout.

enum MenuBar {
    /// DESIGN.md § MenuBar dropdown layout: "280px wide".
    static let width: CGFloat = 280
    /// DESIGN.md § MenuBar dropdown layout: "radius 10".
    /// Note: MenuBarExtra(.window) window chrome provides rounded corners automatically
    /// on macOS 13+. This token is kept for reference and potential future use.
    static let cornerRadius: CGFloat = 10
    /// Tally dot diameter. DESIGN.md § MenuBar status line.
    static let tallyDotSize: CGFloat = 8
}

// MARK: - Motion
// DESIGN.md § Motion. Values in seconds for SwiftUI Animation durations.

enum Motion {
    /// 100ms — hover feedback, color transitions. DESIGN.md line 347.
    static let micro: Double = 0.1
    /// 200ms — capsule appear/dismiss, tab switching. DESIGN.md line 348.
    static let short: Double = 0.2
    /// 300ms — picker opening, segmented transitions. DESIGN.md line 349.
    static let medium: Double = 0.3
    /// 500ms — rare, cross-surface transitions only. DESIGN.md line 350.
    static let long: Double = 0.5

    /// Audio RMS amplitude threshold (range 0.0-1.0, UNITLESS, not a time duration)
    /// to trigger the recording-dot pulse. Lives under Motion alongside
    /// duration constants because DESIGN.md line 356 pins the reference path.
    /// DESIGN.md line 356: "audio crosses Tokens.Motion.waveformActivationThreshold = 0.15".
    static let waveformActivationThreshold: Double = 0.15
}

// MARK: - Typography
// DESIGN.md § Typography. One family, two cuts: Geist + Geist Mono.
//
// NOTE: Tier A Step 4/5 — vendor Geist.woff2 + Geist-Mono.woff2 into Resources/Fonts/
// and register via CTFontManagerRegisterFonts (or Bundle.main.url + NSFont registration)
// so Font.custom("Geist", ...) resolves to the actual typeface instead of falling back
// to the system font. Until then, calls below compile and behave gracefully at runtime.
//
// LINE HEIGHT USAGE: SwiftUI has no direct lineHeight modifier. Apply line heights via
// .lineSpacing(XLineHeight - pointSize) on Text, or wrap in a fixed-height frame:
//   Text("…").font(Typography.display).frame(height: Typography.displayLineHeight)
// The *LineHeight constants below capture the second number in DESIGN.md's "size/lineHeight"
// notation so call-site authors do not need to re-derive them from the spec.

enum Typography {
    /// Geist 23pt Medium. Window titles / display text. DESIGN.md line 56.
    static let display = Font.custom("Geist", size: 23).weight(.medium)
    /// Line height for display text. DESIGN.md line 56: "23/28".
    static let displayLineHeight: CGFloat = 28

    /// Geist 15pt Medium. Settings section headers. DESIGN.md line 57.
    static let sectionTitle = Font.custom("Geist", size: 15).weight(.medium)
    /// Line height for section titles. DESIGN.md line 57: "15/20".
    static let sectionTitleLineHeight: CGFloat = 20

    /// Geist 13pt Regular. Body copy, row labels. DESIGN.md line 58.
    static let body = Font.custom("Geist", size: 13).weight(.regular)
    /// Line height for body copy. DESIGN.md line 58: "13/18".
    static let bodyLineHeight: CGFloat = 18

    /// Geist 12pt Medium. Button labels. DESIGN.md line 59.
    static let buttonLabel = Font.custom("Geist", size: 12).weight(.medium)
    /// Line height for button labels. DESIGN.md line 59: "12/16".
    static let buttonLabelLineHeight: CGFloat = 16

    /// Geist 11pt Medium. Meta labels — callers apply .textCase(.uppercase)
    /// and .tracking(metaLabelTracking). DESIGN.md line 60.
    static let metaLabel = Font.custom("Geist", size: 11).weight(.medium)
    /// Tracking value for meta labels: 0.04em × 11pt = 0.44. DESIGN.md line 60.
    static let metaLabelTracking: CGFloat = 0.44
    /// Line height for meta labels. DESIGN.md line 60: "11/14".
    static let metaLabelLineHeight: CGFloat = 14

    /// Geist Mono 12pt Medium. Timers, hotkeys, model IDs.
    /// Call .monospacedDigit() at use sites for tabular figures. DESIGN.md line 61.
    static let mono = Font.custom("Geist Mono", size: 12).weight(.medium)
    /// Line height for mono text. DESIGN.md line 61: "12/16".
    static let monoLineHeight: CGFloat = 16

    /// Non-uppercase secondary caption text (row subtitles, metadata descriptions).
    /// Geist 11pt Regular. Distinct from metaLabel (Medium, uppercase-tracked).
    static let caption = Font.custom("Geist", size: 11).weight(.regular)
    /// Line height for caption text. Matches metaLabel at 14pt for vertical rhythm.
    static let captionLineHeight: CGFloat = 14

    /// Geist Mono 10pt Semibold. Numbered badges in FirstLaunchWindow.
    /// DESIGN.md § First launch: "numbered badge (Geist Mono 10/14 600 cyan-soft bg)".
    static let badge = Font.custom("Geist Mono", size: 10).weight(.semibold)
    /// Line height for badge text. DESIGN.md: "10/14".
    static let badgeLineHeight: CGFloat = 14
}

// MARK: - Palette
// DESIGN.md § Color. Adaptive via Color.dynamic(light:dark:) for themed values;
// plain Color(nsColor:) for Capsule sub-palette (identical in both modes).
//
// RGBA channel values are pre-computed decimals (e.g. 14/255 = 0.054902) to
// avoid operator_usage_whitespace violations from the N/255 arithmetic form.

enum Palette {

    // MARK: Adaptive (light / dark)

    /// App background. Dark #0B1015 / Light #F3F6F8.
    static let bgApp = Color.dynamic(
        light: NSColor(hex: "#F3F6F8"),
        dark: NSColor(hex: "#0B1015")
    )

    /// Window background. Dark #10171F / Light #FBFCFD.
    static let bgWindow = Color.dynamic(
        light: NSColor(hex: "#FBFCFD"),
        dark: NSColor(hex: "#10171F")
    )

    /// Inset surface (sidebar, code blocks). Dark #0E141B / Light #E2E9EE.
    static let surfaceInset = Color.dynamic(
        light: NSColor(hex: "#E2E9EE"),
        dark: NSColor(hex: "#0E141B")
    )

    /// Subtle stroke / default borders.
    /// Dark  rgba(255,255,255,0.08) / Light rgba(14,23,32,0.08).
    static let strokeSubtle = Color.dynamic(
        light: NSColor(srgbRed: 0.054902, green: 0.090196, blue: 0.125490, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.08)
    )

    /// Strong stroke — active-section left-edge accent + focused-control outlines.
    /// Dark  rgba(143,207,255,0.20) / Light rgba(21,159,225,0.20).
    static let strokeStrong = Color.dynamic(
        light: NSColor(srgbRed: 0.082353, green: 0.623529, blue: 0.882353, alpha: 0.20),
        dark: NSColor(srgbRed: 0.560784, green: 0.811765, blue: 1.000000, alpha: 0.20)
    )

    /// Row dividers. Dark rgba(255,255,255,0.06) / Light rgba(14,23,32,0.06).
    static let divider = Color.dynamic(
        light: NSColor(srgbRed: 0.054902, green: 0.090196, blue: 0.125490, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.06)
    )

    /// Primary text. Dark #EEF3F7 / Light #0E1720.
    static let textPrimary = Color.dynamic(
        light: NSColor(hex: "#0E1720"),
        dark: NSColor(hex: "#EEF3F7")
    )

    /// Secondary text (subtitles, body copy). Dark #C7D2DC / Light #314253.
    static let textSecondary = Color.dynamic(
        light: NSColor(hex: "#314253"),
        dark: NSColor(hex: "#C7D2DC")
    )

    /// Muted text — meta-labels ONLY (uppercase tracked 11/14). Dark #7F90A1 / Light #6E7F90.
    static let textMuted = Color.dynamic(
        light: NSColor(hex: "#6E7F90"),
        dark: NSColor(hex: "#7F90A1")
    )

    /// Electric cyan accent. Dark #59C7FF / Light #099DDF.
    static let accent = Color.dynamic(
        light: NSColor(hex: "#099DDF"),
        dark: NSColor(hex: "#59C7FF")
    )

    /// Strong accent (hover, active recording border). Dark #1AA7F6 / Light #007FC0.
    static let accentStrong = Color.dynamic(
        light: NSColor(hex: "#007FC0"),
        dark: NSColor(hex: "#1AA7F6")
    )

    /// Soft accent fill. Dark rgba(89,199,255,0.12) / Light rgba(9,157,223,0.10).
    static let accentSoft = Color.dynamic(
        light: NSColor(srgbRed: 0.035294, green: 0.615686, blue: 0.874510, alpha: 0.10),
        dark: NSColor(srgbRed: 0.349020, green: 0.780392, blue: 1.000000, alpha: 0.12)
    )

    /// Focus ring. Dark rgba(89,199,255,0.40) / Light rgba(9,157,223,0.40).
    static let focusRing = Color.dynamic(
        light: NSColor(srgbRed: 0.035294, green: 0.615686, blue: 0.874510, alpha: 0.40),
        dark: NSColor(srgbRed: 0.349020, green: 0.780392, blue: 1.000000, alpha: 0.40)
    )

    /// Success / green check. Dark #27B7A4 / Light #1FB9A7.
    static let success = Color.dynamic(
        light: NSColor(hex: "#1FB9A7"),
        dark: NSColor(hex: "#27B7A4")
    )

    /// Warning / amber. Dark #E8A93A / Light #D5972A.
    static let warning = Color.dynamic(
        light: NSColor(hex: "#D5972A"),
        dark: NSColor(hex: "#E8A93A")
    )

    /// Error / red-pink. Dark #FF7A6B / Light #D95C4F.
    static let error = Color.dynamic(
        light: NSColor(hex: "#D95C4F"),
        dark: NSColor(hex: "#FF7A6B")
    )

    // MARK: Capsule — opaque, identical in both modes. DESIGN.md § Capsule lines 121-130.

    enum Capsule {
        /// Capsule background — darkest surface, universal. #0D0D0C.
        static let bg = Color(nsColor: NSColor(hex: "#0D0D0C"))

        /// Capsule foreground text. #F0EDE8.
        static let text = Color(nsColor: NSColor(hex: "#F0EDE8"))

        /// Timer / muted text inside capsule. #9E9A94.
        static let timer = Color(nsColor: NSColor(hex: "#9E9A94"))

        /// Recording tally red. #E8423A.
        static let recording = Color(nsColor: NSColor(hex: "#E8423A"))

        /// Recording glow. rgba(232,66,58,0.35). Channels: 232=0.909804, 66=0.258824, 58=0.227451.
        static let recordingGlow = Color(nsColor: NSColor(srgbRed: 0.909804, green: 0.258824, blue: 0.227451, alpha: 0.35))

        /// Border in idle state. rgba(255,255,255,0.07).
        static let borderIdle = Color(nsColor: NSColor(white: 1, alpha: 0.07))

        /// Border during active recording. rgba(232,66,58,0.40).
        static let borderRec = Color(nsColor: NSColor(srgbRed: 0.909804, green: 0.258824, blue: 0.227451, alpha: 0.40))

        /// Border on error. rgba(255,122,107,0.50). Channels: 255=1.0, 122=0.478431, 107=0.419608.
        static let borderErr = Color(nsColor: NSColor(srgbRed: 1.000000, green: 0.478431, blue: 0.419608, alpha: 0.50))
    }
}

// swiftlint:enable inline_color_rgb inline_color_hex inline_nscolor_rgb
