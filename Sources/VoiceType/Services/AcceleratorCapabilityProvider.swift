import Foundation
import SwiftWhisper

/// Single source of truth for "which accelerator is actually available on this machine".
///
/// Wraps the fork's `WhisperMetal.probeCapability()` and caches its answer for the
/// lifetime of the process. Two reasons this is a separate type rather than a call
/// site in each consumer:
///
///  * The probe is **not cheap and not free of side effects**. It goes through
///    `ggml_backend_metal_reg()`, which creates the Metal device, compiles probe
///    shaders and sets `AGX_RELAX_CDM_CTXSTORE_TIMEOUT`. On a cold shader cache that
///    is several seconds. It is the same work the first model load does anyway, but
///    it must happen exactly once and never on the main thread.
///  * Both the load path (`TranscriptionService`) and the download path
///    (`ModelManager` callers) need the same answer. Asking twice — or letting them
///    disagree — would mean deciding to skip the CoreML encoder while still
///    downloading it, or the reverse.
///
/// The hardware answer cannot change while the app runs, so caching forever is
/// correct here — unlike `coreMLInstalled`, which the caller must re-read each time.
actor AcceleratorCapabilityProvider {
    static let shared = AcceleratorCapabilityProvider()

    private var cached: AcceleratorCapability?
    private var inFlight: Task<AcceleratorCapability, Never>?

    /// Test seam: when set, `current()` returns this without ever touching Metal.
    /// Follows the `_test*` convention already used in TranscriptionService.
    private var _testOverride: AcceleratorCapability?

    /// The capability of the Metal device whisper will actually use.
    ///
    /// Safe to call concurrently and repeatedly: the first caller pays for the probe,
    /// everyone else awaits the same result. The probe itself runs on a global queue
    /// because it blocks for seconds inside C — parking a cooperative-pool thread for
    /// that long would starve unrelated work.
    func current() async -> AcceleratorCapability {
        if let _testOverride { return _testOverride }
        if let cached { return cached }

        if let inFlight {
            return await inFlight.value
        }

        let task = Task<AcceleratorCapability, Never> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let probed = WhisperMetal.probeCapability()
                    continuation.resume(returning: AcceleratorCapability(probed))
                }
            }
        }
        inFlight = task

        let result = await task.value
        cached = result
        inFlight = nil

        AppLog.models.notice("Accelerator capability: \(String(describing: result), privacy: .public)")
        print("[AcceleratorCapabilityProvider] capability = \(result)")
        return result
    }

    /// Test-only: pin the capability so policy tests never depend on the host GPU.
    func _setTestOverride(_ capability: AcceleratorCapability?) {
        _testOverride = capability
    }
}

extension AcceleratorCapability {
    /// Maps the fork's probe result onto the app-level enum. This mapping lives in
    /// exactly one place on purpose: `AccelerationPolicyResolver` stays testable
    /// without linking against the Metal probe, and a future accelerator (or a
    /// change in the fork's enum) has a single site to update.
    init(_ metal: MetalCapability) {
        switch metal {
        case .unavailable:     self = .unavailable
        case .metal:           self = .metal
        case .metalWithTensor: self = .metalWithTensor
        }
    }
}
