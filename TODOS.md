# VoiceType — TODOS

Design-debt и follow-up items, вынесенные из `/plan-design-review` 2026-04-24.
Каждый пункт имеет **What / Why / Pros / Cons / Depends-on**, чтобы кто угодно
поднял эту задачу через 3 месяца и понял контекст.

---

## T1 — Waveform bar pixel-spec (pre-Tier A)

- **What:** добавить в DESIGN.md раздел о waveform bars: точное количество, ширина, gap, диапазон высот, amplitude mapping (RMS vs freq-band).
- **Why:** Subagent finding #19 — сейчас "waveform bars" упомянуты без деталей, каждый engineer при реализации примет разные значения.
- **Pros:** нулевая двусмысленность при миграции `WaveformView.swift` на токены.
- **Cons:** требует 15-30 мин на прототипирование/решение.
- **Context:** предлагаемые значения для старта: 5 bars, 3px width, 2px gap, height 4-20px, RMS mapping с peak-decay 200ms. Проверить визуально в v1/v3 HTML превью.
- **Depends on:** решение перед Tier A W3.

## T2 — SwiftLint setup перед Tier A

- **What:** `brew install swiftlint && swiftlint init`, добавить `.swiftlint.yml` с правилами: запрет inline Color literals (`Color(red:...)`), запрет inline spacing magic numbers (регексп `\.padding\(\d+\)`), force-brackets для token-access.
- **Why:** Tier A мигрирует ~30 цветов + ~50 spacing values + ~10 radii на токены. Без линтера легко пропустить какое-то место; после v1.1 drift начнётся моментально.
- **Pros:** Health score enforcement после Tier A; новый код не может обойти токены; CI-gate (см. CLAUDE.md `## Health Stack`).
- **Cons:** ~30-60 мин настройки + возможные 50-100 исправлений в существующем коде (но это делаем в Tier A в любом случае).
- **Depends on:** установка до начала Tier A шагов 1-8.

## T3 — Light mode visual QA после Tier A

- **What:** после миграции `WindowChrome.swift` + `SettingsView.swift` прогнать оба окна в light mode макОС, снять скриншоты, сверить с v1 HTML preview.
- **Why:** текущая реализация тестируется преимущественно в dark mode. Light mode контрасты AA проходят по спеке, но визуальная гармония должна быть подтверждена.
- **Pros:** ловит регрессии light mode на этапе implementation.
- **Cons:** ручная QA, ~20 мин.
- **Depends on:** Tier A шаги 1-3 завершены.

## T4 — Model download cancel UX

- **What:** определить mechanism отмены активной загрузки модели: клик по progress row / explicit Cancel button / двойной клик?
- **Why:** Pass 2 states atlas показал downloading state с progress bar, но не специфицирован способ отмены. Сейчас в коде `try? await modelManager.downloadModel(...)` — отмена через task cancellation возможна, но UI-триггер не определён.
- **Pros:** полный download lifecycle специфицирован.
- **Cons:** таст-вопрос; предлагаемый default = ghost "Cancel" button рядом с progress bar.
- **Depends on:** до реализации Models tab в Tier A шаг 3.

## T5 — Error log rotation implementation

- **What:** написать `~/Library/Logs/VoiceType/errors.log` daily rotation; решить: custom Swift rotation / использовать `os_log` unified logging / сторонняя библиотека.
- **Why:** DESIGN.md специфицирует daily rotation + keep 7 days. Реализация пока не существует.
- **Pros:** feature-complete error logging на момент v1.1 ship.
- **Cons:** ~1-2 часа реализации; выбор из 3-4 подходов.
- **Context:** рекомендуемый подход — Swift-native file-handle rotation, проверять `errors.log` size/mtime раз в session start. Избегать внешних deps.
- **Depends on:** Tier A шаг 10 (Error Log module).

## T6 — Focus Return edge case: previousApp quit mid-recording

- **What:** специфицировать поведение когда `previousApp` закрылся до dismiss капсулы (пользователь Cmd+Q пока шла запись).
- **Why:** DESIGN.md гарантирует focus return, но не покрывает edge case. Transcription history решает "не потерять текст", но куда вставляется текст при dismiss?
- **Pros:** полный lifecycle покрыт.
- **Cons:** таст-вопрос. Предлагаемый default: transcription уходит только в history (не вставляется никуда), toast "App '{previousApp}' is no longer running — saved to history."
- **Depends on:** Tier A шаг 11 (Focus Return).

## T7 — Multi-screen preferences (v1.2)

- **What:** preference для выбора поведения при multi-monitor: "follow focused window" (текущий v1.0 default) vs "always main screen" vs "last used screen".
- **Why:** v1.0 имеет фиксированное поведение. Для пользователей с 3-monitor setup предпочтения могут различаться.
- **Pros:** accommodates multi-monitor workflows.
- **Cons:** добавляет preference surface; отложено специально чтобы не раздувать v1.1.
- **Depends on:** post-v1.1, target v1.2.

## T8 — Transcription history: search / filter / export / sync (v1.2+)

- **What:** расширить History sheet: full-text search, filter by language/app/date, export to markdown/txt, optional iCloud sync.
- **Why:** v1.1 scope минимален (list + Copy + Re-insert + Delete). При активном использовании 50+ entries в неделю пользователь захочет fish out specific dictation.
- **Pros:** delightful power-user surface.
- **Cons:** каждая под-фича = дополнительный UI surface + edge cases. Sync требует решения о privacy (история содержит текст, который мог быть чувствительным).
- **Depends on:** v1.1 ships + telemetry about history usage.

---

## Process TODOs

## P1 — Update CLAUDE.md `## Design System` section

- **What:** расширить секцию `## Design System` в `CLAUDE.md` ссылками на новые разделы DESIGN.md (Interaction States, Accessibility, User Journey, Error Handling, Transcription History, Focus Return).
- **Why:** сейчас CLAUDE.md упоминает только общий compass и Decisions Log. После сегодняшней ревизии DESIGN.md вырос с 381 до ~650 строк с 10+ новыми разделами.
- **Pros:** CLAUDE.md остаётся проводником; /design-review и другие skills знают где искать.
- **Cons:** ~5 мин редактирования.
- **Depends on:** после commit DESIGN.md.

## P2 — Context-save после сегодняшней сессии

- **What:** запустить `/context-save` с title "v1.1 Track 1 — design review complete, DESIGN.md locked, ready for Tier A".
- **Why:** окно контекста заполняется. Текущая сессия имеет огромное количество decisions (30+ в Decisions Log), которые стоит зафиксировать вне conversation memory.
- **Pros:** следующая сессия может `/context-restore` и получить полный state.
- **Cons:** нет, только плюсы.
- **Depends on:** после finalize passes (сейчас).
