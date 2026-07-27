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
            audioDurationSeconds: pending.audioDurationSeconds
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
}
