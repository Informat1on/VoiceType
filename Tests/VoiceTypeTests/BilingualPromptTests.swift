import XCTest
@testable import VoiceType

// Tests for bilingual prompt plumbing in TranscriptionService.
//
// TranscriptionService.applyInitialPrompt() reads AppSettings.shared, so these
// tests mutate AppSettings.shared.language / .customVocabulary and assert the
// resulting currentInitialPromptText that would be passed to whisper.cpp.
//
// We do NOT load a real whisper model — we only verify the string composition
// logic and the strdup/free lifecycle that setInitialPrompt exercises.
@MainActor
final class BilingualPromptTests: XCTestCase {

    private var service: TranscriptionService!
    private var savedLanguage: Language!
    private var savedVocabulary: String!

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptionService()
        // Snapshot AppSettings state so we can restore after each test.
        savedLanguage = AppSettings.shared.language
        savedVocabulary = AppSettings.shared.customVocabulary
    }

    override func tearDown() async throws {
        // Restore AppSettings to avoid cross-test contamination.
        AppSettings.shared.language = savedLanguage
        AppSettings.shared.customVocabulary = savedVocabulary
        service = nil
        try await super.tearDown()
    }

    // MARK: - Seed present when usesBilingualPrompt is true

    func testBilingualSeedAppliedWhenUsesBilingualPromptTrue() {
        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()

        let prompt = service.currentInitialPromptText
        XCTAssertNotNil(prompt, "Expected a non-nil prompt for .bilingualRuEn")
        XCTAssertTrue(
            prompt?.contains(TranscriptionService.bilingualSeed) == true,
            "Expected bilingual seed in prompt, got: \(prompt ?? "nil")"
        )
    }

    // MARK: - Seed absent for single-language modes

    func testBilingualSeedNotAppliedForRussianOnly() {
        AppSettings.shared.language = .ru
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()

        let prompt = service.currentInitialPromptText
        // No custom vocabulary + no seed => nil prompt
        XCTAssertNil(prompt,
                     "Expected nil prompt for .ru with no custom vocabulary, got: \(prompt ?? "nil")")
    }

    func testBilingualSeedNotAppliedForAuto() {
        AppSettings.shared.language = .auto
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()

        XCTAssertNil(service.currentInitialPromptText,
                     ".auto with no vocabulary must produce nil prompt")
    }

    func testBilingualSeedNotAppliedForEnglish() {
        AppSettings.shared.language = .en
        AppSettings.shared.customVocabulary = ""

        service.applyInitialPrompt()

        XCTAssertNil(service.currentInitialPromptText,
                     ".en with no vocabulary must produce nil prompt")
    }

    // MARK: - Seed + custom vocabulary combined

    func testBilingualSeedPrependedToCustomVocabulary() {
        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = "SwiftUI, Combine"

        service.applyInitialPrompt()

        let prompt = service.currentInitialPromptText
        XCTAssertNotNil(prompt)
        // Seed must come before user vocabulary, separated by " | "
        XCTAssertTrue(
            prompt?.contains(TranscriptionService.bilingualSeed) == true,
            "Seed must be present in combined prompt"
        )
        XCTAssertTrue(
            prompt?.contains("SwiftUI, Combine") == true,
            "Custom vocabulary must be present in combined prompt"
        )
        // Order: seed | user vocab
        if let p = prompt,
           let seedRange = p.range(of: TranscriptionService.bilingualSeed),
           let userRange = p.range(of: "SwiftUI, Combine") {
            XCTAssertLessThan(seedRange.lowerBound, userRange.lowerBound,
                              "Seed must appear before custom vocabulary in the combined prompt")
        }
    }

    func testCustomVocabularyAloneWhenSeedNotActive() {
        AppSettings.shared.language = .ru
        AppSettings.shared.customVocabulary = "SwiftUI, Combine"

        service.applyInitialPrompt()

        let prompt = service.currentInitialPromptText
        XCTAssertEqual(prompt, "SwiftUI, Combine",
                       "For non-bilingual language, only custom vocabulary should be used")
    }

    // MARK: - Idempotency

    func testApplyInitialPromptIsIdempotent() {
        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = "Xcode"

        service.applyInitialPrompt()
        let first = service.currentInitialPromptText

        service.applyInitialPrompt()
        let second = service.currentInitialPromptText

        XCTAssertEqual(first, second, "Repeated applyInitialPrompt must produce the same result")
    }

    // MARK: - Seed constant sanity

    func testBilingualSeedIsNonEmpty() {
        XCTAssertFalse(TranscriptionService.bilingualSeed.isEmpty,
                       "bilingualSeed must not be empty")
    }

    func testBilingualSeedContainsCyrillicAndLatin() {
        let seed = TranscriptionService.bilingualSeed
        let hasCyrillic = seed.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(scalar.value)
        }
        let hasLatin = seed.unicodeScalars.contains { scalar in
            (0x0041...0x007A).contains(scalar.value)
        }
        XCTAssertTrue(hasCyrillic, "bilingualSeed must contain Cyrillic characters")
        XCTAssertTrue(hasLatin, "bilingualSeed must contain Latin characters")
    }
}
