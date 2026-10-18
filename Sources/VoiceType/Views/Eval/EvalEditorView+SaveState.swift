// EvalEditorView+SaveState.swift — VoiceType Eval Collector
//
// Save-state classification for the Eval Collector editor (R3/K2,
// docs/plans/quality-tools.md): the segmented-picker option for the eval
// issue class, the footer save button's state, and the pure classifier that
// derives it. Split out of EvalEditorView.swift to stay under its
// file_length lint budget — same reasoning as
// HistoryStore+FailedTranscriptions.swift for HistoryStore.swift.
//
// 2026-09-24 — Eval Collector: "Save as correct" control examples, issue
// class, raw/final split. See DESIGN.md Decisions Log.

import Foundation

// MARK: - EvalIssueOption

/// Segmented-picker option for the eval issue class (R3/K2). Kept as its own
/// enum — not a raw String binding — for the same reason `Language`/
/// `CoreMLMode` are: `SegmentedControl<T>` needs a concrete `Hashable`
/// selection type, and the picker must support "nothing selected" (`.notSet`),
/// which `evalIssue: String?` represents as nil.
enum EvalIssueOption: CaseIterable, Hashable {
    case notSet
    case asr
    case postprocess
    case insertion
    case capture

    /// The `HistoryStore.Entry.evalIssue` value this option maps to.
    var rawIssue: String? {
        switch self {
        case .notSet: return nil
        case .asr: return "asr"
        case .postprocess: return "postprocess"
        case .insertion: return "insertion"
        case .capture: return "capture"
        }
    }

    var label: String {
        switch self {
        case .notSet: return "Not set"
        case .asr: return "ASR"
        case .postprocess: return "Post-processing"
        case .insertion: return "Insertion"
        case .capture: return "Capture"
        }
    }
}

// MARK: - EvalSaveButtonState

/// Pure, testable classification of the footer save button's state — see
/// `EvalEditorView.saveButtonState(entry:correction:)`.
enum EvalSaveButtonState: Equatable {
    /// Correction is unchanged from the whisper output: saves a control
    /// ("all correct") example — `userCorrection = text`, `evalIssue = nil`.
    case saveAsCorrect
    /// Correction differs from the whisper output: saves an eval pair, with
    /// an optional issue class.
    case saveEvalPair
    /// No entry, a failed entry, or an empty correction: nothing to save.
    case disabled
}

// MARK: - EvalEditorView.saveButtonState

extension EvalEditorView {
    /// Pure classification, no view state read — testable without an
    /// EvalEditorView instance. Rules (R3):
    ///  - no entry, or a failed entry (`status == .failed`, empty text) → disabled
    ///  - correction empty after trimming whitespace/newlines → disabled
    ///  - correction == entry.text (untrimmed) → save as a control example
    ///  - otherwise → save as an eval pair
    static func saveButtonState(entry: HistoryStore.Entry?, correction: String) -> EvalSaveButtonState {
        guard let entry else { return .disabled }
        if entry.status == .failed { return .disabled }
        let trimmed = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .disabled }
        if correction == entry.text { return .saveAsCorrect }
        return .saveEvalPair
    }
}
