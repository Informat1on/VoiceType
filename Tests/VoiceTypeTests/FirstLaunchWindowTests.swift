import XCTest
@testable import VoiceType

final class FirstLaunchWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure each test starts with a clean onboarding state
        UserDefaults.standard.removeObject(forKey: OnboardingState.hasCompletedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.hasCompletedKey)
        super.tearDown()
    }

    // MARK: 1 — UserDefaults round-trip

    func testOnboardingStateHasCompletedRoundTrip() {
        XCTAssertFalse(OnboardingState.hasCompleted, "Default (no value stored) must be false")

        OnboardingState.hasCompleted = true
        XCTAssertTrue(OnboardingState.hasCompleted, "After setting true, must read true")

        OnboardingState.hasCompleted = false
        XCTAssertFalse(OnboardingState.hasCompleted, "After setting false, must read false")
    }

    // MARK: 2 — Blocker evaluation: all granted

    func testBlockerEvaluationAllGranted() {
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: true,
            hasAccessibilityPermission: true,
            hasAnyDownloadedModel: true
        )
        XCTAssertTrue(result, "All three blockers satisfied must return true")
    }

    // MARK: 3 — Blocker evaluation: partial (each individual missing case)

    func testBlockerEvaluationMissingMicrophone() {
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: false,
            hasAccessibilityPermission: true,
            hasAnyDownloadedModel: true
        )
        XCTAssertFalse(result, "Missing microphone permission must return false")
    }

    func testBlockerEvaluationMissingAccessibility() {
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: true,
            hasAccessibilityPermission: false,
            hasAnyDownloadedModel: true
        )
        XCTAssertFalse(result, "Missing accessibility permission must return false")
    }

    func testBlockerEvaluationMissingModel() {
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: true,
            hasAccessibilityPermission: true,
            hasAnyDownloadedModel: false
        )
        XCTAssertFalse(result, "Missing downloaded model must return false")
    }

    func testBlockerEvaluationAllMissing() {
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: false,
            hasAccessibilityPermission: false,
            hasAnyDownloadedModel: false
        )
        XCTAssertFalse(result, "All blockers missing must return false")
    }

    // MARK: 4 — Hotkey is NOT a blocker

    func testHotkeyIsNotABlocker() {
        // Hotkey step is step 4 / neutral — it has no parameter in allBlockersSatisfied.
        // Passing the 3 blockers as true must return true regardless of any hotkey state.
        let result = OnboardingState.allBlockersSatisfied(
            hasMicrophonePermission: true,
            hasAccessibilityPermission: true,
            hasAnyDownloadedModel: true
        )
        XCTAssertTrue(
            result,
            "Three blockers satisfied must return true — hotkey step is not a blocker"
        )
    }

    // MARK: 5 — Key constant stability

    func testOnboardingStateKeyConstant() {
        XCTAssertEqual(
            OnboardingState.hasCompletedKey,
            "hasCompletedOnboarding",
            "Key must match the UserDefaults key used at write sites"
        )
    }
}
