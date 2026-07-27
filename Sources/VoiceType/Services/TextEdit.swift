// TextEdit.swift — VoiceType
//
// The post-processing pipeline's audit trail: what each stage changed, where,
// and under which rule.
//
// Why this exists
// ---------------
// The eval metric (scripts/categorized-eval.py) compares multisets of surface
// forms, not positions — it says so itself. For replacements that is tolerable,
// because the surfaces are rare. For deletions it is a qualitative defect: a
// record can contain eight occurrences of "вот", and deleting the wrong one
// while keeping the annotated one scores as a success. Reconstructing positions
// by diffing the output is possible but pointless: the pipeline already knows
// exactly what it did.
//
// Why the log cannot lie
// ----------------------
// A log that merely *agrees* with the output proves nothing — a single edit
// replacing the whole input with the whole output would satisfy that. So the
// contract is stricter, and every clause is checked by `validate(against:)`:
//
//   1. `original` equals the input slice at `editRange` — the edit describes
//      real input, not an invention;
//   2. edits are sorted and non-overlapping — they compose into one pass;
//   3. `matchedRange` (the exact token the rule fired on) is contained in
//      `editRange` (which may also swallow a comma and the whitespace seam),
//      so the metric can align on the token rather than on punctuation;
//   4. the stage's output is produced BY APPLYING the edits, never computed
//      alongside them. `apply(_:to:)` is the only writer.
//
// Offsets are in Characters (extended grapheme clusters) of that stage's own
// input, matching how the tokenizers index text. The eval corpus annotates
// spans in Unicode code points; `codePointOffsets(in:)` converts at the audit
// boundary rather than making every stage carry two coordinate systems.
//
// Each stage logs against ITS OWN input, which is why the pipeline returns
// `[StageEdits]` in execution order rather than one flat array: filler offsets
// are relative to the text before the dictionary ran, lexicon offsets to the
// text after. Flattening them would produce ranges that cannot be applied or
// compared together — the second defect plan review caught.
struct TextEdit: Equatable {

    /// Which rule fired. An enum rather than a string so a typo cannot silently
    /// create a new category that the audit then ignores.
    enum Rule: Equatable {
        /// Dictionary entry, carrying the matched source form.
        case lexicon(form: String)
        /// Filler word removal, carrying the removed word in canonical form.
        case filler(word: String)
        /// Cyrillic lookalike inside a Latin identifier.
        case homoglyph
    }

    /// The exact token the rule matched, in Characters of the stage input.
    /// The metric aligns on this, not on `editRange`.
    let matchedRange: Range<Int>

    /// What is actually replaced, including any comma and whitespace the rule
    /// absorbs. Equals `matchedRange` when the rule takes nothing extra.
    let editRange: Range<Int>

    /// The stage input's own text at `editRange`.
    let original: String

    /// Replacement text; empty for a deletion.
    let replacement: String

    let rule: Rule

    init(
        matchedRange: Range<Int>,
        editRange: Range<Int>? = nil,
        original: String,
        replacement: String,
        rule: Rule
    ) {
        self.matchedRange = matchedRange
        self.editRange = editRange ?? matchedRange
        self.original = original
        self.replacement = replacement
        self.rule = rule
    }
}

/// One stage's edits, in that stage's own coordinate system.
struct StageEdits: Equatable {
    enum Stage: String, Equatable {
        case fillers
        case lexicon
    }

    let stage: Stage
    let edits: [TextEdit]
}

extension TextEdit {

    /// Applies edits to `input`. This is the ONLY way a stage produces its
    /// output, which is what makes the log an account of the transformation
    /// rather than a claim about it.
    ///
    /// Precondition: edits are sorted by `editRange.lowerBound` and do not
    /// overlap — guaranteed by construction (each stage walks the text once,
    /// left to right) and asserted by `validate(against:)` in tests.
    static func apply(_ edits: [TextEdit], to input: [Character]) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var cursor = 0

        for edit in edits {
            if edit.editRange.lowerBound > cursor {
                output += String(input[cursor..<edit.editRange.lowerBound])
            }
            output += edit.replacement
            cursor = max(cursor, edit.editRange.upperBound)
        }

        if cursor < input.count {
            output += String(input[cursor...])
        }
        return output
    }

    /// Every clause of the contract above, as a list of violations. Empty means
    /// the log is trustworthy. Used by tests; cheap enough to call on a corpus.
    static func validate(_ edits: [TextEdit], against input: [Character]) -> [String] {
        var problems: [String] = []
        var previousEnd = -1

        for (i, edit) in edits.enumerated() {
            guard edit.editRange.lowerBound >= 0, edit.editRange.upperBound <= input.count else {
                problems.append("edit \(i): editRange \(edit.editRange) out of bounds (input \(input.count))")
                continue
            }
            guard edit.matchedRange.lowerBound >= edit.editRange.lowerBound,
                  edit.matchedRange.upperBound <= edit.editRange.upperBound else {
                problems.append("edit \(i): matchedRange \(edit.matchedRange) not inside editRange \(edit.editRange)")
                continue
            }
            let slice = String(input[edit.editRange])
            if slice != edit.original {
                problems.append("edit \(i): original \(edit.original.debugDescription) != input slice \(slice.debugDescription)")
            }
            if edit.editRange.lowerBound < previousEnd {
                problems.append("edit \(i): overlaps or precedes the previous edit")
            }
            previousEnd = edit.editRange.upperBound
        }
        return problems
    }

    /// Character offsets → Unicode code point offsets, the coordinate system
    /// the eval corpus annotates spans in (`Tests/Fixtures/eval-ru/schema.json`).
    /// Identical for plain Cyrillic and Latin text; they diverge on emoji and
    /// combining marks, which is exactly when a silent mismatch would be
    /// hardest to notice.
    static func codePointOffsets(for range: Range<Int>, in input: [Character]) -> Range<Int> {
        func scalars(upTo index: Int) -> Int {
            input[0..<index].reduce(0) { $0 + $1.unicodeScalars.count }
        }
        let lower = scalars(upTo: range.lowerBound)
        let upper = lower + input[range].reduce(0) { $0 + $1.unicodeScalars.count }
        return lower..<upper
    }
}
