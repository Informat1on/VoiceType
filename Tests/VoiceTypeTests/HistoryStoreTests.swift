// HistoryStoreTests.swift — VoiceType
//
// Unit tests for HistoryStore (history.jsonl, rolling cap, persistence).
// All tests use a hermetic temp directory via HistoryStore.test(storeURL:).

import XCTest
@testable import VoiceType

@MainActor
final class HistoryStoreTests: XCTestCase {

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

    private func sampleEntry(
        text: String = "hello",
        app: String = "TestApp",
        bundleID: String? = "com.test",
        language: String = "en"
    ) -> HistoryStore.Entry {
        HistoryStore.Entry(
            text: text,
            targetAppName: app,
            targetAppBundleID: bundleID,
            language: language
        )
    }

    // MARK: - testAppendStoresEntry

    func testAppendStoresEntry() throws {
        let (store, _) = try makeStore()
        let entry = sampleEntry(text: "hello")
        store.append(entry)
        XCTAssertEqual(store.entries().count, 1)
        XCTAssertEqual(store.entries().first?.text, "hello")
    }

    // MARK: - testRollingCapAt100

    func testRollingCapAt100() throws {
        let (store, _) = try makeStore()
        for i in 0..<110 {
            store.append(sampleEntry(text: "entry \(i)"))
        }
        XCTAssertEqual(
            store.entries().count,
            100,
            "Cap must evict oldest entries to stay at 100"
        )
        // Newest entry should be the last one appended (entry 109).
        XCTAssertEqual(store.entries().first?.text, "entry 109")
    }

    // MARK: - testDeletes

    func testDeletes() throws {
        let (store, _) = try makeStore()
        let a = sampleEntry(text: "alpha")
        let b = sampleEntry(text: "beta")
        store.append(a)
        store.append(b)
        XCTAssertEqual(store.entries().count, 2)
        store.delete(a.id)
        let remaining = store.entries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.text, "beta")
    }

    // MARK: - testPersistsAcrossReinit

    func testPersistsAcrossReinit() throws {
        let (store1, url) = try makeStore()
        let entry = sampleEntry(text: "persisted text", app: "Safari", bundleID: "com.apple.safari", language: "ru")
        store1.append(entry)

        // Create a second HistoryStore pointing to the same file.
        let store2 = HistoryStore.test(storeURL: url)
        let loaded = store2.entries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "persisted text")
        XCTAssertEqual(loaded.first?.targetAppName, "Safari")
        XCTAssertEqual(loaded.first?.targetAppBundleID, "com.apple.safari")
        XCTAssertEqual(loaded.first?.language, "ru")
    }

    // MARK: - testNewestFirst

    func testNewestFirst() throws {
        let (store, _) = try makeStore()
        store.append(sampleEntry(text: "first"))
        store.append(sampleEntry(text: "second"))
        store.append(sampleEntry(text: "third"))
        let all = store.entries()
        XCTAssertEqual(
            all.map(\.text),
            ["third", "second", "first"],
            "Entries must be newest-first"
        )
    }

    // MARK: - testClearEmptiesStore

    func testClearEmptiesStore() throws {
        let (store, url) = try makeStore()
        store.append(sampleEntry(text: "gone"))
        store.clear()
        XCTAssertEqual(store.entries().count, 0)
        // File should exist but be empty.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 0, "File should be empty after clear()")
    }

    // MARK: - testCharCountMatchesTextLength

    func testCharCountMatchesTextLength() throws {
        let (store, _) = try makeStore()
        let text = "Привет мир"
        store.append(sampleEntry(text: text))
        XCTAssertEqual(store.entries().first?.charCount, text.count)
    }

    // MARK: - testPersistedFileIsChronological

    func testPersistedFileIsChronological() throws {
        let (store1, url) = try makeStore()
        store1.append(sampleEntry(text: "oldest"))
        store1.append(sampleEntry(text: "middle"))
        store1.append(sampleEntry(text: "newest"))

        // Read the raw file lines.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 3, "One JSON line per entry")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(HistoryStore.Entry.self, from: Data($0.utf8)) }
        XCTAssertEqual(
            decoded.map(\.text),
            ["oldest", "middle", "newest"],
            "File must store entries in chronological (oldest-first) order"
        )
    }

    // MARK: - testDeleteNonexistentIDIsNoop

    func testDeleteNonexistentIDIsNoop() throws {
        let (store, _) = try makeStore()
        store.append(sampleEntry(text: "keep"))
        store.delete(UUID()) // Random non-existent UUID.
        XCTAssertEqual(store.entries().count, 1)
    }

    // MARK: - testNilBundleIDRoundtrips

    func testNilBundleIDRoundtrips() throws {
        let (store, url) = try makeStore()
        store.append(sampleEntry(text: "no bundle", bundleID: nil))
        let store2 = HistoryStore.test(storeURL: url)
        XCTAssertNil(
            store2.entries().first?.targetAppBundleID,
            "nil bundleID must round-trip through JSON correctly"
        )
    }

    // MARK: - testRapidFireAppendsPreserveOrderAndCount

    /// 50 back-to-back @MainActor appends.
    /// HistoryStore is @MainActor so there's no real concurrency, but this verifies
    /// that sequential appends produce deterministic ordering and correct count.
    func testRapidFireAppendsPreserveOrderAndCount() throws {
        let (store, _) = try makeStore()

        for i in 0..<50 {
            store.append(sampleEntry(text: "entry-\(i)"))
        }

        let all = store.entries()
        XCTAssertEqual(all.count, 50, "All 50 appends should be present")
        XCTAssertEqual(all.first?.text, "entry-49", "Newest entry should be first (newest-first ordering)")
        XCTAssertEqual(all.last?.text, "entry-0", "Oldest entry should be last")
    }

    // MARK: - testLoadDropsCorruptLines

    /// A single corrupt JSONL line must be silently dropped; valid lines before and after
    /// it must survive. This is the desired behaviour per DESIGN.md error-handling rules.
    func testLoadDropsCorruptLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.jsonl")

        // Two valid ISO-8601 encoded lines surrounding one corrupt line.
        // Build each JSON object by concatenating two halves to stay within the 140-char limit.
        let id1 = "00000000-0000-0000-0000-000000000001"
        let id2 = "00000000-0000-0000-0000-000000000002"
        let validBase = #","charCount":5,"targetAppName":"A","targetAppBundleID":"a","language":"ru"}"#
        let valid1 = "{\"id\":\"\(id1)\",\"timestamp\":\"2024-01-20T00:00:00Z\",\"text\":\"clean\""
            + validBase
        let corrupt = "{not valid json"
        let afterBase = #","charCount":5,"targetAppName":"B","targetAppBundleID":"b","language":"en"}"#
        let valid2 = "{\"id\":\"\(id2)\",\"timestamp\":\"2024-01-20T00:01:00Z\",\"text\":\"after\""
            + afterBase
        let content = [valid1, corrupt, valid2].joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let store = HistoryStore.test(storeURL: url)
        let loaded = store.entries()

        // If this fails with count == 0, HistoryStore's load() is throwing on the first
        // corrupt line and bailing out entirely instead of skipping it — that is a bug.
        XCTAssertEqual(loaded.count, 2, "Corrupt JSONL line must be silently dropped; valid lines must be loaded")
        XCTAssertTrue(loaded.contains { $0.text == "clean" }, "First valid entry must survive")
        XCTAssertTrue(loaded.contains { $0.text == "after" }, "Third valid entry must survive")
    }

    // MARK: - testUnicodeBoundarySliceCorrectness

    /// ZWJ family sequence + flag emoji must survive a JSON encode → decode round-trip
    /// with no grapheme cluster damage. Swift String.count returns grapheme clusters,
    /// which is the correct unit; the test verifies JSON encoding uses the same unit.
    func testUnicodeBoundarySliceCorrectness() throws {
        let (store, url) = try makeStore()

        // Mixed RU + ZWJ family emoji + EN + flag emoji sequence.
        // Split across two string literals (concatenated) to respect the 140-char line limit.
        let text = "Привет мир \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
            + " hello world \u{1F1F7}\u{1F1FA}\u{1F1EC}\u{1F1E7} done"
        let entry = HistoryStore.Entry(
            text: text,
            targetAppName: "T",
            targetAppBundleID: "t",
            language: "ru"
        )
        store.append(entry)

        // In-memory round-trip
        let inMemory = store.entries()
        XCTAssertEqual(inMemory.first?.text, text, "In-memory text must be bit-for-bit identical")
        XCTAssertEqual(inMemory.first?.charCount, text.count, "charCount must equal Swift grapheme-cluster count")

        // Persistence round-trip: re-open same file.
        let store2 = HistoryStore.test(storeURL: url)
        XCTAssertEqual(store2.entries().first?.text, text, "Text must survive JSONL encode/decode without grapheme cluster damage")
        XCTAssertEqual(store2.entries().first?.charCount, text.count, "charCount must be preserved across persistence round-trip")
    }

    // MARK: - testCapEnforcedOnAppendBeyondLimit

    /// Appending 150 entries must evict the oldest 50, leaving exactly 100.
    /// The entries retained must be e50…e149 (newest 100). Both the in-memory
    /// cache and the persisted file must agree on the cap.
    func testCapEnforcedOnAppendBeyondLimit() throws {
        let (store, url) = try makeStore()

        for i in 0..<150 {
            store.append(sampleEntry(text: "e\(i)"))
        }

        let all = store.entries()
        XCTAssertEqual(all.count, 100, "Cap must evict oldest entries, keeping exactly 100")
        XCTAssertEqual(all.first?.text, "e149", "Newest entry (e149) must be first")
        XCTAssertEqual(all.last?.text, "e50", "Oldest surviving entry must be e50")
        XCTAssertFalse(all.contains { $0.text == "e0" }, "Evicted entries (e0–e49) must not appear in results")

        // Persistence layer must also cap to 100 on reload.
        let store2 = HistoryStore.test(storeURL: url)
        XCTAssertEqual(store2.entries().count, 100, "Reloaded store must also have exactly 100 entries (cap enforced at flush)")
        XCTAssertEqual(store2.entries().first?.text, "e149")
        XCTAssertEqual(store2.entries().last?.text, "e50")
    }
}
