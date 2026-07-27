// PromptBudget.swift — VoiceType
//
// Pure prompt-budget math for whisper's `initial_prompt`, backing the token
// counter on Settings > Advanced > Custom vocabulary (see
// Views/Settings/CustomVocabularySection.swift, which owns rendering only —
// this file owns every fact and every number). Every constant here is a fact
// read out of whisper.cpp v1.9.1 (SwiftWhisper fork), not derived — do not
// "simplify" the numbers without re-checking the source lines below.
//
// - Limit is 223 tokens, not 224. `max_prompt_ctx = min(n_max_text_ctx,
//   n_text_ctx/2) = 224` (whisper.cpp:6926), but with `carry_initial_prompt
//   == false` (VoiceType's mode — never toggled) the prompt lands in
//   `prompt_past1`, and whisper.cpp:7127 takes
//   `min(max_prompt_ctx - n_take0 - 1, …)` = 223.
// - The truncation is silent for us: `WHISPER_LOG_WARN("initial prompt is
//   too long")` (whisper.cpp:6946) only fires in the `carry_initial_prompt
//   == true` branch, which VoiceType never exercises. Nothing reaches the
//   log.
// - The SUFFIX survives — whisper keeps the *last* 223 tokens and drops the
//   front of the prompt, not the other way around.
// - `no_context` defaults to `true` (whisper.cpp:5939) and VoiceType never
//   changes it, so the budget is never shared with segment history — all 223
//   slots are available to `initial_prompt`.
import Foundation

enum PromptBudget {

    /// Real ceiling whisper.cpp leaves for `initial_prompt` tokens in
    /// VoiceType's configuration. See header comment for the derivation.
    static let limit = 223

    /// Builds the exact string `TranscriptionService.applyInitialPrompt()`
    /// hands to whisper — the single source of truth both share, so the
    /// on-screen counter can never drift from what's actually sent.
    static func fullPrompt(seed: String, vocabulary: String) -> String {
        [seed, vocabulary].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// Evaluates the Custom vocabulary field's state for the Settings UI.
    static func evaluate(seed: String, vocabulary: String) -> Evaluation {
        let tokenizer = WhisperTokenizer.shared
        let combined = fullPrompt(seed: seed, vocabulary: vocabulary)
        return Evaluation(
            totalTokens: tokenizer.count(combined),
            seedTokens: seed.isEmpty ? 0 : tokenizer.count(seed),
            limit: limit,
            isExact: tokenizer.isReady
        )
    }
}

/// Token-budget snapshot for the Custom vocabulary field.
struct Evaluation {
    /// Whole prompt as whisper will see it: seed + separator + vocabulary.
    let totalTokens: Int
    /// How much of the budget the invisible bilingual seed eats on its own —
    /// shown so the user understands why their own text has less room than
    /// the raw 223 might suggest.
    let seedTokens: Int
    /// `PromptBudget.limit`, carried along so the UI doesn't need a second import.
    let limit: Int
    /// `false` when the vocabulary resource failed to load and `totalTokens`
    /// is `WhisperTokenizer`'s conservative byte-count estimate rather than a
    /// real token count — the UI should render this with a tilde.
    let isExact: Bool

    var overflow: Int { max(0, totalTokens - limit) }
    var isOverflowing: Bool { overflow > 0 }
}
