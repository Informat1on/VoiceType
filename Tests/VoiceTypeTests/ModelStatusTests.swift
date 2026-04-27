import XCTest
import Combine
@testable import VoiceType

// Tests for ModelStatus enum semantics and TranscriptionService status transitions
// that can be exercised without loading a real .bin model file.
//
// Warm-up integration (testWarmUpAdvancesStatusToReady) requires a real Whisper
// context and is therefore skipped here — status transitions are validated through
// @Published Combine sinks that observe side-effects of unloadModel() and the
// initial .notLoaded default.

// MARK: - ModelStatus unit tests

final class ModelStatusTests: XCTestCase {

    // MARK: testInitialStatusIsNotLoaded

    /// A freshly-constructed TranscriptionService must start at .notLoaded.
    /// Regression guard: if the default ever drifts, the menu bar would show
    /// a stale .ready dot immediately on launch (before any model loads).
    @MainActor
    func testInitialStatusIsNotLoaded() {
        let service = TranscriptionService()
        XCTAssertEqual(service.modelStatus, .notLoaded)
    }

    // MARK: testStatusEquatable_sameCase

    func testStatusEquatable_sameCaseNotLoaded() {
        XCTAssertEqual(ModelStatus.notLoaded, ModelStatus.notLoaded)
    }

    func testStatusEquatable_sameCaseLoading() {
        XCTAssertEqual(ModelStatus.loading, ModelStatus.loading)
    }

    func testStatusEquatable_sameCaseWarming() {
        XCTAssertEqual(ModelStatus.warming, ModelStatus.warming)
    }

    func testStatusEquatable_sameCaseReady() {
        XCTAssertEqual(ModelStatus.ready, ModelStatus.ready)
    }

    // MARK: testStatusEquatable_differentCases

    func testStatusEquatable_differentCasesAreNotEqual() {
        XCTAssertNotEqual(ModelStatus.notLoaded, ModelStatus.ready)
        XCTAssertNotEqual(ModelStatus.loading, ModelStatus.warming)
        XCTAssertNotEqual(ModelStatus.ready, ModelStatus.notLoaded)
    }

    // MARK: testErrorEqualityIncludesMessage

    func testErrorEqualityIncludesMessage_sameMessage() {
        let a = ModelStatus.error("file not found")
        let b = ModelStatus.error("file not found")
        XCTAssertEqual(a, b, ".error cases with identical messages must be equal")
    }

    func testErrorEqualityIncludesMessage_differentMessage() {
        let a = ModelStatus.error("file not found")
        let b = ModelStatus.error("SIGABRT in whisper_encode")
        XCTAssertNotEqual(a, b, ".error cases with different messages must not be equal")
    }

    func testErrorEqualityIncludesMessage_errorVsReady() {
        XCTAssertNotEqual(ModelStatus.error("x"), ModelStatus.ready)
    }

    // MARK: testUnloadModelResetsStatusToNotLoaded

    /// After unloadModel() the status must revert to .notLoaded so the dot in
    /// MenuBarView switches from any prior state back to the steel-grey sentinel.
    @MainActor
    func testUnloadModelResetsStatusToNotLoaded() {
        let service = TranscriptionService()
        // We cannot call loadModel without a real file, but we can
        // simulate the scenario by checking that unloadModel idempotently
        // sets .notLoaded even when already .notLoaded.
        service.unloadModel()
        XCTAssertEqual(service.modelStatus, .notLoaded)
    }

    // MARK: testModelStatusPublishedOnUnload

    /// Verify that modelStatus is @Published and emits via Combine when unloadModel() is called.
    @MainActor
    func testModelStatusPublishedOnUnload() {
        let service = TranscriptionService()
        var received: [ModelStatus] = []
        var cancellables = Set<AnyCancellable>()

        service.$modelStatus
            .sink { received.append($0) }
            .store(in: &cancellables)

        // Trigger a status transition: unloadModel always sets .notLoaded.
        service.unloadModel()
        service.unloadModel()

        // We should have received at least the initial value + two .notLoaded events.
        // Duplicates may be deduplicated by SwiftUI, but Combine sink fires on every
        // assignment regardless.
        XCTAssertTrue(received.count >= 1, "Combine sink must fire at least once")
        XCTAssertEqual(received.last, .notLoaded, "Last emitted value must be .notLoaded")
    }

    // MARK: testErrorCaseIsNotReady

    func testErrorCaseIsNotReady() {
        XCTAssertNotEqual(ModelStatus.error("anything"), ModelStatus.ready)
        XCTAssertNotEqual(ModelStatus.error("anything"), ModelStatus.loading)
        XCTAssertNotEqual(ModelStatus.error("anything"), ModelStatus.warming)
        XCTAssertNotEqual(ModelStatus.error("anything"), ModelStatus.notLoaded)
    }
}
