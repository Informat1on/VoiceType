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
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true)

        XCTAssertEqual(result.raw, " Продолжение следует...", "raw must predate the filter")
        XCTAssertEqual(result.text, "", "the whole output was boilerplate — nothing to insert")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует..."])
    }

    /// `raw` is also untouched by the normalizer.
    func testRawIsNotNormalized() {
        let segments = [" Спроси у кодекса про хендов."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true)

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
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true)

        XCTAssertFalse(result.text.contains("Продолжение следует"), "trailing boilerplate must go")
        XCTAssertTrue(result.text.contains("Codex"), "surviving speech must still be normalized")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// Trim runs last, so it also removes whitespace that earlier steps left
    /// exposed at the end.
    func testTrimRunsLast() {
        let segments = [" Спроси у кодекса.  ", " Продолжение следует."]

        let trimmed = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true)
        XCTAssertEqual(trimmed.text, " Спроси у Codex.", "trailing whitespace must be gone")

        let untrimmed = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true)
        XCTAssertEqual(untrimmed.text, " Спроси у Codex.  ", "toggle off must preserve it")
    }

    /// Leading whitespace is preserved in both toggle positions — every normal
    /// VoiceType transcription starts with the space whisper puts at the head
    /// of its first segment (100 of 100 history entries do), and a filtered
    /// one must not become the sole exception.
    func testLeadingWhitespaceSurvivesFiltering() {
        let segments = [" Продолжение следует...", " Спасибо."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: true)

        XCTAssertEqual(result.text, " Спасибо.", "the surviving segment keeps its own leading space")
    }

    // MARK: - edge cases

    /// A whitespace-only segment next to boilerplate must not be mistaken for
    /// boilerplate, and must not stop the edge run from being recognised
    /// either — it simply is not a template.
    func testWhitespaceSegmentNextToTemplate() {
        let segments = [" Смотри.", "   ", " Продолжение следует."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true)

        XCTAssertEqual(result.text, " Смотри.   ", "only the template is dropped")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// A template in the strict middle is protected, and the chain reports no
    /// removals at all.
    func testTemplateInMiddleIsNotRemovedByTheChain() {
        let segments = [" Смотри.", " Продолжение следует.", " А дальше про пайплайн."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true)

        XCTAssertEqual(result.text, result.raw, "nothing matched the dictionary, nothing filtered")
        XCTAssertTrue(result.removedTemplates.isEmpty)
    }

    /// Ordinary speech with no dictionary hits and no boilerplate must come
    /// out byte-identical apart from the trim.
    func testOrdinarySpeechIsUnchanged() {
        let segments = [" Смотри, давай сегодня разберём эту задачу до конца."]
        let result = TranscriptionService.postProcess(segments: segments, trim: false, normalize: true)

        XCTAssertEqual(result.text, result.raw)
        XCTAssertTrue(result.removedTemplates.isEmpty)
    }

    func testEmptyInput() {
        let result = TranscriptionService.postProcess(segments: [], trim: true, normalize: true)

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
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false)

        XCTAssertEqual(result.text, " Спроси у кодекса про хендов.")
        XCTAssertEqual(result.raw, " Спроси у кодекса про хендов.")
    }

    /// Toggle off must NOT disable the hallucination filter: it has no user
    /// toggle by design, because it removes text the user never spoke.
    func testNormalizeOffStillFiltersHallucinations() {
        let segments = [" Спроси у кодекса.", " Продолжение следует."]
        let result = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false)

        XCTAssertEqual(result.text, " Спроси у кодекса.", "boilerplate goes, dictionary stays out")
        XCTAssertEqual(result.removedTemplates, [" Продолжение следует."])
    }

    /// Trim is independent of the normalizer toggle — the two gates must not
    /// be wired to each other.
    func testTrimStillAppliesWithNormalizeOff() {
        let segments = [" Спроси у кодекса.  "]

        let trimmed = TranscriptionService.postProcess(segments: segments, trim: true, normalize: false)
        XCTAssertEqual(trimmed.text, " Спроси у кодекса.")

        let untrimmed = TranscriptionService.postProcess(segments: segments, trim: false, normalize: false)
        XCTAssertEqual(untrimmed.text, " Спроси у кодекса.  ")
    }

    /// The stamp must say which pipeline actually ran: claiming `n1` for an
    /// entry produced with the dictionary switched off would make history
    /// unattributable, which is the one job the stamp has.
    func testStampMarksSkippedNormalization() {
        let on = TranscriptionService.pipelineStamp(forPrompt: "same prompt", normalizing: true)
        let off = TranscriptionService.pipelineStamp(forPrompt: "same prompt", normalizing: false)

        XCTAssertEqual(on, "n1:p66fddd00ccb8")
        XCTAssertEqual(off, "n1-nolex:p66fddd00ccb8", "same prompt hash, different pipeline")
        XCTAssertNotEqual(on, off)
    }
}
