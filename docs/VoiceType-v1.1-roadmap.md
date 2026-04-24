# VoiceType v1.1 — Roadmap & Weekly Plan

> Generated after /office-hours session on 2026-04-23.
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
