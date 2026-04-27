# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-04-27

### Added
- **3 model presets in Settings → Models.** Fast (small-q5, ~190 MB),
  Balanced (large-v3-turbo-q5, ~547 MB, marked **Recommended**), Max
  Quality (large-v3-turbo, ~810 MB). The full 7-model list moved into a
  collapsed "Advanced" expander for power users. New users get a clear
  3-tier story instead of a wall of jargon. Existing model selection is
  preserved; if you have a non-preset model selected, the preset row
  shows a "Custom" indicator pointing you to Advanced.
- **`scripts/codex-review.sh`** developer helper that wraps `codex review`
  with 24h SHA-keyed caching, fail-fast on `--range <base>..<custom-head>`,
  and ref-peeling for annotated tags. Standardizes the post-feature
  Codex review gate that's now part of the project's shipping workflow.

### Changed
- **Error toasts now persist to `~/Library/Logs/VoiceType/errors.log`.**
  Previously `showErrorToast()` wrote only to `os.Logger`, so errors
  flashed in the top-right and disappeared without a trail. Logging now
  happens inside `ErrorToastWindow.show()` so every toast caller benefits
  automatically.
- **Toast queue with min-visible-time 2.5s.** Rapid back-to-back errors
  no longer flash for milliseconds and replace each other. Toasts stay
  visible for at least 2.5s; new toasts queue (FIFO, max 3, oldest drops
  with a warning logged).
- **Persistent (urgent) toasts pre-empt the queue.** The
  restart-required toast fired by PermissionManager when you grant
  Accessibility now displaces any visible toast immediately, instead of
  queueing behind a stale accessibility-instructions toast and getting
  drowned out by the 600ms restart delay.

### Fixed
- **Errors not landing in `errors.log`.** Toasts now actually persist
  every error to the log file, every time. Three Codex review rounds
  caught two regressions in the queue logic before merge: FIFO order
  broken when the queue was non-empty after `minVisibleTime`, and the
  `persistent` flag dropped on queued toasts.

### Internal
- **Codex review pipeline standardized** as a hard gate before merging
  any feature ≥ ~50 LOC. Caught 4 P2/P3 findings across 4 streams in
  this release that would otherwise have shipped: FIFO regression,
  persistent flag round-trip, persistent pre-emption, annotated-tag SHA
  comparison.
- **`.gitignore` cleanup.** Top-level entries for `.claude/`,
  `.cursorrules`, `AGENTS.md`, `LEAN-CTX.md` so machine-local agent
  state and global lean-ctx instruction copies stop showing up in
  `git status`.
- **+20 tests across 4 streams.** ErrorToastQueueTests (8),
  ModelPresetTests (11), plus regression coverage. Total: 296 → 316.

## [1.2.2] - 2026-04-27

### Added
- **Edit any history item, not just the latest one.** Settings → Advanced
  → History now has an Edit button on every transcription that opens the
  EvalEditorView for that specific entry. Listen to the audio (if it's
  still in the rolling buffer), see the whisper output, edit the
  pre-filled correction, save. Multiple editors can be open simultaneously
  for different entries — each has its own window owned by AppDelegate.

### Changed
- **MICROPHONE + ACCESSIBILITY in Settings → General** consolidated into a
  single compact PERMISSIONS block. One-line rows in the granted state
  ("● Microphone granted [Open Privacy…]"); the explanatory hint panel
  with Refresh / Restart App buttons appears only when the permission is
  denied. Stops the General tab from being dominated by housekeeping.
- **Shortcuts tab no longer duplicates the accessibility section.** When
  accessibility is denied, an inline button "Go to General → Permissions"
  switches the tab. Single source of truth.

### Fixed
- **Window leak from history-edit path.** EvalEditorWindow opened from a
  history entry had no strong owner and could deallocate. Now stored in a
  `[UUID: EvalEditorWindow]` registry on AppDelegate; closing a window
  cleans up its registry entry and its NotificationCenter observer.
  (Codex review VT-REV-001.)
- **Accessibility regression in PERMISSIONS section.** The wrapping
  `.accessibilityElement(children: .combine)` was swallowing the
  Refresh / Restart App / Open Privacy buttons from VoiceOver. Replaced
  with `.contain` so each button stays individually focusable. (Codex
  review VT-REV-002.)
- **Silent data loss when editing a rotated entry.** If the entry being
  edited got pushed out of the 100-item rolling buffer, the previous
  Save flow silently closed the window and lost the typed correction. A
  poll timer now detects rotation and shows a warning banner advising
  the user to copy their correction before closing; Save itself no
  longer auto-closes on a missing entry. (Codex review VT-REV-003.)
- **Shortcuts tab inline hint is now actionable.** Was a text-only
  PrefsRow ("see General → Permissions") with no tap target. Now an
  explicit Button that switches the tab and announces correctly to
  VoiceOver. (Codex review VT-REV-004.)
- **NotificationCenter observer leak.** Each opened eval editor was
  leaking one block-based observer until process exit. Token now stored
  per entry and removed on window close. (Codex re-review.)

### Under the hood
- Two rounds of Codex review on this release. Round 1 found 2 High + 2
  Medium issues, all addressed. Round 2 found 1 Low (the observer leak
  above), addressed before tagging. Establishing post-feature Codex
  review as a hard gate before any patch ships.

## [1.2.1] - 2026-04-27

### Added
- **Eval Collector for whisper-output → user-correction pairs.** New
  `Cmd+Opt+E` hotkey opens an editor window on the last transcription. The
  whisper output is shown read-only and the correction field is *pre-filled*
  with the same text — you only edit the parts that are wrong, no full
  rewrite. Click Save and the pair lands in `history.jsonl` with
  `isSavedEval: true`. Each transcription now also persists its audio (16
  kHz mono PCM CAF, ~150 KB per 5s clip; 100-entry rolling buffer for
  unsaved, saved pairs preserved indefinitely). This is the foundation for
  future LLM-postprocessing — once 50+ corrections accumulate, the corpus
  is ready for prompt design or fine-tuning.
- **Accessibility permission section in Settings → General.** Until now
  Microphone permission status was visible on the General tab but
  Accessibility was not, even though Accessibility is what allows
  VoiceType to insert transcribed text into other apps. Both permissions
  now sit side-by-side with the same coloured-dot indicator and "Open
  Privacy…" button. Without Accessibility, transcription completes
  silently and nothing pastes — you should not have to dig three menus
  deep to learn that.

### Changed
- **Status dot enlarged from 5pt to 9pt with inline state label.** The
  dot in the menu bar dropdown was too small to notice. Now it's 9pt
  (1.8x larger) and shows "Loading…" / "Warming…" / "Error" text next to
  the dot when not ready. The same dot is also duplicated in
  Settings → Models tab next to the active model — you no longer have to
  open the dropdown to check status.
- **Language selector compacted.** "Auto-detect" / "Русский" / "English"
  / "Bilingual RU+EN" → `Auto` / `RU` / `EN` / `RU+EN`. Two-letter codes
  fit cleanly in a SegmentedControl without overflow. VoiceOver still
  reads the long form ("Russian", "Russian + English (bilingual)") via
  `accessibilityLabel`. The "Promoted to first-class" placeholder
  subtitle was replaced with a useful description of each option.
- **Default model is Large v3 Turbo Q5 for fresh installs.** Existing
  users keep their selection. Backed by full 7-model benchmark on M4
  Pro: turbo-q5 ties full Turbo on every WER metric, runs 30% faster on
  short clips and 13% faster on 90-second free speech, occupies a third
  of the disk (547 MB vs 1.5 GB). See `scripts/bench-output/`.

### Fixed
- **Status dot identity bug in Settings → Models.** When you switched
  models, the newly selected row immediately showed a green "ready" dot
  even though the old model was still loaded. The status published by
  `TranscriptionService` now only reaches the row whose model name
  actually matches `loadedModelName` — every other row shows
  `.notLoaded`. (Codex review VT-REV-001.)
- **VoiceOver regression in language picker.** When the segments were
  shortened to "RU"/"EN"/"RU+EN", VoiceOver was reading the codes
  literally because `longDisplayName` was only wired to the picker-level
  `accessibilityValue`, not to each segment. Each segment now has an
  explicit `.accessibilityLabel(language.longDisplayName)`. (Codex
  review VT-REV-002.)
- **`record-bench.sh` audio device selection** — interactive picker
  replaces the hard-coded `:0` (which was often a virtual mic).

### Tooling
- **`./install-app.sh`** now does a full kill → clean → build → install →
  verify cycle. Removes both `/Applications` and `~/Applications` copies,
  kills any running VoiceType process, rebuilds the bundle, registers
  with LaunchServices, and prints the installed version. Use this after
  every code change so you never test a stale binary again.
- **`scripts/bench.sh`** extended to all 7 models; **`scripts/compare-live.sh`**
  records 60–120 seconds of free speech and diffs Turbo vs Turbo-Q5
  side-by-side with timing.

### Bench data summary (M4 Pro, 25-phrase corpus)

| Model | WER | RTF | Disk | RAM |
|---|---|---|---|---|
| tiny | 42.5% | 10.0x | 75 MB | 303 MB |
| base | 34.5% | 10.0x | 141 MB | 412 MB |
| small-q5 | 27.0% | 10.1x | 181 MB | 558 MB |
| small | 26.2% | 9.4x | 465 MB | 887 MB |
| medium | 24.1% | 4.2x | 1400 MB | 2179 MB |
| **turbo-q5** | **23.2%** | **5.4x** | **547 MB** | **879 MB** |
| turbo | 23.2% | 3.7x | 1500 MB | 1914 MB |

Note: tiny/base/small-q5 are latency-identical on M4 Pro (~0.59s/phrase),
so picking tiny "for speed" buys nothing but costs 34 WER points on
identifiers. medium is dominated on every axis by turbo-q5 — slower,
worse WER, larger.

## [1.2.0] - 2026-04-27

### Added
- **Large v3 Turbo Q5 — new default for fresh installs.** Quantized variant of
  Turbo. Same accuracy as the full f16 build (verified head-to-head on a
  25-phrase RU+code-switch corpus and a 90-second free-speech recording — the
  per-block WER breakdown is byte-identical), but the disk file is 547 MB
  instead of 1.5 GB and inference is roughly 30% faster on short clips and
  13% faster on long-form dictation. The full Turbo remains available for
  users who want it. Existing users with an explicit model choice keep their
  selection; only fresh installs get Q5 as default.
- **Benchmark infrastructure.**
  - `scripts/record-bench.sh` — interactive recorder for a 25-phrase
    Russian + code-switch dataset. Now picks the audio device interactively
    so you do not silently record from a virtual mic (Camo, OBS).
  - `scripts/bench.sh` — runs whisper-cli over the recorded dataset against
    every installed model, computes WER (via jiwer) and RTF, writes a CSV
    plus a polished `RESULTS.md`.
  - `scripts/compare-live.sh` — record 60-120 seconds of free speech, run
    both Turbo and Turbo-Q5 head-to-head, print side-by-side timings and a
    word-level diff.
  - `Tests/Fixtures/bench/` — placeholder for the recorded dataset.

### Fixed
- `record-bench.sh` no longer hard-codes audio device index `:0` (which was
  often a virtual microphone like Camo and recorded silence). The script now
  lists available avfoundation audio inputs, lets the user pick by index,
  verifies the choice with a 1-second test recording (peak amplitude check
  via sox), and caches the selection in `Tests/Fixtures/bench/.bench-device`
  so re-runs do not re-prompt.

### Under the hood
- Bench data on M4 Pro across 4 models (small, medium, turbo, turbo-q5):
  turbo-q5 matches turbo on every metric while occupying a third of the disk
  and finishing each transcription in ~70% of the time. medium is dominated
  on every axis. small remains the speed champion (RTF 9.5x) at the cost of
  ~17% WER on tech anglicisms.

## [1.1.0] - 2026-04-27

### Added
- **Large v3 Turbo model.** The fastest high-quality Whisper model is now
  supported on Apple Silicon. Best balance of speed and accuracy. Roughly 1.2
  seconds for typical short clips on M4.
- **Faster first transcription via implicit warm-up.** When you switch models,
  VoiceType now silently primes Metal and CoreML caches with a 500 ms silence
  pass. Before, the first real transcription after switching took several
  seconds. Now it is hot from the start.
- **Model status indicator in the menu bar dropdown.** A small coloured dot
  next to the active model shows whether it is loading, warming up, ready, or
  errored. No more guessing whether the model is ready before you press the
  hotkey.
- **First-launch celebration moment.** Brief animation after the 4-step setup
  checklist completes.

### Fixed
- **SIGABRT crash on Large v3 Turbo.** A bug in whisper.cpp v1.7.5 left the
  CoreML scheduler with stale state, which corrupted mel tensor metadata on
  the second transcription onwards. Picked up the upstream fix
  (`ggml_backend_sched_reset` before `whisper_coreml_encode`).
- Several race conditions and edge cases in transcription, model loading, and
  permissions handling, surfaced by two rounds of independent Codex audits.
  No more dangling C pointers, no more out-of-order model loads silently
  overwriting newer ones, no more wedged transcriptions on hung native calls.
- VoiceOver announcements and `reduceMotion` timing on the first-launch
  checklist.

### Changed
- Empty recordings now return cleanly instead of throwing a confusing error.
- Permission refresh and accessibility-restart watching are now independent.
  Opening Microphone Settings no longer accidentally cancels the accessibility
  re-grant watcher.
- `setInitialPrompt` is correctly deferred during warm-up so user vocabulary
  changes are never lost to a race with the silent silence pass.

### Under the hood
- Forked SwiftWhisper to
  [Informat1on/SwiftWhisper](https://github.com/Informat1on/SwiftWhisper),
  bundling whisper.cpp v1.7.5 plus a cherry-pick of the upstream CoreML
  scheduler reset fix. Upstream `exPHAT/SwiftWhisper` has been unmaintained
  since August 2023.
- Test suite expanded substantially during the audit fix rounds. Currently
  278 tests, 0 failures.

## [1.0.2] - 2026-04-15

See [release notes](https://github.com/Informat1on/VoiceType/releases/tag/v1.0.2).

## [1.0.1] - 2026-04-12

See [release notes](https://github.com/Informat1on/VoiceType/releases/tag/v1.0.1).

## [1.0.0] - 2026-04-12

Initial public release.
