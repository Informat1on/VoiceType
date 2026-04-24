# RU+EN bilingual language mode

- Status: ACCEPTED
- Date: 2026-04-24
- Related decisions: D1, D5, D10 (v1.1 /plan-eng-review, commit `ee23166`)
- Related spike: [2026-04-25-initial-prompt-plumbing.md](./2026-04-25-initial-prompt-plumbing.md)

## Context

VoiceType supports voice typing in multiple languages via whisper.cpp. Russian and
English speakers routinely code-switch mid-utterance — tool names, API identifiers,
library imports, error messages, client names, brand terms are usually English inside
Russian sentences ("запушь этот commit в main", "проверь auth middleware в handler").

The current implementation stores the language as a raw `String` on `AppSettings.preferredLanguage`,
with `"auto"` as the canonical value for language auto-detection
(`Sources/VoiceType/Models/AppSettings.swift:154`). `TranscriptionService` normalizes
it and calls `WhisperLanguage(rawValue: language) ?? .auto`
(`Sources/VoiceType/Services/TranscriptionService.swift:74`), silently falling back
to `.auto` on any unknown input.

Real-world observation during Week 0 validation: whisper.cpp's `language=auto` on
code-switching Russian/English utterances reliably picks `en` and mangles the Russian
segments (transliterates "как дела" as garbage, drops Cyrillic entirely). Setting
`language=ru` and feeding a bilingual `initial_prompt` that seeds both scripts produces
clean RU+EN output.

Two problems fall out of this:

1. **Auto is the wrong default for bilingual speakers.** We need a dedicated
   "Bilingual RU+EN" preset that pins the decoder to Russian and steers it with a
   bilingual prompt.
2. **Raw-string `preferredLanguage` silently degrades on unknown values.** Any typo
   in `UserDefaults`, any future rename, any refactor that drops a case — and the
   user gets `.auto` with no warning. For a feature that directly affects
   transcription quality, silent degradation is a severity-2 bug waiting to happen.

## Decision

### 1. Introduce a typed `Language` enum

Replace `AppSettings.preferredLanguage: String` with:

```swift
enum Language: String, Codable, CaseIterable {
    case auto
    case ru
    case en
    case bilingualRuEn = "ru-en"
    // ... other single-language cases as needed
}
```

Raw values are stable identifiers persisted to `UserDefaults`. Compile-time switches
over `Language` replace runtime `rawValue` comparisons. Unknown raw values at load
time fall back to `.auto` **explicitly and loudly** (logged via `AppLog`), not silently.

### 2. Map `Language` to whisper.cpp params via computed properties

```swift
extension Language {
    var whisperLanguage: WhisperLanguage? {
        switch self {
        case .auto:          return nil            // nil => detect_language = true
        case .ru:            return .russian
        case .en:            return .english
        case .bilingualRuEn: return .russian       // PIN to ru, do NOT auto-detect
        }
    }

    var usesBilingualPrompt: Bool {
        switch self {
        case .bilingualRuEn: return true
        default:             return false
        }
    }
}
```

Both properties MUST be exhaustive switches (no `default:` clause). Adding a new
`Language` case produces a compiler error at every mapping site, which is exactly
the guardrail this ADR is buying.

### 3. `bilingualRuEn` = `language=ru` + bilingual `initial_prompt`

When `AppSettings.language == .bilingualRuEn`, the runtime does two things:

- `whisper.params.language = .russian` and `whisper.params.detect_language = false`.
- `TranscriptionService.setInitialPrompt(_:)` is called with the bilingual seed
  text, allocated via `strdup` per the lifetime rules documented in the
  [initial-prompt-plumbing spike](./2026-04-25-initial-prompt-plumbing.md).

Crucially, the initial prompt MUST be re-applied after every `loadModel(...)`: the
`WhisperParams` object is replaced when the model reloads, and `initial_prompt` is
a raw `UnsafePointer<CChar>?` that does not survive the swap. Forgetting this means
the user's vocabulary silently evaporates on model change.

### 4. `bilingualRuEn` never silently degrades to `.auto`

Any code that translates a `Language` to whisper.cpp params uses an exhaustive
`switch` over the enum. The sequence
`WhisperLanguage(rawValue: someString) ?? .auto` is banned in the settings-to-runtime
path. If a downstream component needs string interop (legacy migration, telemetry,
logs), the conversion lives in a single documented adapter that logs on unknown
input rather than swallowing it.

## Consequences

**Unlocks:**

- A dedicated "Bilingual RU+EN" preset in Settings that actually works on code-switching
  utterances (the primary validation-gate user story for this developer audience).
- Compile-time safety for every future `Language` addition. Adding Spanish or German
  later means the compiler walks us through every site that needs updating.
- A clean extension point for the Custom Vocabulary textarea (Track 2 W1 Step 0b):
  the bilingual seed prompt for `bilingualRuEn` lives alongside the user's
  custom additions in the same `initial_prompt` pipeline.

**Requires:**

- **Migration of existing `UserDefaults`** from the raw-string key `"preferredLanguage"`
  to a `Language` rawValue. Migration strategy: on first launch post-upgrade, read
  the old string, map known values (`"auto"` → `.auto`, `"ru"` → `.ru`, `"en"` → `.en`)
  to `Language`, default unknown to `.auto` **with a logged warning**, persist under
  the new key, delete the old key. Covered by a unit test on the migration path.
- **Re-application of `initial_prompt` in `TranscriptionService.loadModel(...)`.**
  If a future change to `loadModel` forgets to re-apply the prompt, silent loss.
  Covered by `TranscriptionServiceInitialPromptTests` verifying the prompt survives
  a model reload.
- **Exhaustive switches everywhere `Language` is read.** No `default:` clauses that
  mask new cases. Caught by design review and (post Tier A) by SwiftLint.

**Blocks:**

- The raw-string `WhisperLanguage(rawValue:) ?? .auto` pattern in
  `TranscriptionService.whisperLanguage(for:)`. To be deleted as part of
  Track 2 W1 Step 0a.

## Alternatives considered

### A. Keep `preferredLanguage: String`, add `"ru-en"` as a magic string

Cheapest change — one string literal handled as a new branch in
`TranscriptionService.whisperLanguage(for:)`. Rejected because it preserves exactly
the silent-degradation mechanism this ADR exists to remove. Any typo or refactor
still routes to `.auto` without a log line. Severity-2 bug risk unchanged.

### B. `language=auto` + bilingual prompt for every RU+EN case

Rely on whisper.cpp's auto-detect but feed it a strong bilingual prompt and hope
it picks `ru` correctly. Rejected after Week 0 validation showed auto-detect
preferring `en` on even mildly English-heavy code-switched speech. The bilingual
prompt does not override language selection inside whisper.cpp — it seeds the
decoder AFTER language is chosen. Relying on this is relying on a heuristic
we already observed failing.

### C. Two separate settings: `language: Language` + `useBilingualPrompt: Bool`

Full orthogonality. User picks `.ru` and independently toggles "enable bilingual
prompt". Rejected because it surfaces an implementation detail that the user does
not care about (and cannot reason about without reading our ADRs). The user wants
"my Russian + English voice typing works." The bilingual mode is one preset that
encodes both settings correctly; the user does not need to understand the two
knobs behind it.

### D. Infer `bilingualRuEn` from the user's typing history

Auto-detect at the VoiceType layer: look at the last N transcriptions, see the
script mix, switch modes. Rejected as premature. The spec surface is already
complex enough for v1.1; add this in v1.2 only if explicit-preset data shows
users wanting it.

## Validation

- **Unit test (`LanguageEnumTests`):** every `Language` case has non-`default`
  mappings for `whisperLanguage`, `usesBilingualPrompt`, and the raw-value round-trip.
- **Unit test (`TranscriptionServiceInitialPromptTests`):** `initial_prompt`
  survives `loadModel(...)` — the prompt set before reload is equal to the prompt
  queried after reload.
- **Integration test (Track 2 W3 — language detection audit):** 10 audio clips,
  WER comparison between `language=auto+prompt` and `language=ru+bilingual_prompt`
  on code-switched Russian/English speech. This ADR is the hypothesis that W3
  tests; if W3 contradicts it, we re-open the ADR.

## References

- commit `ee23166` — v1.1 /plan-eng-review lock (D1, D5, D10)
- commit `dcb0ca7` — v1.1 /plan-design-review lock (Settings Language selector)
- Week 0 validation notes — `docs/VoiceType-v1.1-roadmap.md`
- `Sources/VoiceType/Models/AppSettings.swift:154` — current raw-string storage (to be replaced)
- `Sources/VoiceType/Services/TranscriptionService.swift:61-92` — current normalization + silent fallback (to be replaced)
