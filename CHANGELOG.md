# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
