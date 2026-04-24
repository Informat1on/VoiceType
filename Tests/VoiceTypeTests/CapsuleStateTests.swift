// CapsuleStateTests.swift — Tier A Step 6 (Scope E)
//
// Verifies equatability across all 6 CapsuleState cases, including
// associated-value comparison. Guards against accidental Equatable breakage
// when adding new states.
//
// DESIGN.md § Interaction States — Capsule.

import XCTest
@testable import VoiceType

final class CapsuleStateTests: XCTestCase {

    // MARK: - Simple case equality

    func testRecordingEqualsRecording() {
        XCTAssertEqual(CapsuleState.recording, CapsuleState.recording)
    }

    func testTranscribingEqualsTranscribing() {
        XCTAssertEqual(CapsuleState.transcribing, CapsuleState.transcribing)
    }

    func testEmptyResultEqualsEmptyResult() {
        XCTAssertEqual(CapsuleState.emptyResult, CapsuleState.emptyResult)
    }

    // MARK: - Associated value equality

    func testInsertedEqualsSameValues() {
        let a = CapsuleState.inserted(charCount: 42, targetAppName: "Cursor")
        let b = CapsuleState.inserted(charCount: 42, targetAppName: "Cursor")
        XCTAssertEqual(a, b)
    }

    func testInsertedNotEqualDifferentCharCount() {
        let a = CapsuleState.inserted(charCount: 10, targetAppName: "Cursor")
        let b = CapsuleState.inserted(charCount: 20, targetAppName: "Cursor")
        XCTAssertNotEqual(a, b)
    }

    func testInsertedNotEqualDifferentAppName() {
        let a = CapsuleState.inserted(charCount: 42, targetAppName: "Cursor")
        let b = CapsuleState.inserted(charCount: 42, targetAppName: "Notes")
        XCTAssertNotEqual(a, b)
    }

    func testErrorInlineEqualsSameMessage() {
        let a = CapsuleState.errorInline(message: "Mic denied")
        let b = CapsuleState.errorInline(message: "Mic denied")
        XCTAssertEqual(a, b)
    }

    func testErrorInlineNotEqualDifferentMessage() {
        let a = CapsuleState.errorInline(message: "Mic denied")
        let b = CapsuleState.errorInline(message: "No model")
        XCTAssertNotEqual(a, b)
    }

    func testErrorToastEqualsSameValues() {
        let a = CapsuleState.errorToast(title: "Crash", body: "See log")
        let b = CapsuleState.errorToast(title: "Crash", body: "See log")
        XCTAssertEqual(a, b)
    }

    func testErrorToastNotEqualDifferentTitle() {
        let a = CapsuleState.errorToast(title: "Crash", body: "See log")
        let b = CapsuleState.errorToast(title: "OOM", body: "See log")
        XCTAssertNotEqual(a, b)
    }

    func testErrorToastNotEqualDifferentBody() {
        let a = CapsuleState.errorToast(title: "Crash", body: "See log")
        let b = CapsuleState.errorToast(title: "Crash", body: "Reload model")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Cross-case inequality

    func testRecordingNotEqualTranscribing() {
        XCTAssertNotEqual(CapsuleState.recording, CapsuleState.transcribing)
    }

    func testRecordingNotEqualEmptyResult() {
        XCTAssertNotEqual(CapsuleState.recording, CapsuleState.emptyResult)
    }

    func testTranscribingNotEqualEmptyResult() {
        XCTAssertNotEqual(CapsuleState.transcribing, CapsuleState.emptyResult)
    }

    func testInsertedNotEqualRecording() {
        let inserted = CapsuleState.inserted(charCount: 5, targetAppName: "App")
        XCTAssertNotEqual(inserted, CapsuleState.recording)
    }

    func testErrorInlineNotEqualEmptyResult() {
        let err = CapsuleState.errorInline(message: "error")
        XCTAssertNotEqual(err, CapsuleState.emptyResult)
    }

    func testErrorToastNotEqualErrorInline() {
        let toast = CapsuleState.errorToast(title: "T", body: "B")
        let inline = CapsuleState.errorInline(message: "T")
        XCTAssertNotEqual(toast, inline)
    }

    // MARK: - All 6 cases are distinct from each other

    func testAllSixCasesAreMutuallyInequal() {
        let states: [CapsuleState] = [
            .recording,
            .transcribing,
            .inserted(charCount: 1, targetAppName: "App"),
            .errorInline(message: "err"),
            .errorToast(title: "t", body: "b"),
            .emptyResult
        ]

        for i in 0..<states.count {
            for j in 0..<states.count where i != j {
                XCTAssertNotEqual(states[i], states[j], "Expected \(states[i]) != \(states[j])")
            }
        }
    }
}
