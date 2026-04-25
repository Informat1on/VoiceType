# initial_prompt plumbing — Week 0 Spike

**Date:** 2026-04-25
**Spike for:** v1.1 Track 2 Weekend 1 (hotwords / Custom Vocabulary)
**Status:** IMPLEMENTED
**Verdict:** **Plumbed via `@dynamicMemberLookup` — works without modifying SwiftWhisper, but lifetime management is on us.**
**Implemented in:** feat(language): bilingual prompt plumbing + default to .bilingualRuEn

---

## Question

Does our Swift integration with whisper.cpp expose `whisper_full_params.initial_prompt`
end-to-end, so the user-facing "Custom Vocabulary" textarea can actually steer the
decoder?

## TL;DR

Yes — but not safely out of the box. The wrapper we use (SwiftWhisper) makes every
field of `whisper_full_params` reachable via Swift dynamic member lookup, so
`whisper.params.initial_prompt = somePointer` compiles and works. But the C field is a
raw `UnsafePointer<CChar>?` and the wrapper does NOT manage its lifetime for us. We
have to allocate, retain, and free the C string ourselves, or upstream a typed wrapper
analogous to the existing `language` property.

## Evidence

### 1. We don't call whisper.cpp directly

A repo-wide `ctx_search` for `whisper_full` returned **0 hits in `Sources/`**
(only references in `docs/VoiceType-v1.1-roadmap.md`). All whisper.cpp interaction
goes through the SwiftWhisper SPM dependency:

- `Package.swift:11` — `.package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")`
- `Sources/VoiceType/Services/TranscriptionService.swift` uses
  `Whisper`, `WhisperLanguage`, `whisper.params.language`, `whisper.params.n_threads`,
  `whisper.transcribe(audioFrames:)`. No direct C calls.

### 2. SwiftWhisper exposes the full C param surface via `@dynamicMemberLookup`

`.build/checkouts/SwiftWhisper/Sources/SwiftWhisper/WhisperParams.swift:5-29`:

```swift
@dynamicMemberLookup
public class WhisperParams {
    internal var whisperParams: whisper_full_params
    internal var _language: UnsafeMutablePointer<CChar>?

    public init(strategy: WhisperSamplingStrategy = .greedy) {
        self.whisperParams = whisper_full_default_params(...)
        self.language = .auto
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<whisper_full_params, T>) -> T {
        get { whisperParams[keyPath: keyPath] }
        set { whisperParams[keyPath: keyPath] = newValue }
    }

    public var language: WhisperLanguage { ... }  // hand-written, manages strdup lifetime
}
```

Translation: any field defined on the C `whisper_full_params` struct — `initial_prompt`,
`prompt_tokens`, `prompt_n_tokens`, `temperature`, `no_context`, etc. — is reachable as
`whisper.params.<field>` from Swift. Only `language` has been hand-wrapped into a typed
Swift API with lifetime management.

### 3. params is passed by value into `whisper_full` — pointer lifetime is critical

`.build/checkouts/SwiftWhisper/Sources/SwiftWhisper/Whisper.swift:119`:

```swift
whisper_full(self.whisperContext, self.params.whisperParams, audioFrames, Int32(audioFrames.count))
```

`self.params.whisperParams` is a value copy of the C struct, but **any pointer fields
inside that struct (like `initial_prompt: UnsafePointer<CChar>?`) must point to memory
that stays alive for the duration of the `whisper_full` call** — which runs on a
background queue (`DispatchQueue.global(qos: .userInitiated).async` at line 117).

The naive pattern is a use-after-free trap:

```swift
"мой промпт".withCString { ptr in
    whisper.params.initial_prompt = ptr   // ptr dangles after this closure returns
}
whisper.transcribe(audioFrames: audio)    // crash or garbage
```

### 4. The pattern to copy already lives in SwiftWhisper

`WhisperParams.swift:31-41` shows how `language` is handled correctly:

```swift
public var language: WhisperLanguage {
    get { ... }
    set {
        guard let pointer = strdup(newValue.rawValue) else { return }
        if let _language = _language { free(_language) }
        self._language = pointer
        whisperParams.language = UnsafePointer(pointer)
    }
}

deinit {
    if let _language = _language { free(_language) }
}
```

This is the template for `initial_prompt`. Allocate with `strdup` (or `UnsafeMutablePointer.allocate`),
keep the owning pointer in an instance variable, free in `deinit`, free the previous one
on every set.

## Impact on Track 2 Weekend 1

The original roadmap framed Weekend 1 as:

1. Add a "Custom Vocabulary" textarea in Settings → Advanced.
2. Plumb its value into `whisper_full_params.initial_prompt`.
3. Ship a "Developer Bilingual RU+EN" preset.

Plumbing reality:

- Step 1 (UI textarea + AppSettings persistence) — unchanged, ~1 hr.
- Step 2 — needs a small lifetime-safe wrapper. Two options below.
- Step 3 (preset) — unchanged, ~30 min.

So the original "this is a UI task" framing holds, with one extra ~1 hr unit of careful
Swift/C bridging code. **No need to fork SwiftWhisper, no need to wait on upstream.**
Track 2 W1 is unblocked.

## Recommended path

**Option A (preferred): wrap locally in `TranscriptionService`.**

Keep an `_initialPrompt: UnsafeMutablePointer<CChar>?` next to the existing service
state. On every settings change:

```swift
func setInitialPrompt(_ text: String?) {
    if let existing = _initialPrompt { free(existing); _initialPrompt = nil }
    guard let text, !text.isEmpty else {
        whisper?.params.initial_prompt = nil
        return
    }
    guard let ptr = strdup(text) else { return }
    _initialPrompt = ptr
    whisper?.params.initial_prompt = UnsafePointer(ptr)
}
```

Free in `deinit`. Re-apply on `loadModel(...)` (params object might be replaced).

Pros: zero upstream coupling, ships this weekend, identical pattern to existing
`language` handling.
Cons: bridging code lives in our repo, not in SwiftWhisper.

**Option B (good citizen): PR upstream `var initialPrompt: String?` to SwiftWhisper.**

Mirror the `language` setter exactly. Adds `_initialPrompt: UnsafeMutablePointer<CChar>?`
to `WhisperParams`. Same lifetime story, same `deinit`.

Pros: every SwiftWhisper user benefits, our call site becomes one-liner
`whisper.params.initialPrompt = "..."`.
Cons: branch-tracked dependency on `master`; upstream may take time to merge; we'd
either pin a fork or vendor the change while waiting.

**Recommended: ship Option A this weekend, file Option B as a follow-up PR after
v1.1 ships and we have real-world data on whether the feature pulls its weight.**

## Open questions for implementation

- Does whisper.cpp truncate `initial_prompt` at some length (256 tokens? 1024?)? We
  should clamp the textarea or warn. (Cheap to check in upstream whisper.cpp source —
  do during impl.)
- Should we also expose `prompt_tokens` / `prompt_n_tokens` for power users who want
  exact token control? Defer to v1.2; textarea is the v1.1 wedge.
- What happens when `params` object is recreated (e.g., on model reload)? Confirm by
  reading `TranscriptionService.swift:120-142` during impl.

## Files inspected

- `Package.swift` (deps)
- `Sources/VoiceType/Services/TranscriptionService.swift` (call site)
- `.build/checkouts/SwiftWhisper/Sources/SwiftWhisper/WhisperParams.swift` (param API)
- `.build/checkouts/SwiftWhisper/Sources/SwiftWhisper/Whisper.swift` (transcribe + whisper_full call)

## Decision

Track 2 W1 stays as planned. Implementation route: **Option A** (local wrapper in
`TranscriptionService`). Filing **Option B** as a follow-up after v1.1 ships and we
have validation-gate data.
