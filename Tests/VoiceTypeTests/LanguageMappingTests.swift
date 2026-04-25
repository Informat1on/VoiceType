import XCTest
import SwiftWhisper
@testable import VoiceType

// Tests for Language.auto behavior audit (Chunk V — 2026-04-25).
//
// Regression guard: verifies the DESIGN.md Language Mapping table is correctly
// implemented and that switching from .bilingualRuEn → .auto never leaks the
// bilingual initial_prompt into the subsequent transcription.
//
// We do NOT load a real whisper model.  All assertions target:
//   - Language enum computed properties (pure Swift, no model needed)
//   - TranscriptionService.applyInitialPrompt() / setInitialPrompt() (string
//     composition + C-string lifecycle, exercised without a loaded Whisper instance)
//   - applyRuntimeConfiguration() is NOT tested here because it requires a live
//     Whisper object (needs a .bin model file) — that path is covered by the
//     existing integration build + code review per ADR 2026-04-25.
@MainActor
final class LanguageMappingTests: XCTestCase {

    private var service: TranscriptionService!
    private var savedLanguage: Language!
    private var savedVocabulary: String!

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptionService()
        savedLanguage = AppSettings.shared.language
        savedVocabulary = AppSettings.shared.customVocabulary
    }

    override func tearDown() async throws {
        AppSettings.shared.language = savedLanguage
        AppSettings.shared.customVocabulary = savedVocabulary
        service = nil
        try await super.tearDown()
    }

    // MARK: - Table-driven: all 4 cases against DESIGN.md spec

    /// Asserts the DESIGN.md "Language Mapping" table is implemented correctly
    /// for every enum case.  If a new case is added without updating this table,
    /// the count guard in LanguageEnumTests will catch it first.
    func testEachLanguageMapsToExpectedWhisperConfig() {
        struct Row {
            let language: Language
            let expectedWhisperLanguage: WhisperLanguage?
            let expectedUsesBilingualPrompt: Bool
            let description: String
        }

        let table: [Row] = [
            Row(
                language: .auto,
                expectedWhisperLanguage: nil,         // nil => detect_language = true
                expectedUsesBilingualPrompt: false,
                description: ".auto → nil whisperLanguage, no bilingual prompt"
            ),
            Row(
                language: .ru,
                expectedWhisperLanguage: .russian,
                expectedUsesBilingualPrompt: false,
                description: ".ru → .russian, no bilingual prompt"
            ),
            Row(
                language: .en,
                expectedWhisperLanguage: .english,
                expectedUsesBilingualPrompt: false,
                description: ".en → .english, no bilingual prompt"
            ),
            Row(
                language: .bilingualRuEn,
                expectedWhisperLanguage: .russian,    // pinned to ru; NOT auto
                expectedUsesBilingualPrompt: true,
                description: ".bilingualRuEn → .russian, bilingual prompt active"
            )
        ]

        for row in table {
            XCTAssertEqual(
                row.language.whisperLanguage,
                row.expectedWhisperLanguage,
                "\(row.description): whisperLanguage mismatch"
            )
            XCTAssertEqual(
                row.language.usesBilingualPrompt,
                row.expectedUsesBilingualPrompt,
                "\(row.description): usesBilingualPrompt mismatch"
            )
        }
    }

    // MARK: - Concern 1: switch from .bilingualRuEn → .auto clears prompt

    /// When user switches from .bilingualRuEn to .auto with no custom vocabulary,
    /// applyInitialPrompt() must produce a nil prompt — bilingual seed must NOT
    /// carry over.
    func testSwitchFromBilingualToAutoClearsPrompt() {
        // Arrange: start in bilingual mode, apply its prompt
        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = ""
        service.applyInitialPrompt()
        XCTAssertNotNil(
            service.currentInitialPromptText,
            "Pre-condition: bilingual mode must set a non-nil prompt"
        )

        // Act: switch to .auto and re-apply
        AppSettings.shared.language = .auto
        service.applyInitialPrompt()

        // Assert: prompt must be cleared
        XCTAssertNil(
            service.currentInitialPromptText,
            "After switching .bilingualRuEn → .auto, prompt must be nil (no leakage)"
        )
    }

    /// Same switch but with a custom vocabulary present: prompt should retain
    /// only the vocabulary, NOT the bilingual seed.
    func testSwitchFromBilingualToAutoKeepsCustomVocabularyOnly() {
        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = "Xcode, SwiftUI"
        service.applyInitialPrompt()

        // Switch to .auto
        AppSettings.shared.language = .auto
        service.applyInitialPrompt()

        let prompt = service.currentInitialPromptText
        XCTAssertEqual(
            prompt,
            "Xcode, SwiftUI",
            ".auto with custom vocabulary must pass through vocabulary only (no seed)"
        )
        XCTAssertFalse(
            prompt?.contains(TranscriptionService.bilingualSeed) == true,
            "Bilingual seed must NOT appear in the prompt after switching to .auto"
        )
    }

    // MARK: - Concern 1 (inverse): switch from .auto → .bilingualRuEn adds seed

    func testSwitchFromAutoToBilingualAddsSeed() {
        AppSettings.shared.language = .auto
        AppSettings.shared.customVocabulary = ""
        service.applyInitialPrompt()
        XCTAssertNil(
            service.currentInitialPromptText,
            "Pre-condition: .auto with no vocabulary must produce nil prompt"
        )

        AppSettings.shared.language = .bilingualRuEn
        service.applyInitialPrompt()

        XCTAssertTrue(
            service.currentInitialPromptText?.contains(TranscriptionService.bilingualSeed) == true,
            "After switching .auto → .bilingualRuEn, bilingual seed must be present"
        )
    }

    // MARK: - Concern 1: .auto mode never sets bilingual prompt (standalone)

    /// applyInitialPrompt() with .auto language must always produce nil prompt
    /// regardless of prior state.
    func testAutoModeNeverSetsBilingualPrompt() {
        AppSettings.shared.language = .auto
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()

        XCTAssertNil(
            service.currentInitialPromptText,
            ".auto mode with no custom vocabulary must never set a bilingual prompt"
        )
        XCTAssertFalse(
            service.currentInitialPromptText?.contains(TranscriptionService.bilingualSeed) == true,
            "Bilingual seed must never appear when language is .auto"
        )
    }

    // MARK: - Concern 2: .auto maps to WhisperLanguage.auto (string "auto")

    /// whisper.cpp accepts "auto", nullptr, or empty string for language-auto-detect.
    /// Our wiring passes WhisperLanguage.auto (rawValue = "auto") which is valid per
    /// whisper.cpp:3907: strcmp(params.language, "auto") == 0 triggers auto-detect.
    /// This test guards that the mapping is preserved and Language.auto.whisperLanguage
    /// is nil (which causes applyRuntimeConfiguration to set .auto + detect_language=true).
    func testAutoModeProducesAutoDetectParam() {
        // Language.auto.whisperLanguage must be nil — this is what drives
        // detect_language = true in applyRuntimeConfiguration.
        XCTAssertNil(
            Language.auto.whisperLanguage,
            "Language.auto.whisperLanguage must be nil to trigger detect_language=true"
        )

        // The fallback used when whisperLanguage is nil must be WhisperLanguage.auto
        // (rawValue = "auto"), which whisper.cpp accepts as auto-detect.
        let fallback = Language.auto.whisperLanguage ?? .auto
        XCTAssertEqual(
            fallback,
            .auto,
            "Fallback for nil whisperLanguage must be WhisperLanguage.auto"
        )
        XCTAssertEqual(
            fallback.rawValue,
            "auto",
            "WhisperLanguage.auto.rawValue must be \"auto\" — the string whisper.cpp recognizes"
        )
    }

    // MARK: - whisper.cpp auto-detect string convention guard

    /// Documents and guards that WhisperLanguage.auto.rawValue == "auto".
    /// whisper.cpp:3907 explicitly checks strcmp(params.language, "auto") == 0
    /// as one of its three auto-detect triggers.  If SwiftWhisper ever changes
    /// this rawValue the C-layer contract silently breaks.
    func testWhisperLanguageAutoRawValueIsAutoString() {
        XCTAssertEqual(
            WhisperLanguage.auto.rawValue,
            "auto",
            "WhisperLanguage.auto.rawValue must remain \"auto\" — whisper.cpp:3907 depends on this string"
        )
    }

    // MARK: - Concern 2: detect_language flag derivation is correct per case

    /// detect_language = (whisperLanguage == nil).  Only .auto must trigger it;
    /// all fixed-language cases must NOT.
    func testDetectLanguageFlagDerivationPerCase() {
        for lang in Language.allCases {
            let shouldDetect = lang.whisperLanguage == nil
            if lang == .auto {
                XCTAssertTrue(
                    shouldDetect,
                    ".auto must derive detect_language=true (whisperLanguage is nil)"
                )
            } else {
                XCTAssertFalse(
                    shouldDetect,
                    "\(lang) must derive detect_language=false (whisperLanguage is non-nil)"
                )
            }
        }
    }

    // MARK: - Idempotency: repeated applyInitialPrompt calls are stable

    func testApplyInitialPromptIdempotentForAuto() {
        AppSettings.shared.language = .auto
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()
        let first = service.currentInitialPromptText

        service.applyInitialPrompt()
        let second = service.currentInitialPromptText

        XCTAssertEqual(first, second, "Repeated applyInitialPrompt for .auto must be idempotent")
    }
}
