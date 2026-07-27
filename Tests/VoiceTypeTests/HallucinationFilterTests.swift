// HallucinationFilterTests.swift — VoiceType
//
// Unit tests for HallucinationFilter (task T16, 2026-07-27). The rule under
// test — drop only contiguous template runs anchored at the start and/or end
// of the segment array, never the strict middle — was picked over two
// simpler alternatives (suffix-only, match-anywhere) by measurement on a
// 1000-file relabeled corpus; see the doc comment on HallucinationFilter for
// the numbers. These tests pin that behavior case by case.

import XCTest
@testable import VoiceType

final class HallucinationFilterTests: XCTestCase {

    // MARK: - testWholeOutputSingleHallucination

    /// Case 1: the entire output is one hallucinated segment → empty array.
    func testWholeOutputSingleHallucination() {
        let result = HallucinationFilter.filter(segments: ["Продолжение следует..."])
        XCTAssertEqual(result, [])
    }

    // MARK: - testTrailingHallucinationAfterSpeech

    /// Case 2: real speech followed by a hallucinated tail → speech kept
    /// byte-for-byte (including its leading space), tail dropped.
    func testTrailingHallucinationAfterSpeech() {
        let result = HallucinationFilter.filter(segments: [
            " Встреча перенесена на завтра.",
            " Продолжение следует..."
        ])
        XCTAssertEqual(result, [" Встреча перенесена на завтра."])
    }

    // MARK: - testTwoConsecutiveTrailingHallucinations

    /// Case 3: two hallucinated segments in a row at the tail (observed in
    /// the corpus) → both dropped, speech kept.
    func testTwoConsecutiveTrailingHallucinations() {
        let result = HallucinationFilter.filter(segments: [
            " Заказ готов, можно забирать.",
            " Продолжение следует...",
            " Продолжение следует..."
        ])
        XCTAssertEqual(result, [" Заказ готов, можно забирать."])
    }

    // MARK: - testTemplateInStrictMiddleIsProtected

    /// Case 3a: a template match in the STRICT MIDDLE (speech, template,
    /// speech) must survive untouched — this is the middle-protection
    /// guarantee the whole "runs from both edges" rule exists for.
    func testTemplateInStrictMiddleIsProtected() {
        let input = [
            " Первая часть записи.",
            " Продолжение следует.",
            " Вторая часть записи."
        ]
        let result = HallucinationFilter.filter(segments: input)
        XCTAssertEqual(result, input, "A template match in the strict middle must never be dropped")
    }

    // MARK: - testTemplateAtStartThenSpeech

    /// Case 3b: template first, then real speech — the actual recording
    /// from the data ("Продолжение следует..." + " Спасибо."), 31.4s of
    /// leading silence. Suffix-only removal misses this one; the
    /// both-edges rule catches it.
    func testTemplateAtStartThenSpeech() {
        let result = HallucinationFilter.filter(segments: [
            "Продолжение следует...",
            " Спасибо."
        ])
        XCTAssertEqual(result, [" Спасибо."])
    }

    // MARK: - testTemplatesOnBothEdgesAroundSpeech

    /// Case 3c: template, speech, template → both edges dropped, speech
    /// untouched.
    func testTemplatesOnBothEdgesAroundSpeech() {
        let result = HallucinationFilter.filter(segments: [
            "Продолжение следует...",
            " Давайте начнём совещание.",
            " Продолжение следует..."
        ])
        XCTAssertEqual(result, [" Давайте начнём совещание."])
    }

    // MARK: - testPunctuationVariations

    /// Case 4: punctuation/whitespace/case variations of the template all
    /// match — the normalizer must strip trailing `.`/`…`/`!`/`?` in any
    /// count or mix, collapse internal whitespace, trim edges, and
    /// lowercase before comparing.
    func testPunctuationVariations() {
        let variations = [
            "Продолжение следует.",
            "Продолжение следует...",
            "Продолжение следует…",
            " Продолжение   следует ",
            "ПРОДОЛЖЕНИЕ СЛЕДУЕТ"
        ]
        for variant in variations {
            let result = HallucinationFilter.filter(segments: [variant])
            XCTAssertEqual(result, [], "Expected '\(variant)' to be recognized as the template and dropped")
        }
    }

    // MARK: - testPartialContainmentIsNotDropped

    /// Case 5: partial containment is not a match — the segment must be
    /// verbatim-equal to a template after normalization, not merely contain
    /// one as a substring.
    /// Punctuation separated from the word by a space: stripping the "." must
    /// not leave a trailing space that defeats the template match.
    func testPunctuationSeparatedBySpaceStillMatches() {
        XCTAssertEqual(HallucinationFilter.filter(segments: [" Продолжение следует ."]), [])
        XCTAssertEqual(HallucinationFilter.filter(segments: [" Продолжение следует ..."]), [])
    }

    func testPartialContainmentIsNotDropped() {
        let segment = "Продолжение следует, если я правильно понял"
        let result = HallucinationFilter.filter(segments: [segment])
        XCTAssertEqual(result, [segment])
    }

    // MARK: - testThanksIsNotATemplate

    /// Case 6: "Спасибо." is deliberately NOT in the closed template list
    /// (it occurs as genuine speech in the corpus) — must never be dropped.
    func testThanksIsNotATemplate() {
        let result = HallucinationFilter.filter(segments: ["Спасибо."])
        XCTAssertEqual(result, ["Спасибо."])
    }

    // MARK: - testOrdinarySpeechIsReturnedIdentical

    /// Case 7: ordinary multi-segment speech with no template matches at
    /// all → array returned identical to the input.
    func testOrdinarySpeechIsReturnedIdentical() {
        let input = [
            " Добрый день,",
            " сегодня обсудим план на неделю",
            " и распределим задачи."
        ]
        let result = HallucinationFilter.filter(segments: input)
        XCTAssertEqual(result, input)
    }

    // MARK: - testEmptyInputReturnsEmptyOutput

    /// Case 8: empty array in → empty array out, no crash on the empty-input
    /// path through the leading/trailing run scans.
    func testEmptyInputReturnsEmptyOutput() {
        let result = HallucinationFilter.filter(segments: [])
        XCTAssertEqual(result, [])
    }

    // MARK: - testWhitespaceOnlySegmentIsNotTreatedAsTemplate

    /// Case 9: a segment made of only whitespace normalizes to the empty
    /// string, which is not in the template set, so it is kept as-is.
    /// Deliberate: an all-whitespace segment is not this filter's defect
    /// class (it's not the subtitle-boilerplate hallucination), so it is
    /// left untouched rather than special-cased.
    func testWhitespaceOnlySegmentIsNotTreatedAsTemplate() {
        let result = HallucinationFilter.filter(segments: ["   "])
        XCTAssertEqual(result, ["   "])
    }
}
