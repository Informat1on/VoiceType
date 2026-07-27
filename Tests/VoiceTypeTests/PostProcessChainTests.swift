import XCTest
@testable import VoiceType

// Integration tests for the post-processing chain as a whole.
//
// Why these exist on top of HallucinationFilterTests and
// LexiconNormalizerTests: unit tests of the two pure functions in isolation
// cannot catch the defects that actually break the product here — a step that
// is never called, the two steps in the wrong order, a `raw` that no longer
// holds whisper's untouched output, or trim running before normalization.
// Plan review flagged exactly this gap.
@MainActor
final class PostProcessChainTests: XCTestCase {

    // MARK: - raw is the untouched whisper output

    /// `raw` must survive every later step, including a filter pass that
    /// removes the entire text. This is the corpus contract from the rawText
    /// work: without it, history can no longer tell ASR errors apart from
    /// post-processing errors.
    func testRawKeepsUntouchedWhisperOutputEvenWhenEverythingIsFiltered() {
        let segments = [" Продолжение следует..."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)

        XCTAssertEqual(result.raw, " Продолжение следует...", "raw must predate the filter")
        XCTAssertEqual(result.text, "", "the whole output was boilerplate — nothing to insert")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует..."])
    }

    /// `raw` is also untouched by the normalizer.
    func testRawIsNotNormalized() {
        let segments = [" Спроси у кодекса про хендов."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)

        XCTAssertEqual(result.raw, " Спроси у кодекса про хендов.")
        XCTAssertTrue(result.text.contains("Codex"), "text must be normalized")
        XCTAssertTrue(result.text.contains("handoff"), "text must be normalized")
        XCTAssertFalse(result.raw.contains("Codex"), "raw must not be normalized")
    }

    // MARK: - order of steps

    /// The filter must run BEFORE the normalizer, on whisper's own segment
    /// boundaries. If the order were reversed the normalizer would see the
    /// hallucination text, and — more importantly — the segment boundaries the
    /// filter needs no longer exist after the join.
    func testFilterRunsBeforeNormalizer() {
        let segments = [" Смотри, спроси у кодекса.", " Продолжение следует."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)

        XCTAssertFalse(result.text.contains("Продолжение следует"), "trailing boilerplate must go")
        XCTAssertTrue(result.text.contains("Codex"), "surviving speech must still be normalized")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// Trim runs last, so it also removes whitespace that earlier steps left
    /// exposed at the end.
    func testTrimRunsLast() {
        let segments = [" Спроси у кодекса.  ", " Продолжение следует."]

        let trimmed = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)
        XCTAssertEqual(trimmed.text, " Спроси у Codex.", "trailing whitespace must be gone")

        let untrimmed = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: false)
        XCTAssertEqual(untrimmed.text, " Спроси у Codex.  ", "toggle off must preserve it")
    }

    /// Leading whitespace is preserved in both toggle positions — every normal
    /// VoiceType transcription starts with the space whisper puts at the head
    /// of its first segment (100 of 100 history entries do), and a filtered
    /// one must not become the sole exception.
    func testLeadingWhitespaceSurvivesFiltering() {
        let segments = [" Продолжение следует...", " Спасибо."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)

        XCTAssertEqual(result.text, " Спасибо.", "the surviving segment keeps its own leading space")
    }

    // MARK: - edge cases

    /// A whitespace-only segment next to boilerplate must not be mistaken for
    /// boilerplate, and must not stop the edge run from being recognised
    /// either — it simply is not a template.
    func testWhitespaceSegmentNextToTemplate() {
        let segments = [" Смотри.", "   ", " Продолжение следует."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: false)

        XCTAssertEqual(result.text, " Смотри.   ", "only the template is dropped")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// A template in the strict middle is protected, and the chain reports no
    /// removals at all.
    func testTemplateInMiddleIsNotRemovedByTheChain() {
        let segments = [" Смотри.", " Продолжение следует.", " А дальше про пайплайн."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: false)

        XCTAssertEqual(result.text, result.raw, "nothing matched the dictionary, nothing filtered")
        XCTAssertTrue(result.removedTemplates.isEmpty)
    }

    /// Ordinary speech with no dictionary hits and no boilerplate must come
    /// out byte-identical apart from the trim.
    func testOrdinarySpeechIsUnchanged() {
        let segments = [" Смотри, давай сегодня разберём эту задачу до конца."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: false)

        XCTAssertEqual(result.text, result.raw)
        XCTAssertTrue(result.removedTemplates.isEmpty)
    }

    func testEmptyInput() {
        let result = TranscriptionService.postProcess(segments: [], trim: true, normalize: true, removeFillers: false)

        XCTAssertEqual(result.raw, "")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.removedTemplates.isEmpty)
    }

    // MARK: - normalize toggle (Settings > General > Insertion)

    /// Toggle off: the dictionary must not touch the text at all. This is the
    /// escape hatch for the accepted risk that `кодекс` / `опус` / `сонет` are
    /// ordinary Russian words, so "off" has to mean off, not "milder".
    func testNormalizeOffLeavesDictionaryFormsAlone() {
        let segments = [" Спроси у кодекса про хендов."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false, removeFillers: false)

        XCTAssertEqual(result.text, " Спроси у кодекса про хендов.")
        XCTAssertEqual(result.raw, " Спроси у кодекса про хендов.")
    }

    /// Toggle off must NOT disable the hallucination filter: it has no user
    /// toggle by design, because it removes text the user never spoke.
    func testNormalizeOffStillFiltersHallucinations() {
        let segments = [" Спроси у кодекса.", " Продолжение следует."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false, removeFillers: false)

        XCTAssertEqual(result.text, " Спроси у кодекса.", "boilerplate goes, dictionary stays out")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// Trim is independent of the normalizer toggle — the two gates must not
    /// be wired to each other.
    func testTrimStillAppliesWithNormalizeOff() {
        let segments = [" Спроси у кодекса.  "]

        let trimmed = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false, removeFillers: false)
        XCTAssertEqual(trimmed.text, " Спроси у кодекса.")

        let untrimmed = TranscriptionService.postProcess(segments: segments, trim: false, normalize: false, removeFillers: false)
        XCTAssertEqual(untrimmed.text, " Спроси у кодекса.  ")
    }

    // MARK: - both toggles, all four combinations

    /// One input that exercises both stages: a filler to drop and a dictionary
    /// form to rewrite. Each combination must produce exactly its own result —
    /// this is what catches a stage wired to the wrong flag.
    func testAllFourToggleCombinations() {
        let segments = [" Смотри, мне вот это у кодекса спросить."]

        let both = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: true)
        XCTAssertEqual(both.text, " Смотри, мне это у Codex спросить.")

        let fillersOnly = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false, removeFillers: true)
        XCTAssertEqual(fillersOnly.text, " Смотри, мне это у кодекса спросить.")

        let lexiconOnly = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: false)
        XCTAssertEqual(lexiconOnly.text, " Смотри, мне вот это у Codex спросить.")

        let neither = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false, removeFillers: false)
        XCTAssertEqual(neither.text, " Смотри, мне вот это у кодекса спросить.")

        XCTAssertEqual(neither.raw, " Смотри, мне вот это у кодекса спросить.", "raw never changes")
    }

    /// Fillers run BEFORE the dictionary so a filler cannot hide a multi-word
    /// dictionary entry by standing between its halves.
    func testFillersRunBeforeTheDictionary() {
        let segments = [" Запусти сонет ну агенты сегодня."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true, removeFillers: true)

        XCTAssertTrue(
            result.text.contains("Sonnet-агенты"),
            "removing the filler must expose the composite entry, got: \(result.text)"
        )
    }

    /// Each stage logs against its own input, and applying a batch to that
    /// input must reproduce the batch's output. Without this the log would be
    /// an unverifiable claim — plan review's exact objection.
    func testStageEditLogsReconstructTheirOwnStageOutput() {
        let segments = [" Смотри, мне вот это у кодекса спросить, ну ладно."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: true)

        XCTAssertEqual(result.stages.map(\.stage), [.fillers, .lexicon], "batches are in execution order")

        var current = Array(result.raw)
        for batch in result.stages {
            XCTAssertEqual(
                TextEdit.validate(batch.edits, against: current),
                [],
                "\(batch.stage.rawValue) batch violates the edit contract"
            )
            current = Array(TextEdit.apply(batch.edits, to: current))
        }
        XCTAssertEqual(String(current), result.text, "applying every batch in order must rebuild the final text")
    }

    /// A stage that is off must contribute no batch at all — an empty batch
    /// would read as "ran and changed nothing", which is a different fact.
    func testDisabledStagesContributeNoBatch() {
        let segments = [" Смотри, мне вот это у кодекса спросить."]

        XCTAssertEqual(
            TranscriptionService.postProcess(segments: segments, trim: false, normalize: false, removeFillers: true)
                .stages.map(\.stage), [.fillers])
        XCTAssertEqual(
            TranscriptionService.postProcess(segments: segments, trim: false, normalize: true, removeFillers: false)
                .stages.map(\.stage), [.lexicon])
        XCTAssertTrue(
            TranscriptionService.postProcess(segments: segments, trim: false, normalize: false, removeFillers: false)
                .stages.isEmpty)
    }

    func testStampCoversBothToggles() {
        let prompt = "same prompt"
        XCTAssertEqual(
            TranscriptionService.pipelineStamp(forPrompt: prompt, normalizing: true, removingFillers: true),
            "n2:p66fddd00ccb8")
        XCTAssertEqual(
            TranscriptionService.pipelineStamp(forPrompt: prompt, normalizing: false, removingFillers: true),
            "n2-nolex:p66fddd00ccb8")
        XCTAssertEqual(
            TranscriptionService.pipelineStamp(forPrompt: prompt, normalizing: true, removingFillers: false),
            "n2-nofill:p66fddd00ccb8")
        XCTAssertEqual(
            TranscriptionService.pipelineStamp(forPrompt: prompt, normalizing: false, removingFillers: false),
            "n2-nofill-nolex:p66fddd00ccb8",
            "suffixes follow pipeline order, so each state has exactly one spelling")
    }

    func testStampMarksSkippedNormalization() {
        let on = TranscriptionService.pipelineStamp(forPrompt: "same prompt", normalizing: true, removingFillers: true)
        let off = TranscriptionService.pipelineStamp(forPrompt: "same prompt", normalizing: false, removingFillers: true)

        XCTAssertEqual(on, "n2:p66fddd00ccb8")
        XCTAssertEqual(off, "n2-nolex:p66fddd00ccb8", "same prompt hash, different pipeline")
        XCTAssertNotEqual(on, off)
    }
}
