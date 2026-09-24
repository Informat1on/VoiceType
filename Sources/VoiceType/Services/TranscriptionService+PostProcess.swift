// TranscriptionService+PostProcess.swift — VoiceType
//
// Post-processing chain, trim helper and pipeline stamp — moved verbatim out
// of TranscriptionService.swift (quality-tools plan, T1): that file was 1186
// lines against the 1200-line file_length error threshold in .swiftlint.yml.
// Nothing below changed behavior; only the file it lives in changed. All
// three members reference only `TranscriptionService`-internal/private state
// they already had access to as members of the same type (extensions in the
// same module see `private` declarations of the type they extend).

import CryptoKit
import Foundation

extension TranscriptionService {

    // MARK: - Post-processing chain

    /// The whole post-processing chain as one pure function.
    ///
    /// Exposed (rather than inlined into `transcribe`) because unit tests of
    /// `HallucinationFilter` and `LexiconNormalizer` in isolation cannot catch
    /// the defects that actually matter here: a missing call, the two steps in
    /// the wrong order, a mutated `raw`, or trim running before normalization.
    /// Plan review flagged exactly this gap.
    ///
    /// Order is load-bearing:
    ///   1. `raw` is captured from the untouched segments — it is the corpus
    ///      artifact and must never reflect any filtering.
    ///   2. The hallucination filter runs on whisper's own segment boundaries,
    ///      which only exist before the join.
    ///   3. Fillers are removed from the joined text.
    ///   4. The lexicon normalizer runs after them, so a filler standing
    ///      between the halves of a multi-word dictionary entry cannot hide it
    ///      ("сонет ну агенты"). Measured on the owner's 1096-record corpus,
    ///      that collision never actually occurs — but the guard is free and
    ///      the failure would be silent, so the order is chosen to make it
    ///      impossible rather than unlikely.
    ///   5. `conditionallyTrim` runs last, so it also trims whitespace that
    ///      earlier steps may have exposed.
    ///
    /// `trim`, `normalize` and `removeFillers` are passed in rather than read
    /// from `AppSettings` so the chain stays pure and testable in every toggle
    /// combination.
    ///
    /// The hallucination filter has no toggle by design (see
    /// `AppSettings.normalizeTranscript`): it removes text the user never
    /// spoke, which nobody wants inserted.
    static func postProcess(
        segments: [String],
        trim: Bool,
        normalize: Bool,
        removeFillers: Bool
    ) -> PostProcessResult {
        let raw = segments.joined()

        let (kept, removed) = HallucinationFilter.split(segments: segments)

        var text = kept.joined()
        var stages: [StageEdits] = []

        if removeFillers {
            let pass = FillerRemover.removeWithEdits(text)
            text = pass.text
            stages.append(StageEdits(stage: .fillers, edits: pass.edits))
        }

        if normalize {
            let pass = LexiconNormalizer.normalizeWithEdits(text)
            text = pass.text
            stages.append(StageEdits(stage: .lexicon, edits: pass.edits))
        }

        if trim {
            text = trimTrailingWhitespace(text)
        }

        return PostProcessResult(raw: raw, text: text, removedTemplates: removed, stages: stages)
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
        return trimTrailingWhitespace(text)
    }

    /// The trim itself, without the settings lookup. Split out so
    /// `postProcess(segments:trim:)` can stay a pure function testable in both
    /// toggle positions.
    static func trimTrailingWhitespace(_ text: String) -> String {
        var result = text
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }

    // MARK: - Pipeline stamp

    /// Post-processing pipeline version. Bump on every change to the filter
    /// templates or the normalizer rules/dictionary, so history entries stay
    /// attributable to the pipeline that produced them.
    ///
    /// `0` — no post-processing at all (whisper output + optional trim).
    /// `1` — hallucination filter + lexicon normalizer (2026-07-27).
    /// `2` — filler removal added ahead of the normalizer (2026-07-27).
    private static let postProcessingVersion = 2

    /// Snapshot of the pipeline that produced a transcription's final text,
    /// built from the initial prompt active for that run. Must be called
    /// BEFORE whisper.transcribe() runs, not after: transcribe(audio:language:)
    /// defers any pending setInitialPrompt() call to a `defer` block that fires
    /// on return, so reading currentInitialPromptText after the call would
    /// describe the NEXT transcription's prompt, not the one just used.
    ///
    /// Format: "n<postProcessingVersion>[-nolex]:p<first 12 hex chars of
    /// SHA-256(prompt)>". Hashing (rather than embedding the prompt itself)
    /// keeps the stamp short and avoids leaking custom vocabulary into every
    /// history line, while still letting two entries be compared for "same
    /// prompt, different pipeline version". CryptoKit.SHA256, not
    /// Swift.Hasher — Hasher is seeded randomly per process, so it is not
    /// stable across app launches, which a persisted stamp requires.
    ///
    /// Suffixes mark stages that were switched OFF for that entry: `-nofill`
    /// for filler removal, `-nolex` for the dictionary. Without them the stamp
    /// would claim passes that never ran, and attributing an entry's text to
    /// the pipeline that actually produced it is the stamp's only job. They are
    /// suffixes on the version rather than separate version numbers: the rules
    /// did not change, only whether a stage ran.
    ///
    /// Canonical order is pipeline order — `-nofill` before `-nolex` — so the
    /// four combinations produce exactly four strings and never two spellings
    /// of the same state.
    static func pipelineStamp(forPrompt prompt: String?, normalizing: Bool, removingFillers: Bool) -> String {
        let digest = SHA256.hash(data: Data((prompt ?? "").utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var version = "n\(postProcessingVersion)"
        if !removingFillers { version += "-nofill" }
        if !normalizing { version += "-nolex" }
        return "\(version):p\(hex.prefix(12))"
    }
}
