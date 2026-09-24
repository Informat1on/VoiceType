import Foundation
import Combine
import CryptoKit
import SwiftWhisper

// MARK: - ModelStatus

/// Load + warm-up lifecycle for the active Whisper model.
/// Published on TranscriptionService so any observer (e.g. MenuBarView) can
/// render a status indicator without polling.
enum ModelStatus: Equatable {
    /// No model selected / never started loading.
    case notLoaded
    /// `Whisper(fromFileURL:)` is executing on the background thread.
    case loading
    /// Model bytes are in memory; running a silent buffer to prime Metal/CoreML/ANE caches.
    case warming
    /// Model is fully ready; first real transcription will be fast.
    case ready
    /// Load or warm-up threw a hard error (file missing, SIGABRT, etc.).
    /// Associated value carries a short human-readable message for logging.
    case error(String)

    // Custom Equatable: two .error cases are equal only when their messages match.
    static func == (lhs: ModelStatus, rhs: ModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded),
             (.loading, .loading),
             (.warming, .warming),
             (.ready, .ready):
            return true
        case let (.error(l), .error(r)):
            return l == r
        default:
            return false
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(Error?)
    case transcriptionFailed(Error)
    case invalidAudioData
    case unsupportedFormat
    case transcriptionTimeout
    /// D3: a transcription was requested while another was already in flight.
    /// `isTranscribing` is claimed synchronously before any `await`, so
    /// overlapping calls fail fast instead of racing the same instance.
    case busy

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model has not been loaded."
        case .modelLoadFailed(let underlyingError):
            if let error = underlyingError {
                return "Failed to load whisper model: \(error.localizedDescription)"
            }
            return "Failed to load whisper model from the specified URL."
        case .transcriptionFailed(let error):
            return "Audio transcription failed: \(error.localizedDescription)"
        case .invalidAudioData:
            return "Invalid audio data provided. Audio buffer cannot be empty."
        case .unsupportedFormat:
            return "Unsupported audio format. Expected 16kHz mono PCM float samples."
        case .transcriptionTimeout:
            return "Transcription timed out. The model may be too large for your device."
        case .busy:
            return "A transcription is already in progress."
        }
    }
}

// MARK: - TranscriptionOutcome

/// One raw whisper segment, before the hallucination filter. Times in ms from
/// the start of the audio (SwiftWhisper.Segment already converts from 10 ms units).
struct TimedSegment: Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
}

/// Result of `transcribe(audio:language:)`, added ahead of the text normalizer
/// (task t-raw-text, 2026-07-27): once a normalizer sits between whisper and
/// the text callers insert, HistoryStore needs both the untouched whisper
/// output AND a record of which pipeline produced the final text — otherwise
/// the accumulated corpus can never separate ASR errors from post-processing
/// errors.
struct TranscriptionOutcome {
    /// Segments joined, before ANY post-processing — the untouched whisper
    /// output. Deliberately captured before the hallucination filter too, so
    /// the corpus keeps the artifact even when the filter removes all of it.
    let rawText: String
    /// What actually gets inserted: rawText after the post-processing chain
    /// (hallucination filter → lexicon normalizer → conditionallyTrim).
    let text: String
    /// Snapshot of the pipeline that produced `text`, taken before whisper ran.
    let pipelineStamp: String
    /// Subtitle-boilerplate segments the hallucination filter removed, in the
    /// order they appeared. Empty on the overwhelming majority of runs.
    /// Carried out of the pure chain so the caller can log them: the filter
    /// itself stays side-effect free, but a dropped segment is exactly the
    /// signal T16 exists to measure, and it must not vanish silently.
    let removedTemplates: [String]
    /// Raw whisper segments with timings, in decode order. Consumed by the replay
    /// harness only; the dictation path ignores it.
    let segments: [TimedSegment]
}

/// Result of the pure post-processing chain. Separate from
/// `TranscriptionOutcome` because it carries no pipeline stamp — the stamp
/// depends on the prompt active at whisper time, which the chain knows nothing
/// about.
struct PostProcessResult {
    let raw: String
    let text: String
    let removedTemplates: [String]
    /// What each rewriting stage changed, in execution order. Each batch is in
    /// its OWN stage's coordinate system (filler offsets predate the dictionary
    /// pass, lexicon offsets follow it), which is why this is a list of batches
    /// and not one flat array — flattening would produce ranges that cannot be
    /// applied or compared together. See TextEdit.swift.
    let stages: [StageEdits]
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var lastResult: String?
    /// Load + warm-up lifecycle. Observed by MenuBarView. Not `private(set)`
    /// (D3): `abandonRun` in NativeAbortSignal.swift sets `.notLoaded`.
    @Published var modelStatus: ModelStatus = .notLoaded

    /// H3: max seconds a native transcription may run before it is forcibly
    /// cancelled (D3: via `runNative`/`race`). Effective ceiling is
    /// `Self.effectiveTimeout(base:audioSeconds:)`, never less than the audio.
    var transcriptionTimeout: TimeInterval = 30

    /// D3: how long `transcribe`/`shutdown` wait for warm-up to retire before
    /// abandoning its native run.
    static let warmUpWaitLimit: TimeInterval = 10

    // D3: internal, not private — runNative/onNativeRunReturned/abandonRun
    // live in NativeAbortSignal.swift (file_length budget) and need these.
    var whisper: Whisper?
    var modelURL: URL?
    private var currentLanguage: String?
    private var currentModelName: String?
    var _initialPrompt: NativeCString?
    var currentInitialPromptText: String?
    /// D3: native runs abandoned but not yet actually returned. Incremented in
    /// `abandonRun`, decremented in `onNativeRunReturned` on genuine retirement
    /// — NOT gated on `self.whisper` matching. `shutdown()` needs this at zero.
    var abandonedRunCount: Int = 0
    /// D3: (token, whisper) of whichever native call `runNative` has in
    /// flight, so an external bounded wait can trigger THIS run's abort signal.
    var activeRun: (token: NativeRunToken, whisper: Whisper)?

    // H1: monotonically-increasing generation counter for loadModel.
    // Each call captures a local copy before the async work begins.
    // The result is committed only when the captured generation matches the
    // current value — stale (out-of-order) loads are silently discarded.
    var modelLoadGeneration: Int = 0

    /// Cancellable handle for background warm-up. Cancelled (and awaited) by transcribe()
    /// so a real transcription always pre-empts an ongoing warm-up pass.
    var warmUpTask: Task<Void, Never>?

    /// True while performWarmUp() is executing — defers setInitialPrompt() the same way
    /// isTranscribing does (VT-WARM-002: prevents prompt restore from overwriting user intent).
    private var isWarmingUp: Bool = false

    // Double-optional sentinel for deferred prompt updates during transcription.
    // .none           → no pending update
    // .some(nil)      → pending clear (setInitialPrompt(nil) was called while busy)
    // .some("text")   → pending prompt text to apply after transcription completes
    private var _pendingPrompt: String??

    private var recommendedThreadCount: Int32 {
        let availableCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let tunedCores = availableCores <= 4
            ? availableCores
            : min(8, max(4, availableCores - 2))
        return Int32(tunedCores)
    }
    
    var isModelLoaded: Bool {
        whisper != nil
    }
    
    var loadedModelName: String? {
        currentModelName
    }

    // Bilingual seed prompt for .bilingualRuEn mode.
    // Mixes Russian prose with inline English technical terms so the whisper.cpp
    // decoder sees both scripts before audio decoding begins.  The seed is ~130
    // chars — well within whisper.cpp's 224-token initial_prompt limit.
    // Rationale: Week 0 validation showed language=auto picks English and mangles
    // Cyrillic on code-switched speech.  Pinning language=ru plus this seed
    // produces clean RU+EN output.  (See ADR 2026-04-24-ruen-language-mode.)
    static let bilingualSeed =
        "Запушь этот commit в main. Проверь auth middleware в handler. Это работает."

    func setInitialPrompt(_ text: String?) {
        // Guard against UAF: if whisper_full is currently running on a background thread
        // it holds a raw pointer into _initialPrompt via the value-copy of whisper_full_params.
        // Freeing that buffer now would be a C-level use-after-free.
        // Defer the update instead; _flushPendingPrompt() applies it once transcription ends.
        //
        // VT-WARM-002: warm-up also runs whisper_full on a C thread — apply the same guard.
        // performWarmUp() checks _pendingPrompt after the silence pass and skips its
        // savedPromptText restore when a pending update exists, ensuring user intent wins.
        if isTranscribing || isWarmingUp {
            _pendingPrompt = .some(text)
            AppLog.transcription.notice("setInitialPrompt deferred: \(self.isTranscribing ? "transcription" : "warm-up") in progress")
            return
        }
        _applyPromptNow(text)
    }

    /// Unconditionally installs a new prompt buffer. Must only be called when NOT transcribing.
    ///
    /// D3: `_initialPrompt` is now a `NativeCString` (ARC-owned), so replacing it
    /// only drops this service's own reference — a native run in flight that
    /// captured the previous box (see `runNative`) keeps its own strong
    /// reference, so the buffer is freed only once that run actually returns.
    private func _applyPromptNow(_ text: String?) {
        currentInitialPromptText = text.flatMap { $0.isEmpty ? nil : $0 }
        guard let text, !text.isEmpty, let box = NativeCString(text) else {
            _initialPrompt = nil
            whisper?.params.initial_prompt = nil
            return
        }
        _initialPrompt = box
        whisper?.params.initial_prompt = UnsafePointer(box.pointer)
    }

    /// Called after transcription completes to flush any prompt change that was deferred.
    private func _flushPendingPrompt() {
        guard let pending = _pendingPrompt else { return }
        _pendingPrompt = nil
        _applyPromptNow(pending)
        AppLog.transcription.notice("Deferred initial prompt applied after transcription")
    }

    #if DEBUG
    // Test seams — compiled out of release builds.
    func _testFlushPendingPrompt() { _flushPendingPrompt() }

    /// VT-WARM-002: drive isWarmingUp without a real Whisper context.
    var _testIsWarmingUp: Bool {
        get { isWarmingUp }
        set { isWarmingUp = newValue }
    }

    /// VT-WARM-002: drive modelLoadGeneration without invoking loadModel.
    var _testModelLoadGeneration: Int {
        get { modelLoadGeneration }
        set { modelLoadGeneration = newValue }
    }

    /// VT-WARM-004: plant a modelStatus value without going through loadModel.
    func _testSetModelStatus(_ status: ModelStatus) { modelStatus = status }

    /// D3: drive isTranscribing without a real transcription (mirrors _testIsWarmingUp).
    var _testIsTranscribing: Bool {
        get { isTranscribing }
        set { isTranscribing = newValue }
    }

    /// D3: observe abandoned-run bookkeeping directly.
    var _testAbandonedRunCount: Int { abandonedRunCount }
    #endif

    /// Build and apply the initial prompt from the current language + custom vocabulary.
    /// Must be called:
    ///   - on first model load / model reload (loadModel re-calls this after params reset)
    ///   - when AppSettings.language changes
    ///   - when AppSettings.customVocabulary changes
    func applyInitialPrompt() {
        let seed = AppSettings.shared.language.usesBilingualPrompt
            ? Self.bilingualSeed
            : ""
        let user = AppSettings.shared.customVocabulary
        // PromptBudget.fullPrompt is the single source of truth for this join —
        // CustomVocabularySection's token counter builds the exact same string,
        // and a second inline copy here would silently drift from it over time.
        let combined = PromptBudget.fullPrompt(seed: seed, vocabulary: user)
        setInitialPrompt(combined.isEmpty ? nil : combined)
    }

    private func applyRuntimeConfiguration(language: Language) {
        guard let whisper else { return }
        let resolvedWhisperLang = language.whisperLanguage
        whisper.params.language = resolvedWhisperLang ?? .auto
        whisper.params.detect_language = (resolvedWhisperLang == nil)
        whisper.params.n_threads = recommendedThreadCount
        currentLanguage = resolvedWhisperLang?.rawValue
        print(
            "[TranscriptionService] Runtime config: language=\(language.rawValue) → whisper=\((resolvedWhisperLang?.rawValue) ?? "auto"), detectLanguage=\(resolvedWhisperLang == nil), threads=\(recommendedThreadCount), usesBilingualPrompt=\(language.usesBilingualPrompt)"
        )
    }

    // No deinit needed for `_initialPrompt` (D3): it is a `NativeCString`, which
    // frees its own strdup buffer in its own `deinit` once nothing — including
    // this service and any in-flight native run's closure — references it.

    /// Release the whisper context before the process exits.
    ///
    /// ggml's Metal device is owned by a C++ static and is destroyed during atexit.
    /// If a whisper context is still holding Metal buffers at that point,
    /// ggml_metal_rsets_free() aborts on `GGML_ASSERT([rsets->data count] == 0)` —
    /// reproduced against whisper.cpp v1.9.1 by letting a context outlive main().
    /// TranscriptionService is a long-lived singleton, so nothing would free the
    /// context on its own: the terminate path must do it explicitly.
    ///
    /// Async because releasing the context out from under a running `whisper_full`
    /// is a use-after-free: SwiftWhisper's transcribe() is not cancellation-aware
    /// (it resumes a continuation from its own DispatchQueue), so the only safe
    /// move is to wait for the C side to finish.  Callers must therefore hold up
    /// termination — see AppDelegate.applicationShouldTerminate.
    ///
    /// - Returns: `true` if the context was released and a normal exit is safe.
    ///   `false` means a transcription was still running past the deadline and the
    ///   context is deliberately still alive — the caller must then bypass atexit
    ///   (`_exit`) instead of returning through a normal exit, or ggml will abort.
    @discardableResult
    func shutdown() async -> Bool {
        // Reject anything that would install a new context behind our back, and
        // invalidate a loadModel() still awaiting Whisper(fromFileURL:).
        isShuttingDown = true
        modelLoadGeneration &+= 1

        // D3: bound the warm-up drain — a wedged native call must not hang app
        // quit. Times out → abandon its run; the while-loop below then waits
        // (bounded) for abandonedRunCount to clear before declaring it safe.
        if let task = warmUpTask {
            task.cancel()
            warmUpTask = nil
            let reason = "shutdown: warm-up wait exceeded \(Self.warmUpWaitLimit)s"
            if await waitForWarmUpTask(task, reason: reason) == false {
                AppLog.models.error("shutdown: timed out waiting for warm-up — its native run was abandoned")
            }
        }

        // Wait out an in-flight transcription, a model load still inside
        // Whisper(fromFileURL:), and (D3) any abandoned run not yet retired —
        // abandoning only detaches it from user-facing state, it does not make
        // whisper_full return instantly, so freeing `whisper` under it would
        // still be a use-after-free.
        let deadline = Date().addingTimeInterval(Self.shutdownDrainTimeout)
        while (isTranscribing || activeModelLoads > 0 || abandonedRunCount > 0) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !isTranscribing, activeModelLoads == 0, abandonedRunCount == 0 else {
            AppLog.models.error(
                "shutdown timed out (transcribing=\(self.isTranscribing), loads=\(self.activeModelLoads), abandonedRuns=\(self.abandonedRunCount)) — context left alive, caller must _exit"
            )
            return false
        }

        whisper = nil
        modelStatus = .notLoaded
        return true
    }

    /// How long shutdown() waits for a running transcription before giving up.
    static let shutdownDrainTimeout: TimeInterval = 5.0

    /// Set by shutdown(); makes loadModel/transcribe refuse to start new work while
    /// the app is quitting, so nothing installs a context after the drain.
    private var isShuttingDown = false

    /// Number of loadModel() calls currently inside `Whisper(fromFileURL:)`.
    ///
    /// Counted here rather than by tracking Tasks in the caller: model loads are
    /// started from more than one place (AppDelegate.modelLoadTask, but also the
    /// on-demand ensureModelLoaded() path inside the transcription pipeline), and a
    /// native context still under construction must not outlive the shutdown drain.
    private var activeModelLoads = 0

    // MARK: - Metal-only shadow path

    /// Builds (or reuses) `<Models>/.metal-only/<same filename>` as a relative
    /// symlink to `../<same filename>` and returns its URL.
    ///
    /// Why this works without touching whisper.cpp: `whisper_get_coreml_path_encoder`
    /// (whisper.cpp:3328, `src/whisper.cpp` in the SwiftWhisper fork) derives the
    /// CoreML encoder path from the *string* passed to `Whisper(fromFileURL:)` —
    /// it never calls `realpath`. Handing it a same-named symlink that lives one
    /// directory away from the real `-encoder.mlmodelc` bundle makes its own
    /// lookup fail (no sibling encoder next to the symlink), and the fork —
    /// built with `WHISPER_COREML_ALLOW_FALLBACK` — falls through to Metal. The
    /// real model file never moves and is never touched.
    ///
    /// Exposed `internal` (not `private`) so `TranscriptionServiceShadowPathTests`
    /// can exercise the filesystem logic directly without booting a Whisper context.
    ///
    /// - Throws: whenever a correct symlink cannot be produced. Never falls back
    ///   to returning `url` itself on failure — a silent fallback here would
    ///   silently re-enable CoreML against the resolved policy, which is exactly
    ///   the class of quiet lie the M5 CoreML-bypass work was fixing in the
    ///   first place (a stale "CoreML: enabled" log line that had been wrong for
    ///   years). Callers must treat a throw as a hard model-load failure.
    static func shadowModelURL(for url: URL) throws -> URL {
        // Shared with ModelManager.deleteModel, which must remove this same
        // symlink when its target model is deleted — see the constant's doc
        // comment for why it isn't a private literal here.
        let metalOnlyShadowDirectoryName = AccelerationPolicyResolver.metalOnlyShadowDirectoryName
        let fm = FileManager.default
        let modelsDir = url.deletingLastPathComponent()
        let shadowDir = modelsDir.appendingPathComponent(metalOnlyShadowDirectoryName, isDirectory: true)
        let filename = url.lastPathComponent
        let target = shadowDir.appendingPathComponent(filename)
        // Must match exactly what createSymbolicLink below writes — this is the
        // string compared against destinationOfSymbolicLink() when reusing.
        let relativeDestination = "../" + filename

        func shadowError(_ reason: String) -> NSError {
            NSError(
                domain: "TranscriptionService.ShadowSymlink",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Metal-only shadow path for \(filename): \(reason)"]
            )
        }

        // shadowDir may already exist as a plain file from some unrelated cause —
        // fail loudly instead of trying (and failing) to mkdir over it.
        var shadowDirIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: shadowDir.path, isDirectory: &shadowDirIsDirectory) {
            guard shadowDirIsDirectory.boolValue else {
                throw shadowError("\(metalOnlyShadowDirectoryName) exists and is not a directory")
            }
        } else {
            do {
                try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
            } catch {
                throw shadowError("could not create \(metalOnlyShadowDirectoryName) directory: \(error.localizedDescription)")
            }
        }

        // Reuse-as-is: if a correct symlink is already sitting there (the common
        // case — most loads reload the same model), skip the write entirely and
        // avoid any window where `target` doesn't exist.
        if let existingDestination = try? fm.destinationOfSymbolicLink(atPath: target.path),
           existingDestination == relativeDestination {
            return target
        }

        // Something else occupies `target` that is not the correct symlink — a
        // stray regular file/directory (as opposed to a symlink pointing
        // elsewhere, e.g. left over from a renamed model) must not be silently
        // clobbered by the rename() below, which replaces whatever is there.
        var targetIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) {
            var isSymlink = false
            if let attrs = try? fm.attributesOfItem(atPath: target.path) {
                isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            }
            guard isSymlink else {
                throw shadowError("a non-symlink already exists at the shadow path")
            }
        }

        // Atomic install: write a uniquely-named symlink, then rename() it onto
        // `target`. rename(2) is atomic at the filesystem level and simply
        // replaces whatever inode (including a stale symlink) is at the
        // destination — there is no window where `target` is missing. This
        // matters because loadModel() only serialises via a generation counter,
        // not a mutex (see modelLoadGeneration doc above loadModel): two
        // overlapping loads of the same model can both reach this function, and
        // Whisper(fromFileURL:) opens `target` on a background queue. A
        // remove-then-create would let the second call's create observe a
        // momentarily-missing path and hand the first call's still-running
        // constructor an ENOENT. FileManager.replaceItemAt is not used here —
        // it is documented and implemented around swapping regular
        // files/directories (backup-and-restore semantics) and is not the
        // primitive for atomically repointing a symlink; rename(2) is.
        let tempURL = shadowDir.appendingPathComponent(".shadow-\(UUID().uuidString)")
        do {
            try fm.createSymbolicLink(atPath: tempURL.path, withDestinationPath: relativeDestination)
        } catch {
            throw shadowError("failed to create symlink: \(error.localizedDescription)")
        }

        let renameResult: Int32 = tempURL.withUnsafeFileSystemRepresentation { tempFS in
            target.withUnsafeFileSystemRepresentation { targetFS in
                guard let tempFS, let targetFS else { return -1 }
                return rename(tempFS, targetFS)
            }
        }
        guard renameResult == 0 else {
            let errnoMessage = String(cString: strerror(errno))
            try? fm.removeItem(at: tempURL)
            throw shadowError("rename() failed: \(errnoMessage)")
        }

        return target
    }

    func loadModel(at url: URL, language: Language = .auto, model: TranscriptionModel? = nil) async throws {
        // Nothing may create a native context once the teardown has started —
        // it would outlive the drain and hit the atexit assert.  See shutdown().
        guard !isShuttingDown else {
            AppLog.models.warning("loadModel called during shutdown — rejected")
            throw TranscriptionError.modelLoadFailed(NSError(
                domain: "TranscriptionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "The app is quitting."]
            ))
        }

        // C1: Guard against swapping the Whisper instance (and freeing the old one)
        // while whisper_full is running on a background thread holding a raw C pointer
        // into its context.  Replacing `whisper` mid-transcription is a UAF.
        guard !isTranscribing else {
            AppLog.models.warning("loadModel called while transcription is active — rejected to prevent UAF")
            throw TranscriptionError.modelLoadFailed(NSError(
                domain: "TranscriptionService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot load a new model while transcription is in progress."]
            ))
        }

        // H1: Capture and increment the generation counter BEFORE the async work.
        // If a newer loadModel call arrives while we await, our generation will be
        // stale and we discard the result rather than overwriting the newer model.
        modelLoadGeneration &+= 1
        let myGeneration = modelLoadGeneration

        print("[TranscriptionService] Loading model from \(url.lastPathComponent)")
        AppLog.models.notice("Loading model \(url.lastPathComponent, privacy: .public)")

        // VT-WARM-003: Cancel any in-flight warm-up BEFORE the file-existence guard so a
        // previous warm-up cannot race to write .ready over the .error status we set below.
        if let existingTask = warmUpTask {
            existingTask.cancel()
            _ = await existingTask.value   // drain so whisper_full finishes on the C side
            warmUpTask = nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[TranscriptionService] Model file not found: \(url.lastPathComponent)")
            AppLog.models.error("Model file is missing: \(url.lastPathComponent, privacy: .public)")
            modelStatus = .error("Model file not found: \(url.lastPathComponent)")
            throw TranscriptionError.modelLoadFailed(nil)
        }

        modelStatus = .loading

        let resolvedWhisperLang = language.whisperLanguage
        let shouldDetectLanguage = resolvedWhisperLang == nil
        let threadCount = recommendedThreadCount
        let whisperLanguageRawValue = (resolvedWhisperLang ?? .auto).rawValue

        modelURL = url
        currentLanguage = resolvedWhisperLang?.rawValue
        currentModelName = url.lastPathComponent.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")

        // Use ModelManager's authoritative CoreML URL instead of fragile string replacement
        let coreMLURL: URL? = model.map { ModelManager.shared.coreMLModelURL(for: $0) }
        let hasCoreML = coreMLURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        // Contract from AccelerationPolicyResolver.resolve's doc comment: a model
        // that doesn't ship a CoreML encoder (hasCoreMLSupport == false) must never
        // report one as "installed" here, even if a *different* model's encoder
        // bundle happens to sit on disk under a name whisper.cpp's own `-qX_X`
        // suffix stripping would also match (see ModelManager.needsCoreMLDownload) —
        // otherwise e.g. smallQ5 could silently pick up small's encoder.
        let modelSupportsCoreML = model?.hasCoreMLSupport ?? false
        let coreMLInstalledForPolicy = modelSupportsCoreML && hasCoreML

        let tensorCapability = await AcceleratorCapabilityProvider.shared.current()
        let decision = AccelerationPolicyResolver.resolve(
            mode: AppSettings.shared.coreMLMode,
            capability: tensorCapability,
            coreMLInstalled: coreMLInstalledForPolicy
        )

        // .coreML: effectiveURL is `url`, byte-for-byte identical to pre-M5
        // behavior — there is no M3/M4 hardware available here to verify a
        // changed CoreML path against, so it must not change at all.
        // .metalOnly: route through the shadow symlink so whisper.cpp's own
        // CoreML lookup fails and it falls through to Metal. See
        // shadowModelURL's doc comment for the mechanism.
        let effectiveURL: URL
        switch decision.policy {
        case .coreML:
            effectiveURL = url
        case .metalOnly:
            do {
                effectiveURL = try Self.shadowModelURL(for: url)
            } catch {
                // Never fall back to `url` on failure — that would silently
                // re-enable CoreML against the resolved policy. See
                // shadowModelURL's doc comment for why that is unacceptable.
                let message = "Failed to prepare Metal-only shadow path for \(url.lastPathComponent): \(error.localizedDescription)"
                print("[TranscriptionService] \(message)")
                AppLog.models.error("\(message, privacy: .public)")
                ErrorLogger.shared.log(message: message, category: "models", context: ["stage": "shadow-symlink"])
                modelStatus = .error(message)
                throw TranscriptionError.modelLoadFailed(error)
            }
        }

        if decision.policy == .metalOnly {
            // ggml is about to print its own "whisper_init_state: failed to load
            // Core ML model ..." line below — that failure is the whole point of
            // the shadow path, not a regression. Say so up front so the next
            // person reading the log doesn't go "fix" it.
            print("[TranscriptionService] Expected next: whisper.cpp will report it could not find a CoreML encoder — intentional (Metal-only policy: \(decision.reason)).")
        }

        let coreMLRequested = decision.policy == .coreML
        // whisper.cpp never exposes state->ctx_coreml, so "loaded" can't be
        // observed from here — coreMLAttempted only says whether we left the
        // real path in place for whisper.cpp to *try* CoreML on, not whether it
        // actually succeeded. Do not rename this to "coreMLActuallyLoaded" or
        // similar; that would repeat the exact false-confidence bug this
        // diagnostic replaces (see CLAUDE.md task context / prior session).
        let coreMLAttempted = effectiveURL == url
        print(
            "[TranscriptionService] Acceleration decision: policy=\(decision.policy), reason=\"\(decision.reason)\", tensorCapability=\(tensorCapability), coreMLInstalled=\(coreMLInstalledForPolicy), coreMLRequested=\(coreMLRequested), coreMLAttempted=\(coreMLAttempted)"
        )
        AppLog.models.notice(
            "Acceleration decision: policy=\(String(describing: decision.policy), privacy: .public) reason=\(decision.reason, privacy: .public) tensorCapability=\(String(describing: tensorCapability), privacy: .public) coreMLInstalled=\(coreMLInstalledForPolicy) coreMLRequested=\(coreMLRequested) coreMLAttempted=\(coreMLAttempted)"
        )

        print(
            "[TranscriptionService] Loading model: \(currentModelName ?? "unknown") (lang: \(whisperLanguageRawValue), detectLanguage: \(shouldDetectLanguage), threads: \(threadCount))"
        )
        let startTime = CFAbsoluteTimeGetCurrent()
        // Bracket the native constructor so shutdown() can wait for it — see
        // activeModelLoads.  Both @MainActor, so the ± pair cannot interleave.
        activeModelLoads += 1
        defer { activeModelLoads -= 1 }
        let newWhisper: Whisper = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let params = WhisperParams(strategy: .greedy)
                params.language = WhisperLanguage(rawValue: whisperLanguageRawValue) ?? .auto
                params.detect_language = shouldDetectLanguage
                params.n_threads = threadCount
                params.print_progress = false
                params.print_timestamps = false
                params.print_special = false
                params.print_realtime = false

                continuation.resume(returning: Whisper(fromFileURL: effectiveURL, withParams: params))
            }
        }
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        print("[TranscriptionService] Model \(currentModelName ?? "unknown") loaded in \(String(format: "%.2f", loadTime))s")
        AppLog.models.notice("Model load finished")

        // H1: If a newer loadModel call has already committed a different model,
        // discard this stale result rather than overwriting the authoritative state.
        guard myGeneration == modelLoadGeneration else {
            AppLog.models.notice("Discarding stale model load (generation \(myGeneration) < \(self.modelLoadGeneration))")
            print("[TranscriptionService] Stale model load discarded (gen \(myGeneration) vs current \(modelLoadGeneration))")
            return
        }

        whisper = newWhisper
        applyRuntimeConfiguration(language: language)

        // Re-apply initial prompt so a model reload never silently erases user vocabulary
        // or the bilingual seed.  (The WhisperParams object is freshly created above, so
        // any previously-set initial_prompt pointer is gone — must re-apply unconditionally.)
        applyInitialPrompt()

        // Transition to .warming and kick off background warm-up so Metal kernels, CoreML,
        // and the ANE memory allocator are primed before the first real transcription.
        modelStatus = .warming
        warmUpTask = Task { [weak self] in
            await self?.performWarmUp()
        }
    }

    // MARK: - D3: native run bookkeeping (timeout, abort, abandonment)
    // `runNative`, `onNativeRunReturned` and `abandonRun` — the shared
    // abort/timeout machinery used by both `transcribe` and `performWarmUp` —
    // live in an `extension TranscriptionService` in NativeAbortSignal.swift,
    // to stay under this file's file_length budget. `whisper`, `modelURL`,
    // `modelStatus`, `modelLoadGeneration`, `warmUpTask`, `abandonedRunCount`,
    // `activeRun` and `_initialPrompt` are `internal` (not `private`) so that
    // extension can reach them.

    // MARK: - Warm-up

    /// Writes a marker to stderr once warm-up has actually run a compute graph,
    /// but only when build-app.sh asks for it via VOICETYPE_SELFCHECK.
    ///
    /// The self-check needs to outlive lazy pipeline compilation: ggml logs
    /// "loaded in ... sec" as soon as the MTLLibrary is up, long before any
    /// compute pipeline is built, so waiting on that marker alone would kill the
    /// app before "failed to compile pipeline" could ever appear. Warm-up pushes
    /// 500 ms of silence through whisper, which forces those pipelines to be
    /// built for real. Review finding, wave B re-review.
    ///
    /// stderr rather than AppLog because print() is a no-op in release builds and
    /// os_log does not reach the pipe build-app.sh captures.
    static func emitSelfCheckMarker() {
        guard ProcessInfo.processInfo.environment["VOICETYPE_SELFCHECK"] == "1" else { return }
        FileHandle.standardError.write(Data("VOICETYPE_SELFCHECK: warm-up complete\n".utf8))
    }

    /// Primes Metal/CoreML/ANE caches by running 500ms of silence (8000 zero-samples
    /// @ 16 kHz) through whisper.transcribe. Must not affect user-facing state or the
    /// initial prompt.
    ///
    /// - On success: `modelStatus` advances to `.ready`.
    /// - On failure: logs to errors.log and sets `.ready` anyway (warm-up is an
    ///   optimisation, not a hard requirement; the model is still usable).
    /// - Cancelled by `transcribe()` so a real transcription always pre-empts warm-up.
    private func performWarmUp() async {
        guard let whisper else { return }

        // VT-WARM-002: Snapshot the generation so we can detect if loadModel was called
        // again while we were awaiting — in that case we must not touch modelStatus or
        // restore the prompt (the new load will manage those itself).
        let warmUpGeneration = modelLoadGeneration

        // VT-WARM-002/005: Bracket warm-up with isWarmingUp so setInitialPrompt defers
        // its changes to _pendingPrompt instead of modifying the buffer mid-transcription.
        isWarmingUp = true
        defer {
            isWarmingUp = false
            // VT-WARM-005: Nil out warmUpTask on natural exit so the Task does not retain
            // self for the object's entire lifetime.  transcribe() already nils it on the
            // cancel path before awaiting task.value, so this only fires on the success /
            // unforced-error paths.  Both paths are on @MainActor — no data race.
            if warmUpGeneration == modelLoadGeneration {
                warmUpTask = nil
            }
        }

        // Snapshot and clear the initial prompt so the silence buffer is decoded
        // without any bilingual/vocabulary seed — avoids hallucinated tokens in log.
        let savedPromptText = currentInitialPromptText
        _applyPromptNow(nil)

        let silenceBuffer = [Float](repeating: 0, count: 8_000)   // 500 ms @ 16 kHz

        do {
            // D3: 30-second safety timeout — identical ceiling used for real
            // transcriptions — now genuinely enforced via runNative/race: if it
            // elapses, the run is abandoned and this call throws
            // TranscriptionError.transcriptionTimeout instead of hanging.
            _ = try await runNative(on: whisper, audio: silenceBuffer, timeout: 30)

            // VT-WARM-002: Only restore the saved prompt when the generation is still
            // current AND no user-initiated setInitialPrompt arrived while we were busy
            // (the pending update already contains the user's intent and wins).
            if warmUpGeneration == modelLoadGeneration && _pendingPrompt == nil {
                _applyPromptNow(savedPromptText)
            } else if warmUpGeneration == modelLoadGeneration {
                // A pending prompt arrived — flush it now (isWarmingUp is still true here
                // so _flushPendingPrompt goes through _applyPromptNow safely).
                _flushPendingPrompt()
            }

            if !Task.isCancelled && warmUpGeneration == modelLoadGeneration {
                modelStatus = .ready
                AppLog.models.notice("Warm-up completed — model is hot")
                Self.emitSelfCheckMarker()
            }
        } catch {
            // VT-WARM-002: Restore prompt only when still current and no pending update.
            if warmUpGeneration == modelLoadGeneration && _pendingPrompt == nil {
                _applyPromptNow(savedPromptText)
            } else if warmUpGeneration == modelLoadGeneration {
                _flushPendingPrompt()
            }

            if Task.isCancelled {
                // A real transcription pre-empted us — that is fine; status will be
                // managed by the transcription path.
                AppLog.models.notice("Warm-up cancelled (pre-empted by real transcription)")
            } else if warmUpGeneration == modelLoadGeneration {
                AppLog.models.error("Warm-up failed: \(error.localizedDescription, privacy: .public)")
                ErrorLogger.shared.log(error, category: "models", context: ["stage": "warmup"])
                // Model is still loaded — mark ready so the user can transcribe.
                modelStatus = .ready
            }
        }
    }

    /// One-shot manual QA lever: with `VOICETYPE_DEBUG_FAIL_ASR=1` set, the
    /// first `transcribe` call in the process's life fails before touching
    /// whisper (exercises the History "failed"+Retry path); later calls work
    /// normally. Not `#if DEBUG` — the manual checklist runs against the
    /// installed app, which may be a Release build.
    private static var debugFailASRConsumed = false

    private static func consumeDebugFailASROnce() -> Bool {
        guard ProcessInfo.processInfo.environment["VOICETYPE_DEBUG_FAIL_ASR"] == "1" else { return false }
        guard !debugFailASRConsumed else { return false }
        debugFailASRConsumed = true
        return true
    }

    /// D3: waits up to `warmUpWaitLimit` for `task` (a `warmUpTask` already
    /// cancelled and nilled by the caller) to retire, instead of forever. Past
    /// the limit, abandons its native run (`abandonRun`, using `reason`) and
    /// returns `false`; `true` means it retired in time. Shared by
    /// `drainWarmUpBeforeTranscribe` and `shutdown`.
    private func waitForWarmUpTask(_ task: Task<Void, Never>, reason: String) async -> Bool {
        do {
            _ = try await Self.race(
                timeout: Self.warmUpWaitLimit,
                operation: { await task.value },
                onTimeout: { [weak self] in
                    Task { @MainActor in
                        guard let self, let active = self.activeRun else { return }
                        self.abandonRun(token: active.token, whisper: active.whisper, reason: reason)
                    }
                }
            )
            return true
        } catch {
            return false
        }
    }

    /// VT-WARM-001, bounded (D3): pre-empts an in-flight warm-up via
    /// `waitForWarmUpTask` before a real transcription runs; on timeout throws
    /// `modelNotLoaded` instead of proceeding. Returns the generation captured
    /// before the wait, for the caller to detect a drop/replace. Split out of
    /// `transcribe` for its complexity.
    private func drainWarmUpBeforeTranscribe() async throws -> Int {
        let generationBeforeWait = modelLoadGeneration
        guard let task = warmUpTask else { return generationBeforeWait }
        task.cancel()
        warmUpTask = nil
        guard await waitForWarmUpTask(task, reason: "Warm-up wait exceeded \(Self.warmUpWaitLimit)s") else {
            AppLog.transcription.error("Timed out waiting \(Self.warmUpWaitLimit)s for warm-up to finish — model dropped")
            throw TranscriptionError.modelNotLoaded
        }
        return generationBeforeWait
    }

    func transcribe(audio: [Float], language: Language = .auto) async throws -> TranscriptionOutcome {
        // A transcription started after the drain would keep whisper_full running
        // past the point where we report the app safe to quit.  See shutdown().
        guard !isShuttingDown else {
            AppLog.transcription.warning("transcribe called during shutdown — rejected")
            throw TranscriptionError.modelNotLoaded
        }

        // D3 exclusivity: claim isTranscribing synchronously, before any `await`,
        // so an overlapping call gets `.busy` instead of racing the same
        // Whisper instance (previously only `whisper.inProgress`, checked
        // several `await`s below, guarded against this).
        guard !isTranscribing else {
            AppLog.transcription.warning("transcribe called while another transcription is already in progress")
            throw TranscriptionError.busy
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            // Apply any prompt change that was deferred while whisper_full was running.
            // isTranscribing is already false here, so _applyPromptNow will not re-defer.
            _flushPendingPrompt()
        }

        if Self.consumeDebugFailASROnce() {
            let debugError = NSError(
                domain: "TranscriptionService.DebugFailASR",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Forced failure via VOICETYPE_DEBUG_FAIL_ASR=1 (manual QA only)."]
            )
            AppLog.transcription.notice("VOICETYPE_DEBUG_FAIL_ASR=1: failing this transcription before whisper runs")
            throw TranscriptionError.transcriptionFailed(debugError)
        }

        guard let whisper else {
            print("[TranscriptionService] ERROR: Model not loaded")
            AppLog.transcription.error("Transcription requested without a loaded model")
            throw TranscriptionError.modelNotLoaded
        }

        guard !audio.isEmpty else {
            print("[TranscriptionService] ERROR: Empty audio data")
            AppLog.transcription.error("Transcription requested with empty audio")
            throw TranscriptionError.invalidAudioData
        }

        print("[TranscriptionService] Starting transcription with model: \(currentModelName ?? "unknown")")
        print("[TranscriptionService] Audio samples: \(audio.count), duration: \(String(format: "%.2f", Double(audio.count) / 16000.0))s, language: \(language.rawValue)")

        // Pre-flight check: Handle instanceBusy with retry for rapid sequential transcriptions.
        // Defensive-in-depth only now: the isTranscribing guard above should make this
        // unreachable (a wedged native run drops its Whisper instance, see abandonRun).
        if whisper.inProgress {
            print("[TranscriptionService] Whisper busy, waiting with backoff...")
            // Wait up to 1.5s total with linear backoff (100ms, 200ms, 300ms, 400ms, 500ms)
            for attempt in 1...5 {
                try await Task.sleep(nanoseconds: UInt64(100_000_000 * attempt))
                if !whisper.inProgress {
                    print("[TranscriptionService] Whisper ready after \(attempt) retry(s)")
                    break
                }
            }

            // Final check - if still busy, throw descriptive error
            if whisper.inProgress {
                print("[TranscriptionService] ERROR: Whisper still busy after retries")
                AppLog.transcription.error("Transcription skipped because previous job is still running")
                let busyError = NSError(
                    domain: "Whisper",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Previous transcription still completing"]
                )
                throw TranscriptionError.transcriptionFailed(busyError)
            }
        }

        // Apply runtime config only after confirming whisper is idle — prevents mutating
        // language/thread params while whisper_full runs on a background thread.
        applyRuntimeConfiguration(language: language)

        // VT-WARM-001, bounded (D3): cancel + wait for warm-up to retire before
        // calling whisper.transcribe(), but bounded by warmUpWaitLimit instead
        // of awaiting task.value forever (see drainWarmUpBeforeTranscribe).
        let generationBeforeWait = try await drainWarmUpBeforeTranscribe()

        // VT-WARM-004: Warm-up may have been cancelled mid-flight leaving status at .warming.
        // The model is already exercised enough; advance to .ready so the UI stays coherent.
        if modelStatus == .warming {
            modelStatus = .ready
        }

        // D3: re-read the instance AFTER the wait above — a timeout there (or
        // in warm-up's own 30s ceiling) may have dropped/replaced it. ASR must
        // never run on the instance captured before this await.
        guard modelLoadGeneration == generationBeforeWait, let currentWhisper = self.whisper else {
            AppLog.transcription.warning("Model instance changed or was dropped while waiting for warm-up — aborting this transcription")
            throw TranscriptionError.modelNotLoaded
        }

        progress = 0.0
        lastResult = nil

        do {
            // Read the normalizer toggle once, here, and use the same value
            // for both the stamp and the chain. Reading it twice would let a
            // toggle flipped mid-transcription produce a history entry whose
            // stamp contradicts its own text.
            let normalize = AppSettings.shared.normalizeTranscript
            let removeFillers = AppSettings.shared.removeFillerWords

            // Snapshot the pipeline stamp BEFORE whisper runs — see
            // pipelineStamp(forPrompt:)'s doc comment for why capturing it
            // after this call would describe the wrong transcription.
            let stamp = Self.pipelineStamp(
                forPrompt: currentInitialPromptText,
                normalizing: normalize,
                removingFillers: removeFillers
            )

            let transcribeStart = CFAbsoluteTimeGetCurrent()

            // D3: honest timeout, never less than the audio's own duration —
            // enforced via runNative/race, which actually abandons a wedged
            // native call instead of just cancelling the loser's Swift Task.
            let audioSeconds = Double(audio.count) / 16000.0
            let timeoutSeconds = Self.effectiveTimeout(base: transcriptionTimeout, audioSeconds: audioSeconds)
            let segments: [Segment] = try await runNative(on: currentWhisper, audio: audio, timeout: timeoutSeconds)

            let segmentTexts = segments.map { $0.text }

            let transcribeTime = CFAbsoluteTimeGetCurrent() - transcribeStart
            let realtimeFactor = transcribeTime > 0 ? audioSeconds / transcribeTime : 0
            print(
                "[TranscriptionService] Transcription completed in \(String(format: "%.2f", transcribeTime))s (\(String(format: "%.2fx", realtimeFactor)) realtime)"
            )

            let processed = TranscriptionService.postProcess(
                segments: segmentTexts,
                trim: AppSettings.shared.trimWhitespaceAfterInsert,
                normalize: normalize,
                removeFillers: removeFillers
            )

            // A dropped subtitle-boilerplate segment is the whole signal T16
            // exists to measure, and it never reaches history when the filter
            // empties the text: AppDelegate returns on the empty-text guard
            // before recordPending runs. Log it so the artifact is not lost
            // silently. errors.log rotates after 7 days, so this is a
            // frequency counter, not a permanent corpus — a deliberate trade
            // against putting blank rows in the user's History list.
            if !processed.removedTemplates.isEmpty {
                let joined = processed.removedTemplates
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " | ")
                ErrorLogger.shared.log(
                    message: "Hallucination filter dropped \(processed.removedTemplates.count) "
                        + "segment(s) [\(joined)]; result empty: \(processed.text.isEmpty); "
                        + "pipeline: \(stamp)",
                    category: "transcription"
                )
            }

            progress = 1.0
            lastResult = processed.text

            print("[TranscriptionService] Result ready (characters: \(processed.text.count))")
            AppLog.transcription.notice("Transcription result is ready")
            return TranscriptionOutcome(
                rawText: processed.raw,
                text: processed.text,
                pipelineStamp: stamp,
                removedTemplates: processed.removedTemplates,
                segments: segments.map { TimedSegment(text: $0.text, startMs: $0.startTime, endMs: $0.endTime) }
            )
        } catch TranscriptionError.transcriptionTimeout {
            progress = 0.0
            AppLog.transcription.error("Transcription timed out after \(self.transcriptionTimeout)s")
            print("[TranscriptionService] Transcription timed out after \(transcriptionTimeout)s")
            ErrorLogger.shared.log(
                message: "Transcription timed out after \(transcriptionTimeout)s — model may be too large",
                category: "transcription"
            )
            throw TranscriptionError.transcriptionTimeout
        } catch {
            progress = 0.0
            print("[TranscriptionService] Transcription error: \(error)")
            AppLog.transcription.error("Transcription failed inside Whisper pipeline")
            throw TranscriptionError.transcriptionFailed(error)
        }
    }

    func unloadModel() {
        // C1: Never nil out `whisper` while whisper_full holds its C context pointer.
        guard !isTranscribing else {
            AppLog.models.warning("unloadModel called while transcription is active — deferred")
            print("[TranscriptionService] unloadModel deferred: transcription in progress")
            return
        }
        print("[TranscriptionService] Unloading model")
        warmUpTask?.cancel()
        warmUpTask = nil
        whisper = nil
        modelURL = nil
        currentLanguage = nil
        currentModelName = nil
        lastResult = nil
        progress = 0.0
        modelStatus = .notLoaded
    }

    // MARK: - Post-processing chain, trim helper, pipeline stamp
    // Moved to TranscriptionService+PostProcess.swift (quality-tools plan,
    // T1): this file was 1186 lines against the 1200-line file_length error
    // threshold. See that file for postProcess/conditionallyTrim/
    // trimTrailingWhitespace/pipelineStamp and postProcessingVersion.
}

// D3 timeout/race helpers (RaceOutcomeBox, TranscriptionService.effectiveTimeout,
// TranscriptionService.race) live in NativeAbortSignal.swift — they need no
// TranscriptionService-private state, only `TranscriptionError`, and keeping
// them there keeps this file under the file_length budget.
