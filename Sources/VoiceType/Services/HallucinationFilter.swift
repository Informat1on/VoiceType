import Foundation

/// Drops whisper.cpp subtitle-boilerplate hallucinations from a transcription
/// (task T16, 2026-07-27).
///
/// **Why per-segment, not per-line.** The app's output never contains `\n` —
/// verified on 100 output/re-run pairs and 100 `history.jsonl` entries, zero
/// with `\n`. The line breaks visible in `whisper-cli` dumps are the CLI's own
/// printing (one line per segment); the app never sees them. So this filter
/// takes whisper's own segment boundaries as input rather than trying to
/// reconstruct them by splitting text — there is nothing to split.
///
/// **Why no duration or character-density thresholds.** Both were tried
/// against a 1000-file relabeled measurement and both failed:
///   - Duration: hallucinations span 0.61s–60.21s, and the corpus also
///     contains genuine short speech ("По поводу.", 0.92s). No cut point
///     separates them.
///   - Character density: hallucinations measured 1.02–36.18 chars/sec,
///     genuine speech 0.91–23.15 chars/sec — the ranges fully overlap.
/// Do not reintroduce either without a fresh measurement that actually
/// separates the two populations; the ones that were tried do not.
///
/// **The rule that does work, per the same measurement:** drop only
/// contiguous runs of template segments anchored at the start and/or the end
/// of the segment array. A segment in the strict middle is never dropped,
/// even if it verbatim-matches a template — that protects the case where
/// whisper splits genuine speech into its own segment next to a hallucinated
/// one. Suffix-only removal was tried too and missed 1 of 19 cases (a
/// "template first, then real trailing speech" recording); dropping a
/// template match anywhere in the array caught all 19 but gives up the
/// middle protection. Runs-from-both-edges caught all 19 with zero false
/// positives and keeps the middle protected.
enum HallucinationFilter {

    /// Closed list of known subtitle-boilerplate segments, already in
    /// normalized form (see `normalize(_:)`). Only verbatim matches count —
    /// partial containment (e.g. "Продолжение следует, если я правильно
    /// понял") must never match.
    ///
    /// Deliberately excludes things like "спасибо" / "спасибо за просмотр" /
    /// "подписывайтесь": those occur as genuine speech in the owner's corpus,
    /// and a false positive there costs more than the hallucination it would
    /// catch.
    private static let templates: Set<String> = [
        // Confirmed by measurement — 19 of 19 hallucination cases in the
        // 1000-file corpus.
        "продолжение следует",
        // Known artifacts of Russian subtitle credits in whisper's training
        // data. Not observed in the owner's corpus, but same defect class.
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры и перевод сделал dimatorzok",
        "редактор субтитров а.синецкая",
        "корректор а.кулакова"
    ]

    /// Drops whisper segments whose entire text is subtitle boilerplate.
    ///
    /// Removes only contiguous runs of template-matching segments starting
    /// from index 0 and/or ending at the last index; everything strictly
    /// between those two runs is returned untouched, byte-for-byte, in its
    /// original order — including whatever leading space whisper put at the
    /// start of each segment. If every segment is consumed by the two runs,
    /// the result is an empty array (the caller's existing `.emptyResult`
    /// capsule state already covers empty output — no new UI needed).
    static func filter(segments: [String]) -> [String] {
        split(segments: segments).kept
    }

    /// Same rule as `filter(segments:)`, but also reports what was dropped.
    ///
    /// The caller needs the dropped segments to log them, and they cannot be
    /// recovered afterwards by set subtraction: a template that appears both
    /// at an edge (dropped) and in the strict middle (protected) is the same
    /// string, so comparing kept against input would under-report the drop and
    /// mislabel the protected one.
    static func split(segments: [String]) -> (kept: [String], removed: [String]) {
        guard !segments.isEmpty else { return ([], []) }

        let isTemplate = segments.map { templates.contains(normalize($0)) }

        var leadingRun = 0
        while leadingRun < segments.count && isTemplate[leadingRun] {
            leadingRun += 1
        }

        var trailingRun = 0
        while trailingRun < segments.count && isTemplate[segments.count - 1 - trailingRun] {
            trailingRun += 1
        }

        let keepStart = leadingRun
        let keepEnd = segments.count - trailingRun
        guard keepStart < keepEnd else { return ([], segments) }

        return (
            kept: Array(segments[keepStart..<keepEnd]),
            removed: Array(segments[0..<keepStart]) + Array(segments[keepEnd...])
        )
    }

    /// Normalizes a segment for comparison against `templates`: trims edge
    /// whitespace, collapses internal whitespace runs to a single space,
    /// strips any trailing run of sentence-ending punctuation (`.`, `…`,
    /// `!`, `?`, any count or mix), then lowercases. Used only for the
    /// membership check — the original segment text is what gets returned.
    private static func normalize(_ segment: String) -> String {
        let collapsed = segment
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var trimmedPunctuation = collapsed
        let trailingPunctuation = CharacterSet(charactersIn: ".…!?")
        while let last = trimmedPunctuation.unicodeScalars.last,
              trailingPunctuation.contains(last) {
            trimmedPunctuation.unicodeScalars.removeLast()
        }

        // Trim again after stripping punctuation: " следует . " collapses to
        // "следует ." above, and removing the "." would otherwise leave a
        // trailing space that no template can match.
        return trimmedPunctuation
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
