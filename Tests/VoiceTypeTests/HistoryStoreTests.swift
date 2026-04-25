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
}
