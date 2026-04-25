// FontRegistrationTests.swift — Tier A Step 14 (accelerated)
//
// Verifies that Geist and Geist Mono TTFs are bundled and register correctly
// so that Font.custom("Geist", ...) resolves to the actual typeface.
// DESIGN.md § Typography: vendor Geist + Geist Mono into Resources/Fonts/.
//
// Bundle strategy: SPM test targets run without NSApplication, so Bundle.main
// is the test runner, not the VoiceType app bundle. Resources live in
// VoiceType_VoiceType.bundle, accessible via Bundle.module (the SPM-generated
// resource accessor for the VoiceType target). We use Bundle.module via
// the voiceTypeResourceBundle() helper which resolves the correct bundle.

import XCTest
import AppKit
import CoreText
@testable import VoiceType

final class FontRegistrationTests: XCTestCase {

    // MARK: - Bundle presence

    func testGeistRegularIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "Geist-Regular", withExtension: "ttf"),
            "Geist-Regular.ttf must be present in VoiceType resource bundle"
        )
    }

    func testGeistMediumIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "Geist-Medium", withExtension: "ttf"),
            "Geist-Medium.ttf must be present in VoiceType resource bundle"
        )
    }

    func testGeistSemiBoldIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "Geist-SemiBold", withExtension: "ttf"),
            "Geist-SemiBold.ttf must be present in VoiceType resource bundle"
        )
    }

    func testGeistMonoRegularIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "GeistMono-Regular", withExtension: "ttf"),
            "GeistMono-Regular.ttf must be present in VoiceType resource bundle"
        )
    }

    func testGeistMonoMediumIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "GeistMono-Medium", withExtension: "ttf"),
            "GeistMono-Medium.ttf must be present in VoiceType resource bundle"
        )
    }

    func testGeistMonoSemiBoldIsBundled() {
        XCTAssertNotNil(
            voiceTypeResourceBundle().url(forResource: "GeistMono-SemiBold", withExtension: "ttf"),
            "GeistMono-SemiBold.ttf must be present in VoiceType resource bundle"
        )
    }

    // MARK: - Registration + family resolution

    /// Register all bundled fonts for the test process, then assert that
    /// NSFont(name:size:) resolves non-nil for the Geist family.
    /// Note: CTFontManagerRegisterFontsForURL with .process scope is idempotent
    /// (code 105 = already registered is benign).
    func testGeistFamilyResolvesAfterRegistration() {
        registerFontsForTesting()

        // Font.custom("Geist", ...) uses the PostScript family name.
        // Geist TTFs expose PostScript family "Geist" with weights via subfamily.
        let font = NSFont(name: "Geist-Regular", size: 13)
        XCTAssertNotNil(font, "NSFont(name:\"Geist-Regular\", size:13) must return non-nil after registration")
    }

    func testGeistMonoFamilyResolvesAfterRegistration() {
        registerFontsForTesting()

        let font = NSFont(name: "GeistMono-Regular", size: 12)
        XCTAssertNotNil(font, "NSFont(name:\"GeistMono-Regular\", size:12) must return non-nil after registration")
    }

    func testGeistMediumResolvesAfterRegistration() {
        registerFontsForTesting()

        let font = NSFont(name: "Geist-Medium", size: 13)
        XCTAssertNotNil(font, "NSFont(name:\"Geist-Medium\", size:13) must return non-nil after registration")
    }

    func testGeistMonoMediumResolvesAfterRegistration() {
        registerFontsForTesting()

        let font = NSFont(name: "GeistMono-Medium", size: 12)
        XCTAssertNotNil(font, "NSFont(name:\"GeistMono-Medium\", size:12) must return non-nil after registration")
    }

    func testGeistMonoSemiBoldResolvesAfterRegistration() {
        registerFontsForTesting()

        let font = NSFont(name: "GeistMono-SemiBold", size: 12)
        XCTAssertNotNil(font, "NSFont(name:\"GeistMono-SemiBold\", size:12) must return non-nil after registration")
    }

    // MARK: - File size sanity (guards against HTML redirect pages being saved as .ttf)

    func testFontFileSizesAreReasonable() throws {
        let fontNames = [
            "Geist-Regular", "Geist-Medium", "Geist-SemiBold",
            "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"
        ]
        let bundle = voiceTypeResourceBundle()
        for name in fontNames {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else {
                XCTFail("Font file missing: \(name).ttf")
                continue
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 40_000, "\(name).ttf is only \(size) bytes — likely an HTML redirect, not a real TTF")
        }
    }

    // MARK: - Helpers

    /// Resolve the VoiceType resource bundle at test time.
    /// SPM builds a `VoiceType_VoiceType.bundle` next to the test executable;
    /// Bundle.module (generated by SPM) finds it via mainPath or buildPath.
    private func voiceTypeResourceBundle() -> Bundle {
        // Bundle.module is generated by SPM's resource_bundle_accessor.swift
        // into the VoiceType target. It resolves VoiceType_VoiceType.bundle
        // at the build-output path, which is present during `swift test`.
        return Bundle.module
    }

    /// Register all bundled Geist fonts for the test process.
    /// Mirrors AppDelegate.registerEmbeddedFonts() without going through NSApplication.
    private func registerFontsForTesting() {
        let fontNames = [
            "Geist-Regular", "Geist-Medium", "Geist-SemiBold",
            "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"
        ]
        let bundle = voiceTypeResourceBundle()
        for name in fontNames {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Ignore errors — code 105 (already registered) is benign.
        }
    }
}
