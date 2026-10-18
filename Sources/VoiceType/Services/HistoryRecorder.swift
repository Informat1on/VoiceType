// HistoryRecorder.swift — VoiceType
//
// Thin, testable seam around HistoryStore for the transcription pipeline's
// history bookkeeping. AppDelegate.transcribeAndInject is private and drives
// a real NSWindow (VoiceTypeWindow), so it cannot be unit tested directly —
// see the header comment in AppDelegateRecordingTests.swift. HistoryRecorder
// extracts just the "what goes into history, and when" decision into a small
// injectable type so it can be tested in isolation against a
// HistoryStore.test(...) instance, without instantiating any UI.
//
// Task 1 (P1) fix, architectural audit finding: the history entry used to be
// created and appended ONLY after a successful injectText() call. When
// injection failed (e.g. Accessibility permission revoked mid-session), the
// transcript was silently dropped and its audio file became an orphan on
// disk — despite DESIGN.md § Transcription History promising the opposite
// and specifying an `insertSuccess` field. Fix: record the entry BEFORE
// injection is attempted (recordPending), then update it with the actual
// outcome afterward (recordOutcome). The transcript survives either way.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

@MainActor
final class HistoryRecorder {

    private let store: HistoryStore

    // No default value for `store`: a default expression referencing the
    // MainActor-isolated HistoryStore.shared would itself need to be
    // MainActor-isolated, which default-argument evaluation is not under
    // strict concurrency. Callers pass HistoryStore.shared explicitly instead
    // (see AppDelegate) — HistoryStore.test(storeURL:) for tests.
    init(store: HistoryStore) {
        self.store = store
    }

    /// Everything recordPending() needs to build a history entry, bundled into
    /// one value instead of a 7-parameter function signature (swiftlint
    /// function_parameter_count) — mirrors HistoryStore.Entry's own field set.
    struct PendingTranscription {
        let text: String
        let targetAppName: String
        let targetAppBundleID: String?
        let language: String
        let audioPath: String?
        let model: String?
        let audioDurationSeconds: Double?
        /// Untouched whisper output — see HistoryStore.Entry.rawText's doc
        /// comment. Pass the raw text unconditionally; Entry's own init
        /// collapses it to nil when it matches `text`. Defaults to nil so
        /// call sites unrelated to the transcription pipeline (e.g. tests)
        /// are unaffected.
        let rawText: String?
        /// See TranscriptionService.pipelineStamp(forPrompt:). Defaults to
        /// nil for the same reason as rawText above.
        let pipelineStamp: String?

        init(
            text: String,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String,
            audioPath: String?,
            model: String?,
            audioDurationSeconds: Double?,
            rawText: String? = nil,
            pipelineStamp: String? = nil
        ) {
            self.text = text
            self.targetAppName = targetAppName
            self.targetAppBundleID = targetAppBundleID
            self.language = language
            self.audioPath = audioPath
            self.model = model
            self.audioDurationSeconds = audioDurationSeconds
            self.rawText = rawText
            self.pipelineStamp = pipelineStamp
        }
    }

    /// Appends a pending history entry BEFORE injection is attempted, so the
    /// transcript is persisted even if the subsequent injectText() call fails.
    /// `insertSuccess` starts nil ("unknown yet") — call `recordOutcome` once
    /// the injection result is known to fill it in.
    ///
    /// Returns the stored entry's id, to be passed to `recordOutcome`.
    @discardableResult
    func recordPending(_ pending: PendingTranscription) -> UUID {
        let entry = HistoryStore.Entry(
            text: pending.text,
            targetAppName: pending.targetAppName,
            targetAppBundleID: pending.targetAppBundleID,
            language: pending.language,
            audioPath: pending.audioPath,
            model: pending.model,
            audioDurationSeconds: pending.audioDurationSeconds,
            rawText: pending.rawText,
            pipelineStamp: pending.pipelineStamp
        )
        store.append(entry)
        return entry.id
    }

    /// Updates the previously recorded entry with the actual injection outcome.
    /// No-op if the entry is no longer present — e.g. it was evicted by the
    /// rolling cap between recordPending and this call, which for a single
    /// in-flight transcription is not reachable in practice (the cap is 100
    /// regular entries; this call happens milliseconds after recordPending).
    func recordOutcome(id: UUID, insertSuccess: Bool) {
        guard let entry = store.entry(byID: id) else { return }
        store.update(entry.withInsertOutcome(insertSuccess))
    }

    // MARK: - D4: failed transcriptions

    /// Everything recordTranscriptionFailure() needs to build a failed history
    /// entry. Unlike PendingTranscription, `audioPath` is required — a failed
    /// entry with no audio can never be retried, so the caller must already
    /// have a saved recording before calling this.
    struct FailedTranscription {
        let targetAppName: String
        let targetAppBundleID: String?
        let language: String
        let audioPath: String
        let model: String?
        let audioDurationSeconds: Double?
        /// "timeout" | "error" | "empty" — see HistoryStore.Entry.failureReason.
        let reason: String
    }

    /// Appends a new FAILED entry (empty text, status == .failed, audio kept)
    /// when ASR itself errors or times out — see D4 (reliable-dictation plan,
    /// §3). This is a fresh append, not a pending/outcome pair like
    /// recordPending/recordOutcome: there is no successful injection to record
    /// an outcome for, since there is no text to inject yet.
    ///
    /// Returns the stored entry's id, to be passed to recordRetryResult(id:...)
    /// or recordRetryFailure(id:reason:) once a retry from History runs.
    @discardableResult
    func recordTranscriptionFailure(_ failure: FailedTranscription) -> UUID {
        let entry = HistoryStore.Entry(
            text: "",
            targetAppName: failure.targetAppName,
            targetAppBundleID: failure.targetAppBundleID,
            language: failure.language,
            audioPath: failure.audioPath,
            model: failure.model,
            audioDurationSeconds: failure.audioDurationSeconds,
            status: .failed,
            failureReason: failure.reason
        )
        store.append(entry)
        return entry.id
    }

    /// Fills in a successful retry: the entry stops being failed, gains the
    /// retried text, and moves to the front of History (HistoryStore.
    /// promoteRetried(_:) — see its doc comment for why: the entry's
    /// `timestamp` does NOT change on retry, only its position).
    ///
    /// Returns false if the entry is no longer present — e.g. it was evicted
    /// by the failed-entry cap before the retry completed — so the caller
    /// knows the retry result has nowhere to go.
    @discardableResult
    func recordRetryResult(
        id: UUID,
        text: String,
        rawText: String?,
        pipelineStamp: String?,
        model: String?
    ) -> Bool {
        guard let entry = store.entry(byID: id) else { return false }
        store.promoteRetried(entry.withTranscriptionResult(
            text: text,
            rawText: rawText,
            pipelineStamp: pipelineStamp,
            model: model
        ))
        return true
    }

    /// Records D6 per-stage latency (stopToSamples/asr/insert/total, in ms)
    /// for the dictation that produced this entry. No-op if the entry is no
    /// longer present.
    func recordLatency(id: UUID, latencyMs: [String: Int]) {
        guard let entry = store.entry(byID: id) else { return }
        store.update(entry.withLatency(latencyMs))
    }

    /// Records that a retry from History failed again, updating just the
    /// failure reason ("timeout" | "error" | "empty") — the entry stays
    /// failed. No-op if the entry is no longer present.
    func recordRetryFailure(id: UUID, reason: String) {
        guard let entry = store.entry(byID: id) else { return }
        store.update(entry.withFailureReason(reason))
    }
}
