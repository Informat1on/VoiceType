// HistoryStore+EntryMutations.swift — VoiceType
//
// Entry mutation helpers not tied to a failed-transcription retry (see
// HistoryStore+FailedTranscriptions.swift for those): Eval Collector save
// (R3/K2, docs/plans/quality-tools.md), audio-rotation detach, and the
// actual-insertion-outcome update. Split out of HistoryStore.swift to stay
// under its file_length lint budget — same reasoning as
// HistoryStore+FailedTranscriptions.swift.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

extension HistoryStore.Entry {

    /// Returns a copy with userCorrection and isSavedEval set, and evalIssue
    /// recorded as given — nil for a control example saved without edits.
    func withEvalSaved(correction: String, issue: String?) -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: id,
            timestamp: timestamp,
            text: text,
            charCount: charCount,
            targetAppName: targetAppName,
            targetAppBundleID: targetAppBundleID,
            language: language,
            audioPath: audioPath,
            userCorrection: correction,
            isSavedEval: true,
            evalIssue: issue,
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

    /// Returns a copy with audioPath cleared (rotation).
    func withAudioPathCleared() -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: id,
            timestamp: timestamp,
            text: text,
            charCount: charCount,
            targetAppName: targetAppName,
            targetAppBundleID: targetAppBundleID,
            language: language,
            audioPath: nil,
            userCorrection: userCorrection,
            isSavedEval: isSavedEval,
            evalIssue: evalIssue,
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

    /// Returns a copy with insertSuccess set to the actual injection outcome
    /// (task 1/P1: the entry is written BEFORE injection is attempted).
    func withInsertOutcome(_ succeeded: Bool) -> HistoryStore.Entry {
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
            evalIssue: evalIssue,
            model: model,
            audioDurationSeconds: audioDurationSeconds,
            insertSuccess: succeeded,
            rawText: rawText,
            pipelineStamp: pipelineStamp,
            status: status,
            failureReason: failureReason,
            latencyMs: latencyMs
        )
    }
}
