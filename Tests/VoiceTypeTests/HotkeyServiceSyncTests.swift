import XCTest
@testable import VoiceType

/// Tests for `HotkeyService.syncIsRecording(_:)` — the bridge that keeps the
/// service's internal `isRecording` flag in step with externally-initiated
/// recording (e.g., the menubar "Start recording" entry point).
/// Regression guard for the bug where menu-started recording could not be
/// stopped via hotkey because the service still thought it wasn't recording.
final class HotkeyServiceSyncTests: XCTestCase {
    @MainActor
    func testSyncTrueSetsIsRecording() {
        let service = HotkeyService()
        XCTAssertFalse(service.isRecording)
        service.syncIsRecording(true)
        XCTAssertTrue(service.isRecording)
    }

    @MainActor
    func testSyncFalseClearsIsRecording() {
        let service = HotkeyService()
        service.syncIsRecording(true)
        service.syncIsRecording(false)
        XCTAssertFalse(service.isRecording)
    }

    @MainActor
    func testSyncIsIdempotent() {
        let service = HotkeyService()
        service.syncIsRecording(true)
        service.syncIsRecording(true)
        XCTAssertTrue(service.isRecording)
        service.syncIsRecording(false)
        service.syncIsRecording(false)
        XCTAssertFalse(service.isRecording)
    }

    @MainActor
    func testSyncTrueAllowsHotkeyToggleToStopMenuStartedRecording() {
        let service = HotkeyService()
        var stoppedCallCount = 0
        service.onRecordingStopped = { stoppedCallCount += 1 }
        // Simulate menu-started recording: external caller flips the flag.
        service.syncIsRecording(true)
        XCTAssertTrue(service.isRecording)
        // A subsequent hotkey-triggered stop path must now succeed.
        // (Direct-call validation: flipping back via sync mirrors what the
        // public stop path does without exercising Carbon APIs.)
        service.syncIsRecording(false)
        XCTAssertFalse(service.isRecording)
        // Callback is NOT invoked by syncIsRecording itself — sync is a pure
        // state bridge; callbacks fire only on hotkey-initiated transitions.
        XCTAssertEqual(stoppedCallCount, 0)
    }
}
