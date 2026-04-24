import XCTest
@testable import VoiceType

final class MenuBarStateTests: XCTestCase {

    // MARK: - 1. State derivation: Not Ready

    func testMenuBarStateDerivationNotReady_missingMicOnly() {
        let state = MenuBarStateMachine.derive(
            appState: .idle,
            hasMic: false,
            hasA11y: true,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(
            state,
            .notReady(missingMic: true, missingA11y: false, missingModel: false),
            "Missing mic alone must yield .notReady with missingMic=true"
        )
    }

    func testMenuBarStateDerivationNotReady_missingA11yOnly() {
        let state = MenuBarStateMachine.derive(
            appState: .idle,
            hasMic: true,
            hasA11y: false,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(
            state,
            .notReady(missingMic: false, missingA11y: true, missingModel: false),
            "Missing a11y alone must yield .notReady with missingA11y=true"
        )
    }

    func testMenuBarStateDerivationNotReady_missingModelOnly() {
        let state = MenuBarStateMachine.derive(
            appState: .idle,
            hasMic: true,
            hasA11y: true,
            hasModel: false,
            elapsed: 0
        )
        XCTAssertEqual(
            state,
            .notReady(missingMic: false, missingA11y: false, missingModel: true),
            "Missing model alone must yield .notReady with missingModel=true"
        )
    }

    func testMenuBarStateDerivationNotReady_allMissing() {
        let state = MenuBarStateMachine.derive(
            appState: .idle,
            hasMic: false,
            hasA11y: false,
            hasModel: false,
            elapsed: 0
        )
        XCTAssertEqual(
            state,
            .notReady(missingMic: true, missingA11y: true, missingModel: true),
            "All blockers missing must yield .notReady with all three flags true"
        )
    }

    // MARK: - 2. State derivation: Idle

    func testMenuBarStateDerivationIdle() {
        let state = MenuBarStateMachine.derive(
            appState: .idle,
            hasMic: true,
            hasA11y: true,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(state, .idle, "All blockers satisfied + AppState.idle must yield .idle")
    }

    func testMenuBarStateDerivationIdle_injectingMapsToIdle() {
        // AppState.injecting is a brief transient (< 1 frame) — render as idle
        let state = MenuBarStateMachine.derive(
            appState: .injecting,
            hasMic: true,
            hasA11y: true,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(state, .idle, "AppState.injecting must map to .idle in MenuBarState")
    }

    // MARK: - 3. State derivation: Recording

    func testMenuBarStateDerivationRecording() {
        let state = MenuBarStateMachine.derive(
            appState: .recording,
            hasMic: true,
            hasA11y: true,
            hasModel: true,
            elapsed: 14
        )
        XCTAssertEqual(
            state,
            .recording(elapsed: 14),
            "All blockers satisfied + AppState.recording must yield .recording with the given elapsed"
        )
    }

    // MARK: - 4. State derivation: Transcribing

    func testMenuBarStateDerivationTranscribing() {
        let state = MenuBarStateMachine.derive(
            appState: .transcribing,
            hasMic: true,
            hasA11y: true,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(state, .transcribing, "AppState.transcribing must yield .transcribing")
    }

    // MARK: - 5. Not Ready always wins over recording/transcribing

    func testNotReadyWinsOverRecording() {
        // Even if AppState says recording, missing a blocker means Not Ready
        let state = MenuBarStateMachine.derive(
            appState: .recording,
            hasMic: false,
            hasA11y: true,
            hasModel: true,
            elapsed: 0
        )
        XCTAssertEqual(
            state,
            .notReady(missingMic: true, missingA11y: false, missingModel: false),
            "Not Ready must override recording when a blocker is missing"
        )
    }

    // MARK: - 6. Missing blocker count

    func testNotReadyStepCountComputation_oneMissing() {
        let n = MenuBarStateMachine.missingBlockerCount(
            missingMic: true, missingA11y: false, missingModel: false
        )
        XCTAssertEqual(n, 1)
    }

    func testNotReadyStepCountComputation_twoMissing() {
        let n = MenuBarStateMachine.missingBlockerCount(
            missingMic: true, missingA11y: true, missingModel: false
        )
        XCTAssertEqual(n, 2)
    }

    func testNotReadyStepCountComputation_threeMissing() {
        let n = MenuBarStateMachine.missingBlockerCount(
            missingMic: true, missingA11y: true, missingModel: true
        )
        XCTAssertEqual(n, 3)
    }

    func testNotReadyStepCountComputation_noneMissing() {
        let n = MenuBarStateMachine.missingBlockerCount(
            missingMic: false, missingA11y: false, missingModel: false
        )
        XCTAssertEqual(n, 0, "Zero missing blockers must return 0 (guard against impossible state)")
    }

    // MARK: - 7. Recording timer formatting

    func testRecordingTimerFormat_zero() {
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(0), "0:00")
    }

    func testRecordingTimerFormat_oneSecond() {
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(1), "0:01")
    }

    func testRecordingTimerFormat_59seconds() {
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(59), "0:59")
    }

    func testRecordingTimerFormat_60seconds() {
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(60), "1:00")
    }

    func testRecordingTimerFormat_600seconds() {
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(600), "10:00")
    }

    func testRecordingTimerFormat_3600seconds() {
        // No hour rollover in v1.1; 3600s → "60:00"
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(3600), "60:00")
    }

    func testRecordingTimerFormat_negativeClampsToZero() {
        // Negative elapsed (clock skew / timer jitter) must not produce garbage
        XCTAssertEqual(MenuBarStateMachine.formatElapsed(-5), "0:00")
    }

    // MARK: - 8. MenuBar tokens regression

    func testMenuBarTokensWidth() {
        XCTAssertEqual(MenuBar.width, 280, "MenuBar.width must be 280pt per DESIGN.md § MenuBar dropdown layout")
    }

    func testMenuBarTokensCornerRadius() {
        XCTAssertEqual(MenuBar.cornerRadius, 10, "MenuBar.cornerRadius must be 10 per DESIGN.md § MenuBar dropdown layout")
    }

    func testMenuBarTokensTallyDotSize() {
        XCTAssertEqual(MenuBar.tallyDotSize, 8, "MenuBar.tallyDotSize must be 8pt per DESIGN.md § MenuBar status line")
    }
}
