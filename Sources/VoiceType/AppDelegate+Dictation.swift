// AppDelegate+Dictation.swift — VoiceType
//
// Reliable-dictation integration (docs/plans/reliable-dictation.md, task D):
// wires wave 1's building blocks (clipboard-preserving insertion, honest ASR
// timeout, failed-transcription history model) into the main dictation path —
// transcribeAndInject, the async injectText, and History's retryTranscription.
// Split out of AppDelegate.swift, which was already at the file_length budget
// before this work — see the note left at its former MARK: - Transcription
// Pipeline site.
//
// DESIGN.md § Transcription History. docs/plans/reliable-dictation.md §§ D2–D6.

import Foundation
import AppKit

// MARK: - D2: insertion target decision

/// Whether text produced by the current dictation session may still be
/// inserted into the frontmost app, or must be blocked because the user
/// switched apps while transcription was running. See
/// `AppDelegate.insertionTargetDecision(sessionTargetPID:frontmostPID:)`.
enum InsertionTargetDecision: Equatable {
    case insert
    case blockTargetChanged
}

// MARK: - D4: retry-from-History outcome

/// Outcome of `AppDelegate.retryTranscription(for:)`. The retried text is
/// never inserted — it only fills in the History entry; a normal Re-insert
/// (existing History action) follows if the user wants it.
enum RetryTranscriptionOutcome: Equatable {
    /// The entry now holds transcribed text (`status == nil`).
    case transcribed
    /// `appState != .idle` — another dictation, insertion, or retry is in flight.
    case busy
    /// The entry has already been removed (e.g. evicted by the failed-entry cap).
    case entryMissing
    /// The entry is not a failed entry — nothing to retry.
    case notFailed
    /// The entry has no `audioPath`, or the audio file no longer exists / failed to decode.
    case audioMissing
    /// ASR ran but returned empty text — the entry stays failed, `failureReason = "empty"`.
    case emptyResult
    /// ASR errored or timed out — the entry stays failed.
    case failed
}

extension AppDelegate {

    // MARK: - D2: pure decision function

    /// `sessionTargetPID == nil` means VoiceType itself was frontmost when the
    /// hotkey was pressed (see `sessionTargetApp`'s doc comment) — the check
    /// does not apply there, matching prior behavior. `frontmostPID == nil`
    /// (no frontmost app at all, e.g. a transient desktop-switch moment) also
    /// falls back to `.insert` rather than blocking on missing information.
    nonisolated static func insertionTargetDecision(
        sessionTargetPID: pid_t?,
        frontmostPID: pid_t?
    ) -> InsertionTargetDecision {
        guard let sessionTargetPID else { return .insert }
        guard let frontmostPID else { return .insert }
        return sessionTargetPID == frontmostPID ? .insert : .blockTargetChanged
    }

    // MARK: - D6: pure latency computation

    /// Per-stage dictation latency, floored to whole milliseconds. `total` is
    /// always the sum of the three legs (never measured independently), so it
    /// can never disagree with them.
    nonisolated static func latencyMs(
        stop: ContinuousClock.Instant,
        samplesReady: ContinuousClock.Instant,
        asrDone: ContinuousClock.Instant,
        insertDone: ContinuousClock.Instant
    ) -> [String: Int] {
        func floorMs(_ duration: Duration) -> Int {
            let (seconds, attoseconds) = duration.components
            return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
        }

        let stopToSamples = floorMs(samplesReady - stop)
        let asr = floorMs(asrDone - samplesReady)
        let insert = floorMs(insertDone - asrDone)
        return [
            "stopToSamples": stopToSamples,
            "asr": asr,
            "insert": insert,
            "total": stopToSamples + asr + insert
        ]
    }

    // MARK: - D3 retry helper shared by live dictation and History retry

    /// `runASR`'s outcome: either the digital-silence gate fired (ASR never
    /// ran), or ASR actually ran and produced a `TranscriptionOutcome` (whose
    /// `text` may itself be empty). docs/plans/empty-result-audio.md §3 C2 —
    /// callers need to tell these two "empty result" causes apart so the
    /// digital-silence one always discards its audio while a genuine
    /// whisper-empty one can still become a retryable failed History entry.
    enum ASRResult {
        case digitalSilence
        case transcribed(TranscriptionOutcome)
    }

    /// `ensureModelLoaded()` + `transcribe(...)`, with exactly one retry when
    /// the model instance was dropped between the load and the transcribe call
    /// (`TranscriptionError.modelNotLoaded` — see
    /// `TranscriptionService.transcribe`'s own re-check of `self.whisper` after
    /// its internal warm-up wait, docs/plans/reliable-dictation.md § D3
    /// "повторная проверка экземпляра"). Shared by `transcribeAndInject` and
    /// `retryTranscription(for:)` so both get the same one-shot recovery.
    private func runASR(samples: [Float]) async throws -> ASRResult {
        // docs/plans/silence-gate.md: a recording that is entirely digital
        // silence must not reach whisper — on this corpus it hallucinates
        // instead of returning "". The gate lives here, not inside
        // TranscriptionService.transcribe, because performWarmUp pushes its
        // own 8000 zeros through runNative directly, bypassing both
        // transcribe and runASR, to warm the model — so the gate placement
        // here leaves that warm-up path untouched. Placing the gate in
        // runASR (rather than TranscriptionService.transcribe) covers both
        // production callers at once and leaves TranscriptionService itself
        // unchanged.
        let decision = DigitalSilenceGate.evaluate(samples)
        if decision.isDigitalSilence {
            AppLog.transcription.notice(
                "Digital silence — ASR skipped rms=\(decision.rms, privacy: .public) sampleCount=\(samples.count, privacy: .public) durationSeconds=\(Double(samples.count) / 16000.0, privacy: .public)"
            )
            return .digitalSilence
        }

        do {
            try await ensureModelLoaded()
            let outcome = try await transcriptionService.transcribe(
                audio: samples,
                language: AppSettings.shared.language
            )
            return .transcribed(outcome)
        } catch TranscriptionError.modelNotLoaded {
            try await ensureModelLoaded()
            let outcome = try await transcriptionService.transcribe(
                audio: samples,
                language: AppSettings.shared.language
            )
            return .transcribed(outcome)
        }
    }

    func ensureModelLoaded() async throws {
        while let modelLoadTask {
            await modelLoadTask.value
        }

        guard !transcriptionService.isModelLoaded else {
            print("[AppDelegate] Model already loaded")
            return
        }

        let model = AppSettings.shared.selectedModel
        let language = AppSettings.shared.language
        guard modelManager.isModelDownloaded(model: model) else {
            print("[AppDelegate] Model not downloaded: \(model.rawValue)")
            throw TranscriptionError.modelNotLoaded
        }

        let modelURL = modelManager.modelURL(for: model)
        print("[AppDelegate] Loading model on-demand: \(modelURL.lastPathComponent) with language: \(language.rawValue)")
        try await transcriptionService.loadModel(at: modelURL, language: language, model: model)
    }

    // MARK: - Transcription pipeline

    /// - Parameters:
    ///   - wasInterrupted: docs/plans/empty-result-audio.md §3 C4 — whether
    ///     `handleRecordingStopped` detected a capture interruption
    ///     (`captureFailure != nil`, the same value that decides whether
    ///     "Recording interrupted" is shown). No default: every call site
    ///     must decide explicitly. Only consulted on the empty-result path —
    ///     an interrupted-but-non-empty result is unaffected.
    ///   - stopStartedAt: D6 — the instant `handleRecordingStopped` began running.
    ///   - samplesReady: D6 — the instant the raw audio samples were available
    ///     (right after `stopRecordingRetaining` returned).
    func transcribeAndInject(
        samples: [Float],
        audioPath: String? = nil,
        audioDuration: Double? = nil,
        wasInterrupted: Bool,
        stopStartedAt: ContinuousClock.Instant,
        samplesReady: ContinuousClock.Instant
    ) async {
        print("[AppDelegate] transcribeAndInject: \(samples.count) samples")

        // docs/plans/empty-result-audio.md §3 C4: runASR's ASRResult is
        // unpacked here into (text, rawText, pipelineStamp, emptyReason) so
        // the rest of this function can treat "digital silence" and "whisper
        // returned an empty string" uniformly as an empty result, while still
        // remembering WHICH one it was for EmptyResultAudioHandler below.
        let text: String
        let rawText: String?
        let pipelineStamp: String?
        let emptyReason: EmptyResultAudioHandler.EmptyReason?
        let asrDone: ContinuousClock.Instant
        do {
            let asrResult = try await runASR(samples: samples)
            asrDone = ContinuousClock.now
            print("[AppDelegate] Transcription finished successfully")
            AppLog.transcription.notice("Transcription completed")
            switch asrResult {
            case .digitalSilence:
                text = ""
                rawText = nil
                pipelineStamp = nil
                emptyReason = .digitalSilence
            case .transcribed(let outcome):
                text = outcome.text
                rawText = outcome.rawText
                pipelineStamp = outcome.pipelineStamp
                emptyReason = outcome.text.isEmpty ? .whisperEmpty : nil
            }
        } catch {
            print("[AppDelegate] Transcription error: \(error)")
            AppLog.transcription.error("Transcription failed")
            // P2-2: log to file before showing inline error so the most common
            // runtime failure path produces a diagnostic entry in errors.log.
            ErrorLogger.shared.log(error, category: "transcription")

            // D4: an ASR error/timeout is only recoverable-via-Retry when we
            // actually have audio to retry with. Without it there's nothing
            // History could ever replay, so the message stays the old
            // unconditional failure — no false promise of a saved record.
            if let audioPath {
                let reason: String
                if case TranscriptionError.transcriptionTimeout = error {
                    reason = "timeout"
                } else {
                    reason = "error"
                }
                historyRecorder.recordTranscriptionFailure(HistoryRecorder.FailedTranscription(
                    targetAppName: sessionTargetApp?.localizedName
                        ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "app",
                    targetAppBundleID: sessionTargetApp?.bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    language: AppSettings.shared.language.rawValue,
                    audioPath: audioPath,
                    model: AppSettings.shared.selectedModel.rawValue,
                    audioDurationSeconds: audioDuration,
                    reason: reason
                ))
                voiceTypeWindow?.show(state: .errorInline(message: "Failed · Saved to History"))
            } else {
                // Inline capsule error only — no NSAlert. Blocking modal would
                // steal focus and double-notify the user. Codex review P1.
                voiceTypeWindow?.show(state: .errorInline(message: "Transcription failed"))
            }
            // Schedule 4s auto-dismiss so the capsule does not hang indefinitely.
            // P2 review finding #2.
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss(after: 4)
            appState = .idle
            return
        }

        // Trim is handled upstream by TranscriptionService.conditionallyTrim(_:),
        // gated on AppSettings.shared.trimWhitespaceAfterInsert. No secondary trim here.
        guard emptyReason == nil else {
            print("[AppDelegate] Transcription produced empty string — flashing emptyResult")
            AppLog.transcription.notice("Transcription produced empty text")
            // docs/plans/empty-result-audio.md §3 C4: fixed ordering — show
            // the capsule, THEN run the audio/History decision synchronously
            // (still on MainActor) BEFORE appState flips back to .idle, so a
            // new dictation cannot start mid-decision. The deferred hide()
            // below is unaffected — it's guarded by capsuleSessionID exactly
            // as before.
            voiceTypeWindow?.show(state: .emptyResult)
            if let emptyReason {
                EmptyResultAudioHandler(store: .shared, recorder: historyRecorder).handle(
                    reason: emptyReason,
                    wasInterrupted: wasInterrupted,
                    audioPath: audioPath,
                    audioDurationSeconds: audioDuration
                ) { path in
                    HistoryRecorder.FailedTranscription(
                        targetAppName: sessionTargetApp?.localizedName
                            ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "app",
                        targetAppBundleID: sessionTargetApp?.bundleIdentifier
                            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        language: AppSettings.shared.language.rawValue,
                        audioPath: path,
                        model: AppSettings.shared.selectedModel.rawValue,
                        audioDurationSeconds: audioDuration,
                        reason: "empty"
                    )
                }
            }
            // D5: return to .idle immediately so the next hotkey press is never
            // blocked by this purely cosmetic flash. capsuleSessionID guards the
            // delayed hide() below so it cannot hide a capsule already showing
            // the NEXT dictation's state.
            appState = .idle
            let token = capsuleSessionID
            Task { @MainActor [weak self] in
                let flashMs = insertedFlashDurationMs(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                try? await Task.sleep(for: .milliseconds(flashMs))
                guard let self, self.capsuleSessionID == token else { return }
                self.voiceTypeWindow?.hide()
            }
            return
        }

        appState = .injecting

        // Capture target app name BEFORE injection — injection may shift focus.
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let charCount = text.count

        // D2: decide whether the app that was frontmost at hotkey-press time is
        // still frontmost now. Computed before recordPending so the history
        // entry (written unconditionally, below) already exists by the time
        // the blocked branch needs to attach insertSuccess=false to it.
        let targetDecision = AppDelegate.insertionTargetDecision(
            sessionTargetPID: sessionTargetApp?.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )

        // Record to history BEFORE injectText runs — task 1 (P1) fix. Previously
        // the entry was only appended after a successful injection, so a failed
        // insert (e.g. revoked Accessibility permission) silently dropped the
        // transcript and its audio file became an orphan on disk. Recording here
        // means the transcript survives regardless of outcome; recordOutcome
        // below fills in the actual insertSuccess once it's known.
        // Best-effort: flush failures are logged to ErrorLogger but never
        // surface to the user. DESIGN.md § Transcription History. Step 9.
        let historyEntryID = historyRecorder.recordPending(.init(
            text: text,
            targetAppName: targetAppName,
            targetAppBundleID: targetBundleID,
            language: AppSettings.shared.language.rawValue,
            audioPath: audioPath,
            model: AppSettings.shared.selectedModel.rawValue,
            audioDurationSeconds: audioDuration,
            rawText: rawText,
            pipelineStamp: pipelineStamp
        ))

        if targetDecision == .blockTargetChanged {
            historyRecorder.recordOutcome(id: historyEntryID, insertSuccess: false)
            // The user has moved on to another app while transcription ran —
            // pulling focus back to the originally-captured app on errorInline
            // auto-dismiss would yank them away from wherever they are now.
            // Must run BEFORE the capsule is shown, same ordering invariant as
            // every other suppressNextRestore call site in this file.
            FocusCaptureService.shared.suppressNextRestore()
            ErrorLogger.shared.log(
                message: "Insertion blocked: frontmost app changed during transcription "
                    + "(expected \(sessionTargetApp?.bundleIdentifier ?? "unknown"), "
                    + "got \(targetBundleID ?? "unknown"))",
                category: "insertion"
            )
            voiceTypeWindow?.show(state: .errorInline(message: "App changed · Saved to History"))
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss(after: 4)
            appState = .idle
            return
        }

        // Keep the app busy until the text is fully inserted, so the next hotkey
        // press cannot race with the paste/typing sequence.
        let injectionSucceeded = await injectText(text, mode: AppSettings.shared.textInjectionMode)
        let insertDone = ContinuousClock.now
        historyRecorder.recordOutcome(id: historyEntryID, insertSuccess: injectionSucceeded)

        // D6: recorded for both a successful and a failed insertion — only the
        // blocked-target path above (no insertion attempted at all) skips it.
        let latency = AppDelegate.latencyMs(
            stop: stopStartedAt,
            samplesReady: samplesReady,
            asrDone: asrDone,
            insertDone: insertDone
        )
        historyRecorder.recordLatency(id: historyEntryID, latencyMs: latency)
        let latencySummary = "stopToSamples=\(latency["stopToSamples"] ?? -1)ms "
            + "asr=\(latency["asr"] ?? -1)ms "
            + "insert=\(latency["insert"] ?? -1)ms "
            + "total=\(latency["total"] ?? -1)ms"
        AppLog.transcription.notice("Latency \(latencySummary, privacy: .public)")

        if injectionSucceeded {
            // D5: return to .idle immediately — insertText's own return already
            // means the clipboard restore (if any) is done, so nothing here still
            // needs the busy state. The next hotkey press can start recording
            // right away; the `.inserted` flash below is purely cosmetic and runs
            // independently. capsuleSessionID guards its delayed hide() so a
            // stale flash from THIS dictation cannot hide a capsule already
            // showing the next one.
            appState = .idle
            voiceTypeWindow?.show(state: .inserted(charCount: charCount, targetAppName: targetAppName))
            let token = capsuleSessionID
            Task { @MainActor [weak self] in
                let flashMs = insertedFlashDurationMs(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                try? await Task.sleep(for: .milliseconds(flashMs))
                guard let self, self.capsuleSessionID == token else { return }
                self.voiceTypeWindow?.hide()
            }
        } else {
            // Only hide the capsule if injectText did NOT already show an inline error.
            // If pendingErrorInlineShown is true, the capsule is displaying errorInline
            // and the 4s scheduleErrorInlineDismiss will dismiss it. P2 finding #1.
            if !pendingErrorInlineShown {
                voiceTypeWindow?.hide()
            }
            pendingErrorInlineShown = false
            appState = .idle
        }
    }

    /// Returns `true` on successful injection, `false` on failure. Callers use
    /// the result to decide whether to flash the `.inserted` capsule or route
    /// through the error path.
    ///
    /// D1 (reliable-dictation): routes through
    /// `TextInjectionService.insertText`, which preserves the full clipboard
    /// (all pasteboard items, all types) across a paste-mode insertion instead
    /// of the old string-only save/restore.
    @discardableResult
    func injectText(_ text: String, mode: TextInjectionMode) async -> Bool {
        permissionManager.checkAllPermissions()

        print("[AppDelegate] Injecting text (mode: \(mode.rawValue), characters: \(text.count))")
        do {
            let report = try await textInjectionService.insertText(
                text,
                mode: mode,
                pressEnterAfter: AppSettings.shared.autoEnterAfterInsert
            )
            print("[AppDelegate] Text injected successfully")
            let reportSummary = "method=\(report.method.rawValue) clipboard=\(report.clipboard.rawValue)"
            AppLog.insertion.notice("Text insertion completed \(reportSummary, privacy: .public)")
            return true
        } catch {
            print("[AppDelegate] Text injection failed: \(error)")
            AppLog.insertion.error("Text insertion failed")

            ErrorLogger.shared.log(error, category: "insertion")
            if case TextInjectionService.TextInjectionError.missingAccessibilityPermission = error {
                permissionManager.openAccessibilitySettings()
                // User has been directed to System Settings to grant permission. Don't
                // auto-pull focus back to the captured app on errorInline auto-dismiss.
                FocusCaptureService.shared.suppressNextRestore()
                voiceTypeWindow?.show(state: .errorInline(message: "Accessibility denied · Open"))
            } else {
                voiceTypeWindow?.show(state: .errorInline(message: "Text insertion failed · Retry"))
            }
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss(after: 4)
            // Signal to transcribeAndInject that the inline error is already displayed.
            // Prevents the else-branch from hiding the capsule immediately. P2 finding #1.
            pendingErrorInlineShown = true
            return false
        }
    }

    // MARK: - D4: retry transcription from History

    /// Pure precheck for `retryTranscription(for:)`. `nil` means the caller may
    /// proceed; order is significant — `busy` is checked first because it says
    /// nothing about the entry itself, then entry-shape checks in the order
    /// they'd naturally be discovered (existence → failed-ness → audio).
    nonisolated static func retryPrecheck(
        isIdle: Bool,
        entryExists: Bool,
        entryIsFailed: Bool,
        audioFileExists: Bool
    ) -> RetryTranscriptionOutcome? {
        guard isIdle else { return .busy }
        guard entryExists else { return .entryMissing }
        guard entryIsFailed else { return .notFailed }
        guard audioFileExists else { return .audioMissing }
        return nil
    }

    /// Re-runs ASR on a failed History entry's saved audio. Never inserts the
    /// resulting text — it only fills in the entry (HistoryRecorder.
    /// recordRetryResult moves it to the front via `HistoryStore.
    /// promoteRetried(_:)`); a normal Re-insert is the existing History action
    /// for actually typing/pasting it. Exclusivity: only runs while
    /// `appState == .idle`; for the duration `appState = .transcribing` (no
    /// capsule shown) so the hotkey and "Start recording" cannot race a
    /// parallel recording against this retry.
    func retryTranscription(for entryID: UUID) async -> RetryTranscriptionOutcome {
        let entry = HistoryStore.shared.entry(byID: entryID)
        let audioFileExists: Bool
        if let audioPath = entry?.audioPath {
            audioFileExists = FileManager.default.fileExists(
                atPath: HistoryStore.shared.audioDirectory.appendingPathComponent(audioPath).path
            )
        } else {
            audioFileExists = false
        }

        if let precheck = AppDelegate.retryPrecheck(
            isIdle: appState == .idle,
            entryExists: entry != nil,
            entryIsFailed: entry?.isFailed ?? false,
            audioFileExists: audioFileExists
        ) {
            return precheck
        }

        // retryPrecheck already guarantees entry != nil, entry!.isFailed, and
        // entry!.audioPath pointing at an existing file at this point.
        guard let entry, let audioPath = entry.audioPath else {
            return .audioMissing
        }

        appState = .transcribing
        defer { appState = .idle }

        let audioURL = HistoryStore.shared.audioDirectory.appendingPathComponent(audioPath)
        let samples: [Float]
        do {
            samples = try audioCaptureService.loadSamples(from: audioURL)
        } catch {
            AppLog.transcription.error("Retry: failed to read audio for entry \(entryID, privacy: .public)")
            ErrorLogger.shared.log(error, category: "transcription", context: ["stage": "retry-load-audio"])
            return .audioMissing
        }
        guard !samples.isEmpty else {
            AppLog.transcription.error("Retry: audio for entry \(entryID, privacy: .public) decoded to zero samples")
            return .audioMissing
        }

        let asrResult: ASRResult
        do {
            asrResult = try await runASR(samples: samples)
        } catch TranscriptionError.transcriptionTimeout {
            historyRecorder.recordRetryFailure(id: entryID, reason: "timeout")
            ErrorLogger.shared.log(message: "Retry transcription timed out", category: "transcription")
            return .failed
        } catch {
            historyRecorder.recordRetryFailure(id: entryID, reason: "error")
            ErrorLogger.shared.log(error, category: "transcription", context: ["stage": "retry"])
            return .failed
        }

        // docs/plans/empty-result-audio.md §3 C2: digital silence on a retry
        // is treated exactly like an empty transcription — the entry's audio
        // is never touched by a retry (it's already owned by this failed
        // entry), only its failureReason updates.
        let outcome: TranscriptionOutcome
        switch asrResult {
        case .digitalSilence:
            historyRecorder.recordRetryFailure(id: entryID, reason: "empty")
            return .emptyResult
        case .transcribed(let transcribed):
            outcome = transcribed
        }

        guard !outcome.text.isEmpty else {
            historyRecorder.recordRetryFailure(id: entryID, reason: "empty")
            return .emptyResult
        }

        let succeeded = historyRecorder.recordRetryResult(
            id: entryID,
            text: outcome.text,
            rawText: outcome.rawText,
            pipelineStamp: outcome.pipelineStamp,
            model: AppSettings.shared.selectedModel.rawValue
        )
        return succeeded ? .transcribed : .entryMissing
    }
}
