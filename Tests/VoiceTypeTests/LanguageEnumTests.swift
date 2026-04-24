import XCTest
@testable import VoiceType

final class LanguageEnumTests: XCTestCase {

    // MARK: - Raw value stability

    func testEveryCaseHasStableRawValue() {
        XCTAssertEqual(Language.auto.rawValue, "auto")
        XCTAssertEqual(Language.ru.rawValue, "ru")
        XCTAssertEqual(Language.en.rawValue, "en")
        XCTAssertEqual(Language.bilingualRuEn.rawValue, "ru+en")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for lang in Language.allCases {
            let data = try encoder.encode(lang)
            let decoded = try decoder.decode(Language.self, from: data)
            XCTAssertEqual(decoded, lang, "Round-trip failed for \(lang)")
        }
    }

    // MARK: - WhisperLanguage mapping

    func testWhisperLanguageMapping() {
        XCTAssertNil(Language.auto.whisperLanguage,
                     ".auto must map to nil (detect_language = true)")
        XCTAssertEqual(Language.ru.whisperLanguage, .russian)
        XCTAssertEqual(Language.en.whisperLanguage, .english)
        // .bilingualRuEn must pin to .russian, not auto-detect
        XCTAssertEqual(Language.bilingualRuEn.whisperLanguage, .russian)
    }

    // MARK: - Bilingual prompt flag

    func testUsesBilingualPromptOnlyForBilingualRuEn() {
        XCTAssertFalse(Language.auto.usesBilingualPrompt)
        XCTAssertFalse(Language.ru.usesBilingualPrompt)
        XCTAssertFalse(Language.en.usesBilingualPrompt)
        XCTAssertTrue(Language.bilingualRuEn.usesBilingualPrompt)
    }

    // MARK: - Display names

    func testEveryDisplayNameIsNonEmpty() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.displayName.isEmpty, "\(lang).displayName must not be empty")
        }
    }

    // MARK: - CaseIterable completeness

    func testAllCasesContainsExpectedCount() {
        // If a new case is added this test reminds us to update tests too.
        XCTAssertEqual(Language.allCases.count, 4)
    }

    // MARK: - Legacy migration (UserDefaults injection)
    // Full migration path testing requires UserDefaults injection which is not yet
    // wired into AppSettings (AppSettings uses UserDefaults.standard directly).
    // The migration logic is covered by code review and will be exercised by
    // the integration test suite once UserDefaults injection is available (future work).
}
