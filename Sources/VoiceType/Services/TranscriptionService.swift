import Foundation
import Combine
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

    /// Cancellable handle for background warm-up. Cancelled by transcribe() so a real
    /// transcription always pre-empts an ongoing warm-up pass.
    private var warmUpTask: Task<Void, Never>?

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
        if isTranscribing {
            _pendingPrompt = .some(text)
            AppLog.transcription.notice("setInitialPrompt deferred: transcription in progress")
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
    /// Test seam: allows unit tests to trigger _flushPendingPrompt without running
    /// a real whisper transcription.  Not part of the public API; production code
    /// reaches this path only through the defer block in transcribe().
    /// Compiled out of release builds so the seam never leaks into shipping binaries.
    func _testFlushPendingPrompt() {
        _flushPendingPrompt()
    }
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

    func loadModel(at url: URL, language: Language = .auto, model: TranscriptionModel? = nil) async throws {
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[TranscriptionService] Model file not found: \(url.lastPathComponent)")
            AppLog.models.error("Model file is missing: \(url.lastPathComponent, privacy: .public)")
            modelStatus = .error("Model file not found: \(url.lastPathComponent)")
            throw TranscriptionError.modelLoadFailed(nil)
        }

        // Cancel any in-flight warm-up from a previous model before starting a new load.
        warmUpTask?.cancel()
        warmUpTask = nil
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
        print("[TranscriptionService] CoreML encoder available: \(hasCoreML) at \(coreMLURL?.lastPathComponent ?? "N/A")")

        print(
            "[TranscriptionService] Loading model: \(currentModelName ?? "unknown") (lang: \(whisperLanguageRawValue), detectLanguage: \(shouldDetectLanguage), threads: \(threadCount))"
        )
        let startTime = CFAbsoluteTimeGetCurrent()
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

                continuation.resume(returning: Whisper(fromFileURL: url, withParams: params))
            }
        }
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        print("[TranscriptionService] Model \(currentModelName ?? "unknown") loaded in \(String(format: "%.2f", loadTime))s")
        print("[TranscriptionService] GPU acceleration: \(hasCoreML ? "CoreML ENABLED" : "CPU only")")
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
            // Restore prompt before marking ready so any subscriber that reacts to
            // .ready immediately has the correct prompt in place.
            _applyPromptNow(savedPromptText)
            if !Task.isCancelled {
                modelStatus = .ready
                AppLog.models.notice("Warm-up completed — model is hot")
            }
        } catch {
            // Restore prompt even on error so user vocabulary is not silently lost.
            _applyPromptNow(savedPromptText)
            if Task.isCancelled {
                // A real transcription pre-empted us — that is fine; status will be
                // managed by the transcription path.
                AppLog.models.notice("Warm-up cancelled (pre-empted by real transcription)")
            } else {
                AppLog.models.error("Warm-up failed: \(error.localizedDescription, privacy: .public)")
                ErrorLogger.shared.log(error, category: "models", context: ["stage": "warmup"])
                // Model is still loaded — mark ready so the user can transcribe.
                modelStatus = .ready
            }
        }
    }

    func transcribe(audio: [Float], language: Language = .auto) async throws -> String {
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

        // Pre-empt any in-flight warm-up so the real transcription is not queued
        // behind a silence-buffer pass on the single-threaded whisper context.
        warmUpTask?.cancel()
        warmUpTask = nil

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
            return trimmed
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
}
