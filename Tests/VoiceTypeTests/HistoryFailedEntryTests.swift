// HistoryFailedEntryTests.swift — VoiceType
//
// Unit tests for the D4/D6 failed-transcription model (reliable-dictation
// plan, task C): HistoryStore.Entry's status/failureReason/latencyMs fields,
// their own eviction cap (maxFailedEntries), HistoryStore.promoteRetried(_:),
// and the HistoryRecorder methods that drive them.
//
// All tests are hermetic: each uses a fresh temp directory via
// HistoryStore.test(storeURL:audioDirectory:) and cleans up in
// addTeardownBlock — same pattern as HistoryStoreTests.swift.

import XCTest
@testable import VoiceType

@MainActor
final class HistoryFailedEntryTests: XCTestCase {

    // MARK: - Helpers

    /// Bundles a hermetic store with its backing paths — a plain struct
    /// rather than a 3-tuple (swiftlint large_tuple caps tuples at 2 members).
    private struct Fixture {
        let store: HistoryStore
        let url: URL
        let audioDir: URL
    }

    private func makeStore() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url, audioDirectory: audioDir)
        return Fixture(store: store, url: url, audioDir: audioDir)
    }

    private func regularEntry(text: String = "hello", audioPath: String? = nil) -> HistoryStore.Entry {
        HistoryStore.Entry(
            text: text,
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: audioPath
        )
    }

    private func failedEntry(audioPath: String? = "failed.caf", reason: String = "timeout") -> HistoryStore.Entry {
        HistoryStore.Entry(
            text: "",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: audioPath,
            status: .failed,
            failureReason: reason
        )
    }

    // MARK: - Decoding / encoding

    /// A JSONL line written before status/failureReason/latencyMs existed must
    /// still decode — same backward-compat contract as rawText/pipelineStamp.
    func testLegacyLineDecodesNewFieldsAsNilAndIsNotFailed() throws {
        let legacyLine = """
        {"id":"\(UUID().uuidString)","timestamp":"2024-01-01T00:00:00Z","text":"legacy entry","charCount":12,"targetAppName":"TestApp","language":"en"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryStore.Entry.self, from: Data(legacyLine.utf8))

        XCTAssertEqual(entry.text, "legacy entry")
        XCTAssertNil(entry.status, "Legacy lines never had status — must decode as nil")
        XCTAssertNil(entry.failureReason, "Legacy lines never had failureReason — must decode as nil")
        XCTAssertNil(entry.latencyMs, "Legacy lines never had latencyMs — must decode as nil")
        XCTAssertFalse(entry.isFailed, "A legacy entry (status nil) must never read as failed")
    }

    /// nil status/failureReason/latencyMs must not appear as JSON keys at all —
    /// the whole point of "old files never need migrating" is that a store
    /// with no failed entries produces byte-identical JSONL to before this task.
    func testRegularEntryOmitsNewKeysWhenNil() throws {
        let entry = regularEntry()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("\"status\""), "status key must be absent when nil")
        XCTAssertFalse(json.contains("\"failureReason\""), "failureReason key must be absent when nil")
        XCTAssertFalse(json.contains("\"latencyMs\""), "latencyMs key must be absent when nil")
    }

    /// A failed entry's keys must be present and round-trip.
    func testFailedEntryRoundTripsStatusAndFailureReason() throws {
        let fx = try makeStore()
        let store = fx.store
        let url = fx.url
        let entry = failedEntry(audioPath: "abc.caf", reason: "timeout")
        store.append(entry)

        let store2 = HistoryStore.test(storeURL: url, audioDirectory: store.audioDirectory)
        let loaded = try XCTUnwrap(store2.entries().first)
        XCTAssertEqual(loaded.status, .failed)
        XCTAssertEqual(loaded.failureReason, "timeout")
        XCTAssertTrue(loaded.isFailed)
        XCTAssertEqual(loaded.text, "")
    }

    // MARK: - with…-helpers carry the new fields

    func testWithEvalSavedPreservesStatusAndLatency() {
        let entry = failedEntry().withLatency(["asr": 500])
        let updated = entry.withEvalSaved(correction: "corrected")
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.failureReason, "timeout")
        XCTAssertEqual(updated.latencyMs, ["asr": 500])
    }

    func testWithAudioPathClearedPreservesStatusAndLatency() {
        let entry = failedEntry().withLatency(["asr": 500])
        let updated = entry.withAudioPathCleared()
        XCTAssertNil(updated.audioPath)
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.failureReason, "timeout")
        XCTAssertEqual(updated.latencyMs, ["asr": 500])
    }

    func testWithInsertOutcomePreservesStatusAndLatency() {
        let entry = failedEntry().withLatency(["asr": 500])
        let updated = entry.withInsertOutcome(true)
        XCTAssertEqual(updated.insertSuccess, true)
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.failureReason, "timeout")
        XCTAssertEqual(updated.latencyMs, ["asr": 500])
    }

    func testWithLatencySetsFieldAndPreservesOthers() {
        let entry = regularEntry()
        let updated = entry.withLatency(["stopToSamples": 100, "asr": 800, "insert": 30, "total": 930])
        XCTAssertEqual(updated.latencyMs, ["stopToSamples": 100, "asr": 800, "insert": 30, "total": 930])
        XCTAssertEqual(updated.text, entry.text)
        XCTAssertNil(updated.status)
    }

    func testWithFailureReasonStaysFailedAndChangesOnlyReason() {
        let entry = failedEntry(reason: "timeout").withLatency(["asr": 500])
        let updated = entry.withFailureReason("error")
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.failureReason, "error")
        XCTAssertEqual(updated.latencyMs, ["asr": 500])
        XCTAssertTrue(updated.isFailed)
    }

    func testWithTranscriptionResultClearsStatusAndFailureReasonButKeepsLatency() {
        let entry = failedEntry(audioPath: "abc.caf", reason: "timeout")
            .withLatency(["asr": 500])
        let updated = entry.withTranscriptionResult(
            text: "retried text",
            rawText: "retried text raw",
            pipelineStamp: "n2:pdeadbeefdead",
            model: "small.en-q5_1"
        )
        XCTAssertNil(updated.status, "Successful retry must clear status")
        XCTAssertNil(updated.failureReason, "Successful retry must clear failureReason")
        XCTAssertEqual(updated.text, "retried text")
        XCTAssertEqual(updated.charCount, "retried text".count)
        XCTAssertEqual(updated.rawText, "retried text raw")
        XCTAssertEqual(updated.pipelineStamp, "n2:pdeadbeefdead")
        XCTAssertEqual(updated.model, "small.en-q5_1")
        XCTAssertEqual(updated.latencyMs, ["asr": 500], "latencyMs must survive a retry")
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.timestamp, entry.timestamp, "Retry must not change the original timestamp")
        XCTAssertEqual(updated.audioPath, "abc.caf")
    }

    func testWithTranscriptionResultKeepsPriorModelWhenNilGiven() {
        let withModel = HistoryStore.Entry(
            text: "",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            model: "small.en-q5_1",
            status: .failed,
            failureReason: "timeout"
        )
        let updated = withModel.withTranscriptionResult(text: "done", rawText: nil, pipelineStamp: "n2:pabc", model: nil)
        XCTAssertEqual(updated.model, "small.en-q5_1", "nil model argument must keep the entry's prior model")
    }

    func testWithTranscriptionResultCollapsesRawTextWhenEqualToText() {
        let entry = failedEntry()
        let updated = entry.withTranscriptionResult(text: "same", rawText: "same", pipelineStamp: "n2:pabc", model: nil)
        XCTAssertNil(updated.rawText, "rawText must collapse to nil when it matches the final text")
    }

    // MARK: - latestEntry() skips failed entries

    func testLatestEntrySkipsFailedEntries() throws {
        let store = try makeStore().store
        store.append(regularEntry(text: "first regular"))
        store.append(failedEntry())

        let latest = store.latestEntry()
        XCTAssertEqual(latest?.text, "first regular", "latestEntry() must skip the newer failed entry")
        XCTAssertFalse(latest?.isFailed ?? true)
    }

    func testLatestEntryReturnsNilWhenOnlyFailedEntriesExist() throws {
        let store = try makeStore().store
        store.append(failedEntry())

        XCTAssertNil(store.latestEntry(), "latestEntry() must return nil when every entry is failed")
    }

    // MARK: - Failed entries are excluded from the regular cap and audio rotation

    func testFailedEntryNotEvictedBy100RegularAppends() throws {
        let fx = try makeStore()
        let store = fx.store
        let audioDir = fx.audioDir
        try Data().write(to: audioDir.appendingPathComponent("failed.caf"))
        let failed = failedEntry(audioPath: "failed.caf")
        store.append(failed)

        for i in 0..<100 {
            store.append(regularEntry(text: "r\(i)"))
        }

        let entries = store.entries()
        XCTAssertEqual(
            entries.filter { $0.isSavedEval != true && !$0.isFailed }.count,
            100,
            "Regular cap must still hold at 100"
        )
        XCTAssertTrue(entries.contains { $0.id == failed.id },
                      "Failed entry must survive 100 regular appends — it is excluded from the regular cap")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("failed.caf").path),
            "Failed entry's audio must not be rotated away by regular-entry audio rotation"
        )
    }

    // MARK: - maxFailedEntries boundary (20 → 21)

    func testFailedEntryCapEvictsOldestAtBoundaryAndDeletesItsAudio() throws {
        let fx = try makeStore()
        let store = fx.store
        let audioDir = fx.audioDir

        var oldestID: UUID?
        for i in 0..<21 {
            let path = "failed\(i).caf"
            try Data().write(to: audioDir.appendingPathComponent(path))
            let entry = failedEntry(audioPath: path, reason: "error")
            if i == 0 { oldestID = entry.id }
            store.append(entry)
        }

        let entries = store.entries()
        let failedEntries = entries.filter(\.isFailed)
        XCTAssertEqual(
            failedEntries.count,
            HistoryStore.maxFailedEntries,
            "Failed entries must be capped at maxFailedEntries"
        )
        XCTAssertFalse(entries.contains { $0.id == oldestID },
                       "Oldest failed entry must be evicted once the cap (20) is exceeded")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("failed0.caf").path),
            "Evicted failed entry's audio file must be deleted from disk after a successful flush"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("failed20.caf").path),
            "Surviving failed entry's audio must remain"
        )
    }

    // MARK: - promoteRetried

    func testPromoteRetriedMovesToFrontAndClearsFailedStatus() throws {
        let store = try makeStore().store
        let failed = failedEntry(audioPath: "abc.caf", reason: "timeout")
        store.append(failed)
        store.append(regularEntry(text: "newer regular entry"))

        let retried = failed.withTranscriptionResult(
            text: "retried text", rawText: nil, pipelineStamp: "n2:pabc", model: "small.en-q5_1"
        )
        store.promoteRetried(retried)

        let entries = store.entries()
        XCTAssertEqual(entries.first?.id, failed.id, "Promoted entry must be moved to the front")
        XCTAssertEqual(entries.first?.text, "retried text")
        XCTAssertFalse(entries.first?.isFailed ?? true, "Promoted entry must no longer be failed")
        XCTAssertEqual(entries.count, 2, "No entry must be lost by promotion")
    }

    /// The just-promoted entry is inserted at index 0 BEFORE the regular cap
    /// runs as part of the same promoteRetried() call — so when promoting
    /// pushes the regular count to 101, the entry evicted must be one of the
    /// 100 pre-existing regular entries (the oldest one), never the
    /// just-promoted entry itself.
    func testPromoteRetriedEntryIsNotEvictedByItsOwnPromotionPass() throws {
        let store = try makeStore().store

        // 100 pre-existing regular entries already at the cap.
        for i in 0..<100 {
            store.append(regularEntry(text: "r\(i)"))
        }
        let oldestPreexistingID = try XCTUnwrap(store.entries().last?.id, "r0 must be the oldest entry")

        let failed = failedEntry(audioPath: "abc.caf", reason: "timeout")
        store.append(failed) // failed entries are exempt from the regular cap.

        let retried = failed.withTranscriptionResult(
            text: "retried text", rawText: nil, pipelineStamp: "n2:pabc", model: nil
        )
        store.promoteRetried(retried)

        let entries = store.entries()
        XCTAssertEqual(entries.first?.id, failed.id, "Promoted entry must be at the front")
        XCTAssertTrue(entries.contains { $0.id == failed.id && $0.text == "retried text" },
                      "Promoted entry must survive the eviction pass triggered by its own promotion")
        XCTAssertFalse(entries.contains { $0.id == oldestPreexistingID },
                       "The pre-existing oldest regular entry must be evicted instead of the promoted one")
        XCTAssertEqual(
            entries.filter { $0.isSavedEval != true && !$0.isFailed }.count,
            100,
            "Regular cap must still hold at exactly 100 after promotion"
        )
    }

    func testPromoteRetriedIsNoopForUnknownID() throws {
        let store = try makeStore().store
        store.append(regularEntry(text: "kept"))

        let phantom = HistoryStore.Entry(
            text: "ghost",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en"
        )
        store.promoteRetried(phantom)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1, "promoteRetried must be a no-op for an id that isn't in the store")
        XCTAssertEqual(entries.first?.text, "kept")
    }

    // MARK: - HistoryRecorder methods

    func testRecorderRecordTranscriptionFailureAppendsFailedEntry() throws {
        let fx = try makeStore()
        let store = fx.store
        let audioDir = fx.audioDir
        try Data().write(to: audioDir.appendingPathComponent("rec.caf"))
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordTranscriptionFailure(.init(
            targetAppName: "Cursor",
            targetAppBundleID: "com.cursor.cursor",
            language: "en",
            audioPath: "rec.caf",
            model: "small.en-q5_1",
            audioDurationSeconds: 4.0,
            reason: "timeout"
        ))

        let entry = try XCTUnwrap(store.entry(byID: id))
        XCTAssertTrue(entry.isFailed)
        XCTAssertEqual(entry.failureReason, "timeout")
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.audioPath, "rec.caf")
    }

    func testRecorderRecordRetryResultPromotesEntryAndReturnsTrue() throws {
        let fx = try makeStore()
        let store = fx.store
        let audioDir = fx.audioDir
        try Data().write(to: audioDir.appendingPathComponent("rec.caf"))
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordTranscriptionFailure(.init(
            targetAppName: "Cursor",
            targetAppBundleID: "com.cursor.cursor",
            language: "en",
            audioPath: "rec.caf",
            model: nil,
            audioDurationSeconds: nil,
            reason: "timeout"
        ))

        let succeeded = recorder.recordRetryResult(
            id: id, text: "retried", rawText: nil, pipelineStamp: "n2:pabc", model: "small.en-q5_1"
        )
        XCTAssertTrue(succeeded)

        let entry = try XCTUnwrap(store.entry(byID: id))
        XCTAssertFalse(entry.isFailed)
        XCTAssertEqual(entry.text, "retried")
        XCTAssertEqual(entry.model, "small.en-q5_1")
        XCTAssertEqual(store.entries().first?.id, id, "A successful retry must promote the entry to the front")
    }

    func testRecorderRecordRetryResultReturnsFalseForUnknownID() throws {
        let store = try makeStore().store
        let recorder = HistoryRecorder(store: store)

        let succeeded = recorder.recordRetryResult(
            id: UUID(), text: "retried", rawText: nil, pipelineStamp: nil, model: nil
        )
        XCTAssertFalse(succeeded, "recordRetryResult must return false when the entry no longer exists")
    }

    func testRecorderRecordLatencyUpdatesEntry() throws {
        let store = try makeStore().store
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordPending(.init(
            text: "hello",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: nil,
            model: nil,
            audioDurationSeconds: nil
        ))

        recorder.recordLatency(id: id, latencyMs: ["stopToSamples": 100, "asr": 800, "insert": 30, "total": 930])

        let entry = try XCTUnwrap(store.entry(byID: id))
        XCTAssertEqual(entry.latencyMs, ["stopToSamples": 100, "asr": 800, "insert": 30, "total": 930])
    }

    func testRecorderRecordLatencyIsNoopForUnknownID() throws {
        let store = try makeStore().store
        let recorder = HistoryRecorder(store: store)
        store.append(regularEntry(text: "kept"))

        recorder.recordLatency(id: UUID(), latencyMs: ["asr": 500])

        XCTAssertNil(store.entries().first?.latencyMs, "recordLatency must not touch an unrelated entry")
    }

    func testRecorderRecordRetryFailureUpdatesReasonAndStaysFailed() throws {
        let fx = try makeStore()
        let store = fx.store
        let audioDir = fx.audioDir
        try Data().write(to: audioDir.appendingPathComponent("rec.caf"))
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordTranscriptionFailure(.init(
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: "rec.caf",
            model: nil,
            audioDurationSeconds: nil,
            reason: "timeout"
        ))

        recorder.recordRetryFailure(id: id, reason: "error")

        let entry = try XCTUnwrap(store.entry(byID: id))
        XCTAssertTrue(entry.isFailed)
        XCTAssertEqual(entry.failureReason, "error")
    }

    func testRecorderRecordRetryFailureIsNoopForUnknownID() throws {
        let store = try makeStore().store
        let recorder = HistoryRecorder(store: store)
        store.append(regularEntry(text: "kept"))

        recorder.recordRetryFailure(id: UUID(), reason: "error")

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries.first?.isFailed ?? true, "recordRetryFailure must not touch an unrelated entry")
    }
}
