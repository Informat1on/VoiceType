import XCTest
@testable import VoiceType

// Tests for TranscriptionService.setInitialPrompt(_:) lifetime management.
// These tests exercise the strdup/free lifecycle and the stored-text bookkeeping
// without loading a real whisper model (which requires a .bin file on disk).
//
// The re-apply-after-loadModel path is NOT tested here: loadModel requires a
// real model file and a GPU/CPU whisper context, making it too expensive and
// fragile for a unit suite. The logic is covered by code review of the
// loadModel implementation against the ADR.
@MainActor
final class TranscriptionServiceInitialPromptTests: XCTestCase {

    private var service: TranscriptionService!

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptionService()
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testSetInitialPromptStoresNonEmptyText() {
        service.setInitialPrompt("hello")
        XCTAssertEqual(service.currentInitialPromptText, "hello")
    }

    func testSetInitialPromptEmptyStringClearsPrompt() {
        // Prime with a value first so we verify the clear is not a no-op.
        service.setInitialPrompt("something")
        service.setInitialPrompt("")
        XCTAssertNil(service.currentInitialPromptText)
    }

    func testSetInitialPromptNilClearsPrompt() {
        service.setInitialPrompt("something")
        service.setInitialPrompt(nil)
        XCTAssertNil(service.currentInitialPromptText)
    }

    func testSetInitialPromptReplacesPreviousText() {
        // Implicitly exercises the free-old-before-allocate-new path.
        // A memory error (double-free, use-after-free) would crash here
        // under ASan or even in a plain debug run.
        service.setInitialPrompt("first")
        service.setInitialPrompt("second")
        XCTAssertEqual(service.currentInitialPromptText, "second")
    }

    func testSetInitialPromptIdempotentNil() {
        // Calling nil → nil should not crash (no double-free on an already-nil pointer).
        service.setInitialPrompt(nil)
        service.setInitialPrompt(nil)
        XCTAssertNil(service.currentInitialPromptText)
    }
}
