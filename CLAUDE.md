# VoiceType

Lightweight macOS menu bar voice typing app powered by `whisper.cpp`, optimized for Apple Silicon.

## Health Stack

- typecheck: swift build -c debug
- test: swift test
- shell: shellcheck *.sh

(Lint and dead-code are intentionally not configured yet — see
`docs/decisions/2026-04-26-views-inventory.md` Tier A for SwiftLint plan.)

## Design System

Always read `DESIGN.md` before making any visual or UI decision. All font choices,
colors, spacing, radii, motion, and aesthetic direction live there. Do not deviate
without explicit user approval. Record every change in the `## Decisions Log`
section at the bottom of `DESIGN.md` with date + rationale.

The compass: **"A tool for people who just build things, with the polish of
commercial software."** Every design decision serves that one thing.

Key sections in DESIGN.md (all locked as of 2026-04-24):
- **Aesthetic Direction** — Cool Ink-Steel palette, Geist/Geist Mono, no glassmorphism
- **Color** — dark/light token pairs; adapt via `NSColor(name:dynamicProvider:)`
- **Layout** — native rows + dividers (not cards), Settings tab order General→Models→Shortcuts→Advanced
- **Interaction States** — 6 capsule states: recording/transcribing/inserted/errorInline/errorToast/emptyResult
- **Accessibility** — contrast rules, VoiceOver announcements on all state transitions, colorblind REC label
- **Motion** — `Motion.micro/short/medium/long = 100/200/300/500ms`; silent waveform during silence
- **User Journey** — first-launch arc (4-step checklist), daily-use arc (800ms ceremony), error-recovery arc
- **Error Handling & Logging** — solvable errors inline, unsolvable as toast; all errors to `~/Library/Logs/VoiceType/errors.log`
- **Transcription History** — `history.jsonl` (100 entries rolling); re-insert activates targetApp first
- **Focus Return** — capture previousApp at hotkey; restore on dismiss; mandatory behavior
- **Language Mapping** — `Language.bilingualRuEn` = `whisperLanguage: .ru` + `usesBilingualPrompt: true` (NOT auto)
- **Implementation Plan** — 14 Tier A steps with test requirements per step; see Pre-Tier A W1 steps 0a-0c

In QA / design-review mode, flag any code that doesn't match `DESIGN.md`:
inline color literals, missing token usage, hero-header in Settings, continuous
waveform animation during silence, `.ultraThinMaterial` on capsule, boxed cards
in preferences, `NSAlert.runModal()` for errors instead of capsule states.

The Tier A refactor (tokens + view migration) is sequenced for v1.1 Weekend 3-4.
Track 2 W1 (Language enum + hotwords) is Weekend 1, independent of Tier A.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. The
skill has multi-step workflows, checklists, and quality gates that produce better
results than an ad-hoc answer. When in doubt, invoke the skill. A false positive is
cheaper than a false negative.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke /office-hours
- Strategy, scope, "think bigger", "what should we build" → invoke /plan-ceo-review
- Architecture, "does this design make sense" → invoke /plan-eng-review
- Design system, brand, "how should this look" → invoke /design-consultation
- Design review of a plan → invoke /plan-design-review
- Developer experience of a plan → invoke /plan-devex-review
- "Review everything", full review pipeline → invoke /autoplan
- Bugs, errors, "why is this broken", "wtf", "this doesn't work" → invoke /investigate
- Test the site, find bugs, "does this work" → invoke /qa (or /qa-only for report only)
- Code review, check the diff, "look at my changes" → invoke /review
- Visual polish, design audit, "this looks off" → invoke /design-review
- Developer experience audit, try onboarding → invoke /devex-review
- Ship, deploy, create a PR, "send it" → invoke /ship
- Merge + deploy + verify → invoke /land-and-deploy
- Configure deployment → invoke /setup-deploy
- Post-deploy monitoring → invoke /canary
- Update docs after shipping → invoke /document-release
- Weekly retro, "how'd we do" → invoke /retro
- Second opinion, codex review → invoke /codex
- Safety mode, careful mode, lock it down → invoke /careful or /guard
- Restrict edits to a directory → invoke /freeze or /unfreeze
- Upgrade gstack → invoke /gstack-upgrade
- Save progress, "save my work" → invoke /context-save
- Resume, restore, "where was I" → invoke /context-restore
- Security audit, OWASP, "is this secure" → invoke /cso
- Make a PDF, document, publication → invoke /make-pdf
- Launch real browser for QA → invoke /open-gstack-browser
- Import cookies for authenticated testing → invoke /setup-browser-cookies
- Performance regression, page speed, benchmarks → invoke /benchmark
- Review what gstack has learned → invoke /learn
- Tune question sensitivity → invoke /plan-tune
- Code quality dashboard → invoke /health
