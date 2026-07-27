// ProtectedRegions.swift — VoiceType
//
// The "Неприкосновенные зоны" clause of the post-processing convention, shared
// by every stage of the pipeline that rewrites transcript text.
//
// Extracted from LexiconNormalizer when FillerRemover needed the same rule.
// Duplicating it would have meant two protections drifting apart at the first
// edit — and a quoted fragment that one stage respects while another rewrites
// it is worse than no protection at all, because the inconsistency is invisible
// until it corrupts something.
//
// The contract is a per-character mask rather than a list of ranges: callers
// tokenize differently (the normalizer works on word/separator runs, the filler
// remover on whole words), and a mask lets each one ask the only question that
// matters — "does any character of this token fall inside a protected zone?" —
// without agreeing on a token type first.
//
// Protection is deliberately conservative about unpaired delimiters: an opening
// backtick or quote with no closer grants nothing. The convention says as much,
// and the alternative (protect to end of text) would silently disable
// post-processing for the rest of a record because of one stray character.
enum ProtectedRegions {

    /// A `true` at index `i` means `chars[i]` is inside a protected zone and
    /// must not be rewritten by any stage.
    static func mask(for chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        markPairedDelimiter(chars, delimiter: "`", mask: &mask)
        markPairedDelimiter(chars, delimiter: "\"", mask: &mask)
        markPairedGuillemets(chars, mask: &mask)
        markPathLikeTokens(chars, mask: &mask)
        return mask
    }

    /// True when any character of `range` is protected. Any overlap
    /// disqualifies the whole token — a partially protected token is still a
    /// token the stage must leave alone.
    static func isProtected(_ range: Range<Int>, mask: [Bool]) -> Bool {
        mask[range].contains(true)
    }

    /// Pairs same-character delimiters sequentially (1st+2nd, 3rd+4th, ...). A
    /// trailing unpaired delimiter grants no protection, per convention.
    private static func markPairedDelimiter(_ chars: [Character], delimiter: Character, mask: inout [Bool]) {
        var positions: [Int] = []
        for (idx, c) in chars.enumerated() where c == delimiter {
            positions.append(idx)
        }
        var i = 0
        while i + 1 < positions.count {
            let start = positions[i]
            let end = positions[i + 1]
            for j in start...end { mask[j] = true }
            i += 2
        }
    }

    /// Guillemets have distinct open/close characters, so pairing is
    /// stack-based rather than sequential; an unmatched "«" or a stray "»"
    /// grants no protection.
    private static func markPairedGuillemets(_ chars: [Character], mask: inout [Bool]) {
        var stack: [Int] = []
        for (idx, c) in chars.enumerated() {
            if c == "\u{00AB}" {
                stack.append(idx)
            } else if c == "\u{00BB}", let start = stack.popLast() {
                for j in start...idx { mask[j] = true }
            }
        }
    }

    /// A whitespace-delimited chunk containing "/" or a "." between two
    /// alphanumeric characters is treated as a path or URL and left untouched
    /// in full (sonnet.md, example.com, path/to/file).
    private static func markPathLikeTokens(_ chars: [Character], mask: inout [Bool]) {
        var i = 0
        let n = chars.count
        while i < n {
            while i < n && chars[i].isWhitespace { i += 1 }
            let start = i
            while i < n && !chars[i].isWhitespace { i += 1 }
            let end = i
            if end > start, isPathLike(chars, start, end) {
                for j in start..<end { mask[j] = true }
            }
        }
    }

    private static func isPathLike(_ chars: [Character], _ start: Int, _ end: Int) -> Bool {
        for j in start..<end {
            if chars[j] == "/" { return true }
            if chars[j] == ".", j > start, j + 1 < end {
                let prev = chars[j - 1]
                let next = chars[j + 1]
                if (prev.isLetter || prev.isNumber) && (next.isLetter || next.isNumber) {
                    return true
                }
            }
        }
        return false
    }
}
