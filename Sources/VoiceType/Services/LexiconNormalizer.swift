// LexiconNormalizer.swift — VoiceType
//
// Deterministic post-processing pass that fixes a small, closed set of whisper
// mis-transcriptions in the owner's Russian dictation: proper nouns rendered in
// Cyrillic ("кодекс" -> "Codex"), the word "handoff" mangled by "ff" -> "в"/"фф"
// transliteration drift, missing consonant doubling in borrowed words ("скилу" ->
// "скиллу"), э/е drift in borrowings ("бэкэнд" -> "бэкенд"), and the truncated
// "промт" -> "промпт" form. See
// docs/decisions/2026-07-27-transcript-postprocessing-convention.md for the
// target-output contract this implements, and the measurement history (seven
// local LLMs, an ASR-level initial_prompt lever) that ruled out every
// alternative before this dictionary was written.
//
// Why exact word forms, not prefix/wildcard rules
// -------------------------------------------------
// The dictionary below is a flat list of exact lowercase word forms, each
// mapped to one replacement. This is a deliberate, load-bearing constraint —
// an earlier plan proposed prefix rules (хенд*, комит*, опус*) and was
// rejected at plan review because they silently over-generalize:
//
//   - хенд* would turn хендлеры ("handlers", an unrelated English word) into
//     handoff;
//   - комит* would catch комитет ("committee");
//   - опус* would catch опустим/опустить ("let's assume" / "to lower") — and
//     опуст* occurs 4 times in the reference eval corpus, so the regression
//     would show up directly in the metric;
//   - substring replacement (not even prefix-anchored) would turn допустим
//     into дOpusтим — допустим occurs dozens of times in the owner's corpus.
//
// A missed word costs nothing (whisper's mistake just survives); a wrong
// replacement corrupts a sentence silently. When in doubt, the form is left
// out of the dictionary rather than guessed at — see the excluded handoff
// mis-transcriptions below that don't reduce to a regular transliteration
// pattern (хендол, хендолл, хэндол, хэндофу, хэдболф), and the excluded
// derived words that would need grammar changes to substitute (хэндовый,
// хендовик, хендлеры, хэндок, хенд-от). (хендову was initially placed in
// this excluded group too, then moved to the dictionary on review — it
// turned out to be the regular dative case of хендов, not a derived word:
// "по твоему хендову" in the corpus.)
//
// Matching algorithm
// -------------------
// Text is tokenized into maximal runs of word characters (Unicode
// letters/digits) and "other" runs (whitespace, punctuation, hyphens) that
// are always copied verbatim. Multi-word dictionary entries (сонет агенты,
// core ml) and hyphenated composites (кодекс-ревью) are matched as a
// word/separator/word/... sequence anchored at a word token; single-word
// entries are the degenerate one-word case of the same mechanism. For a
// given first word, candidates are tried longest-first (most words consumed
// wins) — this resolves the сонет / сонет-агент / сонет агенты overlap
// correctly: trying the single-word "сонет" entry first would produce
// "Sonnet агенты" instead of "Sonnet-агенты".
//
// Idempotency (normalize(normalize(x)) == normalize(x)) falls out of the
// dictionary's shape rather than needing special-case code: every key is a
// mis-transcription and every replacement is the correct spelling, and no
// replacement's lowercased form is itself a dictionary key.
enum LexiconNormalizer {

    // MARK: - Public API

    static func normalize(_ text: String) -> String {
        normalizeWithEdits(text).text
    }

    /// The same pass, with the audit trail. The text is produced by APPLYING
    /// the edits — there is no second code path that computes it separately, so
    /// the log cannot describe a transformation other than the one that
    /// happened. See TextEdit.swift for the full contract.
    static func normalizeWithEdits(_ text: String) -> (text: String, edits: [TextEdit]) {
        let chars = Array(text)
        guard !chars.isEmpty else { return (text, []) }

        let mask = ProtectedRegions.mask(for: chars)
        let tokens = tokenize(chars)

        var edits: [TextEdit] = []

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard token.kind == .word, !isProtected(token, mask: mask) else {
                i += 1
                continue
            }

            if let replaced = homoglyphReplacement(tokens: tokens, at: i, mask: mask) {
                edits.append(TextEdit(
                    matchedRanges: [token.range],
                    original: token.text,
                    replacement: replaced,
                    rule: .homoglyph
                ))
                i += 1
                continue
            }

            if let (replacement, consumed) = dictionaryMatch(tokens: tokens, at: i, mask: mask) {
                let range = tokens[i].range.lowerBound..<tokens[i + consumed - 1].range.upperBound
                edits.append(TextEdit(
                    matchedRanges: [range],
                    original: String(chars[range]),
                    replacement: replacement,
                    rule: .lexicon(form: String(chars[range]))
                ))
                i += consumed
                continue
            }

            i += 1
        }

        return (TextEdit.apply(edits, to: chars), edits)
    }

    // MARK: - Tokenization

    private enum TokenKind {
        case word
        case other
    }

    private struct Token {
        let text: String
        let kind: TokenKind
        let range: Range<Int>
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = chars.count
        while i < n {
            let start = i
            let isWordRun = isWordCharacter(chars[i])
            while i < n && isWordCharacter(chars[i]) == isWordRun {
                i += 1
            }
            let text = String(chars[start..<i])
            tokens.append(Token(text: text, kind: isWordRun ? .word : .other, range: start..<i))
        }
        return tokens
    }

    // MARK: - Protected zones
    //
    // Backticks, quotes and path/URL-like tokens are never touched — required
    // by the convention's "Неприкосновенные зоны" section even though no such
    // spans exist in the reference eval corpus today (verified: zero
    // backticks, quotes, URLs or paths in it). Absence of fixtures there isn't
    // license to narrow the contract, same reasoning as the homoglyph rule
    // below.
    //
    // The masking itself lives in ProtectedRegions, shared with FillerRemover:
    // two stages rewriting the same text must agree on what is off limits.

    private static func isProtected(_ token: Token, mask: [Bool]) -> Bool {
        ProtectedRegions.isProtected(token.range, mask: mask)
    }

    // MARK: - Homoglyph rule
    //
    // Cyrillic "М" inside a token shaped like "М<digit>", immediately followed
    // by "Pro"/"Max"/"Ultra", is corrected to the Latin lookalike ("М4 Pro" ->
    // "M4 Pro"). Deliberately narrow: a broader "any Cyrillic letter inside a
    // Latin/digit token" rule was rejected at plan review because it would
    // corrupt "2а" (as in "пункт 2а") into "2a". This category is
    // exploratory — one observation total, zero spans in the reference eval
    // corpus — but the fix is trivial and the cost of missing it (a silently
    // broken identifier) is high, so it stays narrow rather than being
    // dropped. Capital Cyrillic М only, matching the convention's wording
    // literally — lowercase "м" is not part of the observed defect.

    private static func homoglyphReplacement(tokens: [Token], at i: Int, mask: [Bool]) -> String? {
        let token = tokens[i]
        let letters = Array(token.text)
        guard letters.count == 2, letters[0] == "\u{041C}", letters[1].isASCII, letters[1].isNumber else {
            return nil
        }
        guard i + 2 < tokens.count else { return nil }

        let separator = tokens[i + 1]
        guard separator.kind == .other,
              !separator.text.isEmpty,
              separator.text.allSatisfy({ $0.isWhitespace }) else {
            return nil
        }

        let next = tokens[i + 2]
        guard next.kind == .word,
              !isProtected(next, mask: mask),
              ["Pro", "Max", "Ultra"].contains(next.text) else {
            return nil
        }

        return "M" + String(letters[1])
    }

    // MARK: - Dictionary matching

    private static func dictionaryMatch(tokens: [Token], at i: Int, mask: [Bool]) -> (String, Int)? {
        let key = tokens[i].text.lowercased()
        guard let candidates = entriesByFirstWord[key] else { return nil }

        for entry in candidates {
            guard let consumed = matchLength(entry, tokens: tokens, at: i, mask: mask) else { continue }
            guard !isInsideUnlistedHyphenCompound(tokens: tokens, start: i, consumed: consumed) else {
                // The dictionary is a closed list of exact surface forms, and
                // a hyphen compound is its own surface form: `кодекс-ревью`
                // and `опус-агенты` are listed explicitly. Letting a
                // single-word entry fire inside an unlisted compound makes the
                // dictionary generative, which is the behaviour the design
                // deliberately rejects — it turned `Клод-код` (whose target is
                // the product name `Claude Code`) into `Claude-код`, a wrong
                // fix rather than an honest miss. Misses are cheap here;
                // wrong fixes are not.
                return nil
            }
            guard let replacement = replacementText(for: entry, sourceToken: tokens[i]) else {
                // Entry's key matched, but its case-adapting policy declined
                // (mixed-case source) — per convention this means "leave
                // untouched", not "try a shorter candidate".
                return nil
            }
            return (replacement, consumed)
        }
        return nil
    }

    /// True when the token range [start, start+consumed) is glued by a bare
    /// hyphen to an adjacent word, i.e. it is one component of a larger
    /// compound that the dictionary does not list as a whole.
    ///
    /// Only a bare "-" counts: an "other" token of exactly "-" means no spaces
    /// around it, so a spaced dash ("слово — слово") is unaffected. Longest
    /// match wins first, so listed compounds (`сонет-агент`, `кодекс-ревью`)
    /// have already matched by the time this check runs.
    private static func isInsideUnlistedHyphenCompound(
        tokens: [Token], start: Int, consumed: Int
    ) -> Bool {
        // U+2010 HYPHEN and U+2011 NON-BREAKING HYPHEN look identical to the
        // ASCII "-" but are distinct scalars. Listed compounds in the
        // dictionary use ASCII, so a Unicode-hyphen compound never matches as
        // a whole — without them here it would fall through to the
        // single-word entry, which is the exact wrong fix this guard exists to
        // prevent.
        let hyphens: Set<String> = ["-", "\u{2010}", "\u{2011}"]

        func isGluedHyphen(_ index: Int) -> Bool {
            guard index >= 0, index < tokens.count else { return false }
            return tokens[index].kind == .other && hyphens.contains(tokens[index].text)
        }
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < tokens.count else { return false }
            return tokens[index].kind == .word
        }

        let after = start + consumed
        if isGluedHyphen(after) && isWord(after + 1) { return true }
        if isGluedHyphen(start - 1) && isWord(start - 2) { return true }
        return false
    }

    /// Returns the number of tokens consumed by `entry` starting at index `i`
    /// in `tokens`, or nil if the token stream doesn't match the entry's
    /// word/separator/word/... shape from this position.
    private static func matchLength(_ entry: Entry, tokens: [Token], at i: Int, mask: [Bool]) -> Int? {
        var tokenIndex = i + 1
        for wordIndex in 1..<entry.words.count {
            guard tokenIndex < tokens.count else { return nil }
            let separatorToken = tokens[tokenIndex]
            guard separatorToken.kind == .other,
                  !isProtected(separatorToken, mask: mask),
                  separatorToken.text == entry.separators[wordIndex - 1] else {
                return nil
            }
            tokenIndex += 1

            guard tokenIndex < tokens.count else { return nil }
            let wordToken = tokens[tokenIndex]
            guard wordToken.kind == .word,
                  !isProtected(wordToken, mask: mask),
                  wordToken.text.lowercased() == entry.words[wordIndex] else {
                return nil
            }
            tokenIndex += 1
        }
        return tokenIndex - i
    }

    // MARK: - Case handling

    private enum CaseClass {
        case lower
        case title
        case upper
        case mixed
    }

    private static func caseClass(of token: String) -> CaseClass {
        let letters = token.filter { $0.isLetter }
        guard !letters.isEmpty else { return .mixed }
        if letters.allSatisfy({ $0.isLowercase }) { return .lower }
        if letters.allSatisfy({ $0.isUppercase }) { return .upper }
        if let first = token.first, first.isUppercase {
            let restLetters = token.dropFirst().filter { $0.isLetter }
            if restLetters.allSatisfy({ $0.isLowercase }) { return .title }
        }
        return .mixed
    }

    /// The replacement text for `entry` given the casing of `sourceToken`, or
    /// nil if the entry's policy declines to replace (case-adapting entries
    /// leave mixed-case source untouched rather than guess at intent).
    private static func replacementText(for entry: Entry, sourceToken: Token) -> String? {
        switch entry.policy {
        case .canonical:
            // Proper nouns and handoff: the source's casing is ignored
            // entirely (Клод, КЛОД, клод all -> Claude), per convention's
            // explicit exception to the lower/Title/UPPER rule below.
            return entry.replacement
        case .caseAdapting:
            switch caseClass(of: sourceToken.text) {
            case .lower:
                return entry.replacement
            case .upper:
                return entry.replacement.uppercased()
            case .title:
                return entry.replacement.prefix(1).uppercased() + entry.replacement.dropFirst()
            case .mixed:
                return nil
            }
        }
    }

    // MARK: - Dictionary model

    private enum ReplacementPolicy {
        /// Output is always the entry's replacement text verbatim, regardless
        /// of the source token's casing. Used for proper nouns and handoff,
        /// which have one canonical spelling independent of what casing
        /// whisper guessed at.
        case canonical
        /// Output adapts to the source token's casing class (lower/Title/
        /// UPPER); mixed case is left untouched. Used for ordinary Russian
        /// words (doubling, э/е, промт) where casing is just grammar, not
        /// part of the word's identity.
        case caseAdapting
    }

    private struct Entry {
        /// Lowercased word components of the key, in order. Single-word
        /// entries have exactly one element; composite entries (space- or
        /// hyphen-joined) have more.
        let words: [String]
        /// Literal separator text expected between words[n] and words[n+1].
        /// Always words.count - 1 elements.
        let separators: [String]
        let replacement: String
        let policy: ReplacementPolicy
    }

    private static func word(_ form: String, _ replacement: String, _ policy: ReplacementPolicy) -> Entry {
        Entry(words: [form.lowercased()], separators: [], replacement: replacement, policy: policy)
    }

    private static func composite(_ forms: [String], separators: [String], _ replacement: String) -> Entry {
        Entry(words: forms.map { $0.lowercased() }, separators: separators, replacement: replacement, policy: .canonical)
    }

    /// One `.canonical` entry per inflected form sharing a single
    /// replacement — the common shape for proper nouns and handoff, where
    /// every case ending of a lemma maps to the same fixed spelling.
    private static func lemma(_ forms: [String], _ replacement: String) -> [Entry] {
        forms.map { word($0, replacement, .canonical) }
    }

    /// One `.caseAdapting` entry per (form, replacement) pair — used where
    /// the fix is per-word rather than a lemma sharing one replacement
    /// (doubling, э/е, промт groups).
    private static func pairs(_ forms: [(String, String)]) -> [Entry] {
        forms.map { word($0.0, $0.1, .caseAdapting) }
    }

    /// Hyphenated `stem-suffix` composites that all collapse to the same
    /// replacement — used for the handoff хенд-/хэнд- families.
    private static func hyphenLemma(_ stem: String, _ suffixes: [String], _ replacement: String) -> [Entry] {
        suffixes.map { composite([stem, $0], separators: ["-"], replacement) }
    }

    // MARK: - Dictionary data
    //
    // Source of truth: dictionary-vetted.md (task brief attachment), derived
    // from the owner's 1096-recording corpus plus the reference eval corpus's
    // dev split. Every form here is transcribed verbatim from that file — no
    // form was added or guessed at; the eval corpus's holdout split was never
    // read, and extending this list from intuition would invalidate that
    // measurement.

    private static let properNounEntries: [Entry] =
        // Codex — "кодекс" is also a real Russian word ("code of laws"), so a
        // false positive is grammatically possible. Included anyway: all 239
        // corpus occurrences of кодекс* are the tool, none the legal sense.
        lemma(
            ["кодекс", "кодекса", "кодексу", "кодексом", "кодексе", "кодексы", "кодексов", "кодексам", "кодексами"],
            "Codex"
        ) +
        lemma(["фейбл", "фейбла", "фейблу", "фейблом", "фейбле"], "Fable") +
        lemma(["графана", "графаны", "графане", "графану", "графаной"], "Grafana") +
        // Opus — also a real Russian word ("a musical/literary work"). Same
        // reasoning as кодекс above: all 8 corpus occurrences are the model.
        lemma(["опус", "опуса", "опусу", "опусом", "опусе", "опусы", "опусов"], "Opus") +
        lemma(["клод", "клода", "клоду", "клодом", "клоде"], "Claude") +
        lemma(["айтоп", "айтопа", "айтопу", "айтопе", "айтопом"], "iTop") +
        lemma(["редмайн", "редмайна", "редмайну", "редмайне", "редмайном"], "Redmine") +
        lemma(["докер", "докера", "докеру", "докером", "докере"], "Docker") +
        // Sonnet — also a real Russian word (a poetic form). Corpus's only
        // occurrence is inside the glued composite "сонетагента" below —
        // no standalone poetic-sense usage.
        lemma(["сонет", "сонета", "сонету", "сонетом", "сонете"], "Sonnet") +
        lemma(["хайку"], "Haiku") +
        lemma(["антропик", "антропика", "антропику", "антропики", "антропиком"], "Anthropic") +
        lemma(["гитхаб", "гитхаба", "гитхабе", "гитхабу"], "GitHub") +
        lemma(["твиттер", "твиттера", "твиттере"], "Twitter") +
        lemma(["квен", "квена", "квены"], "Qwen") +
        lemma(["сворм", "сворма"], "Swarm")

    // "ff" reliably degrades to "в"/"фф" in the owner's speech, so these
    // forms don't reduce to a morphological rule — each is listed explicitly.
    // The 5 excluded mis-transcriptions (хендол, хендолл, хэндол, хэндофу,
    // хэдболф) don't reduce to a regular transliteration pattern and are
    // one-off ASR errors, not handoff forms — including them would be
    // guessing, which the convention's "Чего постобработка НЕ делает"
    // section explicitly forbids. хендову is the regular dative case of
    // хендов ("по твоему хендову") — added on review, distinct from the
    // still-excluded derived noun хендовик.
    private static let handoffEntries: [Entry] =
        lemma(
            ["хендов", "хендову", "хэндов", "хендофф", "хендоффа", "хендоффов", "хендоффы", "хендоффе"],
            "handoff"
        ) +
        hyphenLemma("хенд", ["офф", "оффа", "оффу", "оффе", "оффом", "оффы", "оффов", "оффах", "оффами"], "handoff") +
        hyphenLemma("хэнд", ["офф", "оффа", "оффе", "оффом", "оффов", "оффах"], "handoff") +
        // Latin form found in the eval corpus's dev spans — whisper
        // sometimes gets the word right but not the spelling convention.
        [composite(["hand", "off"], separators: ["-"], "handoff")]

    private static let compositeEntries: [Entry] = [
        // Glued with no separator at all — a distinct token from "сонет".
        word("сонетагента", "Sonnet-агента", .canonical),
        composite(["сонет", "агенты"], separators: [" "], "Sonnet-агенты"),
        composite(["сонет", "агент"], separators: ["-"], "Sonnet-агент"),
        composite(["сонет", "агентов"], separators: ["-"], "Sonnet-агентов"),
        composite(["сонет", "агенты"], separators: ["-"], "Sonnet-агенты"),
        composite(["кодекс", "ревью"], separators: ["-"], "Codex-ревью"),
        composite(["кодекс", "проверками"], separators: ["-"], "Codex-проверками"),
        composite(["кодекс", "ревьювером"], separators: ["-"], "Codex-ревьювером"),
        composite(["опус", "агенты"], separators: ["-"], "Opus-агенты"),
        composite(["core", "ml"], separators: [" "], "Core ML")
    ]

    // Rule is "normalize to the canonical spelling", not "always double" —
    // аллерта -> алерта removes a doubling, it doesn't add one.
    private static let doublingEntries: [Entry] = pairs([
        ("скилу", "скиллу"), ("скилом", "скиллом"), ("скилов", "скиллов"),
        ("скилы", "скиллы"), ("скиле", "скилле"),
        ("комит", "коммит"), ("комита", "коммита"), ("комите", "коммите"),
        ("комитов", "коммитов"), ("комить", "коммить"), ("комитим", "коммитим"),
        ("комиттим", "коммитим"), ("комитешь", "коммитишь"),
        ("закомить", "закоммитить"), ("закомитить", "закоммитить"), ("закомитим", "закоммитим"),
        ("бекап", "бэкап"), ("аллерта", "алерта"), ("колеги", "коллеги"), ("паралелльно", "параллельно")
    ])

    private static let eScriptEntries: [Entry] = pairs([
        ("бэкэнд", "бэкенд"), ("бэкэнда", "бэкенда"), ("бэкэнду", "бэкенду"),
        ("бэкэнде", "бэкенде"), ("бэкэндом", "бэкендом"),
        ("фронтэнд", "фронтенд"), ("фронтэнда", "фронтенда"), ("фронтэнду", "фронтенду"), ("фронтэнде", "фронтенде")
    ])

    private static let promptEntries: [Entry] = pairs([
        ("промт", "промпт"), ("промта", "промпта"), ("промту", "промпту"),
        ("промтом", "промптом"), ("промте", "промпте"), ("промты", "промпты"), ("промтов", "промптов")
    ]) + [
        // "пром" — a 3-letter truncated form, the shortest and riskiest key
        // in this dictionary. Mapped unconditionally to "промпт": measured
        // on the owner's corpus, all 5 occurrences mean "prompt". This
        // creates an irreconcilable conflict with "выкатить на пром"
        // (release-environment slang) — an exact, context-free dictionary
        // cannot satisfy both readings at once. Accepted risk, not an
        // oversight; see dictionary-vetted.md "Спорные решения".
        word("пром", "промпт", .caseAdapting)
    ]

    private static let allEntries: [Entry] =
        properNounEntries + handoffEntries + compositeEntries + doublingEntries + eScriptEntries + promptEntries

    /// Indexed by the lowercased first word, sorted longest-entry-first so
    /// dictionaryMatch's linear scan implements maximal munch without extra
    /// bookkeeping at the call site.
    private static let entriesByFirstWord: [String: [Entry]] = {
        var index: [String: [Entry]] = [:]
        for entry in allEntries {
            index[entry.words[0], default: []].append(entry)
        }
        for key in index.keys {
            index[key]?.sort { $0.words.count > $1.words.count }
        }
        return index
    }()
}
