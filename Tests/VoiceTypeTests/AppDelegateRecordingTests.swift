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
//
// NOTE — P2 review findings #1 and #2 (injection failure UI + transcription error auto-dismiss):
//
// These behaviours cannot be unit-tested without NSWindow instantiation or a real
// AppDelegate lifecycle (which requires macOS UI entitlements not available in a
// headless test target). The CapsuleStateModel layer IS fully covered:
//
//   P2-#1: injectText returning false while pendingErrorInlineShown=true must NOT
//          call voiceTypeWindow?.hide(). Covered manually:
//          - Trigger an injection failure → capsule must remain in .errorInline state
//            for ~4s, then auto-dismiss (NOT vanish immediately after injectText returns).
//
//   P2-#2: transcription catch must call scheduleErrorInlineDismiss(after:4).
//          Covered at the CapsuleStateModel layer:
//          - CapsuleStateTests verifies scheduleErrorInlineDismiss posts
//            .capsuleErrorInlineExpired after 4s (existing test).
//
// Both are integration-verified via the manual QA checklist in TODOS.md.
// If AppDelegate is refactored to accept injectable window/state seams, add
// XCTestExpectation-based async tests here.
//
// NOTE — P2 round-4/5: stop-time mic-denied suppress-restore fix
//
// Round 5 fix: suppressNextRestore() is now called BEFORE the initial
// voiceTypeWindow?.hide() in handleRecordingStopped(). Prior to this fix,
// hide() triggered restore() which pulled focus back from System Settings
// before suppressNextRestore() had a chance to run.
//
// Manual QA: trigger empty-recording mic-denied path → verify Settings stays
// in front 4 seconds after the inline error appears (no auto-pull-back).
// Steps:
//   1. Revoke Microphone permission for VoiceType in System Settings → Privacy.
//   2. Press and hold the hotkey briefly without speaking, then release.
//   3. VoiceType should open Microphone Settings and show the inline error.
//   4. Settings must remain frontmost for the full ~4s error-dismiss window —
//      the captured app must NOT steal focus back during that time.
//   5. Also verify across Spaces / fullscreen apps — the previous symptom was
//      especially disruptive when the captured app was on a different Space.
//
// NOTE — P2-1 and P2-2 codex fixes (persistent toast VoiceOver + ErrorLogger in catch):
//
// Manual QA checklist (no injectable seam available for unit tests):
//
//   P2-1: "QA: with VoiceOver enabled, grant Accessibility while app is running →
//          verify VoiceOver speaks the restart toast title + body (e.g.
//          'Restart required. VoiceType needs to restart to apply the new
//          Accessibility permission.')"
//
//   P2-2: "QA: trigger a transcription failure (e.g., rename the model file to
//          corrupt it) → verify an entry appears in
//          ~/Library/Logs/VoiceType/errors.log within seconds of the
//          capsule showing the inline error."

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
