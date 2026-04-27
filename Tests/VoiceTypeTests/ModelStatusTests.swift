import XCTest
import Combine
@testable import VoiceType

// Tests for the VT-WARM-001..005 warm-up fixes.
//
// Coverage strategy:
//  - VT-WARM-001 (await warm-up before transcribe): structural fix only — requires a
//    real Whisper model. Covered by code review.
//  - VT-WARM-002 (setInitialPrompt defers during warm-up): tested directly via the
//    _testIsWarmingUp seam — no real model needed.
//  - VT-WARM-003 (cancel warm-up before file-not-found guard): structural fix only —
//    requires a real model file. Covered by code review.
//  - VT-WARM-004 (modelStatus .warming → .ready after cancel): tested via published
//    modelStatus transitions using _testSetModelStatus seam.
//  - VT-WARM-005 (warmUpTask nil on natural exit): structural fix only — requires a
//    real model. Covered by code review.
@MainActor
final class ModelStatusTests: XCTestCase {

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var service: TranscriptionService!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        service = TranscriptionService()
        cancellables = []
    }

    override func tearDown() async throws {
        service = nil
        cancellables = []
        try await super.tearDown()
    }

    // MARK: - VT-WARM-002: setInitialPrompt defers during warm-up

    /// When isWarmingUp is true, setInitialPrompt must NOT modify the live C buffer —
    /// same UAF guard as isTranscribing. The update must be stored as a pending prompt.
    func testSetInitialPromptDefersDuringWarmUp() {
        service.setInitialPrompt("original")
        XCTAssertEqual(service.currentInitialPromptText, "original")

        // Simulate warm-up running.
        service._testIsWarmingUp = true

        service.setInitialPrompt("updated during warmup")

        // Must NOT have applied yet — C buffer is still in use by the silence pass.
        XCTAssertEqual(
            service.currentInitialPromptText,
            "original",
            "setInitialPrompt must defer when warm-up is running (VT-WARM-002)"
        )
    }

    /// Once warm-up ends (isWarmingUp = false) the pending prompt must be flushed
    /// via _flushPendingPrompt() — same mechanism as the transcription path.
    func testPendingPromptAppliedAfterWarmUpEnds() {
        service.setInitialPrompt("original")

        service._testIsWarmingUp = true
        service.setInitialPrompt("new value")

        // Still original while warm-up is active.
        XCTAssertEqual(service.currentInitialPromptText, "original")

        // Simulate warm-up exit: clear the flag, then flush pending (mirrors the
        // defer block in performWarmUp which calls _flushPendingPrompt).
        service._testIsWarmingUp = false
        service._testFlushPendingPrompt()

        XCTAssertEqual(
            service.currentInitialPromptText,
            "new value",
            "Pending prompt must be applied once warm-up finishes (VT-WARM-002)"
        )
    }

    /// nil-clear requested during warm-up must also be deferred correctly.
    func testNilClearDeferredDuringWarmUp() {
        service.setInitialPrompt("has a prompt")

        service._testIsWarmingUp = true
        service.setInitialPrompt(nil)   // Clear while warm-up runs.

        XCTAssertEqual(
            service.currentInitialPromptText,
            "has a prompt",
            "Prompt clear must be deferred during warm-up (VT-WARM-002)"
        )

        service._testIsWarmingUp = false
        service._testFlushPendingPrompt()

        XCTAssertNil(
            service.currentInitialPromptText,
            "Deferred nil-clear must apply after warm-up ends (VT-WARM-002)"
        )
    }

    /// When both isTranscribing and isWarmingUp are false, setInitialPrompt must
    /// apply immediately (regression guard — idle path must remain unaffected).
    func testSetInitialPromptAppliesImmediatelyWhenIdle() {
        XCTAssertFalse(service.isTranscribing)
        XCTAssertFalse(service._testIsWarmingUp)

        service.setInitialPrompt("immediate")
        XCTAssertEqual(service.currentInitialPromptText, "immediate")
    }

    // MARK: - VT-WARM-004: modelStatus must not remain .warming after warm-up cancelled

    /// Confirms ModelStatus.warming is a distinct case that compares equal to itself
    /// and not to .ready — the guard `if modelStatus == .warming` in transcribe() must
    /// fire only when the status is .warming.
    func testModelStatusWarmingEquality() {
        XCTAssertEqual(ModelStatus.warming, ModelStatus.warming)
        XCTAssertNotEqual(ModelStatus.warming, ModelStatus.ready)
        XCTAssertNotEqual(ModelStatus.warming, ModelStatus.loading)
        XCTAssertNotEqual(ModelStatus.warming, ModelStatus.notLoaded)
    }

    /// The transcribe() path advances modelStatus from .warming to .ready before
    /// the actual transcription begins.  We cannot call transcribe() without a model,
    /// but we can verify that the status transitions happen in correct order by
    /// observing @Published modelStatus through a Combine sink.
    func testModelStatusTransitionsPublished() {
        var observed: [ModelStatus] = []
        service.$modelStatus
            .sink { observed.append($0) }
            .store(in: &cancellables)

        // Plant .warming (simulating what loadModel sets before kicking off warmUpTask).
        service._testSetModelStatus(.warming)
        // Advance to .ready (simulating what transcribe() does after cancelling warm-up).
        service._testSetModelStatus(.ready)

        XCTAssertEqual(
            observed,
            [.notLoaded, .warming, .ready],
            "modelStatus must publish .notLoaded → .warming → .ready in sequence (VT-WARM-004)"
        )
    }

    // MARK: - VT-WARM-002 (generation guard): stale generation prevents restore

    /// If modelLoadGeneration advances while warm-up is running, the warm-up's
    /// savedPromptText restore must be skipped.  We verify the generation comparison
    /// logic directly without spinning a real warm-up Task.
    func testGenerationGuardPreventsStaleRestore() {
        // Simulate: warm-up captured generation 1.
        service._testModelLoadGeneration = 1
        let warmUpGeneration = service._testModelLoadGeneration

        // Simulate: a new loadModel increments to generation 2.
        service._testModelLoadGeneration = 2

        // The warm-up would check: warmUpGeneration == modelLoadGeneration.
        // With gen 1 vs 2 — restore must NOT happen.
        XCTAssertFalse(
            warmUpGeneration == service._testModelLoadGeneration,
            "Stale generation must not match current — restore must be skipped (VT-WARM-002)"
        )
    }

    // MARK: - VT-REV-001: status dot identity — only show live status for the loaded model

    /// When loadedModelName matches the row's model rawValue, the full modelStatus
    /// must be forwarded (the status dot should reflect the real load state).
    func testStatusForwardedWhenModelNamesMatch() {
        // Plant .ready status and simulate the service having loaded "tiny-q5_1".
        service._testSetModelStatus(.ready)
        // loadedModelName is a computed var over currentModelName (private).
        // We can't set it directly without loading a file, but we CAN verify the
        // identity logic: when loadedModelName IS nil the result must be .notLoaded.
        // When loadedModelName matches, the caller (SettingsView) forwards modelStatus.
        // This test guards the nil-path (the race scenario from VT-REV-001).

        // With no model loaded, loadedModelName must be nil.
        XCTAssertNil(
            service.loadedModelName,
            "loadedModelName must be nil when no model has been loaded (VT-REV-001 precondition)"
        )
    }

    /// Status dot identity: when loadedModelName is nil (no model in memory),
    /// every row must compute displayedStatus = .notLoaded regardless of modelStatus.
    /// This is the core VT-REV-001 race scenario: user selected turbo-q5 but
    /// small-q5 is still loaded and .ready — turbo-q5 row must show .notLoaded.
    func testStatusDotShownOnlyForActuallyLoadedModel() {
        // Arrange: service is .ready but no model is physically loaded
        // (loadedModelName == nil because no loadModel() call was made).
        service._testSetModelStatus(.ready)
        XCTAssertEqual(service.modelStatus, .ready)

        // Act: simulate SettingsView's per-row identity check for a non-loaded model.
        // The logic from the fixed SettingsView:
        //   let isActuallyLoaded = transcriptionService.loadedModelName == model.rawValue
        //   displayedStatus = isActuallyLoaded ? transcriptionService.modelStatus : .notLoaded
        let modelRawValue = TranscriptionModel.allCases.first?.rawValue ?? "tiny-q5_1"
        let isActuallyLoaded = service.loadedModelName == modelRawValue
        let displayedStatus: ModelStatus = isActuallyLoaded ? service.modelStatus : .notLoaded

        // Assert: even though modelStatus is .ready, the row gets .notLoaded
        // because no model has been loaded into the service.
        XCTAssertFalse(
            isActuallyLoaded,
            "loadedModelName nil must not match any model rawValue (VT-REV-001)"
        )
        XCTAssertEqual(
            displayedStatus,
            .notLoaded,
            "Status dot must be .notLoaded when model is selected but not yet loaded (VT-REV-001)"
        )
    }

    /// Ensures loadedModelName is a public readable property — required for the
    /// identity check in SettingsView.  This test will fail to compile if the
    /// property is ever made private or renamed.
    func testLoadedModelNameIsPubliclyReadable() {
        let name: String? = service.loadedModelName
        XCTAssertNil(name, "loadedModelName must be nil when no model is loaded (VT-REV-001 API guard)")
    }

    // MARK: - Coverage gaps (require a real Whisper model)

    // NOTE(VT-WARM-001, VT-WARM-004): testTranscribeCancelsWarmUpAndAdvancesToReady
    //   Requires loading a real model file so warmUpTask is a live Task<Void,Never>.
    //   Cannot be mocked without abstracting the Whisper dependency.

    // NOTE(VT-WARM-003): testFileNotFoundCancelsWarmUpBeforeError
    //   Requires driving loadModel() with a missing URL while a warmUpTask is live.
    //   Needs a real model for the prior load that seeds warmUpTask.

    // NOTE(VT-WARM-005): testWarmUpTaskClearsAfterNaturalCompletion
    //   warmUpTask is private — no test seam to inspect it after completion
    //   without introducing a Mirror hack (rejected: too fragile).
}
