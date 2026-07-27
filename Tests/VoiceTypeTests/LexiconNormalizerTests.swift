// LexiconNormalizerTests.swift — VoiceType
//
// Unit tests for LexiconNormalizer (task brief-B, 2026-07-27). Covers:
// one representative test per dictionary group, an exhaustive table-driven
// test over every single dictionary pair (so zero-frequency forms are still
// checked by something), the mandatory negative corpus (real words that look
// like dictionary keys but must survive untouched), the no-dictionary-word
// invariant, idempotency, protected zones (backticks/quotes/URLs/paths), and
// the homoglyph rule.

import XCTest
@testable import VoiceType

final class LexiconNormalizerTests: XCTestCase {

    // MARK: - testProperNounGroup

    func testProperNounGroup() {
        XCTAssertEqual(LexiconNormalizer.normalize("кодексом"), "Codex")
        XCTAssertEqual(LexiconNormalizer.normalize("клод"), "Claude")
        // Proper nouns ignore source casing entirely — canonical output
        // regardless of lower/Title/UPPER.
        XCTAssertEqual(LexiconNormalizer.normalize("Клод"), "Claude")
        XCTAssertEqual(LexiconNormalizer.normalize("КЛОД"), "Claude")
        XCTAssertEqual(
            LexiconNormalizer.normalize("два хайку и один сонет-агент"),
            "два Haiku и один Sonnet-агент"
        )
    }

    // MARK: - testProperNounIgnoresCaseEvenWhenMixed

    /// Canonical policy (proper nouns, handoff) differs from case-adapting
    /// policy specifically on mixed-case input: canonical still replaces,
    /// case-adapting does not (see testDoublingGroupMixedCaseUntouched).
    func testProperNounIgnoresCaseEvenWhenMixed() {
        XCTAssertEqual(LexiconNormalizer.normalize("КлОд"), "Claude")
    }

    // MARK: - testHandoffGroup

    func testHandoffGroup() {
        XCTAssertEqual(LexiconNormalizer.normalize("хендов"), "handoff")
        XCTAssertEqual(LexiconNormalizer.normalize("Hand-off"), "handoff")
        XCTAssertEqual(LexiconNormalizer.normalize("ХЕНДОВ"), "handoff")
        XCTAssertEqual(LexiconNormalizer.normalize("хэнд-оффом"), "handoff")
        // Regular dative case of хендов — added on review after corpus check
        // ("по твоему хендову"), distinct from the excluded derived noun
        // "хендовик".
        XCTAssertEqual(LexiconNormalizer.normalize("хендову"), "handoff")
    }

    // MARK: - testCompositeFormsGroup

    func testCompositeFormsGroup() {
        // Glued, no separator.
        XCTAssertEqual(LexiconNormalizer.normalize("сонетагента"), "Sonnet-агента")
        // Multi-word, space separator.
        XCTAssertEqual(LexiconNormalizer.normalize("сонет агенты"), "Sonnet-агенты")
        XCTAssertEqual(LexiconNormalizer.normalize("core ml"), "Core ML")
        // Hyphenated composite: only the first component is replaced, the
        // tail is copied — expressed here as the dictionary's fixed
        // replacement text, not a general rule.
        XCTAssertEqual(LexiconNormalizer.normalize("кодекс-ревью"), "Codex-ревью")
    }

    // MARK: - testUnlistedHyphenCompoundIsLeftAlone

    /// A single-word entry must NOT fire inside a hyphen compound the
    /// dictionary does not list as a whole — otherwise the closed list becomes
    /// generative, which the design rejects.
    ///
    /// Found by the holdout split: `Клод-код` (the product name Claude Code)
    /// came out as `Claude-код`, a wrong fix. An honest miss is the correct
    /// behaviour here — misses are cheap, wrong fixes are not. Adding
    /// `клод-код` to the dictionary would fix it properly, but that entry has
    /// to come from dev/corpus evidence, not from reading the holdout.
    func testUnlistedHyphenCompoundIsLeftAlone() {
        XCTAssertEqual(LexiconNormalizer.normalize("Клод-код"), "Клод-код")
        XCTAssertEqual(LexiconNormalizer.normalize("кодекс-чегототам"), "кодекс-чегототам")
        // The compound guard works on the left side too.
        XCTAssertEqual(LexiconNormalizer.normalize("мега-кодекс"), "мега-кодекс")
        // Listed compounds are unaffected — they match as a whole first.
        XCTAssertEqual(LexiconNormalizer.normalize("кодекс-ревью"), "Codex-ревью")
        XCTAssertEqual(LexiconNormalizer.normalize("сонет-агент"), "Sonnet-агент")
        // A spaced dash is not a compound.
        XCTAssertEqual(LexiconNormalizer.normalize("кодекс — это"), "Codex — это")
        // U+2010 / U+2011 look like "-" but are different scalars; the guard
        // must cover them, otherwise the compound falls through to the
        // single-word entry and produces the wrong fix.
        XCTAssertEqual(LexiconNormalizer.normalize("Клод\u{2011}код"), "Клод\u{2011}код")
        XCTAssertEqual(LexiconNormalizer.normalize("Клод\u{2010}код"), "Клод\u{2010}код")
    }

    // MARK: - testLongestMatchWinsOverSingleWordEntry

    /// The maximal-munch requirement from the brief: trying the single-word
    /// "сонет" entry before the composite ones would produce "Sonnet агенты"
    /// (wrong separator) instead of "Sonnet-агенты".
    func testLongestMatchWinsOverSingleWordEntry() {
        XCTAssertEqual(LexiconNormalizer.normalize("сонет агенты"), "Sonnet-агенты")
        XCTAssertEqual(LexiconNormalizer.normalize("сонет-агент"), "Sonnet-агент")
        // No following match at all — falls back to the single-word entry.
        XCTAssertEqual(LexiconNormalizer.normalize("сонет Пушкина"), "Sonnet Пушкина")
    }

    // MARK: - testDoublingGroup

    func testDoublingGroup() {
        XCTAssertEqual(LexiconNormalizer.normalize("скилу"), "скиллу")
        XCTAssertEqual(LexiconNormalizer.normalize("закомитить"), "закоммитить")
        XCTAssertEqual(LexiconNormalizer.normalize("бекап"), "бэкап")
        // "аллерта" -> "алерта" is a de-doubling, not a doubling — the rule
        // is "canonical form", not "always double".
        XCTAssertEqual(LexiconNormalizer.normalize("аллерта"), "алерта")
    }

    // MARK: - testDoublingGroupCasingAdapts

    func testDoublingGroupCasingAdapts() {
        XCTAssertEqual(LexiconNormalizer.normalize("скилу"), "скиллу")
        XCTAssertEqual(LexiconNormalizer.normalize("Скилу"), "Скиллу")
        XCTAssertEqual(LexiconNormalizer.normalize("СКИЛУ"), "СКИЛЛУ")
    }

    // MARK: - testDoublingGroupMixedCaseUntouched

    /// "Mixed case не трогается" — case-adapting entries (unlike proper
    /// nouns) leave a source token untouched if its casing isn't cleanly
    /// lower/Title/UPPER, rather than guessing which class was intended.
    func testDoublingGroupMixedCaseUntouched() {
        XCTAssertEqual(LexiconNormalizer.normalize("СкилУ"), "СкилУ")
    }

    // MARK: - testEScriptGroup

    func testEScriptGroup() {
        XCTAssertEqual(LexiconNormalizer.normalize("бэкэнд"), "бэкенд")
        XCTAssertEqual(LexiconNormalizer.normalize("фронтэнду"), "фронтенду")
    }

    // MARK: - testPromptGroup

    func testPromptGroup() {
        XCTAssertEqual(LexiconNormalizer.normalize("промт"), "промпт")
        XCTAssertEqual(LexiconNormalizer.normalize("пром"), "промпт")
        // Already-correct form must survive — short token, highest collision
        // risk in the whole dictionary.
        XCTAssertEqual(LexiconNormalizer.normalize("промпт"), "промпт")
    }

    // MARK: - testHomoglyphGroup

    func testHomoglyphGroup() {
        // Cyrillic М3 followed by Pro -> Latin M3.
        XCTAssertEqual(LexiconNormalizer.normalize("М3 Pro"), "M3 Pro")
        XCTAssertEqual(LexiconNormalizer.normalize("М4 Max"), "M4 Max")
        XCTAssertEqual(LexiconNormalizer.normalize("М2 Ultra"), "M2 Ultra")
        // No Pro/Max/Ultra following — rule doesn't fire.
        XCTAssertEqual(LexiconNormalizer.normalize("М3 чип"), "М3 чип")
    }

    // MARK: - testExhaustiveDictionaryTable

    /// One case per dictionary pair from dictionary-vetted.md, transcribed
    /// verbatim. This is what actually exercises the zero-frequency forms —
    /// nothing else in this test file would notice if one of them silently
    /// stopped matching (e.g. a typo introduced while editing the dictionary).
    func testExhaustiveDictionaryTable() {
        let cases: [(source: String, expected: String)] = [
            // Codex
            ("кодекс", "Codex"), ("кодекса", "Codex"), ("кодексу", "Codex"),
            ("кодексом", "Codex"), ("кодексе", "Codex"), ("кодексы", "Codex"),
            ("кодексов", "Codex"), ("кодексам", "Codex"), ("кодексами", "Codex"),
            // Fable
            ("фейбл", "Fable"), ("фейбла", "Fable"), ("фейблу", "Fable"),
            ("фейблом", "Fable"), ("фейбле", "Fable"),
            // Grafana
            ("графана", "Grafana"), ("графаны", "Grafana"), ("графане", "Grafana"),
            ("графану", "Grafana"), ("графаной", "Grafana"),
            // Opus
            ("опус", "Opus"), ("опуса", "Opus"), ("опусу", "Opus"),
            ("опусом", "Opus"), ("опусе", "Opus"), ("опусы", "Opus"), ("опусов", "Opus"),
            // Claude
            ("клод", "Claude"), ("клода", "Claude"), ("клоду", "Claude"),
            ("клодом", "Claude"), ("клоде", "Claude"),
            // iTop
            ("айтоп", "iTop"), ("айтопа", "iTop"), ("айтопу", "iTop"),
            ("айтопе", "iTop"), ("айтопом", "iTop"),
            // Redmine
            ("редмайн", "Redmine"), ("редмайна", "Redmine"), ("редмайну", "Redmine"),
            ("редмайне", "Redmine"), ("редмайном", "Redmine"),
            // Docker
            ("докер", "Docker"), ("докера", "Docker"), ("докеру", "Docker"),
            ("докером", "Docker"), ("докере", "Docker"),
            // Sonnet
            ("сонет", "Sonnet"), ("сонета", "Sonnet"), ("сонету", "Sonnet"),
            ("сонетом", "Sonnet"), ("сонете", "Sonnet"),
            // Haiku
            ("хайку", "Haiku"),
            // Anthropic
            ("антропик", "Anthropic"), ("антропика", "Anthropic"), ("антропику", "Anthropic"),
            ("антропики", "Anthropic"), ("антропиком", "Anthropic"),
            // GitHub
            ("гитхаб", "GitHub"), ("гитхаба", "GitHub"), ("гитхабе", "GitHub"), ("гитхабу", "GitHub"),
            // Twitter
            ("твиттер", "Twitter"), ("твиттера", "Twitter"), ("твиттере", "Twitter"),
            // Qwen
            ("квен", "Qwen"), ("квена", "Qwen"), ("квены", "Qwen"),
            // Swarm
            ("сворм", "Swarm"), ("сворма", "Swarm"),

            // handoff — single-word forms
            ("хендов", "handoff"), ("хендову", "handoff"), ("хэндов", "handoff"),
            ("хендофф", "handoff"), ("хендоффа", "handoff"), ("хендоффов", "handoff"),
            ("хендоффы", "handoff"), ("хендоффе", "handoff"),
            // handoff — хенд- hyphenated forms
            ("хенд-офф", "handoff"), ("хенд-оффа", "handoff"), ("хенд-оффу", "handoff"),
            ("хенд-оффе", "handoff"), ("хенд-оффом", "handoff"), ("хенд-оффы", "handoff"),
            ("хенд-оффов", "handoff"), ("хенд-оффах", "handoff"), ("хенд-оффами", "handoff"),
            // handoff — хэнд- hyphenated forms
            ("хэнд-офф", "handoff"), ("хэнд-оффа", "handoff"), ("хэнд-оффе", "handoff"),
            ("хэнд-оффом", "handoff"), ("хэнд-оффов", "handoff"), ("хэнд-оффах", "handoff"),
            // handoff — Latin
            ("hand-off", "handoff"),

            // Composite forms
            ("сонетагента", "Sonnet-агента"),
            ("сонет агенты", "Sonnet-агенты"),
            ("сонет-агент", "Sonnet-агент"),
            ("сонет-агентов", "Sonnet-агентов"),
            ("сонет-агенты", "Sonnet-агенты"),
            ("кодекс-ревью", "Codex-ревью"),
            ("кодекс-проверками", "Codex-проверками"),
            ("кодекс-ревьювером", "Codex-ревьювером"),
            ("опус-агенты", "Opus-агенты"),
            ("core ml", "Core ML"),

            // Doubling
            ("скилу", "скиллу"), ("скилом", "скиллом"), ("скилов", "скиллов"),
            ("скилы", "скиллы"), ("скиле", "скилле"),
            ("комит", "коммит"), ("комита", "коммита"), ("комите", "коммите"),
            ("комитов", "коммитов"), ("комить", "коммить"), ("комитим", "коммитим"),
            ("комиттим", "коммитим"), ("комитешь", "коммитишь"),
            ("закомить", "закоммитить"), ("закомитить", "закоммитить"), ("закомитим", "закоммитим"),
            ("бекап", "бэкап"), ("аллерта", "алерта"), ("колеги", "коллеги"),
            ("паралелльно", "параллельно"),

            // э/е
            ("бэкэнд", "бэкенд"), ("бэкэнда", "бэкенда"), ("бэкэнду", "бэкенду"),
            ("бэкэнде", "бэкенде"), ("бэкэндом", "бэкендом"),
            ("фронтэнд", "фронтенд"), ("фронтэнда", "фронтенда"),
            ("фронтэнду", "фронтенду"), ("фронтэнде", "фронтенде"),

            // промт
            ("промт", "промпт"), ("промта", "промпта"), ("промту", "промпту"),
            ("промтом", "промптом"), ("промте", "промпте"), ("промты", "промпты"),
            ("промтов", "промптов"), ("пром", "промпт")
        ]

        for testCase in cases {
            XCTAssertEqual(
                LexiconNormalizer.normalize(testCase.source),
                testCase.expected,
                "source: \(testCase.source)"
            )
        }
    }

    // MARK: - testNegativeCorpusUnchanged

    /// Real Russian words (or already-correct forms) that share a prefix or
    /// substring with a dictionary key, but must never be touched — this is
    /// exactly the defect class a wildcard/prefix dictionary would introduce.
    /// сонет and пром are deliberately absent from this list: both are
    /// unconditionally converted by the dictionary, so "leave untouched" and
    /// "convert" can't both be tested for the same word — see the dictionary
    /// comments next to those two entries for the accepted-risk rationale.
    func testNegativeCorpusUnchanged() {
        let unchangedWords = [
            "допустим", "комитет", "опустим", "опустить",
            "хендлеры", "хэндовый", "хендовик",
            "скилл", "скиллу", "скиллы",
            "промпт",
            "коммитил", "пушил", "тестировал",
            "handoff",
            "sonnet.md",
            "pipeline",
            "Xcode",
            "2а",
            "дом 5а"
        ]
        for testCaseWord in unchangedWords {
            XCTAssertEqual(
                LexiconNormalizer.normalize(testCaseWord),
                testCaseWord,
                "must survive unchanged: \(testCaseWord)"
            )
        }
    }

    // MARK: - testInvariantTextWithoutDictionaryWordsIsByteIdentical

    func testInvariantTextWithoutDictionaryWordsIsByteIdentical() {
        let plainText = """
        Вчера вечером мы гуляли по набережной и обсуждали планы на следующую неделю. \
        Погода была прохладной, но без дождя, так что прогулка получилась приятной.

        Утром нужно заехать в магазин за продуктами, а после обеда — забрать посылку \
        с почты. Вечером собираемся встретиться с друзьями и посмотреть фильм.
        """
        XCTAssertEqual(LexiconNormalizer.normalize(plainText), plainText)
    }

    // MARK: - testIdempotency

    func testIdempotency() {
        let mixedText = "Кодексом и Клодом мы делаем сонет-агент, хендов уже готов, скилу подтяну."
        let once = LexiconNormalizer.normalize(mixedText)
        let twice = LexiconNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - testIdempotencyOnEveryDictionaryReplacement

    /// Idempotency spot-checked directly on each category's replacement
    /// output, not just on already-normalized input text.
    func testIdempotencyOnEveryDictionaryReplacement() {
        let replacements = [
            "Codex", "Fable", "Grafana", "Opus", "Claude", "iTop", "Redmine",
            "Docker", "Sonnet", "Haiku", "Anthropic", "GitHub", "Twitter",
            "Qwen", "Swarm", "handoff", "Sonnet-агента", "Sonnet-агенты",
            "Sonnet-агент", "Codex-ревью", "Core ML", "скиллу", "коммитим",
            "бэкап", "алерта", "бэкенд", "фронтенд", "промпт"
        ]
        for replacement in replacements {
            XCTAssertEqual(
                LexiconNormalizer.normalize(replacement),
                replacement,
                "already-normalized form must be a fixed point: \(replacement)"
            )
        }
    }

    // MARK: - testProtectedZoneBackticks

    func testProtectedZoneBackticks() {
        let pairedInput = "смотри `кодекс` внимательно"
        XCTAssertEqual(LexiconNormalizer.normalize(pairedInput), pairedInput, "paired backticks protect")

        // An unpaired backtick grants no protection — the dictionary word
        // after it still normalizes.
        let unpairedInput = "смотри `кодекс внимательно"
        XCTAssertEqual(LexiconNormalizer.normalize(unpairedInput), "смотри `Codex внимательно")
    }

    // MARK: - testProtectedZoneQuotes

    func testProtectedZoneQuotes() {
        let pairedASCII = "он сказал \"кодекс\" вчера"
        XCTAssertEqual(LexiconNormalizer.normalize(pairedASCII), pairedASCII, "paired ASCII quotes protect")

        let pairedGuillemets = "он сказал «кодекс» вчера"
        XCTAssertEqual(LexiconNormalizer.normalize(pairedGuillemets), pairedGuillemets, "paired guillemets protect")

        // Unpaired quote grants no protection — word still normalizes. This
        // is the brief's "слово в кавычках (должно нормализоваться)" case.
        let unpairedASCII = "он сказал \"кодекс вчера"
        XCTAssertEqual(LexiconNormalizer.normalize(unpairedASCII), "он сказал \"Codex вчера")
    }

    // MARK: - testProtectedZoneURLAndPath

    func testProtectedZoneURLAndPath() {
        let urlInput = "смотри https://example.com/кодекс за подробностями"
        XCTAssertEqual(LexiconNormalizer.normalize(urlInput), urlInput, "URL-shaped token protects")

        let pathInput = "открой Sources/VoiceType/кодекс.swift сейчас"
        XCTAssertEqual(LexiconNormalizer.normalize(pathInput), pathInput, "path-shaped token protects")

        // Dot between alphanumerics with no slash — same protection.
        XCTAssertEqual(LexiconNormalizer.normalize("файл sonnet.md готов"), "файл sonnet.md готов")
    }
}
