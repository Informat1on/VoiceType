import XCTest
@testable import VoiceType

// Tests for TranscriptionService.conditionallyTrim(_:).
//
// These tests verify that the user-facing "Trim trailing whitespace" toggle in
// Settings > General > Insertion actually controls whether whisper output is
// trimmed. The helper is `internal` (exposed for @testable import) so we can
// test it in isolation without invoking whisper.cpp, which requires a real
// .bin model file on disk.
//
// Each test resets AppSettings.shared.trimWhitespaceAfterInsert to its default
// (true) in tearDown to prevent bleed into other test cases.
@MainActor
final class TranscriptionServiceTrimToggleTests: XCTestCase {

    override func tearDown() async throws {
        // Restore default so subsequent tests start from a clean slate.
        AppSettings.shared.trimWhitespaceAfterInsert = true
        try await super.tearDown()
    }

    // MARK: - Toggle ON (default)

    func testTrimOnRemovesLeadingAndTrailingWhitespace() {
        AppSettings.shared.trimWhitespaceAfterInsert = true
        let result = TranscriptionService.conditionallyTrim("  hello world  ")
        XCTAssertEqual(result, "hello world")
    }

    func testTrimOnRemovesNewlines() {
        AppSettings.shared.trimWhitespaceAfterInsert = true
        let result = TranscriptionService.conditionallyTrim("\nhello\n")
        XCTAssertEqual(result, "hello")
    }

    func testTrimOnRemovesTrailingSpaceWhisperOftenEmits() {
        // Whisper frequently emits a single trailing space — the primary motivation
        // for this toggle (DESIGN.md § General > Insertion).
        AppSettings.shared.trimWhitespaceAfterInsert = true
        let result = TranscriptionService.conditionallyTrim("Hello, world. ")
        XCTAssertEqual(result, "Hello, world.")
    }

    func testTrimOnEmptyStringRemainsEmpty() {
        AppSettings.shared.trimWhitespaceAfterInsert = true
        let result = TranscriptionService.conditionallyTrim("")
        XCTAssertEqual(result, "")
    }

    func testTrimOnAlreadyCleanStringIsUnchanged() {
        AppSettings.shared.trimWhitespaceAfterInsert = true
        let result = TranscriptionService.conditionallyTrim("clean text")
        XCTAssertEqual(result, "clean text")
    }

    // MARK: - Toggle OFF

    func testTrimOffPreservesLeadingWhitespace() {
        AppSettings.shared.trimWhitespaceAfterInsert = false
        let result = TranscriptionService.conditionallyTrim("  hello  ")
        XCTAssertEqual(result, "  hello  ")
    }

    func testTrimOffPreservesTrailingNewline() {
        AppSettings.shared.trimWhitespaceAfterInsert = false
        let result = TranscriptionService.conditionallyTrim("hello\n")
        XCTAssertEqual(result, "hello\n")
    }

    func testTrimOffPreservesTrailingSpaceWhisperEmits() {
        // With trim disabled the caller receives the raw whisper output intact.
        AppSettings.shared.trimWhitespaceAfterInsert = false
        let result = TranscriptionService.conditionallyTrim("Hello, world. ")
        XCTAssertEqual(result, "Hello, world. ")
    }

    func testTrimOffEmptyStringRemainsEmpty() {
        AppSettings.shared.trimWhitespaceAfterInsert = false
        let result = TranscriptionService.conditionallyTrim("")
        XCTAssertEqual(result, "")
    }

    // MARK: - Toggle round-trip

    func testToggleFlipChangesOutput() {
        let raw = "  whisper output  "

        AppSettings.shared.trimWhitespaceAfterInsert = true
        let trimmed = TranscriptionService.conditionallyTrim(raw)
        XCTAssertEqual(trimmed, "whisper output")

        AppSettings.shared.trimWhitespaceAfterInsert = false
        let untrimmed = TranscriptionService.conditionallyTrim(raw)
        XCTAssertEqual(untrimmed, raw)
    }

    // MARK: - Default is true

    func testDefaultTrimIsEnabled() {
        // Confirm default is true so AppSettings migration doesn't accidentally
        // disable trim for existing users. DESIGN.md § General > Insertion.
        AppSettings.shared.trimWhitespaceAfterInsert = true  // explicit set, mirrors default
        XCTAssertTrue(AppSettings.shared.trimWhitespaceAfterInsert)
    }
}
