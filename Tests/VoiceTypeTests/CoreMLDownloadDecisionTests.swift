import XCTest
@testable import VoiceType

// Tests for CoreMLDownloadDecision.shouldInstall(for:) — the async wrapper that
// composes AcceleratorCapabilityProvider's live probe with AppSettings.shared's
// live coreMLMode and feeds them into the pure AccelerationPolicyResolver.
//
// AccelerationPolicyResolverTests already exhaustively covers the full
// mode × capability × modelSupportsCoreML spec against the pure resolver.
// These tests exist to catch a *wiring* bug in the wrapper — reading the wrong
// capability, the wrong mode, or the wrong model flag — not to re-derive the
// spec table. `_setTestOverride` pins the capability so these never depend on
// the host GPU actually being M5-class hardware.
@MainActor
final class CoreMLDownloadDecisionTests: XCTestCase {

    override func tearDown() async throws {
        // Restore defaults so bleed doesn't affect other test files sharing
        // the AppSettings.shared / AcceleratorCapabilityProvider.shared singletons.
        AppSettings.shared.coreMLMode = .auto
        UserDefaults.standard.removeObject(forKey: "coreMLMode")
        await AcceleratorCapabilityProvider.shared._setTestOverride(nil)
        try await super.tearDown()
    }

    /// Tensor-capable hardware still wants the encoder. Measured on M5 Pro
    /// 2026-07-26: with the model resident and warm the ANE beats Metal+tensor
    /// (192ms vs 231ms on a 5.4s phrase) — see
    /// scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md.
    func testAutoOnTensorHardwareStillRequestsCoreMLForSupportedModel() async {
        AppSettings.shared.coreMLMode = .auto
        await AcceleratorCapabilityProvider.shared._setTestOverride(.metalWithTensor)

        let result = await CoreMLDownloadDecision.shouldInstall(for: .largeV3Turbo)

        XCTAssertTrue(result, "Tensor-capable hardware still benefits from the ANE — auto must request the encoder")
    }

    func testAutoOnPlainMetalRequestsCoreMLForSupportedModel() async {
        AppSettings.shared.coreMLMode = .auto
        await AcceleratorCapabilityProvider.shared._setTestOverride(.metal)

        let result = await CoreMLDownloadDecision.shouldInstall(for: .largeV3Turbo)

        XCTAssertTrue(result, "Pre-M5 Metal in auto mode should prefer CoreML/ANE")
    }

    func testOnModeRequestsCoreMLEvenOnTensorHardware() async {
        AppSettings.shared.coreMLMode = .on
        await AcceleratorCapabilityProvider.shared._setTestOverride(.metalWithTensor)

        let result = await CoreMLDownloadDecision.shouldInstall(for: .largeV3Turbo)

        XCTAssertTrue(result, "Explicit .on pins CoreML on every capability tier — this is what lets a mode switch backfill the encoder")
    }

    func testOffModeNeverRequestsCoreML() async {
        AppSettings.shared.coreMLMode = .off
        await AcceleratorCapabilityProvider.shared._setTestOverride(.metal)

        let result = await CoreMLDownloadDecision.shouldInstall(for: .largeV3Turbo)

        XCTAssertFalse(result)
    }

    func testModelWithoutCoreMLSupportNeverRequestsDownloadRegardlessOfMode() async {
        XCTAssertFalse(TranscriptionModel.smallQ5.hasCoreMLSupport, "Precondition: small-q5_1 ships no CoreML variant")

        for mode in CoreMLMode.allCases {
            AppSettings.shared.coreMLMode = mode
            await AcceleratorCapabilityProvider.shared._setTestOverride(.metal)
            let result = await CoreMLDownloadDecision.shouldInstall(for: .smallQ5)
            XCTAssertFalse(result, "smallQ5 has no CoreML variant — must stay false in mode \(mode.rawValue)")
        }
    }
}
