import Foundation

/// One-line composition of the accelerator probe + policy resolver, used at
/// every call site that decides whether a model's CoreML encoder should be
/// downloaded.
///
/// Kept separate from `AccelerationPolicyResolver` on purpose — that type is
/// pure by design (no file system, no `ModelManager`, no `AppSettings.shared`),
/// which is what makes its spec table exhaustively unit-testable without
/// touching Metal or disk. This wrapper is the one place that pays for the
/// live probe (`AcceleratorCapabilityProvider`) and the live setting
/// (`AppSettings.shared.coreMLMode`), so all four download sites (initial
/// model download, explicit CoreML backfill, Settings re-download, first-launch
/// download) agree on the same answer instead of re-deriving it independently.
@MainActor
enum CoreMLDownloadDecision {
    /// Whether `model`'s CoreML encoder should be present on disk right now,
    /// given the current acceleration mode and hardware. Drives download
    /// decisions only — never eviction. `ModelManager.deleteModel` stays a
    /// purely user-initiated action; a machine that's currently `.auto` and
    /// tensor-capable must not silently delete an encoder some other Mac
    /// (or a future non-tensor machine) still needs.
    static func shouldInstall(for model: TranscriptionModel) async -> Bool {
        let capability = await AcceleratorCapabilityProvider.shared.current()
        return AccelerationPolicyResolver.shouldInstallCoreML(
            mode: AppSettings.shared.coreMLMode,
            capability: capability,
            modelSupportsCoreML: model.hasCoreMLSupport
        )
    }
}
