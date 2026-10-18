import XCTest
@testable import VoiceType

// Tests for the D3 "honest ASR timeout" primitives introduced to fix the
// fictitious 30s timeout: TranscriptionService.transcribe raced
// whisper.transcribe against a timer inside withThrowingTaskGroup, but the
// group waited for BOTH children, so a genuinely stuck whisper_full call
// (SwiftWhisper's async wrapper is not cancellation-aware) wedged
// isTranscribing forever regardless of the "timeout".
//
// This file covers the generic pieces that make the fix possible without
// requiring a real whisper.cpp model file:
//   - TranscriptionService.race: the timeout primitive that returns as soon
//     as the timer OR the operation wins, never waiting for the loser.
//   - TranscriptionService.effectiveTimeout: the ceiling calculation.
//   - NativeAbortSignal / NativeCString: the ownership primitives that make
//     abandoning a run (and later replacing the prompt buffer) memory-safe.
//   - transcribe(audio:language:)'s two synchronous-guard error paths
//     (.busy, .modelNotLoaded) that don't require a loaded model.
//
// The full abort/abandon path (runNative/abandonRun against a real Whisper
// context) is exercised only by the manual checklist
// (docs/plans/reliable-dictation.md §7.6) — same boundary precedent as
// TranscriptionServiceInitialPromptTests's loadModel note.
@MainActor
final class TranscriptionDeadlineTests: XCTestCase {

    // MARK: - Test doubles

    /// Thread-safe boolean flag for asserting a `@Sendable` closure ran (or
    /// didn't) from a test's main-actor assertions.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    /// Thread-safe counter for asserting how many times a `@Sendable` closure
    /// ran, and for simulating `abandonedRunCount`'s increment/decrement
    /// without a real native run.
    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func decrement() {
            lock.lock()
            count -= 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private struct DummyError: Error, Equatable {}

    // MARK: - race: fast success

    func testRaceFastSuccessReturnsResultWithoutCallingOnTimeout() async throws {
        let onTimeoutFlag = FlagBox()
        let start = Date()

        let result = try await TranscriptionService.race(
            timeout: 5.0,
            operation: { "ok" },
            onTimeout: { onTimeoutFlag.set() }
        )

        XCTAssertEqual(result, "ok")
        XCTAssertFalse(onTimeoutFlag.isSet, "onTimeout must not fire when the operation wins")
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "a fast operation must not wait out the 5s timeout to return"
        )
    }

    // MARK: - race: timeout

    func testRaceTimeoutReturnsQuicklyAndCallsOnTimeoutExactlyOnce() async throws {
        let onTimeoutCount = CountBox()
        let start = Date()

        do {
            _ = try await TranscriptionService.race(
                timeout: 0.05,
                operation: {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return "too slow"
                },
                onTimeout: { onTimeoutCount.increment() }
            )
            XCTFail("Expected TranscriptionError.transcriptionTimeout")
        } catch TranscriptionError.transcriptionTimeout {
            // expected
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "race must not wait for the 2s operation once the 0.05s timeout wins"
        )
        XCTAssertEqual(onTimeoutCount.value, 1, "onTimeout must fire exactly once")
    }

    // MARK: - race: operation error propagates

    func testRaceOperationErrorPropagatesAndSkipsOnTimeout() async throws {
        let onTimeoutFlag = FlagBox()

        do {
            _ = try await TranscriptionService.race(
                timeout: 5.0,
                operation: { throw DummyError() },
                onTimeout: { onTimeoutFlag.set() }
            )
            XCTFail("Expected DummyError to propagate")
        } catch is DummyError {
            // expected
        }

        XCTAssertFalse(onTimeoutFlag.isSet, "onTimeout must not fire when the operation throws first")
    }

    // MARK: - race: abandoned-run accounting invariant (plan review)

    /// Mirrors the real abandon/return bookkeeping (abandonRun increments,
    /// onNativeRunReturned decrements) using a plain counter instead of a
    /// Whisper context: the decrement must happen only once the operation
    /// ACTUALLY completes, never at the moment the timeout fires.
    func testAbandonedRunCounterDecrementsOnlyAfterOperationActuallyCompletes() async throws {
        let counter = CountBox()
        let operationFinished = FlagBox()

        do {
            _ = try await TranscriptionService.race(
                timeout: 0.05,
                operation: {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    operationFinished.set()
                    counter.decrement()
                    return "done"
                },
                onTimeout: { counter.increment() }
            )
            XCTFail("Expected TranscriptionError.transcriptionTimeout")
        } catch TranscriptionError.transcriptionTimeout {
            // expected
        }

        XCTAssertEqual(counter.value, 1, "onTimeout's increment must have run by the time race() throws")
        XCTAssertFalse(operationFinished.isSet, "the abandoned operation must still be running in the background")

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(operationFinished.isSet)
        XCTAssertEqual(counter.value, 0, "the decrement must fire once the native call actually returns, not at timeout time")
    }

    // MARK: - effectiveTimeout

    func testEffectiveTimeoutIsNeverLessThanAudioDuration() {
        XCTAssertEqual(TranscriptionService.effectiveTimeout(base: 30, audioSeconds: 12), 30)
        XCTAssertEqual(TranscriptionService.effectiveTimeout(base: 30, audioSeconds: 90), 90)
    }

    // MARK: - NativeAbortSignal

    func testAbortCallbackReflectsTriggerStateViaUserData() {
        let signal = NativeAbortSignal()
        let userData = Unmanaged.passUnretained(signal).toOpaque()

        XCTAssertFalse(NativeAbortSignal.abortCallback(userData), "must read false before trigger()")
        signal.trigger()
        XCTAssertTrue(NativeAbortSignal.abortCallback(userData), "must read true after trigger()")
    }

    func testAbortCallbackReturnsFalseForNilUserData() {
        XCTAssertFalse(NativeAbortSignal.abortCallback(nil))
    }

    // MARK: - NativeRunToken: return-vs-abandon race (plan review, blocking finding #1)
    //
    // Regression coverage for the "timeout wins the race, but the native call
    // returns before the scheduled abandonRun runs" scenario: onTimeout only
    // *schedules* abandonRun on MainActor (see runNative's onTimeout closure),
    // so onNativeRunReturned can fire first. Without markReturned()/
    // markAbandonedIfStillRunning(), that ordering let abandonRun mark the
    // token abandoned and increment abandonedRunCount with nothing left to
    // decrement it — a permanent leak that eventually makes shutdown() return
    // false forever and discards a perfectly good model.
    //
    // A full end-to-end repro through runNative/abandonRun against a real
    // Whisper instance isn't attempted here: SwiftWhisper's
    // `Whisper(fromFileURL:)` stores the C API's return value in a
    // non-optional `OpaquePointer` (force-unwrapping whatever
    // `whisper_init_from_file` gives back), so constructing one without a
    // valid model file traps the process instead of failing gracefully —
    // same boundary already noted in this file's header comment for the
    // rest of the abort/abandon path. These two tests instead exercise
    // `NativeRunToken` directly, which is where the actual race was fixed.

    func testMarkAbandonedIfStillRunningReturnsFalseAfterReturnAlreadyMarked() {
        let token = NativeRunToken()

        token.markReturned()

        XCTAssertFalse(
            token.markAbandonedIfStillRunning(),
            "a run that already returned must not be markable as abandoned"
        )
        XCTAssertFalse(token.isAbandoned, "a no-op transition must leave isAbandoned false")
    }

    func testMarkAbandonedIfStillRunningSucceedsOnceThenNoOps() {
        let token = NativeRunToken()

        XCTAssertTrue(
            token.markAbandonedIfStillRunning(),
            "abandoning a still-running token must succeed the first time"
        )
        XCTAssertTrue(token.isAbandoned)

        XCTAssertFalse(
            token.markAbandonedIfStillRunning(),
            "a second call on an already-abandoned token must be a no-op"
        )
        XCTAssertTrue(token.isAbandoned, "the no-op must not un-mark the earlier abandon")
    }

    // MARK: - NativeCString

    func testNativeCStringHoldsTheOriginalText() throws {
        let box = try XCTUnwrap(NativeCString("hello world"))
        XCTAssertEqual(String(cString: box.pointer), "hello world")
    }

    // MARK: - transcribe: synchronous guards (no model required)

    func testTranscribeThrowsBusyWhenAlreadyTranscribing() async {
        let service = TranscriptionService()
        service._testIsTranscribing = true

        do {
            _ = try await service.transcribe(audio: [0.1])
            XCTFail("Expected TranscriptionError.busy")
        } catch TranscriptionError.busy {
            // expected
        } catch {
            XCTFail("Expected .busy, got \(error)")
        }
    }

    func testTranscribeWithoutModelThrowsModelNotLoaded() async {
        let service = TranscriptionService()

        do {
            _ = try await service.transcribe(audio: [0.1])
            XCTFail("Expected TranscriptionError.modelNotLoaded")
        } catch TranscriptionError.modelNotLoaded {
            // expected — regression guard, unrelated to the D3 changes above
        } catch {
            XCTFail("Expected .modelNotLoaded, got \(error)")
        }
    }
}
