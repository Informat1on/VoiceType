// HistoryStore+FailedTranscriptions.swift — VoiceType
//
// D4/D6 (reliable-dictation plan, task C): failed-transcription entries and
// per-stage dictation latency. Split out of HistoryStore.swift to stay under
// its file_length lint budget — see the note at the top of that file. The
// handful of HistoryStore members this file calls (cachedEntries,
// pendingAudioDeletions, loadIfNeeded(), evictExcessRegularEntries(),
// rotateAudioIfNeeded(), flushAndReapAudio()) are `internal` there for
// exactly that reason; there are no other consumers in the module.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

/// Status of a transcription attempt. nil (absent from Entry) means a regular,
/// successfully transcribed entry — including every entry ever written before
/// this type existed, since absent keys decode to nil. `.failed` marks an ASR
/// error/timeout: text is empty, audio is kept, and the entry is retryable
/// from History. A transcription that ran but returned empty text is NOT
/// `.failed` — it stays a regular entry, so a stray hotkey press doesn't eat
/// a History slot.
enum TranscriptionStatus: String, Codable {
    case failed
}

extension HistoryStore.Entry {

    /// True for a failed transcription — see TranscriptionStatus.
    var isFailed: Bool { status == .failed }

    /// Returns a copy holding a successful (re-)transcription result: clears
    /// `status`/`failureReason` (no longer failed), replaces
    /// `text`/`rawText`/`pipelineStamp`, updates `model` only when given.
    /// Used by the normal pipeline result path and by
    /// HistoryRecorder.recordRetryResult() after a History retry succeeds.
    /// `timestamp` is unchanged — promoteRetried() moves the entry by
    /// position, not by re-dating it.
    func withTranscriptionResult(
        text: String,
        rawText: String?,
        pipelineStamp: String?,
        model: String?
    ) -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: id,
            timestamp: timestamp,
            text: text,
            charCount: text.count,
            targetAppName: targetAppName,
            targetAppBundleID: targetAppBundleID,
            language: language,
            audioPath: audioPath,
            userCorrection: userCorrection,
            isSavedEval: isSavedEval,
            model: model ?? self.model,
            audioDurationSeconds: audioDurationSeconds,
            insertSuccess: insertSuccess,
            // Same collapse rule as the primary init — see rawText's doc comment.
            rawText: (rawText == text) ? nil : rawText,
            pipelineStamp: pipelineStamp,
            status: nil,
            failureReason: nil,
            latencyMs: latencyMs
        )
    }

    /// Returns a copy with latencyMs set (D6 — per-stage dictation timings).
    func withLatency(_ latencyMs: [String: Int]) -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: id,
            timestamp: timestamp,
            text: text,
            charCount: charCount,
            targetAppName: targetAppName,
            targetAppBundleID: targetAppBundleID,
            language: language,
            audioPath: audioPath,
            userCorrection: userCorrection,
            isSavedEval: isSavedEval,
            model: model,
            audioDurationSeconds: audioDurationSeconds,
            insertSuccess: insertSuccess,
            rawText: rawText,
            pipelineStamp: pipelineStamp,
            status: status,
            failureReason: failureReason,
            latencyMs: latencyMs
        )
    }

    /// Returns a copy that stays failed but records a (possibly updated)
    /// failure reason — e.g. a retry that fails again with a different cause.
    func withFailureReason(_ reason: String) -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: id,
            timestamp: timestamp,
            text: text,
            charCount: charCount,
            targetAppName: targetAppName,
            targetAppBundleID: targetAppBundleID,
            language: language,
            audioPath: audioPath,
            userCorrection: userCorrection,
            isSavedEval: isSavedEval,
            model: model,
            audioDurationSeconds: audioDurationSeconds,
            insertSuccess: insertSuccess,
            rawText: rawText,
            pipelineStamp: pipelineStamp,
            status: .failed,
            failureReason: reason,
            latencyMs: latencyMs
        )
    }
}

extension HistoryStore {

    /// Cap on FAILED entries (status == .failed). Separate from maxEntries:
    /// failed entries are excluded from the regular cap entirely (D4), so
    /// without their own bound a long streak of ASR failures could grow
    /// history.jsonl forever.
    static let maxFailedEntries: Int = 20

    /// Evicts the oldest FAILED entries once their count exceeds
    /// maxFailedEntries, mirroring evictExcessRegularEntries() but for the
    /// separate failed-entry cap. Failed entries are excluded from the
    /// regular cap and from audio rotation, so without this they could
    /// accumulate — and their audio with them — without bound.
    ///
    /// Returns the audio filenames belonging to evicted entries, for deletion
    /// after a successful flush() — same ordering rule as
    /// evictExcessRegularEntries(). Called from HistoryStore.append() and
    /// .loadIfNeeded(), hence `internal` rather than `private`.
    func evictExcessFailedEntries() -> [String] {
        let failedCount = cachedEntries.filter(\.isFailed).count
        guard failedCount > Self.maxFailedEntries else { return [] }
        let excess = failedCount - Self.maxFailedEntries

        // Oldest-first among failed entries (cachedEntries itself is newest-first).
        let evicted = cachedEntries
            .filter(\.isFailed)
            .reversed()
            .prefix(excess)

        let orphanedAudio = evicted.compactMap(\.audioPath)
        let idSet = Set(evicted.map(\.id))
        cachedEntries.removeAll { idSet.contains($0.id) }
        return orphanedAudio
    }

    /// Replaces a failed entry by ID with its successful retry result, moves
    /// it to the front of the list (the newest position — its `timestamp` is
    /// left unchanged by withTranscriptionResult), then re-applies the normal
    /// caps. No-op if `updated.id` is no longer present (e.g. it was evicted
    /// by evictExcessFailedEntries() before the retry completed). Because the
    /// entry is inserted at index 0 before the caps run, it is never itself
    /// evicted by this same call — eviction only ever removes the OLDEST
    /// entries. Flushes to disk.
    func promoteRetried(_ updated: Entry) {
        loadIfNeeded()
        guard let idx = cachedEntries.firstIndex(where: { $0.id == updated.id }) else { return }
        cachedEntries.remove(at: idx)
        cachedEntries.insert(updated, at: 0)
        pendingAudioDeletions += evictExcessRegularEntries() + rotateAudioIfNeeded() + evictExcessFailedEntries()
        flushAndReapAudio()
    }
}
