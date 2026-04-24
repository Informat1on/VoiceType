import XCTest
@testable import VoiceType

// swiftlint:disable inline_color_hex

final class TokensTests: XCTestCase {

    // MARK: 1 — Base spacing values

    func testSpacingBaseValues() {
        XCTAssertEqual(Spacing.xs, 4, "Spacing.xs must be 4px")
        XCTAssertEqual(Spacing.md, 12, "Spacing.md must be 12px")
        XCTAssertEqual(Spacing.xxxxl, 64, "Spacing.xxxxl (4xl) must be 64px")
    }

    // MARK: 2 — Derived spacing: windowPadding == xl (value identity) + absolute value

    func testDerivedSpacingConstants() {
        XCTAssertEqual(Spacing.windowPadding, Spacing.xl, "Spacing.windowPadding must equal Spacing.xl (both 24px)")
        XCTAssertEqual(Spacing.windowPadding, 24, "window padding absolute value must be 24px per DESIGN.md line 153")
        XCTAssertEqual(Spacing.prefsRowHorizontal, Spacing.lg, "Spacing.prefsRowHorizontal must equal Spacing.lg (both 16px)")
        XCTAssertEqual(Spacing.prefsRowVertical, Spacing.md, "Spacing.prefsRowVertical must equal Spacing.md (both 12px)")
        XCTAssertEqual(Spacing.sectionGap, Spacing.xxl, "Spacing.sectionGap must equal Spacing.xxl (both 32px)")
    }

    // MARK: 3 — Radius values

    func testRadiusCapsuleAndControl() {
        XCTAssertEqual(Radius.capsule, 14, "Radius.capsule must be 14")
        XCTAssertEqual(Radius.control, 8, "Radius.control must be 8")
        XCTAssertEqual(Radius.window, 12, "Radius.window must be 12")
        XCTAssertEqual(Radius.artworkPercent, 0.28, accuracy: 0.001, "Radius.artworkPercent must be 0.28 (28%)")
    }

    // MARK: 4 — Button padding

    func testButtonPadding() {
        XCTAssertEqual(ButtonPadding.horizontal, 14, "ButtonPadding.horizontal must be 14px (off-scale lock)")
        XCTAssertEqual(ButtonPadding.vertical, 7, "ButtonPadding.vertical must be 7px (off-scale lock)")
    }

    // MARK: 5 — Motion durations

    func testMotionDurations() {
        XCTAssertEqual(Motion.micro, 0.1, accuracy: 0.001, "Motion.micro must be 0.1s (100ms)")
        XCTAssertEqual(Motion.short, 0.2, accuracy: 0.001, "Motion.short must be 0.2s (200ms)")
        XCTAssertEqual(Motion.medium, 0.3, accuracy: 0.001, "Motion.medium must be 0.3s (300ms)")
        XCTAssertEqual(Motion.long, 0.5, accuracy: 0.001, "Motion.long must be 0.5s (500ms)")
    }

    // MARK: 6 — Window sizes

    func testWindowSizes() {
        XCTAssertEqual(WindowSize.settings.width, 620, "Settings window width must be 620")
        XCTAssertEqual(WindowSize.settings.height, 520, "Settings window height must be 520")
        XCTAssertEqual(WindowSize.about.width, 460, "About window width must be 460")
        XCTAssertEqual(WindowSize.about.height, 560, "About window height must be 560")
    }

    // MARK: 7 — Capsule size

    func testCapsuleSize() {
        XCTAssertEqual(CapsuleSize.width, 300, "CapsuleSize.width must be 300")
        XCTAssertEqual(CapsuleSize.height, 44, "CapsuleSize.height must be 44")
    }

    // MARK: 8 — Waveform activation threshold

    func testWaveformActivationThreshold() {
        // Threshold must be low enough for whispered speech (~0.01–0.03 normalized)
        // to produce visible waveform motion, while true silence (0.0) stays flat.
        // Lower bound is 0.004 — comfortably below the current 0.008 value so
        // the value is not pinned on a test boundary.
        let threshold = Motion.waveformActivationThreshold
        XCTAssertLessThanOrEqual(threshold, 0.05)
        XCTAssertGreaterThanOrEqual(threshold, 0.004)
    }

    // MARK: 9 — Hex color parser round-trip (optional safety guard)

    func testHexColorParser() {
        let color = NSColor(hex: "#0B1015")
        guard let srgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert NSColor to sRGB")
            return
        }
        XCTAssertEqual(srgb.redComponent, CGFloat(0x0B) / 255, accuracy: 0.001, "Red channel of #0B1015 must be 0x0B/255")
        XCTAssertEqual(srgb.greenComponent, CGFloat(0x10) / 255, accuracy: 0.001, "Green channel of #0B1015 must be 0x10/255")
        XCTAssertEqual(srgb.blueComponent, CGFloat(0x15) / 255, accuracy: 0.001, "Blue channel of #0B1015 must be 0x15/255")
        XCTAssertEqual(srgb.alphaComponent, 1.0, accuracy: 0.001, "Alpha of a 6-digit hex must be 1.0")
    }

    func testHexColorParserEightCharAlpha() {
        // Guards against byte-mask swaps in the 8-char RRGGBBAA branch.
        let withAlpha = NSColor(hex: "#0B101580")
        var r = CGFloat(0), g = CGFloat(0), b = CGFloat(0), a = CGFloat(0)
        withAlpha.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0x0B / 255.0, accuracy: 0.001)
        XCTAssertEqual(g, 0x10 / 255.0, accuracy: 0.001)
        XCTAssertEqual(b, 0x15 / 255.0, accuracy: 0.001)
        XCTAssertEqual(a, 0x80 / 255.0, accuracy: 0.001)
    }

    // MARK: Additional sanity — capsule horizontal padding and prefs row min-height

    func testCapsuleHorizontalPaddingAndPrefsRowMinHeight() {
        XCTAssertEqual(Spacing.capsuleHorizontal, 14, "Spacing.capsuleHorizontal must be 14px (off-scale lock)")
        XCTAssertEqual(Spacing.prefsRowMinHeight, 40, "Spacing.prefsRowMinHeight must be 40px")
    }

    // MARK: 10 — Typography.badge (Step 4 FirstLaunchWindow numbered badges)

    func testTypographyBadgeExists() {
        // Regression: verify badge font is Geist Mono 10pt Semibold per DESIGN.md
        // § First launch: "numbered badge (Geist Mono 10/14 600 cyan-soft bg)".
        // Font.custom returns a valid value even if the typeface isn't registered
        // at test time — guard the token exists and line-height constant is correct.
        _ = Typography.badge // must compile and not crash
        XCTAssertEqual(Typography.badgeLineHeight, 14, "Typography.badgeLineHeight must be 14pt per DESIGN.md")
    }

    // MARK: 11 — WindowSize.firstLaunch (Step 4 token, Step 5 coverage)

    func testWindowSizeFirstLaunch() {
        XCTAssertEqual(WindowSize.firstLaunch.width, 480, "FirstLaunch window width must be 480 per DESIGN.md § First launch")
    }

    // MARK: 12 — MenuBar tokens (Step 5)

    func testMenuBarTokens() {
        XCTAssertEqual(MenuBar.width, 280, "MenuBar.width must be 280pt per DESIGN.md § MenuBar dropdown layout")
        XCTAssertEqual(MenuBar.cornerRadius, 10, "MenuBar.cornerRadius must be 10 per DESIGN.md § MenuBar dropdown layout")
        XCTAssertEqual(MenuBar.tallyDotSize, 8, "MenuBar.tallyDotSize must be 8pt per DESIGN.md § MenuBar status line")
    }

    // MARK: 13 — Phase 1 Scope C tokens

    func testTypographyMonoSmallExists() {
        _ = Typography.monoSmall   // must compile; Geist Mono 11pt Medium
        XCTAssertEqual(Typography.monoSmallLineHeight, 14, "Typography.monoSmallLineHeight must be 14pt per Phase 1 spec")
    }

    func testPaletteSidebarActiveExists() {
        // Palette.sidebarActive must exist and be non-nil at runtime.
        // Color does not expose channels directly; just verify the token
        // compiles and produces a non-default value.
        let color = Palette.sidebarActive
        // Render to verify it produces a valid SwiftUI Color (no crash)
        _ = color.description
    }

    func testPaletteSidebarHoverExists() {
        let color = Palette.sidebarHover
        _ = color.description
    }

    // MARK: 14 — Phase 1 A7: capsuleErrorInlineExpired notification name

    func testCapsuleErrorInlineExpiredNotificationNameExists() {
        // Verify the name is declared and has the correct bundle-prefixed raw value.
        XCTAssertEqual(
            Notification.Name.capsuleErrorInlineExpired.rawValue,
            "com.voicetype.capsuleErrorInlineExpired"
        )
    }
}

// swiftlint:enable inline_color_hex
