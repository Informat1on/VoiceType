import XCTest
@testable import VoiceType

// Tests for the pure decision helpers added by the reliable-dictation
// AppDelegate integration (task D, docs/plans/reliable-dictation.md §§ D2,
// D4, D6): insertionTargetDecision, latencyMs, and retryPrecheck. All three
// are `nonisolated static func`s with no dependency on a running AppDelegate
// instance, a real NSWindow, or a loaded Whisper model — see
// AppDelegateRecordingTests.swift's header comment for why the rest of the
// pipeline cannot be unit-tested the same way.
@MainActor
final class InsertionTargetDecisionTests: XCTestCase {

    // MARK: - insertionTargetDecision (D2)

    func testNilSessionTargetAlwaysInserts() {
        // VoiceType itself was frontmost at hotkey press — the target check
        // does not apply, matching prior (pre-D2) behavior.
        XCTAssertEqual(
            AppDelegate.insertionTargetDecision(sessionTargetPID: nil, frontmostPID: 123),
            .insert
        )
    }

    func testNilFrontmostAlwaysInserts() {
        // No frontmost app at all (e.g. a transient desktop-switch moment) —
        // falls back to inserting rather than blocking on missing information.
        XCTAssertEqual(
            AppDelegate.insertionTargetDecision(sessionTargetPID: 123, frontmostPID: nil),
            .insert
        )
    }

    func testSamePIDInserts() {
        XCTAssertEqual(
            AppDelegate.insertionTargetDecision(sessionTargetPID: 42, frontmostPID: 42),
            .insert
        )
    }

    func testDifferentPIDBlocks() {
        XCTAssertEqual(
            AppDelegate.insertionTargetDecision(sessionTargetPID: 42, frontmostPID: 99),
            .blockTargetChanged
        )
    }

    // MARK: - latencyMs (D6)

    func testLatencyMsComputesEachLegAndTotal() {
        let clock = ContinuousClock()
        let stop = clock.now
        let samplesReady = stop + .milliseconds(120)
        let asrDone = samplesReady + .milliseconds(340)
        let insertDone = asrDone + .milliseconds(60)

        let result = AppDelegate.latencyMs(
            stop: stop,
            samplesReady: samplesReady,
            asrDone: asrDone,
            insertDone: insertDone
        )

        XCTAssertEqual(result["stopToSamples"], 120)
        XCTAssertEqual(result["asr"], 340)
        XCTAssertEqual(result["insert"], 60)
        XCTAssertEqual(result["total"], 520)
    }

    func testLatencyMsTotalIsAlwaysTheSumOfTheThreeLegs() throws {
        let clock = ContinuousClock()
        let stop = clock.now
        let samplesReady = stop + .milliseconds(7)
        let asrDone = samplesReady + .milliseconds(1_234)
        let insertDone = asrDone + .milliseconds(3)

        let result = AppDelegate.latencyMs(
            stop: stop,
            samplesReady: samplesReady,
            asrDone: asrDone,
            insertDone: insertDone
        )

        let stopToSamples = try XCTUnwrap(result["stopToSamples"])
        let asr = try XCTUnwrap(result["asr"])
        let insert = try XCTUnwrap(result["insert"])
        let total = try XCTUnwrap(result["total"])
        XCTAssertEqual(total, stopToSamples + asr + insert)
    }

    func testLatencyMsFloorsSubMillisecondDurations() {
        let clock = ContinuousClock()
        let stop = clock.now
        // Sub-millisecond leg should floor to 0, not round up to 1.
        let samplesReady = stop + .microseconds(500)
        let asrDone = samplesReady + .milliseconds(10)
        let insertDone = asrDone

        let result = AppDelegate.latencyMs(
            stop: stop,
            samplesReady: samplesReady,
            asrDone: asrDone,
            insertDone: insertDone
        )

        XCTAssertEqual(result["stopToSamples"], 0)
        XCTAssertEqual(result["asr"], 10)
        XCTAssertEqual(result["insert"], 0)
        XCTAssertEqual(result["total"], 10)
    }

    // MARK: - retryPrecheck (D4)

    func testRetryPrecheckBusyTakesPriorityOverEverything() {
        XCTAssertEqual(
            AppDelegate.retryPrecheck(
                isIdle: false,
                entryExists: false,
                entryIsFailed: false,
                audioFileExists: false
            ),
            .busy
        )
    }

    func testRetryPrecheckEntryMissingWhenNoEntry() {
        XCTAssertEqual(
            AppDelegate.retryPrecheck(
                isIdle: true,
                entryExists: false,
                entryIsFailed: false,
                audioFileExists: false
            ),
            .entryMissing
        )
    }

    func testRetryPrecheckNotFailedWhenEntryIsRegular() {
        XCTAssertEqual(
            AppDelegate.retryPrecheck(
                isIdle: true,
                entryExists: true,
                entryIsFailed: false,
                audioFileExists: true
            ),
            .notFailed
        )
    }

    func testRetryPrecheckAudioMissingWhenFileGone() {
        XCTAssertEqual(
            AppDelegate.retryPrecheck(
                isIdle: true,
                entryExists: true,
                entryIsFailed: true,
                audioFileExists: false
            ),
            .audioMissing
        )
    }

    func testRetryPrecheckNilWhenEverythingChecksOut() {
        XCTAssertNil(
            AppDelegate.retryPrecheck(
                isIdle: true,
                entryExists: true,
                entryIsFailed: true,
                audioFileExists: true
            )
        )
    }
}
