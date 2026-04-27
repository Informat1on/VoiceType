# VoiceType — Roadmap

> **Status (2026-04-27): v1.3.0 in progress.**
> v1.1.0, v1.2.0, v1.2.1, v1.2.2 shipped; v1.3.0 staged on main, ready to release.
> Open work tracked in `TODOS.md`. This file is the historical office-hours plan
> from 2026-04-23 plus an at-a-glance release log.

## Releases

| Version | Date       | Highlights |
|---------|------------|-----------|
| v1.1.0  | 2026-04-25 | Tier A token system + view migration + Geist fonts; large-v3-turbo as opt-in |
| v1.2.0  | 2026-04-26 | `largeV3TurboQ5` becomes default; benchmark infrastructure (`scripts/bench*`) |
| v1.2.1  | 2026-04-27 | Eval collector (`Cmd+Opt+E`), accessibility section, UX polish |
| v1.2.2  | 2026-04-27 | Edit any history item, compact permissions; Codex P1 fixes (VT-REV-001..004) |
| v1.3.0  | 2026-04-27 | Toast queue + persistent pre-emption (errors.log fix); 3 model presets; `scripts/codex-review.sh`; `.gitignore` cleanup |

## What's next (post-v1.3.0)

Tracked in `TODOS.md`:

- **Поток G — Notarization.** Requires Apple Developer account ($99/year). `release.sh` ready for `NOTARY_PROFILE` env var. ~1h once account is live.
- **Поток H — LLM postprocessor.** Qwen2.5-1.5B-Instruct Q4_K_M (869 MB) via mlx-swift. Blocked on collecting 50+ saved eval pairs via `Cmd+Opt+E`. ~20h integration when corpus is ready.
- **T5 — Error log rotation.** `errors.log` daily rotation + 7-day retention. Mentioned in DESIGN.md but not yet implemented.
- **T7 — Multi-screen preferences.** Target v1.2/v1.4 — currently fixed "follow focused window" behavior.
- **T8 — Transcription history UX.** Search / filter / export / iCloud sync. Power-user surface.
- **T10 — initial_prompt length clamp.** Verify whisper.cpp truncation threshold + UI counter.

---

## Historical: v1.1 office-hours plan (2026-04-23)

> Original /office-hours session that bootstrapped v1.1.
> Design doc: `~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md`

## Quick links

| Resource | Path |
|----------|------|
| Design doc (APPROVED) | `~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md` |
| Hotwords log (private) | `hotwords-log.md` (gitignored) |
| ADR directory | `docs/decisions/` |
| Week 0 spike results | `docs/decisions/2026-04-25-initial-prompt-plumbing.md` (to create) |

---

## Gitignore — что защищено

| Файл / директория | Причина |
|-------------------|---------|
| `hotwords-log.md` | Личный дневник ошибок диктовки — privacy |
| `.signing-env` | Сертификат подписи Apple Developer |
| `.qwen/` | AI-tool local state |
| `.claude/settings.local.json` | Claude Code local overrides |
| `docs/decisions/private/` | Приватные архитектурные заметки |

---

## Parallel Tracks

**Track 1 — Brand + UX Polish (user-facing)**
`/design-consultation` → `DESIGN.md` → apply to SwiftUI views in
`Sources/VoiceType/Views/{MenuBar,Recording,Settings,About,Shared}`

**Track 2 — Quality (backend + minimal UI)**
`initial_prompt` hotwords → `large-v3-turbo` benchmark → LLM-post deferred v1.2

> W1 Track 2 has priority if time conflicts.
> Quality validation happens BEFORE 5 weekends of polish.
> If hotwords = dud after 1 week → pivot LLM-post to v1.2 sooner.

---

## 7-Day Plan

### День 1 — Setup + habit

- [ ] Открыть `hotwords-log.md` в редакторе — держать открытым
- [ ] При каждой ошибке whisper → записать строчку (10 сек)
- [ ] Опционально pinned symlink: `ln -s "$(ls -t ~/.gstack/projects/Informat1on-VoiceType/*-design-*.md | head -1)" ~/Desktop/VoiceType-v1.1-design.md`

Скиллы: нет. Только habit.

---

### Вечер 2 — initial_prompt plumbing (Week 0 spike)

Запустить `/investigate` со следующим промптом:

```
/investigate verify whether whisper_full_params.initial_prompt is
actually plumbed through our Swift whisper wrapper to the C API call.
Context: design doc at ~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md
requires this for Track 2 Weekend 1. If wrapper zero-inits params
and only sets subset, hotwords feature becomes integration task
not UI task. Need: file path, line number, evidence (read actual
whisper_full call), one-sentence verdict: plumbed / not plumbed /
partially plumbed.
```

→ Записать результат: `docs/decisions/2026-04-25-initial-prompt-plumbing.md`

---

### Вечер 3 — Views inventory (Week 0 spike)

Запустить в чате:

```
Map all SwiftUI views under Sources/VoiceType/Views/. For each file
note: purpose, current polish level (rough/functional/polished),
whether it uses any existing design tokens, obvious refactor
candidates. Save to docs/decisions/2026-04-26-views-inventory.md.
```

→ Результат: `docs/decisions/2026-04-26-views-inventory.md`

---

### Вечер 4 — Recording indicator audit (Week 0 spike)

Запустить `/codex consult`:

```
/codex consult Read Sources/VoiceType/Views/Recording/WaveformView.swift
and related view files. Does it show live audio input waveform or
decorative animation? How to add visual states (idle → recording →
transcribing → inserted) with minimal refactor? 200 words max.
```

→ Результат: `docs/decisions/2026-04-27-recording-waveform-audit.md`
→ Verdict: skip / polish / rebuild для W3 Track 1

---

### Weekend 1 — Суббота утро (2-3 ч) — Track 2: Hotwords

Перед реализацией (опционально):

```
/plan-eng-review Design doc at ~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md.
Focus: Track 2 Weekend 1 — hotwords textarea + initial_prompt
integration + "Developer Bilingual RU+EN" preset. Verify against
docs/decisions/2026-04-25-initial-prompt-plumbing.md.
Mode: DX POLISH. Output actionable checklist.
```

После реализации:

```
/review branch=main — diff for initial_prompt integration +
Custom Vocabulary textarea. Check: config validation, UI edge
cases (empty/huge text/newlines), whisper param plumbing,
whisper_full_params ownership/lifetime.
```

---

### Weekend 1 — Суббота вечер / Воскресенье (3-4 ч) — Track 1: Design

```
/design-consultation Product: VoiceType, open-source local voice-
to-text for bilingual RU+EN users on macOS. Views inventory:
docs/decisions/2026-04-26-views-inventory.md. Reference aesthetic:
MacWhisper (clean, modern, laconic) but NOT a clone. Goal: DESIGN.md
with identity, palette, typography, motion language, iconography.
Design doc: ~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md.
```

→ Результат: `DESIGN.md` в корне репо (коммить публично)

---

### День 7 (воскресенье вечер) — Retro + Save

```
/retro weekly
/context-save
```

---

## Context Guide — как давать контекст скиллам

### Что скиллы читают автоматически

- `CLAUDE.md` в корне (routing rules — уже закоммичен)
- Последний design doc из `~/.gstack/projects/Informat1on-VoiceType/`
- Learnings: `~/.gstack/projects/Informat1on-VoiceType/learnings.jsonl`
- `git log`, `git status`, VERSION, README

Не нужно каждый раз говорить «прочитай design doc» — скиллы делают это сами.

### Что нужно сказать явно

1. **Цель сессии** — «review W1 Track 2», не «посмотри проект»
2. **Scope boundary** — `/freeze Sources/VoiceType/Services/` если правки только в whisper wrapper
3. **Уровень риска** — `/guard` перед `release.sh`, tagging, push --force

### Если скилл пропустил контекст

Дай путь явно:

```
Read ~/.gstack/projects/Informat1on-VoiceType/arseniy-main-design-20260423-211817.md first.
```

Особенно важно для `/codex` — живёт в отдельном процессе, CLAUDE.md не видит.

### Сохранение прогресса

```bash
/context-save     # конец каждой сессии
/context-restore  # начало следующей
```

### Правило большого пальца

- Задача < 15 минут → ручная, без скиллов
- Задача > 30 минут с несколькими шагами → ищи подходящий скилл
- `hotwords-log.md` всегда ручная работа, не делегируй

---

## Daily Checklist (30 сек)

- [ ] Записал хотя бы 1 ошибку в `hotwords-log.md`?
- [ ] Есть «опять съел имя» без записи? (= пропустил case)
- [ ] `git status` — нет случайно незакоммиченных файлов?

## Weekly Checklist (10 мин, воскресенье)

- [ ] `/retro weekly`
- [ ] `/context-save`
- [ ] `wc -l ~/.gstack/projects/Informat1on-VoiceType/timeline.jsonl`

---

## Validation Gate (после W1 Track 2 + 1 неделя dogfooding)

Сравни `hotwords-log.md` за неделю ДО hotwords (baseline) vs ПОСЛЕ:

- Записей **меньше** → initial_prompt работает, продолжаем plan
- Записей **столько же или больше** → initial_prompt = dud, сдвигаем LLM-post на приоритет v1.2 раньше

Это честный process-based criterion, а не ложное «≥90%».

---

## Skills map (в порядке очерёдности)

| Скилл | Когда |
|-------|-------|
| `/investigate` | Вечер 2 — initial_prompt plumbing |
| `/plan-eng-review` | Перед hotwords impl (опционально) |
| `/review` | После каждой фичи перед коммитом |
| `/design-consultation` | Weekend 1 — Track 1 kickoff |
| `/design-shotgun` | Weekend 2 — варианты |
| `/design-review` | Weekend 3-4 — применение DESIGN.md |
| `/health` | Раз в 2 недели |
| `/retro weekly` | Каждое воскресенье |
| `/context-save` | Конец каждой сессии |
| `/ship` | Когда v1.1 готова к релизу |
| `/guard` | Перед release.sh, tagging, push --force |
