// CustomVocabularySection.swift — VoiceType
//
// Self-contained Settings UI for Custom Vocabulary (Settings → Advanced).
// Extracted from SettingsView.swift so the explanation/example/counter block
// added below doesn't push that file further past the file_length lint
// threshold — same extraction pattern as HistorySection.swift / DiagnosticsSection.swift.
//
// Owner's framing (2026-07-27, verbatim ask): the field used to be blank
// space with no explanation — no idea what to write, what format, or what
// it actually buys you. A 41-take measurement (4 arms, deterministic control
// arm reproduced 41/41 byte-identical) found the field wasn't just
// under-explained, it was steering users toward the worst format:
//   - comma list ("Codex, Fable, endpoint")  → transcript periods 168→21,
//     commas 364→97 (whisper copies the seed's punctuation style)
//   - same words as full sentences          → periods held at 239,
//     proper-noun accuracy 18/43 vs 2/43 with no prompt at all
// (regressions do exist even in the good arm — 6 already-correct words
// flipped, and some filler words got dropped; the format choice is a net
// win, not a free lunch).
//
// This view explains the mechanism (a hint the decoder is more likely to
// echo, NOT a find-and-replace dictionary — that's an unimplemented,
// separate feature per README.md:112), shows the measured-good format with
// a worked example, and surfaces the 223-token prompt budget so a long list
// doesn't quietly lose its first half.
//
// PromptBudget (Services/PromptBudget.swift) owns tokenizer-accurate
// counting; this view only renders what it returns.

import SwiftUI

/// Plug-in view for the Custom Vocabulary group inside Settings → Advanced.
/// Renders, top to bottom: mechanism explainer, format guidance with a worked
/// example, the vocabulary text editor, and a live token-budget readout with
/// an overflow warning when the text won't fully fit.
struct CustomVocabularySection: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Один снимок на кадр. Раньше здесь стояло вычисляемое свойство, и
        // каждое обращение к нему заново токенизировало весь промпт: около
        // десяти токенизаций на один render, больше при переполнении и в
        // bilingual-режиме — и всё это на каждое нажатие клавиши, потому что
        // AppSettings.customVocabulary сохраняется без дебаунса. Найдено
        // код-ревью.
        let evaluation = PromptBudget.evaluate(seed: seed, vocabulary: settings.customVocabulary)

        // Mechanism explainer — answers the owner's first question before
        // anything else: what IS this field. Deliberately not "prompt
        // engineering" or "tokens" up front — plain mechanism, no jargon.
        Text(
            "This is a hint for the speech recognizer, not a find-and-replace list. "
            + "Whisper reads it right before your recording and becomes more likely to spell "
            + "a word the way it saw it here — there's no guarantee any single word changes."
        )
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.top, Spacing.prefsRowVertical)

        // Format guidance — measured, not a hunch (see file header). A comma
        // list visibly breaks punctuation across the WHOLE transcript, not
        // just around the listed words.
        Text(
            "Write full sentences in the language you dictate in, not a comma-separated list — "
            + "lists strip punctuation from your whole transcript. For example:"
        )
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.top, Spacing.xs)

        Text("\u{201C}\(formatExample)\u{201D}")
            .font(Typography.mono)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.sm)

        TextEditor(text: $settings.customVocabulary)
            .font(Typography.mono)
            .frame(minHeight: 80, maxHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Palette.strokeSubtle, lineWidth: 1)
            )
            .padding(.horizontal, Spacing.prefsRowHorizontal)
            .padding(.bottom, Spacing.prefsRowVertical)

        // Token budget readout. whisper.cpp's initial_prompt hard-caps at
        // PromptBudget.limit tokens; overflow is silently truncated from the
        // START (see overflowWarning below). Seed is computed exactly like
        // TranscriptionService.applyInitialPrompt() so the count matches
        // what whisper will actually see.
        PrefsRow("Prompt budget", subtitle: seedSubtitle(evaluation)) {
            Text(counterText(evaluation))
                .font(Typography.mono)
                .foregroundStyle(evaluation.isOverflowing ? Palette.warning : Palette.textSecondary)
                .accessibilityLabel(counterAccessibilityLabel(evaluation))
        }

        if evaluation.isOverflowing {
            overflowWarning(evaluation)
        }
    }

    // MARK: - PromptBudget wiring

    /// Seed exactly as TranscriptionService.applyInitialPrompt() computes it —
    /// non-empty only in RU+EN bilingual mode (TranscriptionService.swift:246-253).
    private var seed: String {
        settings.language.usesBilingualPrompt ? TranscriptionService.bilingualSeed : ""
    }

    /// The worked example follows the DICTATION language, not the UI language.
    ///
    /// This matters more than it looks. The measurement behind this section
    /// found that the prompt sets the decoder's *style*, not just its lexicon:
    /// a prompt written as a bare list stripped punctuation from the whole
    /// transcript. By the same mechanism, an English-language prompt in front
    /// of Russian speech is a configuration nobody measured — the arms that
    /// scored well (proper nouns 18/43) were Russian sentences carrying Latin
    /// technical terms. Showing an English example to someone dictating in
    /// Russian would quietly steer them into the untested case.
    private var formatExample: String {
        switch settings.language {
        case .en:
            return "I use Codex and Fable daily. I'm setting up the API endpoint and running Ollama locally."
        case .ru, .bilingualRuEn, .auto:
            return "Я работаю с Codex и Fable. Настраиваю API endpoint, поднимаю Ollama локально."
        }
    }

    /// Only shown when the bilingual seed is actually eating into the budget —
    /// no point mentioning a zero-cost seed in EN/RU/AUTO modes.
    private func seedSubtitle(_ evaluation: Evaluation) -> String? {
        guard evaluation.seedTokens > 0 else { return nil }
        return "\(evaluation.seedTokens) of these tokens are already spent on your RU+EN language setup."
    }

    /// PromptBudget.isExact == false means the count is an estimate — shown
    /// with a leading tilde so the number doesn't read as more precise than it is.
    private func counterText(_ evaluation: Evaluation) -> String {
        let prefix = evaluation.isExact ? "" : "~"
        return "\(prefix)\(evaluation.totalTokens) / \(evaluation.limit) tokens"
    }

    private func counterAccessibilityLabel(_ evaluation: Evaluation) -> String {
        let approx = evaluation.isExact ? "" : "approximately "
        var label = "Prompt budget: \(approx)\(evaluation.totalTokens) of \(evaluation.limit) tokens used."
        if evaluation.seedTokens > 0 {
            label += " \(evaluation.seedTokens) of those are used by your language setup."
        }
        return label
    }

    // MARK: - Overflow warning
    // Pattern: EvalEditorView.swift's rotationWarningBanner (icon + caption,
    // Palette.warning text, no boxed card — matches DESIGN.md native-row rule).

    private func overflowWarning(_ evaluation: Evaluation) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text("Over budget by \(evaluation.overflow) tokens. Whisper silently drops the beginning and keeps only the last \(evaluation.limit) tokens — put your most important words at the end.")
                .font(Typography.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.prefsRowHorizontal)
        .padding(.bottom, Spacing.prefsRowVertical)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(overflowAccessibilityLabel(evaluation))
    }

    private func overflowAccessibilityLabel(_ evaluation: Evaluation) -> String {
        "Warning: over the \(evaluation.limit) token budget by \(evaluation.overflow) tokens. "
            + "Whisper drops the beginning of the prompt and keeps only the end."
    }
}
