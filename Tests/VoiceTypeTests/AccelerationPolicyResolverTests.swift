import XCTest
@testable import VoiceType

// Coverage for the CoreML/Metal accelerator selection policy.
//
// The policy exists because whisper.cpp otherwise routes the encoder to
// CoreML/ANE unconditionally, with no way for the app to decide. It was built
// expecting M5-class tensor hardware to want the opposite — measurement said
// no, the ANE stays faster (189ms vs 225ms on a short phrase; see
// scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md), so Auto
// keeps CoreML everywhere and GPU-only is a manual choice.
//
// AccelerationPolicyResolver is pure (no file system, ModelManager, or
// AppSettings access), so every row of both spec tables is exercised
// directly — no fixtures, no mocking.
final class AccelerationPolicyResolverTests: XCTestCase {

    // MARK: - resolve(): what to run the encoder on right now

    /// Table-driven: every (mode, capability, coreMLInstalled) combination from
    /// the resolve() spec. Also guards the reason string is non-empty, since
    /// it's surfaced directly in diagnostics/UI.
    func testResolveCoversEverySpecRow() {
        struct Row {
            let mode: CoreMLMode
            let capability: AcceleratorCapability
            let coreMLInstalled: Bool
            let expectedPolicy: AccelerationPolicy
            let description: String
        }

        let table: [Row] = [
            // auto
            // Measured 2026-07-26 on M5 Pro: the ANE still wins on tensor-capable
            // hardware once the model is resident and warm (192ms vs 231ms on a
            // 5.4s phrase). See RESULTS-coreml-vs-metal-app-2026-07-26.md — this
            // row is the one the original plan expected to go the other way.
            Row(
                mode: .auto,
                capability: .metalWithTensor,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "auto/metalWithTensor/installed → coreML"
            ),
            Row(
                mode: .auto,
                capability: .metalWithTensor,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "auto/metalWithTensor/not installed → metalOnly"
            ),
            Row(
                mode: .auto,
                capability: .metal,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "auto/metal/installed → coreML"
            ),
            Row(
                mode: .auto,
                capability: .metal,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "auto/metal/not installed → metalOnly"
            ),
            Row(
                mode: .auto,
                capability: .unavailable,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "auto/unavailable/installed → coreML"
            ),
            Row(
                mode: .auto,
                capability: .unavailable,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "auto/unavailable/not installed → metalOnly"
            ),

            // on
            Row(
                mode: .on,
                capability: .metalWithTensor,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "on/metalWithTensor/installed → coreML"
            ),
            Row(
                mode: .on,
                capability: .metal,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "on/metal/installed → coreML"
            ),
            Row(
                mode: .on,
                capability: .unavailable,
                coreMLInstalled: true,
                expectedPolicy: .coreML,
                description: "on/unavailable/installed → coreML"
            ),
            Row(
                mode: .on,
                capability: .metalWithTensor,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "on/metalWithTensor/not installed → metalOnly"
            ),
            Row(
                mode: .on,
                capability: .metal,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "on/metal/not installed → metalOnly"
            ),
            Row(
                mode: .on,
                capability: .unavailable,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "on/unavailable/not installed → metalOnly"
            ),

            // off
            Row(
                mode: .off,
                capability: .metalWithTensor,
                coreMLInstalled: true,
                expectedPolicy: .metalOnly,
                description: "off/metalWithTensor/installed → metalOnly"
            ),
            Row(
                mode: .off,
                capability: .metalWithTensor,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "off/metalWithTensor/not installed → metalOnly"
            ),
            Row(
                mode: .off,
                capability: .metal,
                coreMLInstalled: true,
                expectedPolicy: .metalOnly,
                description: "off/metal/installed → metalOnly"
            ),
            Row(
                mode: .off,
                capability: .metal,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "off/metal/not installed → metalOnly"
            ),
            Row(
                mode: .off,
                capability: .unavailable,
                coreMLInstalled: true,
                expectedPolicy: .metalOnly,
                description: "off/unavailable/installed → metalOnly"
            ),
            Row(
                mode: .off,
                capability: .unavailable,
                coreMLInstalled: false,
                expectedPolicy: .metalOnly,
                description: "off/unavailable/not installed → metalOnly"
            )
        ]

        for row in table {
            let decision = AccelerationPolicyResolver.resolve(
                mode: row.mode,
                capability: row.capability,
                coreMLInstalled: row.coreMLInstalled
            )
            XCTAssertEqual(decision.policy, row.expectedPolicy, row.description)
            XCTAssertFalse(decision.reason.isEmpty, "\(row.description): reason must not be empty")
        }
    }

    /// Core invariant: `.auto` must never resolve to `.metalOnly` when Metal is
    /// dead AND a CoreML encoder is available — ANE beats plain CPU. This is
    /// already covered by two rows above, but it's the one property review
    /// flagged as easy to accidentally regress, so it gets its own guard.
    func testAutoNeverStrandsOnCPUWhenCoreMLIsAvailable() {
        let decision = AccelerationPolicyResolver.resolve(
            mode: .auto,
            capability: .unavailable,
            coreMLInstalled: true
        )
        XCTAssertEqual(decision.policy, .coreML, "auto must fall back to CoreML/ANE when Metal is unavailable")
    }

    /// `.on` without an installed encoder must fall back to metalOnly rather
    /// than crash or silently do nothing — and the reason must say why.
    func testOnModeWithoutInstalledEncoderFallsBackToMetalOnly() {
        let decision = AccelerationPolicyResolver.resolve(
            mode: .on,
            capability: .metal,
            coreMLInstalled: false
        )
        XCTAssertEqual(decision.policy, .metalOnly)
        XCTAssertFalse(decision.reason.isEmpty)
    }

    // MARK: - shouldInstallCoreML(): whether the encoder should live on disk

    /// Table-driven: every (mode, modelSupportsCoreML, capability) combination
    /// from the shouldInstallCoreML() spec.
    func testShouldInstallCoreMLCoversEverySpecRow() {
        struct Row {
            let mode: CoreMLMode
            let modelSupportsCoreML: Bool
            let capability: AcceleratorCapability
            let expected: Bool
            let description: String
        }

        let table: [Row] = [
            // modelSupportsCoreML == false always wins, regardless of mode/capability.
            Row(
                mode: .auto,
                modelSupportsCoreML: false,
                capability: .metal,
                expected: false,
                description: "unsupported model/auto/metal → false"
            ),
            Row(
                mode: .on,
                modelSupportsCoreML: false,
                capability: .metal,
                expected: false,
                description: "unsupported model/on/metal → false"
            ),
            Row(
                mode: .off,
                modelSupportsCoreML: false,
                capability: .metal,
                expected: false,
                description: "unsupported model/off/metal → false"
            ),
            Row(
                mode: .auto,
                modelSupportsCoreML: false,
                capability: .metalWithTensor,
                expected: false,
                description: "unsupported model/auto/metalWithTensor → false"
            ),
            Row(
                mode: .auto,
                modelSupportsCoreML: false,
                capability: .unavailable,
                expected: false,
                description: "unsupported model/auto/unavailable → false"
            ),

            // mode == off → always false when supported.
            Row(
                mode: .off,
                modelSupportsCoreML: true,
                capability: .metal,
                expected: false,
                description: "supported model/off/metal → false"
            ),
            Row(
                mode: .off,
                modelSupportsCoreML: true,
                capability: .metalWithTensor,
                expected: false,
                description: "supported model/off/metalWithTensor → false"
            ),
            Row(
                mode: .off,
                modelSupportsCoreML: true,
                capability: .unavailable,
                expected: false,
                description: "supported model/off/unavailable → false"
            ),

            // mode == on → always true when supported.
            Row(
                mode: .on,
                modelSupportsCoreML: true,
                capability: .metal,
                expected: true,
                description: "supported model/on/metal → true"
            ),
            Row(
                mode: .on,
                modelSupportsCoreML: true,
                capability: .metalWithTensor,
                expected: true,
                description: "supported model/on/metalWithTensor → true"
            ),
            Row(
                mode: .on,
                modelSupportsCoreML: true,
                capability: .unavailable,
                expected: true,
                description: "supported model/on/unavailable → true"
            ),

            // mode == auto → true on every tier: the encoder is worth having
            // wherever the model ships one (measured 2026-07-26, see
            // RESULTS-coreml-vs-metal-app-2026-07-26.md).
            Row(
                mode: .auto,
                modelSupportsCoreML: true,
                capability: .metalWithTensor,
                expected: true,
                description: "supported model/auto/metalWithTensor → true"
            ),
            Row(
                mode: .auto,
                modelSupportsCoreML: true,
                capability: .metal,
                expected: true,
                description: "supported model/auto/metal → true"
            ),
            Row(
                mode: .auto,
                modelSupportsCoreML: true,
                capability: .unavailable,
                expected: true,
                description: "supported model/auto/unavailable → true"
            )
        ]

        for row in table {
            let result = AccelerationPolicyResolver.shouldInstallCoreML(
                mode: row.mode,
                capability: row.capability,
                modelSupportsCoreML: row.modelSupportsCoreML
            )
            XCTAssertEqual(result, row.expected, row.description)
        }
    }

    // MARK: - Fixed-point trap regression guards

    /// `.on` without an installed encoder must still keep asking for a
    /// download. shouldInstallCoreML() is implemented via a hypothetical
    /// resolve(coreMLInstalled: true) query, NOT the caller's real disk state
    /// — if it used the real (false) state instead, `.on` would never escape
    /// metalOnly once the encoder went missing, because "should install"
    /// would forever mirror "is installed".
    func testOnModeRequestsInstallEvenWhileCurrentlyNotInstalled() {
        let decision = AccelerationPolicyResolver.resolve(mode: .on, capability: .metal, coreMLInstalled: false)
        XCTAssertEqual(decision.policy, .metalOnly, "precondition: resolve() falls back while nothing is on disk yet")

        let shouldInstall = AccelerationPolicyResolver.shouldInstallCoreML(
            mode: .on,
            capability: .metal,
            modelSupportsCoreML: true
        )
        XCTAssertTrue(shouldInstall, "on mode must request install even while resolve() is currently metalOnly")
    }

    /// Mirror case: `.auto` on metalWithTensor hardware must never ask to keep
    /// the encoder installed, even if a prior state left one on disk —
    /// the hypothetical query intentionally ignores the caller's real
    /// coreMLInstalled state, so this can't drift into "keep whatever's
    /// already there".
    /// Tensor-capable hardware does not change what `.auto` picks.
    ///
    /// The feature was originally planned the other way round — `.auto` was to
    /// bypass CoreML on M5-class chips. Measurement on the real app scenario
    /// (model resident and warmed, which is how VoiceType runs) reversed it:
    /// 192ms via ANE vs 231ms via Metal+tensor on a 5.4s phrase, 1209ms vs
    /// 1359ms on 81s. The plan's "420ms vs 855ms" came from whisper-cli, which
    /// reloads the model every run and so paid the ANE load cost each time.
    /// Full write-up: scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md
    ///
    /// If a future chip genuinely flips this, change it here with a fresh
    /// measurement attached — not on the strength of the tensor API existing.
    func testAutoModeOnTensorHardwareStillUsesAndKeepsCoreML() {
        let decision = AccelerationPolicyResolver.resolve(mode: .auto, capability: .metalWithTensor, coreMLInstalled: true)
        XCTAssertEqual(decision.policy, .coreML)

        let shouldInstall = AccelerationPolicyResolver.shouldInstallCoreML(
            mode: .auto,
            capability: .metalWithTensor,
            modelSupportsCoreML: true
        )
        XCTAssertTrue(shouldInstall, "auto mode on tensor hardware must keep the encoder — the ANE is still the faster path")
    }

    /// The other half of the fixed-point guard: `.off` must never ask to keep
    /// the encoder, even on hardware where the policy would otherwise want it
    /// and even when it is already sitting on disk.
    func testOffModeNeverRequestsInstallEvenWhenAlreadyInstalled() {
        let decision = AccelerationPolicyResolver.resolve(mode: .off, capability: .metalWithTensor, coreMLInstalled: true)
        XCTAssertEqual(decision.policy, .metalOnly)

        let shouldInstall = AccelerationPolicyResolver.shouldInstallCoreML(
            mode: .off,
            capability: .metalWithTensor,
            modelSupportsCoreML: true
        )
        XCTAssertFalse(shouldInstall, "off mode must never request keeping CoreML installed")
    }

    // MARK: - Property test: shouldInstallCoreML is exactly the hypothetical resolve() query

    /// Exhaustively checks the identity `shouldInstallCoreML` is implemented
    /// with — `modelSupportsCoreML && resolve(..., coreMLInstalled: true).policy == .coreML`
    /// — across the full 3×3×2 input matrix. This is the guard against the two
    /// tables drifting apart: if `shouldInstallCoreML` is ever reimplemented as
    /// a hand-written second table again, this test pins it back to derive
    /// from `resolve()`.
    func testShouldInstallCoreMLIsAlwaysTheHypotheticalResolveQuery() {
        let allCapabilities: [AcceleratorCapability] = [.unavailable, .metal, .metalWithTensor]

        for mode in CoreMLMode.allCases {
            for capability in allCapabilities {
                for modelSupportsCoreML in [true, false] {
                    let actual = AccelerationPolicyResolver.shouldInstallCoreML(
                        mode: mode,
                        capability: capability,
                        modelSupportsCoreML: modelSupportsCoreML
                    )
                    let hypotheticalPolicy = AccelerationPolicyResolver.resolve(
                        mode: mode,
                        capability: capability,
                        coreMLInstalled: true
                    ).policy
                    let expected = modelSupportsCoreML && hypotheticalPolicy == .coreML
                    let context = "mode=\(mode) capability=\(capability) modelSupportsCoreML=\(modelSupportsCoreML)"
                    XCTAssertEqual(actual, expected, "\(context): shouldInstallCoreML must equal the hypothetical resolve() query")
                }
            }
        }
    }
}
