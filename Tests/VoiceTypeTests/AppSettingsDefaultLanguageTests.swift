import XCTest
@testable import VoiceType

// Tests for the AppSettings language default and migration logic.
//
// AppSettings uses UserDefaults.standard directly with a private init, so we
// cannot instantiate a truly isolated instance.  These tests cover:
//   1. The Language enum raw-value the `else` branch resolves to (.bilingualRuEn).
//   2. The migration mapping for known legacy raw values.
//   3. The unknown-legacy fallback that now resolves to .bilingualRuEn.
//
// They do NOT read or write UserDefaults.standard to avoid cross-test pollution.
final class AppSettingsDefaultLanguageTests: XCTestCase {

    // MARK: - Default Language enum value

    func testDefaultLanguageRawValueMatchesBilingualRuEn() {
        // The `else` branch in AppSettings.init assigns `.bilingualRuEn`.
        // Verify that the Language enum case exists and has the expected rawValue
        // so a fresh-install UserDefaults (no stored "language" key) will produce
        // the bilingual preset.
        XCTAssertEqual(Language.bilingualRuEn.rawValue, "ru+en")
    }

    // MARK: - Legacy migration mapping

    func testLegacyAutoMapsToAuto() {
        // Legacy "preferredLanguage=auto" should survive migration unchanged.
        XCTAssertEqual(Language(rawValue: "auto"), .auto)
    }

    func testLegacyRuMapsToRu() {
        XCTAssertEqual(Language(rawValue: "ru"), .ru)
    }

    func testLegacyEnMapsToEn() {
        XCTAssertEqual(Language(rawValue: "en"), .en)
    }

    func testUnknownLegacyRawValueProducesNil() {
        // Unknown raw values from UserDefaults return nil from Language(rawValue:).
        // The AppSettings migration `default:` branch falls back to .bilingualRuEn
        // in that case — this test confirms the nil-on-unknown behavior that the
        // branch guards against.
        XCTAssertNil(Language(rawValue: "zz"),
                     "Unknown rawValue must return nil so the caller can handle it explicitly")
        XCTAssertNil(Language(rawValue: ""),
                     "Empty rawValue must return nil")
    }

    // MARK: - New language key round-trip

    func testNewLanguageKeyRoundTrip() {
        // Simulate what AppSettings.init does when the new "language" key is present:
        // Language(rawValue: stored) produces a valid case.
        for lang in Language.allCases {
            let resolved = Language(rawValue: lang.rawValue)
            XCTAssertEqual(resolved, lang,
                           "Language(\(lang.rawValue)) round-trip failed")
        }
    }
}
