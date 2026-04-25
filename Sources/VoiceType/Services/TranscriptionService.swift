import Foundation
import Combine
import SwiftWhisper

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

    private var whisper: Whisper?
    private var modelURL: URL?
    private var currentLanguage: String?
    private var currentModelName: String?
    private var _initialPrompt: UnsafeMutablePointer<CChar>?
    var currentInitialPromptText: String?

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
        if let existing = _initialPrompt {
            free(existing)
            _initialPrompt = nil
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
        print("[TranscriptionService] Loading model from \(url.lastPathComponent)")
        AppLog.models.notice("Loading model \(url.lastPathComponent, privacy: .public)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[TranscriptionService] Model file not found: \(url.lastPathComponent)")
            AppLog.models.error("Model file is missing: \(url.lastPathComponent, privacy: .public)")
            throw TranscriptionError.modelLoadFailed(nil)
        }

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

        whisper = newWhisper
        applyRuntimeConfiguration(language: language)

        // Re-apply initial prompt so a model reload never silently erases user vocabulary
        // or the bilingual seed.  (The WhisperParams object is freshly created above, so
        // any previously-set initial_prompt pointer is gone — must re-apply unconditionally.)
        applyInitialPrompt()
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

        applyRuntimeConfiguration(language: language)

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
                throw TranscriptionError.transcriptionFailed(NSError(domain: "Whisper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Previous transcription still completing"]))
            }
        }

        isTranscribing = true
        progress = 0.0
        lastResult = nil

        defer {
            isTranscribing = false
        }

        do {
            let transcribeStart = CFAbsoluteTimeGetCurrent()

            // transcribe returns [Segment]
            let segments = try await whisper.transcribe(audioFrames: audio)
            let text = segments.map { $0.text }.joined()

            let transcribeTime = CFAbsoluteTimeGetCurrent() - transcribeStart
            let audioDuration = Double(audio.count) / 16000.0
            let realtimeFactor = transcribeTime > 0 ? audioDuration / transcribeTime : 0
            print(
                "[TranscriptionService] Transcription completed in \(String(format: "%.2f", transcribeTime))s (\(String(format: "%.2fx", realtimeFactor)) realtime)"
            )

            let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            progress = 1.0
            lastResult = trimmed

            print("[TranscriptionService] Result ready (characters: \(trimmed.count))")
            AppLog.transcription.notice("Transcription result is ready")
            return trimmed
        } catch {
            progress = 0.0
            print("[TranscriptionService] Transcription error: \(error)")
            AppLog.transcription.error("Transcription failed inside Whisper pipeline")
            throw TranscriptionError.transcriptionFailed(error)
        }
    }

    func unloadModel() {
        print("[TranscriptionService] Unloading model")
        whisper = nil
        modelURL = nil
        currentLanguage = nil
        currentModelName = nil
        lastResult = nil
        progress = 0.0
    }
}
