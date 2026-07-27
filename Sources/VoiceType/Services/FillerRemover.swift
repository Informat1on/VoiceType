// FillerRemover.swift — VoiceType
//
// Deletes discourse fillers from dictated Russian, per §10 of
// docs/decisions/2026-07-27-transcript-postprocessing-convention.md.
//
// Deletion is a heavier operation than the dictionary's replacements: a wrong
// replacement leaves a strange word the owner can see and fix, a wrong deletion
// removes something that was said. Every narrowing below was bought with a
// measurement, and the ones that were NOT bought are absent.
//
// What is removed, and what deliberately is not
// ---------------------------------------------
// Only `вот`, `ну`, `короче`. The convention's §10 also lists `типа`,
// `значит`, `как бы` and `э-э`; the deterministic layer refuses them:
//
//   - `значит` is a verb or "therefore" far more often than a particle in this
//     corpus — the words to its left are `это`×6, `есть`×4 ("если у людей есть
//     эта роль в кейклоке, значит они могут"). Deleting it breaks the clause.
//   - `типа` is almost always a preposition or noun here: "одного типа",
//     "группу типа read-only", "что-то типа блок-схем".
//   - `как бы` carries modality — "он будет такие события как бы валидировать"
//     is hedged; removing it asserts. The "ну как бы" collocation that would be
//     safe has zero occurrences in the reference corpus.
//
// Neither `значит` nor `типа` appears in a single annotated filler span, so
// excluding them costs nothing measurable and removes the largest risk.
//
// Five conditions, all required
// -----------------------------
//  1. lowercase — every filler the reference corpus deletes is lowercase, and
//     every sentence-initial one it keeps is capitalized. This also covers the
//     case where whisper dropped a full stop: "…как ты рекомендуешь Вот может
//     у кодекса спросить…" is sentence-initial in fact if not in punctuation.
//  2. not sentence-initial — scanning back, a `.`/`!`/`?`/`…`/`:`/`;` means a
//     new sentence; a letter or digit means mid-sentence; anything else
//     (quotes, brackets, dashes, emoji, whitespace) is skipped. Reaching the
//     start of the text counts as sentence-initial. The reference corpus keeps
//     26 of 26 sentence-initial fillers, so this single condition is what makes
//     the rule agree with the annotation.
//  3. for `вот` — the next word is neither `так` nor `и`: "вот так" (37
//     occurrences) and "вот и" (21) are demonstrative, not filler.
//  4. outside protected zones (backticks, quotes, paths/URLs).
//  5. not part of a hyphenated compound — "вот-вот" is an adverb, and its two
//     halves must not be mistaken for two fillers. ASCII `-`, U+2010 and U+2011
//     all count, because they are visually identical.
//
// Measured on the eval corpus with these rules: 30 of 33 annotated dev spans
// removed, zero firings outside annotated spans in dev. The three misses are
// the price of conditions 3 and 2 and are documented in the plan, not silently
// tuned away.
enum FillerRemover {

    private static let fillers: Set<String> = ["вот", "ну", "короче"]

    /// Words after which `вот` is demonstrative rather than filler.
    private static let stopWordsAfterVot: Set<String> = ["так", "и"]

    /// A newline counts as a boundary too: in a `whisper-cli` dump it is a
    /// segment break and in any other source it is a paragraph or turn break.
    /// The app's own output never contains one (0 of 100 history entries), so
    /// this only matters for corpora — but a filler opening a line is opening
    /// something, and keeping it is the conservative side.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "\u{2026}", ":", ";", "\n"]

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]

    static func remove(_ text: String) -> String {
        removeWithEdits(text).text
    }

    /// The pass with its audit trail; the text is produced by APPLYING the
    /// edits, so the log is the transformation rather than a claim about it.
    static func removeWithEdits(_ text: String) -> (text: String, edits: [TextEdit]) {
        let chars = Array(text)
        guard !chars.isEmpty else { return (text, []) }

        let mask = ProtectedRegions.mask(for: chars)
        var edits: [TextEdit] = []
        var index = 0

        while index < chars.count {
            guard isWordCharacter(chars[index]) else {
                index += 1
                continue
            }

            var end = index
            while end < chars.count && isWordCharacter(chars[end]) { end += 1 }
            let range = index..<end
            let word = String(chars[range])

            if shouldRemove(word: word, at: range, in: chars, mask: mask) {
                // A run of fillers ("ну ну", "ну, короче,") becomes ONE edit.
                // Emitting one edit per word made their seams overlap — the
                // first took the space on its right, the second claimed the
                // same space on its left — which both violated the edit
                // contract and produced "слово ." instead of "слово.".
                // Code review caught it; the fix is to treat the run as the
                // unit it actually is.
                let matchedRanges = run(from: range, in: chars, mask: mask)
                let span = matchedRanges[0].lowerBound..<matchedRanges[matchedRanges.count - 1].upperBound
                let editRange = seamRange(for: span, in: chars)
                edits.append(TextEdit(
                    matchedRanges: matchedRanges,
                    editRange: editRange,
                    original: String(chars[editRange]),
                    replacement: "",
                    rule: .filler(words: matchedRanges.map { String(chars[$0]) })
                ))
                index = editRange.upperBound
                continue
            }

            index = end
        }

        return (TextEdit.apply(edits, to: chars), edits)
    }

    // MARK: - The rule

    private static func shouldRemove(
        word: String,
        at range: Range<Int>,
        in chars: [Character],
        mask: [Bool]
    ) -> Bool {
        guard fillers.contains(word) else { return false }                        // 0. in the list
        guard word == word.lowercased() else { return false }                     // 1. lowercase
        guard !ProtectedRegions.isProtected(range, mask: mask) else { return false } // 4. protected
        guard !isInsideHyphenCompound(range, in: chars) else { return false }     // 5. вот-вот
        guard !isSentenceInitial(range, in: chars) else { return false }          // 2. position

        if word == "вот", let next = nextWord(after: range, in: chars),           // 3. вот так / вот и
           stopWordsAfterVot.contains(next.lowercased()) {
            return false
        }
        return true
    }

    /// Scanning back: a terminator opens a new sentence, a letter or digit means
    /// we are inside one, everything else is transparent. Reaching the start of
    /// the text counts as sentence-initial — which also makes a leading emoji or
    /// quote behave like the start rather than like content, the conservative
    /// choice while no observation says otherwise.
    private static func isSentenceInitial(_ range: Range<Int>, in chars: [Character]) -> Bool {
        var i = range.lowerBound - 1
        while i >= 0 {
            let c = chars[i]
            if sentenceTerminators.contains(c) { return true }
            if isWordCharacter(c) { return false }
            i -= 1
        }
        return true
    }

    private static func nextWord(after range: Range<Int>, in chars: [Character]) -> String? {
        var i = range.upperBound
        while i < chars.count && !isWordCharacter(chars[i]) {
            // A hyphen right after the filler means a compound, not a next word.
            if hyphens.contains(chars[i]) { return nil }
            i += 1
        }
        guard i < chars.count else { return nil }
        var end = i
        while end < chars.count && isWordCharacter(chars[end]) { end += 1 }
        return String(chars[i..<end])
    }

    private static func isInsideHyphenCompound(_ range: Range<Int>, in chars: [Character]) -> Bool {
        if range.lowerBound > 0, hyphens.contains(chars[range.lowerBound - 1]) { return true }
        if range.upperBound < chars.count, hyphens.contains(chars[range.upperBound]) { return true }
        return false
    }

    // MARK: - The seam
    //
    // Four cases, each pinned by a test and each taken from the corpus:
    //
    //   both commas   "чтобы, ну, их"           -> "чтобы их"
    //   right only    "вот, допустим"           -> "допустим"
    //   left only     "Вот понимаешь, вот такую" -> "Вот понимаешь, такую"
    //   neither       "мне вот это"             -> "мне это"
    //
    // The asymmetry between the left-only and right-only cases is the rule the
    // reference corpus actually encodes, and it cost four wrong fixes to learn:
    // a comma on BOTH sides belongs to the filler (it is what sets it off), a
    // comma only on the right belongs to it too (the filler opens the clause),
    // but a lone comma on the LEFT belongs to whatever came before — it follows
    // "понимаешь", not "вот". Removing it there deletes the previous clause's
    // punctuation.
    //
    // The one exception: when the filler ends a sentence, a lone left comma
    // would be stranded against the full stop ("слово, ну." -> "слово,."), so
    // it goes with the filler.
    //
    // Only the seam collapses. Whitespace elsewhere is never touched, so a
    // record with no fillers comes back byte-identical — including the leading
    // space every whisper transcript carries.

    private static func seamRange(for range: Range<Int>, in chars: [Character]) -> Range<Int> {
        let leftComma = commaIndex(before: range, in: chars)
        let rightComma = commaIndex(after: range, in: chars)

        if let left = leftComma, let right = rightComma {
            return left..<(right + 1)
        }
        if let left = leftComma, endsSentence(after: range, in: chars) {
            return left..<range.upperBound
        }
        if let right = rightComma {
            var end = right + 1
            if end < chars.count, chars[end] == " " { end += 1 }
            return range.lowerBound..<end
        }

        // No commas: take one trailing space so no double space is left behind;
        // fall back to a leading one when the filler ends the text.
        if range.upperBound < chars.count, chars[range.upperBound] == " " {
            return range.lowerBound..<(range.upperBound + 1)
        }
        if range.lowerBound > 0, chars[range.lowerBound - 1] == " " {
            return (range.lowerBound - 1)..<range.upperBound
        }
        return range
    }

    /// The run of removable fillers starting at `range`, one range per word.
    /// Words are
    /// joined across spaces and commas only — anything else ends the run, so
    /// "ну и ну" is not a run (the "и" between them is content).
    ///
    /// Each subsequent word must pass the SAME conditions, which is what keeps
    /// "вот вот так" honest: the second `вот` is followed by `так`, fails
    /// condition 3, and the run stops at the first word.
    private static func run(from range: Range<Int>, in chars: [Character], mask: [Bool]) -> [Range<Int>] {
        var ranges = [range]
        var cursor = range.upperBound

        while true {
            var next = cursor
            while next < chars.count, chars[next] == " " || chars[next] == "," { next += 1 }
            guard next < chars.count, isWordCharacter(chars[next]) else { return ranges }

            var wordEnd = next
            while wordEnd < chars.count, isWordCharacter(chars[wordEnd]) { wordEnd += 1 }
            let word = String(chars[next..<wordEnd])
            guard shouldRemove(word: word, at: next..<wordEnd, in: chars, mask: mask) else { return ranges }

            ranges.append(next..<wordEnd)
            cursor = wordEnd
        }
    }

    /// True when the next significant character after the filler ends the
    /// sentence — the case where a lone left comma would be left dangling.
    private static func endsSentence(after range: Range<Int>, in chars: [Character]) -> Bool {
        var i = range.upperBound
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return true }
        return sentenceTerminators.contains(chars[i])
    }

    private static func commaIndex(before range: Range<Int>, in chars: [Character]) -> Int? {
        var i = range.lowerBound - 1
        while i >= 0, chars[i] == " " { i -= 1 }
        return i >= 0 && chars[i] == "," ? i : nil
    }

    private static func commaIndex(after range: Range<Int>, in chars: [Character]) -> Int? {
        var i = range.upperBound
        while i < chars.count, chars[i] == " " { i += 1 }
        return i < chars.count && chars[i] == "," ? i : nil
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
