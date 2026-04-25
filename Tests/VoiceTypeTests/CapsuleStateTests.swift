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

// MARK: - VoiceOver announcement copy tests
//
// Verifies verbatim copy strings per v6-a11y.html § 6.3, lines 271–276.
// Uses the injectable `announcer` seam to capture messages without invoking NSAccessibility.
// Each test also validates the didSet path (state assignment → captured announcement).

final class CapsuleStateModelAnnouncementTests: XCTestCase {

    // MARK: - announcementCopy: verbatim strings

    func testRecordingAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 271
        XCTAssertEqual(model.announcementCopy(for: .recording), "VoiceType recording. Speak now.")
    }

    func testTranscribingAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 272
        XCTAssertEqual(model.announcementCopy(for: .transcribing), "Transcribing.")
    }

    func testInsertedAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 273
        XCTAssertEqual(
            model.announcementCopy(for: .inserted(charCount: 42, targetAppName: "Cursor")),
            "Inserted 42 characters into Cursor."
        )
    }

    func testEmptyResultAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 274
        XCTAssertEqual(model.announcementCopy(for: .emptyResult), "Nothing heard.")
    }

    func testErrorInlineAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 275: message normalized + single trailing period.
        // Caller-provided period stays single (normalizePunctuation strips it, period re-added).
        XCTAssertEqual(
            model.announcementCopy(for: .errorInline(message: "Microphone access denied.")),
            "Microphone access denied."
        )
    }

    func testErrorInlineAnnouncementAddsTrailingPeriod() {
        let model = CapsuleStateModel()
        // Raw fragment — period added.
        XCTAssertEqual(
            model.announcementCopy(for: .errorInline(message: "Transcription failed")),
            "Transcription failed."
        )
        // Caller-provided period stays single.
        XCTAssertEqual(
            model.announcementCopy(for: .errorInline(message: "Microphone access denied.")),
            "Microphone access denied."
        )
        // Caller-provided exclamation is normalized to period.
        XCTAssertEqual(
            model.announcementCopy(for: .errorInline(message: "Model load failed!")),
            "Model load failed."
        )
        // Empty input → empty output (announceStateChange guard skips it).
        XCTAssertEqual(
            model.announcementCopy(for: .errorInline(message: "")),
            ""
        )
    }

    func testErrorToastAnnouncementCopy() {
        let model = CapsuleStateModel()
        // v6-a11y.html line 276: title + body joined with single period each
        XCTAssertEqual(
            model.announcementCopy(for: .errorToast(title: "Model failed", body: "Reload the model.")),
            "Model failed. Reload the model."
        )
    }

    func testErrorToastAnnouncementNormalizesPunctuation() {
        let model = CapsuleStateModel()
        // Body already has terminal period — must not double it.
        XCTAssertEqual(
            model.announcementCopy(for: .errorToast(title: "Model failed", body: "Reload the model.")),
            "Model failed. Reload the model."
        )
        // Body without terminal punctuation — period added.
        XCTAssertEqual(
            model.announcementCopy(for: .errorToast(title: "Network down", body: "Try again")),
            "Network down. Try again."
        )
        // Empty title — only body, single period.
        XCTAssertEqual(
            model.announcementCopy(for: .errorToast(title: "", body: "See log.")),
            "See log."
        )
        // Empty body — only title with trailing bang normalized.
        XCTAssertEqual(
            model.announcementCopy(for: .errorToast(title: "Sync failed!", body: "")),
            "Sync failed."
        )
    }

    // MARK: - didSet path: state assignment triggers announcer

    func testStateAssignmentFiresAnnouncer() {
        let model = CapsuleStateModel()
        var captured: [String] = []
        model.announcer = { captured.append($0) }

        model.state = .recording
        XCTAssertEqual(captured.last, "VoiceType recording. Speak now.")

        model.state = .transcribing
        XCTAssertEqual(captured.last, "Transcribing.")

        model.state = .inserted(charCount: 7, targetAppName: "Notes")
        XCTAssertEqual(captured.last, "Inserted 7 characters into Notes.")

        model.state = .emptyResult
        XCTAssertEqual(captured.last, "Nothing heard.")

        model.state = .errorInline(message: "No mic.")
        XCTAssertEqual(captured.last, "No mic.")

        model.state = .errorToast(title: "Crash", body: "See log.")
        XCTAssertEqual(captured.last, "Crash. See log.")

        XCTAssertEqual(captured.count, 6, "Expected one announcement per state transition")
    }
}
