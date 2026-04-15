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
