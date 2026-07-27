import XCTest
@testable import VoiceType

// Tests for the filler deletion pass. Structured by the five conditions of the
// rule plus the seam table, because a deletion rule fails in exactly those
// places: it fires where it should not, or eats the punctuation around it.
final class FillerRemoverTests: XCTestCase {

    // MARK: - The list

    func testRemovesTheThreeListedFillers() {
        XCTAssertEqual(FillerRemover.remove("Смотри, мне вот это все нужно"), "Смотри, мне это все нужно")
        XCTAssertEqual(FillerRemover.remove("Плюс по фронтенду ну пройтись"), "Плюс по фронтенду пройтись")
        XCTAssertEqual(FillerRemover.remove("Давай короче дотестируем"), "Давай дотестируем")
    }

    /// `значит`, `типа`, `как бы` and `э-э` are in the convention but NOT in the
    /// deterministic layer — homonymy makes them undecidable without meaning.
    /// These are the cases that would break if someone widened the list.
    func testLeavesUndecidableFillersAlone() {
        let cases = [
            "Если роль есть в кейклоке, значит они могут",
            "Это значит, что мы меняем интернет",
            "Создать группу типа read-only",
            "Я бы хотел что-то типа блок схем нарисовать",
            "Он будет такие события как бы валидировать"
        ]
        for text in cases {
            XCTAssertEqual(FillerRemover.remove(text), text, "must not touch: \(text)")
        }
    }

    // MARK: - Condition 1: lowercase only

    /// A capitalized filler is sentence-initial in fact even when whisper lost
    /// the full stop — the holdout case that made this condition exist.
    func testCapitalizedFillerIsNeverRemoved() {
        let text = "как ты рекомендуешь Вот может у кодекса спросить"
        XCTAssertEqual(FillerRemover.remove(text), text)

        let ну = "Плюс по фронтенду пройтись Ну это в другой сессии"
        XCTAssertEqual(FillerRemover.remove(ну), ну)
    }

    // MARK: - Condition 2: sentence position

    func testSentenceInitialFillerIsKept() {
        let text = "Всё готово. вот и славно"
        XCTAssertEqual(FillerRemover.remove(text), text, "after a full stop it opens a sentence")
    }

    /// Table of what counts as a sentence boundary when scanning back.
    func testSentenceBoundaryTable() {
        let kept: [String] = [
            "Готово. ну ладно",          // full stop
            "Готово! ну ладно",          // exclamation
            "Готово? ну ладно",          // question
            "Готово\u{2026} ну ладно",   // ellipsis
            "Смотри: ну ладно",          // colon
            "Смотри; ну ладно",          // semicolon
            "\u{00AB}ну ладно",          // opening guillemet at the start
            "(ну ладно",                 // opening bracket at the start
            "\u{2014} ну ладно",         // dialogue dash at the start
            "\u{1F389} ну ладно",        // emoji at the start
            "\n ну ладно",               // newline at the start
            " ну ладно"                  // leading space whisper always emits
        ]
        for text in kept {
            XCTAssertEqual(FillerRemover.remove(text), text, "must be treated as sentence-initial: \(text.debugDescription)")
        }

        let removed: [(String, String)] = [
            ("текст ну ладно", "текст ладно"),
            ("текст\u{00BB} ну ладно", "текст\u{00BB} ладно"),
            ("текст) ну ладно", "текст) ладно")
        ]
        for (input, expected) in removed {
            XCTAssertEqual(FillerRemover.remove(input), expected, "must be mid-sentence: \(input.debugDescription)")
        }
    }

    // MARK: - Condition 3: вот так / вот и

    func testDemonstrativeVotIsKept() {
        let so = "Давай попробуем еще вот так"
        XCTAssertEqual(FillerRemover.remove(so), so)

        let and = "Я вручную вот и на всякий случай"
        XCTAssertEqual(FillerRemover.remove(and), and)
    }

    func testVotBeforeOtherWordsIsRemoved() {
        XCTAssertEqual(FillerRemover.remove("в нижней вот этой панельке"), "в нижней этой панельке")
        XCTAssertEqual(FillerRemover.remove("если вот пустую сессию дать"), "если пустую сессию дать")
    }

    // MARK: - Condition 4: protected zones

    func testProtectedZonesAreNotTouched() {
        let backticks = "смотри `мне вот это` внимательно"
        XCTAssertEqual(FillerRemover.remove(backticks), backticks)

        let quotes = "он сказал \"мне вот это\" вчера"
        XCTAssertEqual(FillerRemover.remove(quotes), quotes)

        let path = "открой Sources/вот/файл.swift сейчас"
        XCTAssertEqual(FillerRemover.remove(path), path)
    }

    // MARK: - Condition 5: hyphenated compounds

    func testHyphenCompoundIsNotSplit() {
        for (name, hyphen) in [("ASCII", "-"), ("U+2010", "\u{2010}"), ("U+2011", "\u{2011}")] {
            let text = "он вот\(hyphen)вот придет"
            XCTAssertEqual(FillerRemover.remove(text), text, "compound with \(name) hyphen must survive")
        }
    }

    // MARK: - The seam table

    func testSeamBothCommas() {
        XCTAssertEqual(FillerRemover.remove("прежде чем говорить, чтобы, ну, их слова"), "прежде чем говорить, чтобы их слова")
    }

    /// A lone comma on the left belongs to the previous clause, not to the
    /// filler — it follows "понимаешь", not "вот". Taken verbatim from the
    /// reference corpus, where deleting it counted as four wrong fixes.
    func testSeamLeftCommaOnlyKeepsTheComma() {
        XCTAssertEqual(
            FillerRemover.remove("Вот понимаешь, вот такую ревью провести"),
            "Вот понимаешь, такую ревью провести"
        )
        XCTAssertEqual(
            FillerRemover.remove("Вот как-то грамотно, вот не знаю"),
            "Вот как-то грамотно, не знаю"
        )
    }

    /// The exception: a filler ending the sentence would strand that comma
    /// against the full stop, so there it goes with the filler.
    func testSeamLeftCommaGoesWhenFillerEndsTheSentence() {
        XCTAssertEqual(FillerRemover.remove("сделаем слово, ну."), "сделаем слово.")
        XCTAssertEqual(FillerRemover.remove("что-то придумать, короче."), "что-то придумать.")
    }

    func testSeamRightCommaOnly() {
        XCTAssertEqual(FillerRemover.remove("и ну, дотестируйте два варианта"), "и дотестируйте два варианта")
    }

    func testSeamNoCommas() {
        XCTAssertEqual(FillerRemover.remove("мне вот это все"), "мне это все")
    }

    /// Deleting a filler must not leave a double space anywhere.
    func testNoDoubleSpaceIsLeftBehind() {
        for text in ["мне вот это", "и ну, дальше", "слово, ну.", "чтобы, ну, их"] {
            XCTAssertFalse(FillerRemover.remove(text).contains("  "), "double space after removing in: \(text)")
        }
    }

    // MARK: - Whole-text invariants

    /// A record with no fillers must come back byte-identical, including the
    /// leading space every whisper transcript carries and any internal runs of
    /// whitespace — only the seam is allowed to collapse.
    func testTextWithoutFillersIsUnchanged() {
        let texts = [
            " Смотри, давай сегодня разберём эту задачу до конца.",
            "  двойные   пробелы   сохраняются  ",
            "Спроси у кодекса про хендов.",
            ""
        ]
        for text in texts {
            XCTAssertEqual(FillerRemover.remove(text), text)
        }
    }

    func testIdempotent() {
        let texts = [
            "мне вот это все ну ладно",
            "прежде чем говорить, чтобы, ну, их слова",
            " Смотри, в нижней вот этой панельке"
        ]
        for text in texts {
            let once = FillerRemover.remove(text)
            XCTAssertEqual(FillerRemover.remove(once), once, "second pass must change nothing: \(text)")
        }
    }

    // MARK: - The audit trail

    /// The log is only trustworthy if it satisfies every clause of the contract
    /// in TextEdit.swift — an edit that merely reproduces the output proves
    /// nothing on its own.
    func testEditLogSatisfiesItsContract() {
        let texts = [
            "мне вот это все ну ладно короче",
            "прежде чем говорить, чтобы, ну, их слова",
            "и ну, дотестируйте два варианта",
            " Смотри, в нижней вот этой панельке, вот этот флажок"
        ]
        for text in texts {
            let (output, edits) = FillerRemover.removeWithEdits(text)
            let chars = Array(text)

            XCTAssertEqual(TextEdit.validate(edits, against: chars), [], "contract violated for: \(text)")
            XCTAssertEqual(TextEdit.apply(edits, to: chars), output, "output must be the edits applied")

            for edit in edits {
                guard case let .filler(word) = edit.rule else {
                    return XCTFail("filler stage must only emit filler edits")
                }
                XCTAssertEqual(String(chars[edit.matchedRange]), word, "matchedRange must be the token itself")
                XCTAssertEqual(edit.replacement, "", "a filler edit is a deletion")
            }
        }
    }

    /// Code point offsets are what the eval corpus annotates in; they must match
    /// character offsets for plain text and account for astral characters.
    func testCodePointOffsetConversion() {
        let plain = Array("мне вот это")
        XCTAssertEqual(TextEdit.codePointOffsets(for: 4..<7, in: plain), 4..<7)

        let withEmoji = Array("\u{1F389} мне вот это")
        // The emoji is one Character but one scalar here; a flag would be two.
        let flag = Array("\u{1F1F7}\u{1F1FA} мне вот это")
        XCTAssertEqual(TextEdit.codePointOffsets(for: 0..<1, in: withEmoji), 0..<1)
        XCTAssertEqual(TextEdit.codePointOffsets(for: 0..<1, in: flag), 0..<2, "one grapheme, two code points")
    }
}
