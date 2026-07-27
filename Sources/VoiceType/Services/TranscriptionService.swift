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
        }
    }
}

// MARK: - TranscriptionOutcome

/// Result of `transcribe(audio:language:)`, added ahead of the text normalizer
/// (task t-raw-text, 2026-07-27): once a normalizer sits between whisper and
/// the text callers insert, HistoryStore needs both the untouched whisper
/// output AND a record of which pipeline produced the final text — otherwise
/// the accumulated corpus can never separate ASR errors from post-processing
/// errors.
struct TranscriptionOutcome {
    /// Segments joined, before conditionallyTrim — the untouched whisper output.
    let rawText: String
    /// What actually gets inserted (currently rawText after conditionallyTrim).
    let text: String
    /// Snapshot of the pipeline that produced `text`, taken before whisper ran.
    let pipelineStamp: String
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var lastResult: String?
    /// Load + warm-up lifecycle. Observed by MenuBarView to render the model status dot.
    @Published private(set) var modelStatus: ModelStatus = .notLoaded

    /// H3: Maximum seconds a native transcription may run before it is forcibly
    /// cancelled.  Previously declared only as an error case but never enforced;
    /// now races against the real whisper.transcribe call via withThrowingTaskGroup.
    var transcriptionTimeout: TimeInterval = 30

    private var whisper: Whisper?
    private var modelURL: URL?
    private var currentLanguage: String?
    private var currentModelName: String?
    private var _initialPrompt: UnsafeMutablePointer<CChar>?
    var currentInitialPromptText: String?

    // H1: monotonically-increasing generation counter for loadModel.
    // Each call captures a local copy before the async work begins.
    // The result is committed only when the captured generation matches the
    // current value — stale (out-of-order) loads are silently discarded.
    private var modelLoadGeneration: Int = 0

    /// Cancellable handle for background warm-up. Cancelled (and awaited) by transcribe()
    /// so a real transcription always pre-empts an ongoing warm-up pass.
    private var warmUpTask: Task<Void, Never>?

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
    private func _applyPromptNow(_ text: String?) {
        if let existing = _initialPrompt {
            free(existing)
            _initialPrompt = nil
            // Clear the C-level pointer immediately so whisper params never reference freed memory
            // if strdup fails below and we return early.
            whisper?.params.initial_prompt = nil
        }
        currentInitialPromptText = text.flatMap { $0.isEmpty ? nil : $0 }
        guard let text, !text.isEmpty else {
            whisper?.params.initial_prompt = nil
            return
        }
        guard let ptr = strdup(text) else { return }
        _initialPrompt = ptr
        whisper?.params.initial_prompt = UnsafePointer(ptr)
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
        let combined = [seed, user].filter { !$0.isEmpty }.joined(separator: " | ")
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

    deinit {
        if let existing = _initialPrompt {
            free(existing)
        }
    }

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

        if let task = warmUpTask {
            task.cancel()
            _ = await task.value   // drain so whisper_full returns on the C side
            warmUpTask = nil
        }

        // Wait out an in-flight transcription rather than freeing under it, and any
        // model load still inside Whisper(fromFileURL:) — that constructor builds a
        // native context which must not land after we declare the exit safe.
        let deadline = Date().addingTimeInterval(Self.shutdownDrainTimeout)
        while (isTranscribing || activeModelLoads > 0) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !isTranscribing, activeModelLoads == 0 else {
            AppLog.models.error("shutdown timed out (transcribing=\(self.isTranscribing), loads=\(self.activeModelLoads)) — context left alive, caller must _exit")
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
            _ = try await withThrowingTaskGroup(of: [Segment].self) { group in
                group.addTask {
                    try await whisper.transcribe(audioFrames: silenceBuffer)
                }
                // 30-second safety timeout — identical ceiling used for real transcriptions.
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw TranscriptionError.transcriptionTimeout
                }
                // Return first result (real transcription or timeout).
                guard let result = try await group.next() else {
                    group.cancelAll()
                    return [Segment]()
                }
                group.cancelAll()
                return result
            }

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

    func transcribe(audio: [Float], language: Language = .auto) async throws -> TranscriptionOutcome {
        // A transcription started after the drain would keep whisper_full running
        // past the point where we report the app safe to quit.  See shutdown().
        guard !isShuttingDown else {
            AppLog.transcription.warning("transcribe called during shutdown — rejected")
            throw TranscriptionError.modelNotLoaded
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

        // Pre-flight check: Handle instanceBusy with retry for rapid sequential transcriptions
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

        // VT-WARM-001: Cancel + await warm-up so whisper_full is fully retired before we
        // call whisper.transcribe() — prevents inProgress collision. Nil first so
        // performWarmUp's defer skips its own nil assignment.
        if let task = warmUpTask {
            task.cancel()
            warmUpTask = nil
            _ = await task.value
        }

        // VT-WARM-004: Warm-up may have been cancelled mid-flight leaving status at .warming.
        // The model is already exercised enough; advance to .ready so the UI stays coherent.
        if modelStatus == .warming {
            modelStatus = .ready
        }

        isTranscribing = true
        progress = 0.0
        lastResult = nil

        defer {
            isTranscribing = false
            // Apply any prompt change that was deferred while whisper_full was running.
            // isTranscribing is already false here, so _applyPromptNow will not re-defer.
            _flushPendingPrompt()
        }

        do {
            // Snapshot the pipeline stamp BEFORE whisper runs — see
            // pipelineStamp(forPrompt:)'s doc comment for why capturing it
            // after this call would describe the wrong transcription.
            let stamp = Self.pipelineStamp(forPrompt: currentInitialPromptText)

            let transcribeStart = CFAbsoluteTimeGetCurrent()

            // H3: Race the actual transcription against a timeout task.
            // `transcriptionTimeout` was previously declared but never enforced —
            // a stuck whisper_full would wedge `isTranscribing = true` forever.
            // withThrowingTaskGroup cancels the winner's sibling automatically.
            let timeoutSeconds = transcriptionTimeout
            let segments: [Segment] = try await withThrowingTaskGroup(of: [Segment].self) { group in
                group.addTask {
                    try await whisper.transcribe(audioFrames: audio)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw TranscriptionError.transcriptionTimeout
                }
                // Take whichever task finishes first; cancel the other.
                guard let result = try await group.next() else {
                    group.cancelAll()
                    let noResultError = NSError(
                        domain: "TranscriptionService",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Task group completed with no result"]
                    )
                    throw TranscriptionError.transcriptionFailed(noResultError)
                }
                group.cancelAll()
                return result
            }

            let text = segments.map { $0.text }.joined()

            let transcribeTime = CFAbsoluteTimeGetCurrent() - transcribeStart
            let audioDuration = Double(audio.count) / 16000.0
            let realtimeFactor = transcribeTime > 0 ? audioDuration / transcribeTime : 0
            print(
                "[TranscriptionService] Transcription completed in \(String(format: "%.2f", transcribeTime))s (\(String(format: "%.2fx", realtimeFactor)) realtime)"
            )

            let trimmed = TranscriptionService.conditionallyTrim(text)

            progress = 1.0
            lastResult = trimmed

            print("[TranscriptionService] Result ready (characters: \(trimmed.count))")
            AppLog.transcription.notice("Transcription result is ready")
            return TranscriptionOutcome(rawText: text, text: trimmed, pipelineStamp: stamp)
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

    // MARK: - Trim helper

    /// Gate trim on the user-facing toggle in Settings > General > Insertion.
    /// Called from `transcribe(audio:language:)` — single source of truth.
    /// Exposed `internal` so `TranscriptionServiceTrimToggleTests` can test it
    /// without invoking whisper.cpp.
    ///
    /// Trims TRAILING whitespace only, matching the prototype label
    /// "Trim trailing whitespace · Removes one trailing space Whisper often
    /// emits" (v1-cool-inksteel.html .prefs-row INSERTION group). Leading
    /// whitespace is preserved when the toggle is on — e.g. transcripts that
    /// intentionally start with an indent are not silently mangled.
    /// Code Reviewer O P2.
    static func conditionallyTrim(_ text: String) -> String {
        guard AppSettings.shared.trimWhitespaceAfterInsert else { return text }
        var result = text
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }

    // MARK: - Pipeline stamp

    /// Post-processing pipeline version. `0` means "no normalizer" — the
    /// current state. Bump on every change to normalizer rules/dictionary so
    /// history entries stay attributable to the pipeline that produced them.
    private static let postProcessingVersion = 0

    /// Snapshot of the pipeline that produced a transcription's final text,
    /// built from the initial prompt active for that run. Must be called
    /// BEFORE whisper.transcribe() runs, not after: transcribe(audio:language:)
    /// defers any pending setInitialPrompt() call to a `defer` block that fires
    /// on return, so reading currentInitialPromptText after the call would
    /// describe the NEXT transcription's prompt, not the one just used.
    ///
    /// Format: "n<postProcessingVersion>:p<first 12 hex chars of SHA-256(prompt)>".
    /// Hashing (rather than embedding the prompt itself) keeps the stamp short
    /// and avoids leaking custom vocabulary into every history line, while
    /// still letting two entries be compared for "same prompt, different
    /// pipeline version". CryptoKit.SHA256, not Swift.Hasher — Hasher is
    /// seeded randomly per process, so it is not stable across app launches,
    /// which a persisted stamp requires.
    static func pipelineStamp(forPrompt prompt: String?) -> String {
        let digest = SHA256.hash(data: Data((prompt ?? "").utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "n\(postProcessingVersion):p\(hex.prefix(12))"
    }
}
