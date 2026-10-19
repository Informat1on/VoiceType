// FocusCaptureSnapshotTests.swift — VoiceType Save & Insert
//
// snapshot() must be a pure read: it must not touch the shared capture state
// that live dictation relies on (docs/plans/fix-and-reinsert.md C1).

import XCTest
import AppKit
@testable import VoiceType

@MainActor
final class FocusCaptureSnapshotTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        FocusCaptureService.shared.clear()
    }

    override func tearDown() async throws {
        FocusCaptureService.shared.isRestoreSuppressed = false
        FocusCaptureService.shared.clear()
        try await super.tearDown()
    }

    func testSnapshotDoesNotChangeSharedCaptureState() {
        let service = FocusCaptureService.shared
        service.isRestoreSuppressed = true
        let appBefore = service.capturedApp?.processIdentifier

        _ = service.snapshot()

        XCTAssertEqual(service.capturedApp?.processIdentifier, appBefore)
        XCTAssertTrue(service.isRestoreSuppressed)
    }
}
