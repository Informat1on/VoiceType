// HistoryRecorderTests.swift — VoiceType
//
// Unit tests for HistoryRecorder — the testable seam extracted from
// AppDelegate.transcribeAndInject (task 1, P1 fix). AppDelegate itself is
// untestable at this seam (private method, drives a real NSWindow — see
// AppDelegateRecordingTests.swift header comment), so these tests exercise
// HistoryRecorder directly against a hermetic HistoryStore.test(...) instance,
// proving the actual regression the audit found: a failed injection must not
// drop the transcript from history.

import XCTest
@testable import VoiceType

@MainActor
final class HistoryRecorderTests: XCTestCase {

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

    // MARK: - testSuccessfulInjectionRecordsInsertSuccessTrue

    func testSuccessfulInjectionRecordsInsertSuccessTrue() throws {
        let (store, _) = try makeStore()
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordPending(.init(
            text: "hello world",
            targetAppName: "Cursor",
            targetAppBundleID: "com.cursor.cursor",
            language: "en",
            audioPath: nil,
            model: "small.en-q5_1",
            audioDurationSeconds: 2.0
        ))
        recorder.recordOutcome(id: id, insertSuccess: true)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1, "Exactly one entry must exist")
        XCTAssertEqual(entries.first?.text, "hello world")
        XCTAssertEqual(entries.first?.insertSuccess, true, "Successful injection must record insertSuccess == true")
    }

    // MARK: - testFailedInjectionStillRecordsEntry

    /// The regression this whole task exists to fix: a failed insert (e.g.
    /// revoked Accessibility permission) must NOT drop the transcript.
    func testFailedInjectionStillRecordsEntry() throws {
        let (store, _) = try makeStore()
        let recorder = HistoryRecorder(store: store)

        let id = recorder.recordPending(.init(
            text: "this must survive",
            targetAppName: "Safari",
            targetAppBundleID: "com.apple.safari",
            language: "ru",
            audioPath: "abc.caf",
            model: "small.en-q5_1",
            audioDurationSeconds: 3.5
        ))
        recorder.recordOutcome(id: id, insertSuccess: false)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1, "Entry must be present even though injection failed")
        XCTAssertEqual(entries.first?.text, "this must survive")
        XCTAssertEqual(entries.first?.insertSuccess, false, "Failed injection must record insertSuccess == false")
    }

    // MARK: - testEntryIsPersistedBeforeOutcomeIsKnown

    /// Verifies the ordering contract itself: recordPending alone (before any
    /// recordOutcome call) must already have written the entry to the store.
    /// This is what makes the entry survive a crash between injectText and
    /// recordOutcome, however unlikely.
    func testEntryIsPersistedBeforeOutcomeIsKnown() throws {
        let (store, _) = try makeStore()
        let recorder = HistoryRecorder(store: store)

        _ = recorder.recordPending(.init(
            text: "pending only",
            targetAppName: "Xcode",
            targetAppBundleID: "com.apple.dt.Xcode",
            language: "en",
            audioPath: nil,
            model: nil,
            audioDurationSeconds: nil
        ))

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1, "recordPending alone must persist the entry")
        XCTAssertNil(entries.first?.insertSuccess, "insertSuccess must be nil until recordOutcome is called")
    }

    // MARK: - testRecordOutcomeIsNoopForUnknownID

    func testRecordOutcomeIsNoopForUnknownID() throws {
        let (store, _) = try makeStore()
        let recorder = HistoryRecorder(store: store)

        _ = recorder.recordPending(.init(
            text: "real entry",
            targetAppName: "TestApp",
            targetAppBundleID: "com.test",
            language: "en",
            audioPath: nil,
            model: nil,
            audioDurationSeconds: nil
        ))
        // Update a random unrelated UUID — must not crash or alter the real entry.
        recorder.recordOutcome(id: UUID(), insertSuccess: true)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.insertSuccess, "Unrelated recordOutcome call must not touch the real entry")
    }
}
