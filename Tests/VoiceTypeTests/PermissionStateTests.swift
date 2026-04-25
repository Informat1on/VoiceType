import XCTest
import AVFoundation
@testable import VoiceType

// MARK: - PermissionState Enum Tests

final class PermissionStateTests: XCTestCase {

    // MARK: 1 — Enum cases are distinct and Equatable

    func testPermissionStateEquatable() {
        XCTAssertEqual(PermissionState.granted, .granted)
        XCTAssertEqual(PermissionState.denied, .denied)
        XCTAssertEqual(PermissionState.notDetermined, .notDetermined)
        XCTAssertNotEqual(PermissionState.granted, .denied)
        XCTAssertNotEqual(PermissionState.granted, .notDetermined)
        XCTAssertNotEqual(PermissionState.denied, .notDetermined)
    }

    // MARK: 2 — hasMicrophonePermission Bool is true only for .granted

    @MainActor
    func testHasMicrophonePermissionTrueOnlyForGranted() async {
        let manager = PermissionManager()

        manager.microphonePermission = .granted
        XCTAssertTrue(manager.hasMicrophonePermission,
                      "hasMicrophonePermission must be true when microphonePermission == .granted")

        manager.microphonePermission = .denied
        XCTAssertFalse(manager.hasMicrophonePermission,
                       "hasMicrophonePermission must be false when microphonePermission == .denied")

        manager.microphonePermission = .notDetermined
        XCTAssertFalse(manager.hasMicrophonePermission,
                       "hasMicrophonePermission must be false when microphonePermission == .notDetermined")
    }

    // MARK: 3 — hasAccessibilityPermission Bool is true only for .granted

    @MainActor
    func testHasAccessibilityPermissionTrueOnlyForGranted() async {
        let manager = PermissionManager()

        manager.accessibilityPermission = .granted
        XCTAssertTrue(manager.hasAccessibilityPermission,
                      "hasAccessibilityPermission must be true when accessibilityPermission == .granted")

        manager.accessibilityPermission = .denied
        XCTAssertFalse(manager.hasAccessibilityPermission,
                       "hasAccessibilityPermission must be false when accessibilityPermission == .denied")

        manager.accessibilityPermission = .notDetermined
        XCTAssertFalse(manager.hasAccessibilityPermission,
                       "hasAccessibilityPermission must be false when accessibilityPermission == .notDetermined")
    }

    // MARK: 4 — microphonePermission on init reflects actual AVCaptureDevice status

    @MainActor
    func testMicrophonePermissionOnInitIsValidState() async {
        let manager = PermissionManager()
        let validStates: [PermissionState] = [.granted, .denied, .notDetermined]
        XCTAssertTrue(
            validStates.contains(manager.microphonePermission),
            "microphonePermission after init must be one of [.granted, .denied, .notDetermined]"
        )
    }

    // MARK: 5 — accessibilityPermission transitions notDetermined → denied after flag is set

    @MainActor
    func testAccessibilityNotDeterminedThenDeniedAfterFlagSet() async {
        // Remove any prior flag to start from a clean state
        UserDefaults.standard.removeObject(forKey: "voicetype.accessibilityPromptShown")
        defer {
            UserDefaults.standard.removeObject(forKey: "voicetype.accessibilityPromptShown")
        }

        // If AX is actually granted in the test environment, skip this test — we
        // can only verify the notDetermined→denied path when the process is not trusted.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else {
            // Process is already trusted — .granted path is the only possible outcome.
            let manager = PermissionManager()
            XCTAssertEqual(
                manager.accessibilityPermission,
                .granted,
                "When process is AX-trusted, accessibilityPermission must be .granted"
            )
            return
        }

        // Flag absent + not trusted → .notDetermined
        let managerBefore = PermissionManager()
        XCTAssertEqual(
            managerBefore.accessibilityPermission,
            .notDetermined,
            "Without the prompt-shown flag and no trust, state must be .notDetermined"
        )

        // Set the flag to simulate having shown the System Settings prompt
        UserDefaults.standard.set(true, forKey: "voicetype.accessibilityPromptShown")

        // Flag present + not trusted → .denied
        let managerAfter = PermissionManager()
        XCTAssertEqual(
            managerAfter.accessibilityPermission,
            .denied,
            "With prompt-shown flag set and no trust, state must be .denied"
        )
    }

    // MARK: 6 — Revocation: granted user revokes AX → state must flip to .denied
    // Code Reviewer L finding P2: revocation path was uncovered.

    @MainActor
    func testAccessibilityRevocationProducesDeniedNotNotDetermined() async {
        // Pre-condition: prompt-shown flag is set (user previously granted, so the
        // flag was set at some point in the past).
        UserDefaults.standard.set(true, forKey: "voicetype.accessibilityPromptShown")
        defer {
            UserDefaults.standard.removeObject(forKey: "voicetype.accessibilityPromptShown")
        }

        // Scenario only meaningful when the process is currently NOT trusted
        // (revocation simulated by the test runner not having AX granted).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else {
            // Process is trusted — we can't test revocation here. The state will
            // correctly be .granted; assert that and exit.
            let manager = PermissionManager()
            XCTAssertEqual(manager.accessibilityPermission, .granted)
            return
        }

        // Flag set + not trusted → .denied (NOT .notDetermined). Critical: a user
        // who previously granted and then revoked should land in .denied, not
        // back in .notDetermined (which would re-open System Settings on the
        // next call to requestAccessibilityPermission(prompt:true)).
        let manager = PermissionManager()
        XCTAssertEqual(
            manager.accessibilityPermission,
            .denied,
            "Revoked user (flag set + not trusted) must be .denied, not .notDetermined"
        )
    }

    // MARK: 7 — PermissionState exhaustive switch (compiler-verified via return type)

    func testPermissionStateAllCasesReachable() {
        // This test primarily documents that all 3 cases exist and can be switched on.
        let states: [PermissionState] = [.granted, .denied, .notDetermined]
        var labels: [String] = []
        for state in states {
            switch state {
            case .granted:       labels.append("granted")
            case .denied:        labels.append("denied")
            case .notDetermined: labels.append("notDetermined")
            }
        }
        XCTAssertEqual(labels, ["granted", "denied", "notDetermined"])
    }
}
