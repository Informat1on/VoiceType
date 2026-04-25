// AppDelegateRecordingTests.swift
//
// NOTE — emptyResult flash + inserted-flash race (codex audit fixes):
//
// Two behaviours added in fix(transcribe) are not unit-tested here because no
// injectable seam exists:
//
//   1. When Whisper returns empty text, `transcribeAndInject` shows .emptyResult
//      for 400 ms then sets appState = .idle. The method is private and drives an
//      NSWindow that cannot be instantiated in a headless Swift test target.
//
//   2. After a successful injection, appState is NOT set to .idle until AFTER the
//      400 ms .inserted flash completes (race fix). Same seam constraint applies.
//
// Both behaviours are covered at the view-model layer:
//   - CapsuleStateTests.swift — verifies .emptyResult is a distinct, equatable state
//   - RecordingWindowTests.swift — verifies CapsuleStateModel publishes .emptyResult
//
// Integration-level verification (manual QA checklist):
//   - Hold hotkey without speaking → capsule should flash "Nothing heard" ~400 ms
//   - Speak → capsule flashes inserted → pressing hotkey during flash must NOT start
//     a new recording (appState is still .injecting during the 400 ms window)
//
// If a future refactor extracts `transcribeAndInject` into a testable pipeline
// struct, add XCTestExpectation-based async tests with a 600 ms wait here.

import XCTest
@testable import VoiceType

final class AppDelegateRecordingTests: XCTestCase {
    func testRecordingReadinessRequiresMicrophonePermission() {
        XCTAssertEqual(
            AppDelegate.recordingReadiness(hasMicrophonePermission: false),
            .missingMicrophonePermission
        )
    }

    func testRecordingReadinessAllowsRecordingWithPermission() {
        XCTAssertEqual(
            AppDelegate.recordingReadiness(hasMicrophonePermission: true),
            .ready
        )
    }

    func testEmptyCaptureMessageExplainsPermissionProblem() {
        XCTAssertEqual(
            AppDelegate.emptyCaptureErrorMessage(hasMicrophonePermission: false),
            AppDelegate.microphonePermissionErrorMessage()
        )
    }

    func testEmptyCaptureMessageExplainsSilentInputWhenPermissionExists() {
        XCTAssertEqual(
            AppDelegate.emptyCaptureErrorMessage(hasMicrophonePermission: true),
            "VoiceType did not capture any audio. Check the selected input device in macOS and try holding the hotkey a bit longer."
        )
    }
}
