// EvalCollectorTests.swift — VoiceType
//
// Unit tests for the Eval Collector feature:
//   - Backward compatibility: old-format entries parse without new fields
//   - Round-trip: new fields encode/decode cleanly
//   - Audio rotation: unsaved audio capped at 100; saved eval pairs exempt
//   - update() replaces existing entry in-place
//   - Correction pre-filled with whisper output on entry creation

import XCTest
@testable import VoiceType

@MainActor
final class EvalCollectorTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(audioDir: URL? = nil) throws -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url, audioDirectory: audioDir ?? dir.appendingPathComponent("audio"))
        return (store, url)
    }

    private func sampleEntry(
        text: String = "hello world",
        audioPath: String? = nil,
        model: String? = nil,
        audioDuration: Double? = nil
    ) -> HistoryStore.Entry {
        HistoryStore.Entry(
            text: text,
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "ru",
            audioPath: audioPath,
            model: model,
            audioDurationSeconds: audioDuration
        )
    }

    // MARK: - testHistoryEntryParsesOldFormatWithoutNewFields

    /// Old JSONL lines (pre-eval-collector) must parse successfully with all
    /// new optional fields defaulting to nil. Backward compatibility is critical.
    func testHistoryEntryParsesOldFormatWithoutNewFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.jsonl")

        // Manually write a minimal old-format JSONL line (no new fields).
        // Build via concatenation to avoid multiline-string indentation issues.
        let oldLine = "{\"id\":\"11111111-1111-1111-1111-111111111111\","
            + "\"timestamp\":\"2024-01-20T10:00:00Z\","
            + "\"text\":\"old transcription\","
            + "\"charCount\":17,"
            + "\"targetAppName\":\"Xcode\","
            + "\"targetAppBundleID\":\"com.apple.dt.Xcode\","
            + "\"language\":\"en\"}"
        try (oldLine + "\n").write(to: url, atomically: true, encoding: .utf8)

        let store = HistoryStore.test(storeURL: url)
        let entries = store.entries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "old transcription")
        XCTAssertNil(entries.first?.audioPath, "audioPath must be nil for old entries")
        XCTAssertNil(entries.first?.userCorrection, "userCorrection must be nil for old entries")
        XCTAssertNil(entries.first?.isSavedEval, "isSavedEval must be nil for old entries")
        XCTAssertNil(entries.first?.model, "model must be nil for old entries")
        XCTAssertNil(entries.first?.audioDurationSeconds, "audioDurationSeconds must be nil for old entries")
    }

    // MARK: - testHistoryEntryRoundTripWithEvalFields

    /// New eval fields must survive a full JSONL encode/decode round-trip.
    func testHistoryEntryRoundTripWithEvalFields() throws {
        let (store1, url) = try makeStore()

        let entry = sampleEntry(
            text: "Привет мир",
            audioPath: "abc123.caf",
            model: "small.en-q5_1",
            audioDuration: 4.5
        )
        store1.append(entry)

        // Save correction.
        let updated = entry.withEvalSaved(correction: "Привет мир (исправлено)")
        store1.update(updated)

        // Re-read from disk.
        let store2 = HistoryStore.test(storeURL: url)
        let loaded = store2.entries()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.audioPath, "abc123.caf")
        XCTAssertEqual(loaded.first?.model, "small.en-q5_1")
        let dur = try XCTUnwrap(loaded.first?.audioDurationSeconds)
        XCTAssertEqual(dur, 4.5, accuracy: 0.001)
        XCTAssertEqual(loaded.first?.userCorrection, "Привет мир (исправлено)")
        XCTAssertEqual(loaded.first?.isSavedEval, true)
    }

    // MARK: - testEntryCapKeeps100RegularAndAllSavedEval

    /// Regular entries are capped at 100 while saved eval pairs are exempt, and
    /// the surviving unsaved-audio set stays within its own budget.
    ///
    /// Renamed from testAudioRotationKeeps100UnsavedAndAllSaved: with the entry
    /// cap in place this exercises the ENTRY cap, not the audio rotation branch.
    /// Entries carrying unsaved audio are a subset of regular entries, which are
    /// already held at maxEntries, so rotateAudioIfNeeded()'s `> maxUnsavedAudio`
    /// condition cannot be reached while the two limits are equal. The old name
    /// claimed coverage the test does not provide. Review finding, wave A.
    func testEntryCapKeeps100RegularAndAllSavedEval() throws {
        let (store, _) = try makeStore()

        // Add 105 unsaved entries with audioPath first (oldest).
        // These will be partially evicted by audio rotation.
        for i in 0..<105 {
            store.append(sampleEntry(text: "unsaved \(i)", audioPath: "unsaved\(i).caf"))
        }

        // The regular-entry cap is 100, so at this point the oldest 5 are gone.
        // Now add more unsaved entries to trigger audio rotation, then save a few.
        // We need the final store to contain both unsaved (with rotation) and saved.
        // Strategy: start fresh with exactly 100 unsaved + save some via update().

        // Clear and restart with a clean scenario for clarity.
        store.clear()

        // Append 100 unsaved entries with audioPath.
        for i in 0..<100 {
            store.append(sampleEntry(text: "unsaved \(i)", audioPath: "u\(i).caf"))
        }

        // Mark 5 of them as saved via update().
        let allEntries = store.entries()
        for i in 0..<5 {
            let saved = allEntries[i].withEvalSaved(correction: "fixed \(i)")
            store.update(saved)
        }

        // Now add 6 more unsaved entries. Regular-entry count goes 95 → 101,
        // so the entry cap evicts exactly one oldest regular entry (task 2 fix:
        // the cap counts only regular entries, not saved eval pairs).
        for i in 100..<106 {
            store.append(sampleEntry(text: "new unsaved \(i)", audioPath: "n\(i).caf"))
        }

        let entries = store.entries()
        // 100 regular entries (capped) + 5 saved eval pairs (exempt from the cap) = 105.
        XCTAssertEqual(
            entries.count,
            105,
            "Cap must hold regular entries at 100 while keeping all 5 saved eval pairs"
        )
        XCTAssertEqual(
            entries.filter { $0.isSavedEval != true }.count,
            100,
            "Regular (non-eval) entry count must be capped at 100"
        )
        XCTAssertEqual(
            entries.filter { $0.isSavedEval == true }.count,
            5,
            "All 5 saved eval pairs must survive the regular-entry cap"
        )

        // Saved eval pairs still have their audioPath.
        let savedWithAudio = entries.filter { $0.isSavedEval == true && $0.audioPath != nil }
        XCTAssertGreaterThan(savedWithAudio.count, 0, "Saved eval pairs must retain audioPath")

        // The total unsaved-with-audio count must be <= 100.
        let unsavedWithAudio = entries.filter { $0.isSavedEval != true && $0.audioPath != nil }
        XCTAssertLessThanOrEqual(
            unsavedWithAudio.count,
            100,
            "Unsaved audio buffer must not exceed 100"
        )
    }

    // MARK: - testSavedEvalNeverRotated

    /// Explicitly verify that a saved eval pair's audioPath is never cleared by rotation,
    /// AND that the entry itself is never evicted by the regular-entry cap, even when
    /// far more than 100 unsaved entries are present (task 2 fix).
    ///
    /// Before the fix, the entry cap counted all entries regardless of isSavedEval,
    /// so this saved pair (appended first, i.e. oldest) would have been evicted by
    /// the time 200 more regular entries were appended — silently discarding a
    /// "kept forever" eval pair, exactly the bug the file header comment promised
    /// wouldn't happen.
    func testSavedEvalNeverRotated() throws {
        let (store, _) = try makeStore()

        // One saved eval pair.
        let evalEntry = sampleEntry(text: "eval", audioPath: "eval.caf")
        let saved = evalEntry.withEvalSaved(correction: "eval corrected")
        store.append(saved)

        // 200 unsaved entries — enough to trigger multiple rotation passes and,
        // pre-fix, multiple entry-cap eviction passes.
        for i in 0..<200 {
            store.append(sampleEntry(text: "bulk \(i)", audioPath: "bulk\(i).caf"))
        }

        let entries = store.entries()

        let evalInStore = try XCTUnwrap(
            entries.first(where: { $0.id == saved.id }),
            "Saved eval pair must survive the regular-entry cap regardless of how many regular entries follow it"
        )
        XCTAssertEqual(
            evalInStore.audioPath,
            "eval.caf",
            "Saved eval pair audioPath must not be cleared by audio rotation"
        )
        XCTAssertEqual(evalInStore.isSavedEval, true)

        // The regular-entry cap must still hold at exactly 100.
        XCTAssertEqual(
            entries.filter { $0.isSavedEval != true }.count,
            100,
            "Regular entries must still be capped at 100 alongside the exempt saved pair"
        )
    }

    // MARK: - testCorrectionDefaultsToWhisperOutput

    /// A freshly created Entry has userCorrection == nil, confirming the
    /// UI should pre-fill the correction field from entry.text, not from
    /// userCorrection (which is nil on new entries).
    func testCorrectionDefaultsToWhisperOutput() {
        let entry = sampleEntry(text: "dictated text")
        XCTAssertNil(entry.userCorrection, "userCorrection must be nil before Save is clicked")
        XCTAssertNil(entry.isSavedEval, "isSavedEval must be nil before Save is clicked")

        // The UI pre-fills from entry.text. After user edits + Save:
        let saved = entry.withEvalSaved(correction: "dictated text (fixed)")
        XCTAssertEqual(saved.userCorrection, "dictated text (fixed)")
        XCTAssertEqual(saved.isSavedEval, true)
        XCTAssertEqual(saved.text, "dictated text", "Original whisper text must be preserved unchanged")
    }

    // MARK: - testUpdateReplacesEntryInPlace

    /// HistoryStore.update(_:) must replace the correct entry without
    /// disturbing surrounding entries or their ordering.
    func testUpdateReplacesEntryInPlace() throws {
        let (store, url) = try makeStore()

        let a = sampleEntry(text: "alpha")
        let b = sampleEntry(text: "beta")
        let c = sampleEntry(text: "gamma")
        store.append(a)
        store.append(b)
        store.append(c)

        // Update the middle entry (b).
        let updatedB = b.withEvalSaved(correction: "beta corrected")
        store.update(updatedB)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 3)
        // Newest-first: gamma, beta, alpha.
        XCTAssertEqual(entries[0].text, "gamma")
        XCTAssertEqual(entries[1].userCorrection, "beta corrected")
        XCTAssertEqual(entries[1].isSavedEval, true)
        XCTAssertEqual(entries[2].text, "alpha")
        XCTAssertNil(entries[2].userCorrection)

        // Verify persistence.
        let store2 = HistoryStore.test(storeURL: url)
        let reloaded = store2.entries()
        XCTAssertEqual(reloaded[1].userCorrection, "beta corrected")
    }

    // MARK: - testEntryByIDReturnsCorrectEntry

    /// entry(byID:) must return the exact entry matching the given UUID.
    func testEntryByIDReturnsCorrectEntry() throws {
        let (store, _) = try makeStore()
        let a = sampleEntry(text: "alpha")
        let b = sampleEntry(text: "beta")
        let c = sampleEntry(text: "gamma")
        store.append(a)
        store.append(b)
        store.append(c)

        let found = store.entry(byID: b.id)
        XCTAssertNotNil(found, "entry(byID:) must return the entry when the ID is present")
        XCTAssertEqual(found?.text, "beta")
        XCTAssertEqual(found?.id, b.id)
    }

    // MARK: - testEntryByIDReturnsNilForUnknownID

    /// entry(byID:) must return nil for a UUID that is not in the store.
    func testEntryByIDReturnsNilForUnknownID() throws {
        let (store, _) = try makeStore()
        store.append(sampleEntry(text: "only entry"))

        let result = store.entry(byID: UUID()) // random unknown UUID
        XCTAssertNil(result, "entry(byID:) must return nil for an ID not present in the store")
    }

    // MARK: - testEvalEditorViewHandlesEntryWithoutAudio

    /// An entry without audioPath (pre-v1.2.1) must round-trip through
    /// withEvalSaved without errors. EvalEditorView uses entry?.audioPath for
    /// the hasAudio guard, so this test verifies the data layer is clean.
    func testEvalEditorViewHandlesEntryWithoutAudio() throws {
        let (store, _) = try makeStore()
        let noAudio = sampleEntry(text: "no audio entry", audioPath: nil)
        store.append(noAudio)

        let found = store.entry(byID: noAudio.id)
        XCTAssertNotNil(found)
        XCTAssertNil(found?.audioPath, "Old entry must have nil audioPath")

        // Saving a correction on an entry without audio must succeed cleanly.
        let foundEntry = try XCTUnwrap(found)
        let saved = foundEntry.withEvalSaved(correction: "corrected no-audio entry")
        store.update(saved)

        let reloaded = store.entry(byID: noAudio.id)
        XCTAssertEqual(reloaded?.userCorrection, "corrected no-audio entry")
        XCTAssertEqual(reloaded?.isSavedEval, true)
        XCTAssertNil(reloaded?.audioPath, "audioPath must remain nil after eval save")
    }

    // MARK: - testSavedEvalCount

    func testSavedEvalCount() throws {
        let (store, _) = try makeStore()

        store.append(sampleEntry(text: "one"))
        store.append(sampleEntry(text: "two"))
        store.append(sampleEntry(text: "three"))

        XCTAssertEqual(store.savedEvalCount(), 0)

        let entries = store.entries()
        store.update(entries[0].withEvalSaved(correction: "fixed three"))
        XCTAssertEqual(store.savedEvalCount(), 1)

        store.update(entries[1].withEvalSaved(correction: "fixed two"))
        XCTAssertEqual(store.savedEvalCount(), 2)
    }
}
