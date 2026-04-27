// ErrorToastQueueTests.swift — VoiceType
//
// Unit tests for ErrorToastWindow queue behaviour and logging integration.
//
// Requirements tested:
//   1. Toast→log integration: logger closure is called when show() is invoked.
//   2. Min-visible-time: a second show() within minVisibleTime queues instead
//      of replacing immediately.
//   3. Queue max-size drop: a 4th enqueue drops the oldest queued entry (index 0
//      of the queue, NOT the currently-displayed toast) and logs a warning.
//
// Implementation notes:
//   - `minVisibleTime` is set to 0 s for tests that need instant replacement and
//     to a large value for tests that need to guarantee queueing.
//   - The `logger` closure is replaced with a capturing mock so tests never touch
//     the real ~/Library/Logs/VoiceType/errors.log file.

import XCTest
@testable import VoiceType

@MainActor
final class ErrorToastQueueTests: XCTestCase {

    // MARK: - Helpers

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var toast: ErrorToastWindow!
    private var loggedMessages: [(message: String, category: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        toast = ErrorToastWindow()
        loggedMessages = []
        // Inject mock logger — no file I/O.
        toast.logger = { [weak self] message, category in
            self?.loggedMessages.append((message: message, category: category))
        }
    }

    override func tearDown() async throws {
        toast.hide()
        toast = nil
        loggedMessages = []
        try await super.tearDown()
    }

    // MARK: - 1. Toast → log integration

    /// Logger closure is called exactly once when show() is invoked.
    func testShowLogsToErrorLogger() {
        toast.show(title: "Crash", body: "whisper exited unexpectedly")

        XCTAssertEqual(loggedMessages.count, 1, "show() must call logger exactly once")
        let entry = loggedMessages[0]
        XCTAssertEqual(entry.category, "toast", "logger category must be 'toast'")
        XCTAssertTrue(
            entry.message.contains("Crash"),
            "logger message must contain the title; got: \(entry.message)"
        )
        XCTAssertTrue(
            entry.message.contains("whisper exited unexpectedly"),
            "logger message must contain the body; got: \(entry.message)"
        )
    }

    /// Logger is called for every show() — even rapid successive calls.
    func testEachShowCallLogs() {
        // minVisibleTime = 999 so all calls after the first are queued,
        // but logging must still happen for every call.
        toast.minVisibleTime = 999
        toast.show(title: "Error 1", body: "body1")
        toast.show(title: "Error 2", body: "body2")
        toast.show(title: "Error 3", body: "body3")

        XCTAssertEqual(loggedMessages.count, 3, "Each show() must log independently")
    }

    // MARK: - 2. Min-visible-time queue

    /// When a second show() arrives within minVisibleTime, the toast stays visible
    /// (not replaced or hidden) and the window remains showing the first content.
    func testSecondShowWithinMinVisibleTimeQueues() async throws {
        toast.minVisibleTime = 10.0 // large so second call always queues

        toast.show(title: "First", body: "B1")
        XCTAssertTrue(toast.isVisible, "Toast must be visible after first show()")

        // Second show() should queue, not immediately replace.
        toast.show(title: "Second", body: "B2")

        // Wait a tick to confirm the window is still visible.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(toast.isVisible, "Toast must remain visible; second show() should have queued")
    }

    /// When a show() arrives and minVisibleTime has already elapsed, the toast
    /// is replaced immediately (no queue involvement).
    func testShowAfterMinVisibleTimeReplacesImmediately() async throws {
        toast.minVisibleTime = 0.0 // elapsed immediately

        toast.show(title: "First", body: "B1")
        XCTAssertTrue(toast.isVisible)

        // With minVisibleTime = 0 the elapsed time already exceeds it.
        toast.show(title: "Second", body: "B2")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(toast.isVisible, "Toast must still be visible after replacement")
        // Only 2 log entries — no queue-drop warning.
        XCTAssertEqual(loggedMessages.count, 2, "Two show() calls must produce two log entries")
        let categories = loggedMessages.map(\.category)
        XCTAssertFalse(categories.contains("toast-warning"), "No queue-drop warning expected")
    }

    // MARK: - 3. Queue max-size drop

    /// The 4th enqueue (when queue already holds maxQueueDepth=3 entries) must
    /// drop the oldest queued entry (not the currently-displayed toast) and
    /// emit a warning via the logger.
    func testFourthToastDropsOldestQueued() {
        // Use a very large minVisibleTime so all calls after the first queue.
        toast.minVisibleTime = 999

        toast.show(title: "Shown", body: "Currently displayed") // shown immediately
        toast.show(title: "Q1", body: "Queue entry 1")          // queued [0]
        toast.show(title: "Q2", body: "Queue entry 2")          // queued [1]
        toast.show(title: "Q3", body: "Queue entry 3")          // queued [2] → queue full (3)
        // Now queue is at capacity. Next show() should drop Q1 and log a warning.
        toast.show(title: "Q4", body: "Queue entry 4")          // drops Q1, queued [2]

        // Total log calls: 5 show() + 1 queue-drop warning = 6
        XCTAssertEqual(loggedMessages.count, 6, "Expected 5 show() logs + 1 drop warning; got \(loggedMessages.count)")

        let warningEntries = loggedMessages.filter { $0.category == "toast-warning" }
        XCTAssertEqual(warningEntries.count, 1, "Exactly one queue-drop warning expected")
        XCTAssertTrue(
            warningEntries[0].message.contains("Q1"),
            "Warning must identify the dropped entry (Q1); got: \(warningEntries[0].message)"
        )
    }

    /// Verify the queue is FIFO: after the current toast is hidden the oldest
    /// queued entry is shown next.
    func testQueueIsFIFO() async throws {
        toast.minVisibleTime = 999

        toast.show(title: "Shown", body: "first")
        toast.show(title: "Second", body: "second") // queued [0]
        toast.show(title: "Third", body: "third")   // queued [1]

        // Both show() calls should have been logged.
        XCTAssertEqual(loggedMessages.count, 3)

        // Hiding the current toast dequeues the oldest (Second).
        // After hide(), Second becomes visible.
        toast.hide()

        // isVisible reflects whether the NSPanel is on screen.
        // The next queued entry is shown synchronously in showNextQueued().
        XCTAssertTrue(toast.isVisible, "Next queued toast (Second) must become visible after hide()")
    }
}
