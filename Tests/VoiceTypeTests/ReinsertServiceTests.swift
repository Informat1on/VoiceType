// ReinsertServiceTests.swift — VoiceType Save & Insert
//
// docs/plans/fix-and-reinsert.md § C2, §5. All collaborators are injected; no
// real focus change, paste or pasteboard write happens.

import XCTest
import AppKit
@testable import VoiceType

@MainActor
final class ReinsertServiceTests: XCTestCase {

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private final class Journal {
        var calls: [String] = []
    }

    private var snapshot: FocusSnapshot {
        FocusSnapshot(app: NSRunningApplication.current, window: nil)
    }

    private func makeService(
        journal: Journal,
        restorer: Bool = true,
        copier: Bool = true,
        verifier: Bool = true,
        insertError: Error? = nil,
        insert: (@MainActor (String) async throws -> Void)? = nil
    ) -> ReinsertService {
        ReinsertService(
            restorer: { _ in journal.calls.append("restore"); return restorer },
            inserter: { text in
                journal.calls.append("insert:\(text)")
                if let insert { try await insert(text) }
                if let insertError { throw insertError }
            },
            copier: { text in journal.calls.append("copy:\(text)"); return copier },
            verifier: { _ in journal.calls.append("verify"); return verifier },
            activationDelay: .zero
        )
    }

    func testInsertsAfterRestoreInOrder() async {
        let journal = Journal()
        let service = makeService(journal: journal)
        let outcome = await service.reinsert("fixed", into: snapshot)
        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(journal.calls, ["restore", "verify", "insert:fixed"])
        XCTAssertFalse(service.isInFlight)
    }

    func testRestorerFalseCopies() async {
        let journal = Journal()
        let service = makeService(journal: journal, restorer: false)
        let outcome = await service.reinsert("fixed", into: snapshot)
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(journal.calls, ["restore", "copy:fixed"])
    }

    func testRestorerFalseAndCopierFalseFails() async {
        let journal = Journal()
        let service = makeService(journal: journal, restorer: false, copier: false)
        let outcome = await service.reinsert("fixed", into: snapshot)
        XCTAssertEqual(outcome, .failed("Clipboard unavailable"))
        XCTAssertFalse(service.isInFlight)
    }

    func testInserterThrowingFails() async {
        let journal = Journal()
        let service = makeService(journal: journal, insertError: Boom())
        let outcome = await service.reinsert("fixed", into: snapshot)
        XCTAssertEqual(outcome, .failed("boom"))
        XCTAssertFalse(journal.calls.contains { $0.hasPrefix("copy") })
        XCTAssertFalse(service.isInFlight)
    }

    func testVerifierFalseCopiesWithoutInserting() async {
        let journal = Journal()
        let service = makeService(journal: journal, verifier: false)
        let outcome = await service.reinsert("fixed", into: snapshot)
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(journal.calls, ["restore", "verify", "copy:fixed"])
    }

    func testConcurrentCallIsBusyAndFlagResets() async {
        let journal = Journal()
        var continuation: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "inserter entered")
        let service = makeService(journal: journal) { _ in
            await withCheckedContinuation { cont in
                continuation = cont
                entered.fulfill()
            }
        }
        let first = Task { @MainActor in await service.reinsert("one", into: self.snapshot) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(service.isInFlight)

        let second = await service.reinsert("two", into: snapshot)
        XCTAssertEqual(second, .busy)
        XCTAssertFalse(journal.calls.contains("insert:two"))

        continuation?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .inserted)
        XCTAssertFalse(service.isInFlight)
    }
}

@MainActor
final class EvalEditorFocusModelTests: XCTestCase {

    private var snapshot: FocusSnapshot {
        FocusSnapshot(app: NSRunningApplication.current, window: nil)
    }

    func testInitialModelCannotInsert() {
        let model = EvalEditorFocusModel()
        XCTAssertFalse(model.canInsert)
        XCTAssertNil(model.snapshot)
    }

    func testUpdateWithSnapshotEnablesInsert() {
        let model = EvalEditorFocusModel()
        model.update(snapshot)
        XCTAssertTrue(model.canInsert)
    }

    func testUpdateNilAfterSnapshotDisablesInsert() {
        let model = EvalEditorFocusModel(snapshot: snapshot)
        XCTAssertTrue(model.canInsert)
        model.update(nil)
        XCTAssertFalse(model.canInsert)
        XCTAssertNil(model.snapshot)
    }
}
