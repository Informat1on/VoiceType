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

## T2 — SwiftLint setup перед Tier A ✅ DONE (2026-04-24, commit `e73cac4`)

- **What:** `brew install swiftlint && swiftlint init`, добавить `.swiftlint.yml` с правилами: запрет inline Color literals (`Color(red:...)`), запрет inline spacing magic numbers (регексп `\.padding\(\d+\)`), force-brackets для token-access.
- **Why:** Tier A мигрирует ~30 цветов + ~50 spacing values + ~10 radii на токены. Без линтера легко пропустить какое-то место; после v1.1 drift начнётся моментально.
- **Pros:** Health score enforcement после Tier A; новый код не может обойти токены; CI-gate (см. CLAUDE.md `## Health Stack`).
- **Cons:** ~30-60 мин настройки + возможные 50-100 исправлений в существующем коде (но это делаем в Tier A в любом случае).
- **Depends on:** установка до начала Tier A шагов 1-8.
- **Outcome:** SwiftLint 0.63.2 installed. `.swiftlint.yml` with 5 custom rules (`inline_color_rgb`, `inline_color_hex`, `inline_nscolor_rgb`, `ultra_thin_material_on_capsule`, `nsalert_runmodal`) — all WARNING until Tokens.swift lands. Spacing-magic-number rule deferred to Tier A (too noisy pre-Tokens.swift). Baseline: 54 warnings, 0 errors. Violations map 1:1 to tracked refactor items.

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

## T5 — Error log rotation implementation ✅ DONE (2026-07-27)

- **What:** написать `~/Library/Logs/VoiceType/errors.log` daily rotation; решить: custom Swift rotation / использовать `os_log` unified logging / сторонняя библиотека.
- **Why:** DESIGN.md специфицирует daily rotation + keep 7 days. Реализация пока не существует.
- **Pros:** feature-complete error logging на момент v1.1 ship.
- **Cons:** ~1-2 часа реализации; выбор из 3-4 подходов.
- **Context:** рекомендуемый подход — Swift-native file-handle rotation, проверять `errors.log` size/mtime раз в session start. Избегать внешних deps.
- **Depends on:** Tier A шаг 10 (Error Log module).
- **Outcome:** реализовано Swift-native file-handle rotation в `Sources/VoiceType/Services/ErrorLogger.swift` (`rotateIfNeeded()` / `deleteStaleArchives()`, ~118-174): daily archive `errors-YYYY-MM-DD.log`, 7-дневный retention, `errors.log` никогда не удаляется. Уже используется `ErrorToastWindow` ("View log") и, начиная с этой сессии, кнопками Settings → Advanced → Diagnostics (`Sources/VoiceType/Views/Settings/DiagnosticsSection.swift`) — "Reveal in Finder" / "Clear" по DESIGN.md § Error Handling & Logging. Задача была найдена архитектурным аудитом как несинхронизированная с кодом: TODO помечал rotation нереализованной, хотя код был готов ещё с 2026-04-27.

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

## T9 — ADR: RU+EN language mode mapping ✅ DONE (2026-04-24, `docs/decisions/2026-04-24-ruen-language-mode.md`)

- **What:** написать `docs/decisions/2026-04-XX-ruen-language-mode.md` — ADR документирующий, почему `Language.bilingualRuEn` маппится в `whisperLanguage: .ru` + bilingual `initial_prompt`, а не в `language=nil` (auto) или отдельный режим.
- **Why:** `/plan-eng-review` 2026-04-24 выявил, что без ADR будущий maintainer не поймёт почему `bilingualRuEn.whisperLanguage = .ru` — это выглядит как баг, но является архитектурным решением. Codex независимо подтвердил риск silent degradation в auto.
- **Pros:** решение самодокументировано; будущий `/plan-eng-review` не повторит этот вопрос.
- **Cons:** 20-30 мин на написание.
- **Context:** решение: "ru+en" = `language=ru` потому что primary use case — русский текст с английскими техтерминами; auto-detect часто выбирает "en" при heavy code-switching и манглит русские части. Bilingual initial_prompt биасирует декодер на техлексику.
- **Depends on:** до W1 Track 2 Weekend 1 (перед реализацией Language enum).

## T10 — initial_prompt length limit: проверить порог whisper.cpp + clamp в UI

- **What:** проверить в whisper.cpp upstream (`whisper.cpp:whisper_full()`), сколько токенов принимает `initial_prompt` перед обрезкой. Добавить clamp в textarea (например, maxLength = 500 символов) + счётчик символов в Settings.
- **Why:** spike-документ `2026-04-25-initial-prompt-plumbing.md` оставил это открытым: "Does whisper.cpp truncate initial_prompt at some length?" Без clamp пользователь с большим словарём получит молчаливую обрезку без feedback.
- **Pros:** честный UX; пользователь знает, что вмещается в prompt.
- **Cons:** ~1 час на исследование + ~30 мин на UI.
- **Context:** искать в whisper.cpp: `prompt_past` логику, context window. Likely trim at ~224 tokens.
- **Depends on:** до W1 Track 2, или сразу после первой рабочей реализации textarea.

## T11 — LLM-постобработка транскрипта локальной моделью (отдельный трек) ⏸ ОТЛОЖЕНА (2026-07-27)

- **What:** после `whisper_full()` прогонять сырой транскрипт через локальную LLM (Apple Foundation Models / llama.cpp-GGUF / MLX) для «причёсывания»: пунктуация и регистр, снятие оговорок и филлеров («эээ», «ну», повторы), нормализация тех-терминов и англицизмов (`гит пуш` → `git push`, `кубернетес` → `Kubernetes`), опционально — режимы вывода (как есть / чистовик / буллеты).
- **Why:** WER-бенч 2026-04-27 показал, что оставшиеся ошибки turbo концентрируются не в общей речи (Block 1 = 1.5%), а в англицизмах (10.5%), идентификаторах (40.8%) и числах (59.2%) — это ошибки *формы*, которые LLM с контекстом чинит лучше, чем более крупная ASR-модель. Плюс пунктуация в whisper для русского нестабильна.
- **Pros:** качество растёт там, где апгрейд ASR-модели уже не помогает; полностью офлайн; переиспользует уже имеющийся `customVocabulary` как словарь подсказок для промпта.
- **Cons:** +латентность на каждую вставку (бюджет DESIGN.md на ceremony — 800 мс, LLM-проход на 3B-модели съедает его целиком); риск галлюцинаций — LLM может «дописать» то, чего не было; +RAM и +размер дистрибутива, если тянуть свою GGUF-модель; нужен guard-rail (diff-порог: если правок больше N%, откатываться к сырому тексту).
- **Context:** ключевая развилка — рантайм. (1) Apple Foundation Models framework (macOS 26+): ~0 МБ дистрибутива, on-device, но модель маленькая и API ограничен guided generation; (2) llama.cpp/GGUF — контроль над моделью, но +2-4 ГБ и второй C++-рантайм в бандле; (3) MLX — быстрый на Apple Silicon, но Python-зависимость либо своя Swift-обвязка. Рекомендация к оценке: сначала (1) как «бесплатный» вариант, замер качества на том же 25-фразовом корпусе (`scripts/bench.sh` + `scripts/wer.py`), и только если не хватает — (2). Обязательный UX-элемент: тумблер «Постобработка» в Settings и показ сырого текста в History рядом с обработанным.
- **Depends on:** независим от трека оптимизации Whisper (T12); желательно после него, т.к. освободившийся бюджет латентности (см. T12: 13.2 с → 1.97 с на 90 с аудио) — это то, из чего оплачивается LLM-проход.
- **Outcome (2026-07-27):** проверены оба реалистичных рантайма, ни один не подошёл — разбор в [`docs/decisions/2026-07-27-t11-llm-postprocessing-runtime.md`](docs/decisions/2026-07-27-t11-llm-postprocessing-runtime.md). Кратко: Apple Foundation Models недоступна (`unavailable(.appleIntelligenceNotEnabled)`), русского нет в списке поддерживаемых языков Apple Intelligence. mlx-swift линкуется с ggml без конфликта символов (проверено вживую), но Qwen3-1.7B-4bit в быстром режиме не правит текст вообще (0 правок на 6 примерах), а в режиме рассуждения тратит 5-7 с на короткую фразу и при этом придумывает и теряет слова. Для сравнения: транскрипция 90 с аудио — около 2 с. llama.cpp списан заранее: вторая копия ggml даёт конфликт символов при линковке.
- **Следующий шаг, если возвращаться:** сперва попробовать детерминированный словарь замен поверх `customVocabulary` — он бьёт ровно в те категории ошибок (англицизмы 10.5%, идентификаторы 40.8%) без задержки и без риска галлюцинаций. Для LLM-пути сначала нужны эталоны «сырой вывод → чистовик», которых нет: `Tests/Fixtures/bench/*.txt` для этого не годятся (числа записаны словами, тогда как постобработка должна давать цифры).

## T12 — Whisper backend: починить Metal + апгрейд whisper.cpp + Neural Accelerators M5 ✅ DONE (2026-07-26)

- **What:** (a) починена доставка `ggml-metal.metal` в .app — Metal-бэкенд не инициализировался вообще; (b) whisper.cpp в форке `Informat1on/SwiftWhisper` поднят с v1.7.5 на v1.9.1; (c) Metal 4 tensor API включён (`has tensor = true`).
- **Итог по (a) и (b):** подтверждён. 90 с аудио: было 13.2 с на CPU, стало 1.97 с.
- **Итог по (c) — не тот, что ожидался.** Tensor API действительно почти вдвое ускоряет сам Metal-энкодер (encode 1213 → 612 мс), но **не обгоняет Neural Engine**. Ожидавшийся выигрыш 855 → 420 мс оказался артефактом методики: мерили `whisper-cli`, который перезагружает модель каждый запуск и потому платит 227–488 мс за загрузку `.mlmodelc` в ANE. Приложение платит это один раз при старте и прячет за `performWarmUp()`. Строгий замер в сценарии приложения: ANE быстрее на 11–16%. Разбор: `scripts/bench-output/RESULTS-coreml-vs-metal-app-2026-07-26.md`.
- **Что осталось в продукте:** явный выбор ускорителя (Auto / Neural Engine / GPU) в настройках, честная диагностика, проба возможностей Metal в форке (`v1.9.1-vt.2`). Auto выбирает ANE везде, где энкодер установлен.

## T13 — Расхождение текстов между ANE и Metal на длинных записях ✅ DONE (2026-07-27)

- **What:** на 81-секундной записи транскрипты через CoreML/ANE и через Metal расходятся (на 5.4 с совпадают побайтово). Начало дословно одинаково, где именно расходится — не локализовано, на качество не оценивалось.
- **Why:** пока расхождение не оценено, сравнение производительности на длинных записях нельзя считать сравнением при равном качестве (замечание код-ревью). Также это влияет на выбор режима: если один из путей систематически точнее, это важнее процентов скорости.
- **How:** прогнать оба пути на наборе `Tests/Fixtures/bench/`, посчитать WER относительно эталонов, локализовать место расхождения.
- **Outcome:** отчёт `scripts/bench-output/RESULTS-t13-ane-vs-metal-2026-07-27.md`. Сначала закрыт гейт, которого раньше не проверяли: каждый бэкенд детерминирован — 8/8 идентичных прогонов на длинном аудио (в одном процессе и кросс-процессно), 4/4 на живой записи. Расхождение оказалось много меньше ожидаемого: на 179 словах живой 81-секундной записи различий четыре — одна содержательная подстановка и три различия в регистре имён собственных. WER на длинном склеенном аудио: ANE 0.179 против Metal 0.191 (3 слова из 262); на коротком корпусе оба 0.200. Политику `auto` менять не нужно, оговорка «11-16% при расходящемся тексте» снята. Постановка задачи содержала дефект: корпус `Tests/Fixtures/bench/` состоит из записей короче 11 с и не способен проявить эффект, поэтому длинное аудио получено склейкой корпуса — ограничения приёма описаны в отчёте.

## T14 — Предкомпилированный `default.metallib` вместо рантайм-компиляции шейдера ✅ DONE (2026-07-27)

- **What:** сейчас `ggml-metal.metal` компилируется в рантайме при первом старте — ~5.8 с на холодном кеше. С установленным Xcode доступен `xcrun metal`, можно собирать `default.metallib` заранее в `build-app.sh`.
- **Why:** убирает единственную заметную задержку первого запуска после установки.
- **Cons:** делает полный Xcode обязательным для сборки релиза (сейчас хватало Command Line Tools). Решение владельца.
- **Depends on:** независимо.
- **Outcome:** сделано в `build-app.sh`, замер на M5 Pro: **7.022 с → 0.001 с** первого старта на холодном кеше. Библиотека собирается без фича-макросов (как апстрим), а приложение принудительно выставляет `GGML_METAL_TENSOR_DISABLE`, приводя рантайм в соответствие: `GGML_METAL_HAS_TENSOR` не добавляет кернелы, а подменяет их реализацию, поэтому одна библиотека не может обслужить и M5, и M1-M4. Осознанная цена: на M5 в Metal-режиме теряется tensor-ускорение энкодера; основной путь (auto → Neural Engine) не затронут. Проверка самодостаточности в `build-app.sh` переписана — прежний инвариант после этой правки не выполнялся бы никогда. Требуется догруженный Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), при его отсутствии сборка откатывается к прежнему поведению, а не падает.

---

## T15 — Package.swift форка не тайпчекается на Xcode 16.x

- **What:** манифест `Package.swift` в форке `Informat1on/SwiftWhisper` падает на Xcode 16.4 с ошибкой «the compiler is unable to type-check this expression in reasonable time» на выражении `let package = Package(...)`. На Xcode 26.6 собирается нормально.
- **Why:** найдено первым же прогоном CI 2026-07-27 (раннер `macos-15` несёт Xcode 16.4). Пока это не исправлено, проект собирается только на Xcode 26.x — раньше об этом никто не знал, потому что локально стоит свежий Xcode. CI переведён на раннер `macos-26` как обход, но ограничение осталось.
- **How:** разбить большое выражение `Package(...)` в манифесте форка на промежуточные переменные (массивы targets/dependencies уже частично вынесены — доделать так же для остального). Затем пуш форка, новый тег, обновление pin по SHA в `Package.swift` VoiceType и `swift package resolve`.
- **Pros:** проект перестаёт зависеть от конкретной мажорной версии Xcode; CI можно вернуть на стабильный раннер.
- **Cons:** правка внешнего репозитория с цепочкой тег → pin → resolve.
- **Depends on:** независимо.

## Process TODOs

## P1 — Update CLAUDE.md `## Design System` section ✅ DONE (2026-04-24)

- **What:** расширить секцию `## Design System` в `CLAUDE.md` ссылками на новые разделы DESIGN.md (Interaction States, Accessibility, User Journey, Error Handling, Transcription History, Focus Return).
- **Why:** сейчас CLAUDE.md упоминает только общий compass и Decisions Log. После сегодняшней ревизии DESIGN.md вырос с 381 до ~650 строк с 10+ новыми разделами.
- **Pros:** CLAUDE.md остаётся проводником; /design-review и другие skills знают где искать.
- **Cons:** ~5 мин редактирования.
- **Depends on:** после commit DESIGN.md.

## P2 — Context-save после сессии ✅ DONE (recurring; latest 2026-04-27)

- **What:** запустить `/context-save` с title "v1.1 Track 1 — design review complete, DESIGN.md locked, ready for Tier A".
- **Why:** окно контекста заполняется. Текущая сессия имеет огромное количество decisions (30+ в Decisions Log), которые стоит зафиксировать вне conversation memory.
- **Pros:** следующая сессия может `/context-restore` и получить полный state.
- **Cons:** нет, только плюсы.
- **Depends on:** после finalize passes (сейчас).

---

## v1.3.0 deliverables (2026-04-27, shipped) ✅

- **Toast logging fix.** `showErrorToast()` now persists every toast to `errors.log` (logging happens inside `ErrorToastWindow.show()` so all callers benefit). FIFO queue (max 3, oldest drops with warning), min-visible-time 2.5s, persistent toasts pre-empt the queue. 3 Codex review rounds. 8 ErrorToastQueueTests. (Поток F)
- **3 model presets.** Settings → Models now shows Fast / Balanced / Max Quality as primary UI; full 7-model list moved to "Advanced" DisclosureGroup. Single shared persistence key. (Поток E)
- **Codex review pipeline standardized.** `scripts/codex-review.sh` wraps `codex review` with 24h SHA-keyed caching, fail-fast on `--range <base>..<custom-head>`, ref-peeling for annotated tags. (Поток Helper)
- **`.gitignore` cleanup.** `.claude/`, `.cursorrules`, `AGENTS.md`, `LEAN-CTX.md` ignored at top level. (Поток Cleanup)

Test count: 296 → 316 (+20). SwiftLint: 54 warnings, 0 errors (baseline).
