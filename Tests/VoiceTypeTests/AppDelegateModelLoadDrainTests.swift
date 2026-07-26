// AppDelegateModelLoadDrainTests.swift — VoiceType
//
// Regression tests for a defect caught in code review of the M5
// acceleration-policy work: a model/accelerator-mode change arriving while a
// transcription is active used to be lost silently.
//
// `AppDelegate.loadModel(for:)` popped the request off `pendingModelLoadRequest`
// and then called `transcriptionService.unloadModel()` + `loadModel()`
// unconditionally. Both refuse to touch the Whisper context while
// `isTranscribing` is true (UAF guard — see TranscriptionService's doc
// comments on those two methods), so the call sequence was: no-op unload,
// then loadModel() throws immediately. The request was never re-queued, so
// the user's setting change (mode or model) was saved but never actually
// applied to the running accelerator until the next unrelated reload or an
// app restart. This was pre-existing for plain model switches too — the M5
// acceleration-mode change path just made it easy to trigger, since a mode
// flip fires during dictation just as often as a model pick does.
//
// The fix adds `AppDelegate.drain(until:deadline:pollInterval:)`, polled
// before the unload/load pair: it waits (bounded by `modelLoadDrainTimeout`,
// far longer than TranscriptionService.shutdownDrainTimeout's 5s, since this
// wait doesn't block app quit) for `isTranscribing` to clear, then proceeds.
// If it never clears, the request is dropped with a log line to
// ErrorLogger + AppLog rather than spinning forever.
//
// `drain` is tested directly rather than through the full `loadModel(for:)`
// pipeline: that path also touches `ModelManager.downloadModel` (real
// network) and `TranscriptionService.loadModel` (a real Whisper context)
// once the wait clears — neither is reachable from this test target. See the
// "Coverage gaps" notes at the bottom of ModelStatusTests.swift for the
// established precedent on this exact boundary (VT-WARM-001/003/005).
import XCTest
@testable import VoiceType

@MainActor
final class AppDelegateModelLoadDrainTests: XCTestCase {

    /// Core regression guard: a request blocked by a busy condition (standing
    /// in for `isTranscribing`) must be APPLIED once that condition clears
    /// within the deadline — not dropped the instant it's first observed as
    /// busy, which is what the old unload/load pair effectively did.
    func testDrainAppliesRequestOnceConditionClearsWithinDeadline() async {
        var callCount = 0
        let clearAfterCalls = 3

        let applied = await AppDelegate.drain(
            until: {
                callCount += 1
                return callCount <= clearAfterCalls   // "busy" for the first few polls
            },
            deadline: Date().addingTimeInterval(5),
            pollInterval: 5_000_000
        )

        XCTAssertTrue(applied, "Request must be applied once the busy condition clears — it must not be lost")
        XCTAssertGreaterThan(callCount, clearAfterCalls, "drain must have kept polling through the busy window")
    }

    /// If the condition never clears, drain() must give up at the deadline
    /// rather than looping forever — the caller then logs and drops the
    /// request instead of busy-waiting or retrying in a tight loop.
    func testDrainGivesUpAtDeadlineWithoutSpinningForever() async {
        let start = Date()

        let applied = await AppDelegate.drain(
            until: { true },   // never clears — simulates a genuinely wedged transcription
            deadline: Date().addingTimeInterval(0.1),
            pollInterval: 10_000_000
        )

        XCTAssertFalse(applied, "A condition that never clears must report failure, not hang forever")
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            1.0,
            "drain() must return promptly once its own deadline passes, not loop indefinitely"
        )
    }

    /// Regression guard for the common case: if the condition is already
    /// clear (no transcription in progress), drain() must return true
    /// immediately without waiting out a full poll cycle first.
    func testDrainReturnsImmediatelyWhenNotBusy() async {
        let start = Date()

        let applied = await AppDelegate.drain(
            until: { false },
            deadline: Date().addingTimeInterval(5),
            pollInterval: 50_000_000
        )

        XCTAssertTrue(applied)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.05,
            "An already-clear condition must not incur a poll-interval sleep"
        )
    }
}
