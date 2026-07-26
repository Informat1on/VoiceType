import Foundation

/// Capability of the current hardware's Metal-family accelerator.
///
/// `metalWithTensor` marks the Metal 4 tensor API introduced on M5-class
/// Apple Silicon. It roughly doubles the speed of whisper.cpp's *Metal* encoder
/// (encode 1213ms → 612ms on M5 Pro) — but that still does not beat the ANE,
/// so it does not change which accelerator `.auto` picks. See
/// `scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md`.
///
/// The capability is still worth probing: it distinguishes a live Metal stack
/// from a dead one (`unavailable`), which is what makes the CoreML fallback
/// decision honest, and it is what the diagnostics report to the user.
enum AcceleratorCapability {
    case unavailable
    case metal
    case metalWithTensor
}

/// Which accelerator whisper.cpp's encoder should run on.
enum AccelerationPolicy {
    case coreML
    case metalOnly
}

/// A resolved accelerator choice plus a human-readable reason. The reason is
/// plain enough to show directly in the UI and write to the diagnostics log.
struct AccelerationDecision: Equatable {
    let policy: AccelerationPolicy
    let reason: String
}

/// Pure decision logic for the CoreML/Metal accelerator policy.
///
/// No file system, `ModelManager`, or `AppSettings.shared` access — every
/// input arrives as a parameter, which is what makes both tables exhaustively
/// testable without touching disk.
///
/// `resolve` and `shouldInstallCoreML` answer two different questions and
/// must never collapse into a single fixed point:
///   - `resolve` picks the accelerator to use RIGHT NOW, given what's already
///     on disk (`coreMLInstalled` reflects today's actual state).
///   - `shouldInstallCoreML` decides whether the encoder should EXIST on disk
///     at all — it drives download/eviction, so it must NOT be computed from
///     today's real `coreMLInstalled` state. Doing that creates a fixed point
///     that never moves: mode `.on` without an installed encoder would keep
///     resolving to `.metalOnly` forever (nothing would ever ask for a
///     download), and `.auto` on hardware with a dead Metal stack would stay
///     pinned to CPU-only whisper.cpp forever (nothing would ever ask for the
///     ANE fallback).
///
///   `shouldInstallCoreML` IS implemented in terms of `resolve` below, but via
///   a hypothetical query — "if the encoder were on disk, would the policy
///   pick it?" (`coreMLInstalled: true`, never the caller's real disk state).
///   That sidesteps the fixed-point trap while keeping one source of truth
///   for "does this mode/capability pair want CoreML at all". Verified
///   row-for-row against the original two independent tables — see
///   `AccelerationPolicyResolverTests`.
enum AccelerationPolicyResolver {

    /// Directory name for the CoreML-bypass symlink farm, one level below the
    /// real models directory (a sibling of the `.bin` files, not inside the
    /// same directory — see `TranscriptionService.shadowModelURL`'s doc
    /// comment for why that distinction is the whole trick).
    ///
    /// Lives here — rather than as a private constant in `TranscriptionService`
    /// — because `ModelManager.deleteModel` also needs it: deleting a model's
    /// `.bin` must take its shadow symlink with it, or `.metal-only/` fills up
    /// with dangling links to files that no longer exist. One shared constant
    /// instead of the same string literal duplicated in two files.
    static let metalOnlyShadowDirectoryName = ".metal-only"

    /// What to run the encoder on right now, given what's already installed.
    ///
    /// Invariant: `.auto` never leaves the system without an accelerator when
    /// one is reachable. It picks the ANE wherever an encoder is installed —
    /// that is the fastest path on every tier measured so far — and falls back
    /// to Metal only when there is no encoder to use.
    ///
    /// Caller contract: `coreMLInstalled` must reflect an encoder that is
    /// actually usable for the *current* model. If the selected model doesn't
    /// support CoreML (`TranscriptionModel.hasCoreMLSupport == false`), the
    /// caller MUST pass `coreMLInstalled: false` regardless of whether some
    /// other model's encoder happens to be sitting on disk — this function has
    /// no way to know about model compatibility on its own, and passing `true`
    /// for an unsupported model would return `.coreML` for an encoder that
    /// doesn't match the loaded model.
    static func resolve(mode: CoreMLMode,
                        capability: AcceleratorCapability,
                        coreMLInstalled: Bool) -> AccelerationDecision {
        switch mode {
        case .off:
            return AccelerationDecision(policy: .metalOnly, reason: "CoreML disabled in settings")

        case .on:
            guard coreMLInstalled else {
                return AccelerationDecision(policy: .metalOnly, reason: "CoreML encoder not installed")
            }
            return AccelerationDecision(policy: .coreML, reason: "CoreML enabled in settings")

        case .auto:
            // The encoder goes to the ANE whenever one is available, on every
            // capability tier — including M5-class hardware with the tensor API.
            //
            // This deliberately contradicts the plan this feature was built
            // from. That plan expected the tensor API to win on M5 and had
            // `.auto` bypass CoreML there. Measurement on the real app scenario
            // says otherwise: with the model resident and warmed, CoreML is
            // 192ms vs 231ms on a 5.4s phrase and 1209ms vs 1359ms on 81s.
            // The earlier "420ms vs 855ms" figure came from whisper-cli, which
            // reloads the model on every run and therefore charged each run for
            // loading the .mlmodelc into the ANE (~250-435ms). VoiceType loads
            // the model once and warms it, so that cost is paid once and never
            // seen by the user. Full write-up:
            // scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md
            //
            // Capability still matters here only through `coreMLInstalled`
            // below and through the reason string — do not reintroduce a
            // per-tier branch without a fresh measurement on that tier.
            guard coreMLInstalled else {
                return AccelerationDecision(policy: .metalOnly, reason: "CoreML encoder not installed — using GPU")
            }
            switch capability {
            case .metalWithTensor, .metal:
                return AccelerationDecision(policy: .coreML, reason: "Neural Engine is the fastest path on this Mac")
            case .unavailable:
                return AccelerationDecision(policy: .coreML, reason: "Metal unavailable — falling back to Neural Engine")
            }
        }
    }

    /// Whether the CoreML encoder should be kept on disk at all — what drives
    /// `ModelManager` downloads/eviction. See the type-level doc comment for
    /// why this is a hypothetical `resolve()` query rather than a hand-written
    /// second table: "would the policy pick CoreML if the encoder were
    /// available?" is exactly "should we make it available".
    static func shouldInstallCoreML(mode: CoreMLMode,
                                    capability: AcceleratorCapability,
                                    modelSupportsCoreML: Bool) -> Bool {
        modelSupportsCoreML &&
            resolve(mode: mode, capability: capability, coreMLInstalled: true).policy == .coreML
    }
}
