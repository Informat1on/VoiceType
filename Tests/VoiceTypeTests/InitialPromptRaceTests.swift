import XCTest
@testable import VoiceType

// Tests for the initial-prompt use-after-free race fix introduced in chunk AA.
//
// Background: whisper_full() runs on a background thread and reads from the raw
// initial_prompt C-string pointer stored in _initialPrompt.  If setInitialPrompt()
// frees that buffer from MainActor while the background thread is still reading,
// the result is a C-level use-after-free.
//
// Fix (Option 1 — deferred apply): when isTranscribing is true, setInitialPrompt
// stores the requested text in _pendingPrompt and returns without touching the live
// C buffer.  _flushPendingPrompt() applies it once the transcription defer fires.
//
// Test seam: isTranscribing is @Published var (internal), so @testable import lets
// tests set it directly without loading a real whisper model.
@MainActor
final class InitialPromptRaceTests: XCTestCase {

    private var service: TranscriptionService!

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptionService()
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: setInitialPrompt while transcribing does NOT free the live buffer

    func testSetInitialPromptDuringTranscriptionDefersUpdate() {
        // Establish a live prompt.
        service.setInitialPrompt("first prompt")
        XCTAssertEqual(service.currentInitialPromptText, "first prompt")

        // Simulate transcription running.
        service.isTranscribing = true

        // Request a prompt change — must be deferred, not applied immediately.
        service.setInitialPrompt("new prompt")

        // currentInitialPromptText must still reflect the live buffer.
        XCTAssertEqual(
            service.currentInitialPromptText,
            "first prompt",
            "Prompt must NOT change while transcribing — buffer is still in use"
        )
    }

    // MARK: - Test 2: pending prompt is applied after transcription completes

    func testPendingPromptIsAppliedAfterTranscriptionCompletes() {
        service.setInitialPrompt("original")
        XCTAssertEqual(service.currentInitialPromptText, "original")

        // Simulate transcription start.
        service.isTranscribing = true
        service.setInitialPrompt("deferred update")

        // Still original while busy.
        XCTAssertEqual(service.currentInitialPromptText, "original")

        // Simulate transcription end — mimics what defer { isTranscribing = false; _flushPendingPrompt() } does.
        service.isTranscribing = false
        // Call the flush directly (it is private, so we trigger it via the same path
        // the defer uses: setting isTranscribing to false does NOT auto-flush in tests —
        // the flush only happens inside the defer block of transcribe().
        // We therefore re-exercise setInitialPrompt now that isTranscribing is false,
        // which simulates the service being idle and a second settings change arriving.
        //
        // To actually exercise _flushPendingPrompt we set isTranscribing=true, queue,
        // then call the internal helper via a second setInitialPrompt call that is idle.
        // Since _flushPendingPrompt is private, we test it indirectly:
        //   1. Queue a deferred prompt.
        //   2. Reset isTranscribing = false.
        //   3. Call setInitialPrompt("") — this calls _applyPromptNow directly (idle),
        //      but does NOT flush the pending. So we need to trigger flush via a fresh
        //      setInitialPrompt cycle.
        //
        // Simpler: expose flushPendingPrompt via a test-only helper.
        // But the brief says "keep it minimal". Use the already-public applyInitialPrompt()
        // as a flush proxy — when idle it calls _applyPromptNow which is fine but does NOT
        // drain _pendingPrompt.
        //
        // CORRECT approach: test the flush by calling the exact code path that transcribe()
        // takes: set isTranscribing=false then call flushPendingPromptForTesting().
        // We expose a single @testable internal helper named _testFlushPendingPrompt().
        service._testFlushPendingPrompt()

        XCTAssertEqual(
            service.currentInitialPromptText,
            "deferred update",
            "Pending prompt must be applied once transcription ends"
        )
    }

    // MARK: - Test 3: nil (clear) deferred during transcription also applies after

    func testClearingPromptToNilDuringTranscriptionAlsoDefers() {
        service.setInitialPrompt("existing prompt")
        XCTAssertEqual(service.currentInitialPromptText, "existing prompt")

        service.isTranscribing = true
        service.setInitialPrompt(nil)   // Request a clear while busy.

        // Must still be non-nil — the buffer is in use.
        XCTAssertEqual(
            service.currentInitialPromptText,
            "existing prompt",
            "Prompt clear must be deferred while transcribing"
        )

        // Flush.
        service.isTranscribing = false
        service._testFlushPendingPrompt()

        XCTAssertNil(service.currentInitialPromptText, "Pending nil-clear must take effect after transcription")
    }

    // MARK: - Test 4: idle path is unaffected — applies immediately

    func testSetInitialPromptWhileIdleAppliesImmediately() {
        XCTAssertFalse(service.isTranscribing)

        service.setInitialPrompt("immediate")
        XCTAssertEqual(service.currentInitialPromptText, "immediate")

        service.setInitialPrompt(nil)
        XCTAssertNil(service.currentInitialPromptText)
    }

    // MARK: - Test 5: last-write-wins for multiple deferred calls

    func testMultipleDeferredPromptsLastWriteWins() {
        service.setInitialPrompt("v1")
        service.isTranscribing = true

        service.setInitialPrompt("v2")
        service.setInitialPrompt("v3")   // Second deferred call overwrites the first.

        service.isTranscribing = false
        service._testFlushPendingPrompt()

        XCTAssertEqual(
            service.currentInitialPromptText,
            "v3",
            "Last-write-wins: only the most recent deferred prompt should be applied"
        )
    }
}
