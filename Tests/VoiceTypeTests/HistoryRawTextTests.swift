// HistoryRawTextTests.swift — VoiceType
//
// Unit tests for the pre-normalizer rawText/pipelineStamp fields added to
// HistoryStore.Entry (task t-raw-text, 2026-07-27). Split out of
// HistoryStoreTests.swift, which already exceeds the file_length lint budget.
//
// Covers: legacy-JSONL decode, survival through the three Entry mutation
// helpers (the main risk — each rebuilds the struct field-by-field), a full
// write/flush/reload disk round trip, pipelineStamp determinism, and the
// rawText collapse-to-nil-when-equal rule.

import XCTest
@testable import VoiceType

@MainActor
final class HistoryRawTextTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url)
        return (store, url)
    }

    // MARK: - testLegacyLineDecodesNewFieldsAsNil

    /// A JSONL line written before rawText/pipelineStamp existed must still
    /// decode — the whole point of adding these as optionals with no custom
    /// CodingKeys is that old history files never need migrating.
    func testLegacyLineDecodesNewFieldsAsNil() throws {
        let legacyLine = """
        {"id":"\(UUID().uuidString)","timestamp":"2024-01-01T00:00:00Z","text":"legacy entry","charCount":12,"targetAppName":"TestApp","language":"en"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryStore.Entry.self, from: Data(legacyLine.utf8))

        XCTAssertEqual(entry.text, "legacy entry")
        XCTAssertNil(entry.rawText, "Legacy lines never had rawText — must decode as nil")
        XCTAssertNil(entry.pipelineStamp, "Legacy lines never had pipelineStamp — must decode as nil")
    }

    // MARK: - testWithInsertOutcomePreservesNewFields

    /// withInsertOutcome is called milliseconds after the entry is created
    /// (HistoryRecorder.recordOutcome) — if it drops rawText/pipelineStamp
    /// while rebuilding the struct, every entry loses them almost immediately.
    func testWithInsertOutcomePreservesNewFields() {
        let entry = HistoryStore.Entry(
            text: "trimmed",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            rawText: "trimmed  ",
            pipelineStamp: "n0:pabc123abc123"
        )
        let updated = entry.withInsertOutcome(true)

        XCTAssertEqual(updated.rawText, "trimmed  ")
        XCTAssertEqual(updated.pipelineStamp, "n0:pabc123abc123")
        XCTAssertEqual(updated.insertSuccess, true)
    }

    // MARK: - testWithEvalSavedPreservesNewFields

    func testWithEvalSavedPreservesNewFields() {
        let entry = HistoryStore.Entry(
            text: "trimmed",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            rawText: "trimmed  ",
            pipelineStamp: "n0:pabc123abc123"
        )
        let updated = entry.withEvalSaved(correction: "corrected text")

        XCTAssertEqual(updated.rawText, "trimmed  ")
        XCTAssertEqual(updated.pipelineStamp, "n0:pabc123abc123")
        XCTAssertEqual(updated.userCorrection, "corrected text")
    }

    // MARK: - testWithAudioPathClearedPreservesNewFields

    func testWithAudioPathClearedPreservesNewFields() {
        let entry = HistoryStore.Entry(
            text: "trimmed",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: "abc.caf",
            rawText: "trimmed  ",
            pipelineStamp: "n0:pabc123abc123"
        )
        let updated = entry.withAudioPathCleared()

        XCTAssertNil(updated.audioPath, "Sanity check: this helper's own job must still work")
        XCTAssertEqual(updated.rawText, "trimmed  ")
        XCTAssertEqual(updated.pipelineStamp, "n0:pabc123abc123")
    }

    // MARK: - testNewFieldsSurviveFlushAndReload

    func testNewFieldsSurviveFlushAndReload() throws {
        let (store1, url) = try makeStore()
        let entry = HistoryStore.Entry(
            text: "trimmed",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            rawText: "trimmed  ",
            pipelineStamp: "n0:pabc123abc123"
        )
        store1.append(entry)

        // Fresh HistoryStore instance pointed at the same file — proves the
        // round trip goes through the real JSONL encode/decode path, not
        // just the in-memory cache.
        let store2 = HistoryStore.test(storeURL: url)
        let loaded = store2.entries().first
        XCTAssertEqual(loaded?.rawText, "trimmed  ")
        XCTAssertEqual(loaded?.pipelineStamp, "n0:pabc123abc123")
    }

    // MARK: - testPipelineStampIsDeterministic

    /// The stamp is persisted and compared across app launches — it must not
    /// depend on process-specific seeding (ruling out Swift.Hasher, which is
    /// randomly seeded per launch; CryptoKit.SHA256 is the mandated fix).
    func testPipelineStampIsDeterministic() {
        // Golden values, not just self-consistency. Comparing two stamps taken
        // in the SAME process passes even with Swift.Hasher — the very thing
        // this test exists to rule out. These literals are SHA-256 prefixes of
        // the prompt string ("" for nil), independently computed outside Swift;
        // they pin the algorithm, so switching to a seeded hash breaks here.
        XCTAssertEqual(
            TranscriptionService.pipelineStamp(forPrompt: "same prompt"), "n0:p66fddd00ccb8")
        XCTAssertEqual(TranscriptionService.pipelineStamp(forPrompt: nil), "n0:pe3b0c44298fc")

        let stampA1 = TranscriptionService.pipelineStamp(forPrompt: "same prompt")
        let stampA2 = TranscriptionService.pipelineStamp(forPrompt: "same prompt")
        XCTAssertEqual(stampA1, stampA2, "Same prompt must always produce the same stamp")

        let stampB = TranscriptionService.pipelineStamp(forPrompt: "different prompt")
        XCTAssertNotEqual(stampA1, stampB, "Different prompts must produce different stamps")

        let stampNil1 = TranscriptionService.pipelineStamp(forPrompt: nil)
        let stampNil2 = TranscriptionService.pipelineStamp(forPrompt: nil)
        XCTAssertEqual(stampNil1, stampNil2, "nil prompt (hashed as empty string) must be deterministic too")
    }

    // MARK: - testRawTextCollapsesToNilWhenEqualToText

    func testRawTextCollapsesToNilWhenEqualToText() {
        let unchanged = HistoryStore.Entry(
            text: "no trailing space",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            rawText: "no trailing space"
        )
        XCTAssertNil(unchanged.rawText, "rawText must collapse to nil when trimming didn't change anything")
    }

    // MARK: - testRawTextKeptWhenTrimChangedText

    func testRawTextKeptWhenTrimChangedText() {
        let trimmedByService = HistoryStore.Entry(
            text: "has trailing space",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            rawText: "has trailing space   "
        )
        XCTAssertEqual(
            trimmedByService.rawText,
            "has trailing space   ",
            "rawText must be kept when it differs from the final text"
        )
    }
}
