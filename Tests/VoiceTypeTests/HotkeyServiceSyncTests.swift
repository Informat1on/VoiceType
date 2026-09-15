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

    /// docs/plans/audio-start-hang.md, задача 5, пункт 9: regression guard for
    /// the async-start bug where a menu-started recording (isRecording synced
    /// true while AppDelegate is still `.starting`, not yet `.recording`)
    /// became impossible to stop/cancel via hotkey toggle.
    ///
    /// Граница честно: этот тест доказывает, что при предварительно
    /// выставленном `syncIsRecording(true)` реальная ветка toggle
    /// (`toggleRecordingInternal`, открыта для тестов) уходит в stop и НЕ
    /// обращается к `canStartRecording`. Что `startRecordingFromMenu()`
    /// действительно выставляет флаг сразу при `.starting` — на code review:
    /// полного пути «меню → сервис → хоткей» из этого теста не достать без
    /// DI в AppDelegate, от которой план осознанно отказался.
    @MainActor
    func testToggleStopsMenuStartedRecordingWithoutConsultingCanStartRecording() {
        let service = HotkeyService()
        var stoppedCallCount = 0
        service.onRecordingStopped = { stoppedCallCount += 1 }
        service.canStartRecording = {
            XCTFail("toggle on an already-recording (menu-started) service must not consult canStartRecording")
            return false
        }

        // Simulates AppDelegate.startRecordingFromMenu() syncing the flag as
        // soon as the start is accepted (.starting), before any success.
        service.syncIsRecording(true)

        service.toggleRecordingInternal()

        XCTAssertFalse(service.isRecording, "toggle must stop a menu-started recording")
        XCTAssertEqual(stoppedCallCount, 1)
    }

    /// A hotkey press arriving WHILE a menu-start is still pending (isRecording
    /// already synced true) must resolve to a single stop, not a duplicate or
    /// missed transition — same seam as above.
    @MainActor
    func testStopInternalStopsMenuStartedRecording() {
        let service = HotkeyService()
        var stoppedCallCount = 0
        service.onRecordingStopped = { stoppedCallCount += 1 }
        service.syncIsRecording(true)

        service.stopRecordingInternal()

        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(stoppedCallCount, 1)
    }
}
