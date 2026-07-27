// WhisperTokenizerTests.swift — VoiceType
//
// Golden-fixture test for WhisperTokenizer + behavioral tests for
// PromptBudget. The fixture (Tests/Fixtures/whisper-tokenizer-golden.json)
// was captured from the REAL whisper_tokenize in whisper.cpp v1.9.1 — every
// case's `ids` sequence, not just its `count`, must match exactly.
//
// The test target has no declared resources (Package.swift intentionally
// does not add any — see task notes), so there is no Bundle.module for
// VoiceTypeTests. The fixture is located relative to #filePath instead.
import XCTest
@testable import VoiceType

final class WhisperTokenizerTests: XCTestCase {

    // MARK: - Golden fixture

    private struct GoldenCase: Decodable {
        let text: String
        let count: Int
        let ids: [Int]
    }

    private struct GoldenFixture: Decodable {
        let cases: [GoldenCase]
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WhisperTokenizerTests.swift -> VoiceTypeTests
            .deletingLastPathComponent() // VoiceTypeTests -> Tests
            .appendingPathComponent("Fixtures/whisper-tokenizer-golden.json")
    }

    private static let fixture: GoldenFixture = {
        let data = try! Data(contentsOf: fixtureURL) // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(GoldenFixture.self, from: data) // swiftlint:disable:this force_try
    }()

    func testTokenizerIsReady() {
        XCTAssertTrue(WhisperTokenizer.shared.isReady, "vocabulary resource must load for the golden test to be meaningful")
    }

    func testGoldenFixtureMatchesExactly() {
        let tokenizer = WhisperTokenizer.shared
        let cases = Self.fixture.cases
        XCTAssertFalse(cases.isEmpty)

        for (index, testCase) in cases.enumerated() {
            let ids = tokenizer.tokenize(testCase.text)
            let label = "case \(index) (\"\(testCase.text.prefix(40))\")"
            XCTAssertEqual(ids, testCase.ids, "\(label): id sequence mismatch")
            XCTAssertEqual(ids.count, testCase.count, "\(label): count mismatch")
        }
    }

    func testEmptyStringTokenizesToNothing() {
        XCTAssertEqual(WhisperTokenizer.shared.tokenize(""), [])
        XCTAssertEqual(WhisperTokenizer.shared.count(""), 0)
    }

    // MARK: - PromptBudget

    func testEvaluateWithinLimit() {
        let evaluation = PromptBudget.evaluate(seed: "", vocabulary: "I use Codex and Fable daily.")
        XCTAssertFalse(evaluation.isOverflowing)
        XCTAssertEqual(evaluation.overflow, 0)
        XCTAssertTrue(evaluation.isExact)
        XCTAssertEqual(evaluation.limit, PromptBudget.limit)
    }

    func testEvaluateOverLimit() {
        let longVocabulary = Array(repeating: "тест", count: 500).joined(separator: " ")
        let evaluation = PromptBudget.evaluate(seed: "", vocabulary: longVocabulary)
        XCTAssertTrue(evaluation.isOverflowing)
        XCTAssertGreaterThan(evaluation.overflow, 0)
        XCTAssertEqual(evaluation.totalTokens - evaluation.overflow, PromptBudget.limit)
    }

    @MainActor
    func testEvaluateSeedEatsIntoBudget() {
        let seed = TranscriptionService.bilingualSeed
        let withSeed = PromptBudget.evaluate(seed: seed, vocabulary: "")
        let withoutSeed = PromptBudget.evaluate(seed: "", vocabulary: "")
        XCTAssertGreaterThan(withSeed.seedTokens, 0)
        XCTAssertEqual(withoutSeed.seedTokens, 0)
        XCTAssertEqual(withSeed.totalTokens, withSeed.seedTokens)
    }

    func testEvaluateEmptySeedAndVocabularyIsZero() {
        let evaluation = PromptBudget.evaluate(seed: "", vocabulary: "")
        XCTAssertEqual(evaluation.totalTokens, 0)
        XCTAssertEqual(evaluation.seedTokens, 0)
        XCTAssertFalse(evaluation.isOverflowing)
    }

    // MARK: - fullPrompt / applyInitialPrompt parity

    /// Guards the exact regression PromptBudget.fullPrompt was extracted to
    /// prevent: TranscriptionService.applyInitialPrompt() building the join
    /// inline again and silently drifting from what PromptBudget (and the
    /// on-screen counter) computes. Drives the real applyInitialPrompt()
    /// path through AppSettings, the same way BilingualPromptTests does.
    @MainActor
    func testFullPromptMatchesApplyInitialPrompt() {
        let service = TranscriptionService()
        let savedLanguage = AppSettings.shared.language
        let savedVocabulary = AppSettings.shared.customVocabulary
        defer {
            AppSettings.shared.language = savedLanguage
            AppSettings.shared.customVocabulary = savedVocabulary
        }

        AppSettings.shared.language = .bilingualRuEn
        AppSettings.shared.customVocabulary = "Codex, Fable, редмайн"

        service.applyInitialPrompt()

        let expected = PromptBudget.fullPrompt(
            seed: TranscriptionService.bilingualSeed,
            vocabulary: "Codex, Fable, редмайн"
        )
        XCTAssertEqual(service.currentInitialPromptText, expected)
    }

    // MARK: - Широкая сверка (офлайн-харнесс)

    /// Сверка на произвольно большом наборе строк, снятом настоящим
    /// `whisper_tokenize`.
    ///
    /// Зачем помимо golden-фикстуры: та содержит 58 синтетических строк, потому
    /// что репозиторий публичный и речь владельца в него не коммитится. Главный
    /// риск реализации — кириллица, которая в whisper.cpp уходит в ветку
    /// «не-буквы» из-за ASCII-локали `std::regex`, и проверять её надо на
    /// реальной речи, а не только на подобранных примерах.
    ///
    /// Файл готовится спайком `docs/dev-diary/session8-artifacts/spikes/tokcount.c`
    /// и остаётся вне git. Формат — JSONL: `{"text": "...", "count": N, "ids": [...]}`.
    ///
    ///     VOICETYPE_TOKENIZER_GOLDEN=/path/to/tokenizer-wide.jsonl \
    ///       swift test --filter testWideCorpusMatchesRealTokenizer
    func testWideCorpusMatchesRealTokenizer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VOICETYPE_TOKENIZER_GOLDEN"] else {
            throw XCTSkip("VOICETYPE_TOKENIZER_GOLDEN not set — offline harness only")
        }

        struct Row: Decodable {
            let text: String
            let count: Int
            let ids: [Int]
        }

        let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let decoder = JSONDecoder()
        let rows: [Row] = try content
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(Row.self, from: Data($0.utf8)) }

        XCTAssertFalse(rows.isEmpty, "харнесс запущен, но файл пуст: \(path)")

        var mismatches = 0
        for (index, row) in rows.enumerated() {
            let ids = WhisperTokenizer.shared.tokenize(row.text)
            if ids != row.ids || ids.count != row.count {
                mismatches += 1
                if mismatches <= 5 {
                    XCTFail("строка \(index) (\"\(row.text.prefix(50))\"): "
                        + "получено \(ids.count) токенов, ожидалось \(row.count)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "расхождений с настоящим токенизатором: \(mismatches) из \(rows.count)")
    }
}
