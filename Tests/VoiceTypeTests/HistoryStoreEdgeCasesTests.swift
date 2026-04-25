// HistoryStoreEdgeCasesTests.swift — VoiceType
//
// Edge-case tests for HistoryStore covering disk failure, partial-line corruption,
// reentrant-load idempotency, and file-deleted-under-us scenarios.
// All tests are hermetic: each uses a fresh temp directory via
// HistoryStore.test(storeURL:) and cleans up in addTeardownBlock.
//
// Phase 2.5 follow-up — chunk U.

import XCTest
@testable import VoiceType

@MainActor
final class HistoryStoreEdgeCasesTests: XCTestCase {

    // MARK: - Helpers

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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

    // MARK: - testDiskFullInMemoryStillUpdates

    /// Edge case 1: disk write failure (parent directory does not exist).
    ///
    /// HistoryStore is initialised with a storeURL whose parent directory does not
    /// exist, so every flush() will fail. Expected behaviour per DESIGN.md:
    ///   a) append() must not crash or throw.
    ///   b) The in-memory list must still update (UI works for the session).
    ///   c) A second append must also succeed in-memory.
    ///
    /// If this test fails, flush() is propagating errors up instead of swallowing them.
    func testDiskFullInMemoryStillUpdates() throws {
        // Point storeURL at a nonexistent directory — flush will always fail.
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent")
        // NOTE: do NOT create missingDir; that's the point.
        addTeardownBlock { try? FileManager.default.removeItem(at: missingDir) }
        let url = missingDir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url)

        // Both appends should silently swallow the write failure.
        store.append(sampleEntry(text: "first"))
        store.append(sampleEntry(text: "second"))

        let all = store.entries()
        // If count == 0 the append bailed out before updating cachedEntries.
        XCTAssertEqual(all.count, 2, "In-memory list must update even when disk flush fails")
        XCTAssertEqual(all.first?.text, "second", "Newest entry must be first (newest-first)")
        XCTAssertEqual(all.last?.text, "first", "Oldest entry must be last")

        // The other half of the invariant: the file MUST NOT exist on disk. Without
        // this assertion the test is a false-green — it would also pass if flush()
        // accidentally created the parent dir and succeeded.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "history.jsonl must not exist when its parent dir was never created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir.path),
                       "Parent dir must not have been created as a side effect of flush()")
    }

    // MARK: - testDiskFullThenRecoveryWritesCleanFile

    /// Edge case 1b: after disk-failure appends, creating the directory and doing one
    /// more append must produce a clean, valid file (no corruption from prior failures).
    func testDiskFullThenRecoveryWritesCleanFile() throws {
        let recoveryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        // Do NOT create the dir yet — first appends will fail to flush.
        addTeardownBlock { try? FileManager.default.removeItem(at: recoveryDir) }
        let url = recoveryDir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url)

        store.append(sampleEntry(text: "offline-1"))
        store.append(sampleEntry(text: "offline-2"))

        // Heal the disk.
        try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        store.append(sampleEntry(text: "online-3"))

        XCTAssertEqual(store.entries().count, 3, "All three in-memory entries must be present after recovery")
        XCTAssertEqual(store.entries().first?.text, "online-3")

        // The file must be a valid JSONL with exactly 3 clean lines.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        // If count differs, offline appends leaked partial data into the file.
        XCTAssertEqual(lines.count, 3, "Recovered file must contain exactly 3 clean JSONL lines")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            XCTAssertNoThrow(try decoder.decode(HistoryStore.Entry.self, from: Data(line.utf8)),
                             "Every line in the recovered file must be valid JSON")
        }
    }

    // MARK: - testLoadDropsPartialLastLineAndSubsequentAppendIsClean

    /// Edge case 2: file with a half-written last JSON object (no closing brace, no newline).
    ///
    /// Expected behaviour:
    ///   a) load() silently drops the partial line.
    ///   b) Valid prior lines are kept.
    ///   c) A subsequent append() writes a clean new line (NOT concatenated to the fragment).
    ///
    /// HistoryStore uses flush() with options: .atomic (write-to-tmp + rename), so it always
    /// rewrites the whole file cleanly. This test verifies that contract is upheld.
    func testLoadDropsPartialLastLineAndSubsequentAppendIsClean() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("history.jsonl")

        // Write one valid JSONL line followed by a partial (no closing brace, no newline).
        let id1 = "00000000-0000-0000-0000-000000000010"
        let validLine = "{\"id\":\"\(id1)\","
            + "\"timestamp\":\"2024-03-01T10:00:00Z\","
            + "\"text\":\"valid\","
            + "\"charCount\":5,"
            + "\"targetAppName\":\"App\","
            + "\"targetAppBundleID\":\"com.app\","
            + "\"language\":\"en\"}\n"
        let partialLine = "{\"text\":\"hello"   // No closing brace, no newline.
        try (validLine + partialLine).write(to: url, atomically: false, encoding: .utf8)

        let store = HistoryStore.test(storeURL: url)

        // Load: valid line survives, partial line is silently dropped.
        let loaded = store.entries()
        // Count 0 would mean load() aborted on the partial line instead of skipping it.
        XCTAssertEqual(loaded.count, 1, "Valid line must be kept; partial last line must be dropped")
        XCTAssertEqual(loaded.first?.text, "valid")

        // Append triggers flush() which rewrites the whole file atomically.
        store.append(sampleEntry(text: "appended"))

        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        // Count > 2 would mean the partial fragment leaked into the rewrite.
        XCTAssertEqual(lines.count, 2, "After append, file must have exactly 2 clean lines")
        XCTAssertFalse(raw.contains("\"text\":\"hello"), "Partial fragment must not appear in clean rewrite")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            XCTAssertNoThrow(try decoder.decode(HistoryStore.Entry.self, from: Data(line.utf8)),
                             "Every line after append must be valid JSONL")
        }
    }

    // MARK: - testLoadIsIdempotent

    /// Edge case 3: @MainActor isolation means true concurrent load + append is impossible
    /// within a single XCTest run — all work runs on the main actor's serial queue.
    ///
    /// What IS worth testing: calling entries() multiple times produces identical, stable
    /// in-memory state, confirming the `loaded` guard prevents redundant disk reads.
    func testLoadIsIdempotent() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("history.jsonl")

        // Pre-populate file with two entries.
        let id1 = "00000000-0000-0000-0000-000000000020"
        let id2 = "00000000-0000-0000-0000-000000000021"
        let tail = ",\"charCount\":5,\"targetAppName\":\"A\",\"targetAppBundleID\":\"a\",\"language\":\"en\"}"
        let line1 = "{\"id\":\"\(id1)\",\"timestamp\":\"2024-04-01T08:00:00Z\",\"text\":\"alpha\"\(tail)\n"
        let line2 = "{\"id\":\"\(id2)\",\"timestamp\":\"2024-04-01T09:00:00Z\",\"text\":\"beta\"\(tail)\n"
        try (line1 + line2).write(to: url, atomically: true, encoding: .utf8)

        let store = HistoryStore.test(storeURL: url)

        // First call triggers load.
        let first = store.entries()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first?.text, "beta", "Newest-first: beta (later timestamp) must be first")

        // Mutate the file on disk OUT-OF-BAND to a single different entry. If the
        // `loaded` guard works, entries() must keep returning the original cached
        // state. Without the guard this test would fail (second call would see the
        // mutated single-entry file). This is the actual proof of idempotency.
        let id3 = "00000000-0000-0000-0000-000000000099"
        let mutatedLine = "{\"id\":\"\(id3)\",\"timestamp\":\"2024-04-01T07:00:00Z\",\"text\":\"mutated\"\(tail)\n"
        try mutatedLine.write(to: url, atomically: true, encoding: .utf8)

        // Second call must still return the original (cached) state.
        let second = store.entries()
        XCTAssertEqual(second.count, 2, "loaded guard must prevent re-read after first load")
        XCTAssertEqual(second.first?.text, "beta", "Cached order must persist across calls")
        XCTAssertEqual(second.map(\.id), first.map(\.id),
                       "UUIDs must match first load — disk mutation must NOT leak into in-memory state")

        // Third call — same invariant.
        let third = store.entries()
        XCTAssertEqual(third.count, 2)
        XCTAssertFalse(third.contains { $0.text == "mutated" },
                       "Out-of-band disk mutation must remain invisible until an explicit reload")
    }

    // MARK: - testFileDeletedUnderUsNextAppendRecreatesFile

    /// Edge case 4: file is deleted while the store is running (e.g. `rm history.jsonl`).
    ///
    /// Expected behaviour:
    ///   a) in-memory list is unaffected (loaded flag stays true, cachedEntries unchanged).
    ///   b) The next append() triggers flush(), which recreates the file cleanly.
    ///   c) The recreated file contains exactly the current in-memory entries.
    func testFileDeletedUnderUsNextAppendRecreatesFile() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url)

        store.append(sampleEntry(text: "before-delete"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File must exist after first append")

        // Simulate `rm history.jsonl`.
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Precondition: file must be gone")

        // In-memory list must still be intact.
        XCTAssertEqual(store.entries().count, 1, "In-memory entries must survive file deletion")
        XCTAssertEqual(store.entries().first?.text, "before-delete")

        // Append triggers flush() which must recreate the file.
        store.append(sampleEntry(text: "after-delete"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "flush() must recreate file after deletion")

        let all = store.entries()
        XCTAssertEqual(all.count, 2, "Both entries (pre- and post-deletion) must be in-memory")
        XCTAssertEqual(all.first?.text, "after-delete")
        XCTAssertEqual(all.last?.text, "before-delete")

        // Recreated file must be valid JSONL with 2 entries in chronological order.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "Recreated file must have exactly 2 JSONL lines")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(HistoryStore.Entry.self, from: Data($0.utf8)) }
        // File stores entries chronologically (oldest-first).
        XCTAssertEqual(decoded.first?.text, "before-delete", "Oldest entry must be first in file")
        XCTAssertEqual(decoded.last?.text, "after-delete", "Newest entry must be last in file")
    }

    // MARK: - testDeletedFileReloadedByNewStoreInstanceReflectsCurrentState

    /// Complementary to testFileDeletedUnderUsNextAppendRecreatesFile:
    /// a brand-new HistoryStore instance opened after the file was recreated
    /// must read back exactly the same two entries.
    func testDeletedFileReloadedByNewStoreInstanceReflectsCurrentState() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: url)

        store.append(sampleEntry(text: "original"))
        try FileManager.default.removeItem(at: url)
        store.append(sampleEntry(text: "recreated"))

        // New instance reads the recreated file.
        let store2 = HistoryStore.test(storeURL: url)
        let reloaded = store2.entries()
        XCTAssertEqual(reloaded.count, 2, "New store instance must read back both entries from recreated file")
        // entries() returns newest-first (load reverses the chronological-on-disk order),
        // so "recreated" (last appended) must be at index 0 and "original" at the tail.
        XCTAssertEqual(reloaded.first?.text, "recreated")
        XCTAssertEqual(reloaded.last?.text, "original")
    }
}
