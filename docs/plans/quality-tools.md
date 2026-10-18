# Этап 2 — инструменты качества: replay продового конвейера и контрольные примеры в Eval

Дата: 2026-09-24. Ветка: `feat/reliable-dictation` (этап 1 закоммичен `f6314e5`, не выпущен;
владелец решил копить этапы и выпустить одной версией). Источник — дорожная карта
журнала s21 §8 и §12-B.

## 1. Цель

Появляется воспроизводимый способ мерить качество и скорость **того же пути, что в
приложении** (модель в памяти, CoreML/Metal, формула потоков, пост-обработка), на наборе
записей — и сравнивать два прогона между собой. Eval Collector начинает копить не только
ошибки, но и контрольные («всё верно») примеры, с пометкой класса проблемы. Это
фундамент для этапа 3: без replay-замера изменения нормализатора/словаря/профилей нельзя
честно оценить.

**Главное ограничение — никакой деградации продового пути**: модель, промпт, язык,
правила пост-обработки и их порядок, вставка, запись — не меняются. Единственная правка
продового кода вне Eval — вынос секции пост-обработки в файл-расширение (дословно) и
новое поле с таймкодами сегментов в `TranscriptionOutcome` (только добавление).

**Вне этого инкремента:** B3 (теневой VAD, детектор повторов) — следующий инкремент, он
строится на данных replay. Мелкий долг D (тесты пишут в реальный `errors.log`) — отдельно.

## 2. Базовая линия (снять до правок на `f6314e5`)

- `swift build -c debug` — exit 0.
- `swift test` — 591 тест, 0 падений, 3 пропущено.
- `swiftlint lint --quiet 2>/dev/null | grep -c warning:` — 47, 0 errors.

## 3. Решения

### R1. Replay — харнесс-тест, не второй исполняемый таргет

`Tests/VoiceTypeTests/ReplayHarnessTests.swift`, по образцу `CorpusDumpTests.swift`
(обоснование в его шапке: второй продукт затащил бы eval-инструмент в релизную сборку,
а тестовый таргет уже линкует продовый код). Пропускается (`XCTSkip`), если не задан
`VOICETYPE_REPLAY_OUT` — обычный `swift test` и CI не затронуты.

Конфигурация сборки/запуска — **см. §3.R1a (по итогам спайка)**.

**Вход — два режима** (ровно один должен быть задан, иначе `XCTFail`):
- `VOICETYPE_REPLAY_HISTORY=<путь к history.jsonl>` — записи истории с непустым
  `audioPath`; аудио ищется в `VOICETYPE_REPLAY_AUDIO_DIR` (по умолчанию — каталог
  `audio/` рядом с файлом истории). Запись без файла аудио → строка `record` с
  `"error":"audio-missing"` (это не падение прогона, см. «Исход»).
  Фильтры: `VOICETYPE_REPLAY_ONLY=saved` — только `isSavedEval == true`;
  `VOICETYPE_REPLAY_LIMIT=N` — первые N после фильтра (порядок — как в файле).
  Записи со `status == "failed"` включаются (их текст пустой — это и есть смысл повтора).
- `VOICETYPE_REPLAY_DIR=<каталог>` — все `*.wav`/`*.caf` по имени; эталон — одноимённый
  `.txt` рядом, если есть (так устроен `Tests/Fixtures/bench/`: `01.wav` + `01.txt`).

**Настройки — как в приложении, без записи в его домен.** Язык, `customVocabulary`,
`normalizeTranscript`, `removeFillerWords`, `trimWhitespaceAfterInsert`, выбранная модель
читаются из домена `com.voicetype.app` **только на чтение** (сырые ключи через
`UserDefaults(suiteName:)`; `AppSettings(defaults:)` на домен приложения НЕ
конструировать — его `init` выполняет миграции с записью). Переопределения:
`VOICETYPE_REPLAY_PROMPT_FILE` (текст vocabulary; пустой файл = без промпта),
`VOICETYPE_REPLAY_MODEL` (путь к `.bin`). На время прогона значения выставляются в
`AppSettings.shared` тестового процесса **до** `loadModel` (он сам зовёт
`applyInitialPrompt()` из `AppSettings.shared`, `TranscriptionService.swift:662`) и
восстанавливаются в `defer`.

**Проверка эффективной конфигурации (fail-closed, до первой записи).** После загрузки
и прогрева харнесс сверяет: `service.currentInitialPromptText` ==
`PromptBudget.fullPrompt(seed:vocabulary:)` от ожидаемых значений (seed — как в
`applyInitialPrompt()`); язык и имя модели — ожидаемые. Не совпало → `XCTFail`, записи
не прогоняются. Если в домене приложения `customVocabulary` отсутствует/пуст и
`VOICETYPE_REPLAY_PROMPT_FILE` не задан — `XCTFail` («промпт не прочитан»; прогон без
промпта возможен только явным пустым файлом). Хеш установленного промпта пишется в `run`
(`promptHash` = часть `p…` штампа).

**Сверка со штампом истории.** В режиме истории у каждой записи сравнивается `p<hash>`
её `pipelineStamp` с `promptHash` прогона; флаг `promptMatchesHistory` в строке `record`; `comparableToHistory` = совпал `p<hash>`,
флаги `-nofill`/`-nolex` штампа и `model` записи с моделью прогона.
Сравнение «replay против истории» в `replay-compare.py` считается только по записям с
`comparableToHistory == true`; остальные выводятся отдельной строкой-счётчиком и
расхождением прогона НЕ считаются и «объяснёнными» тоже не объявляются.

**Путь распознавания** — ровно продовый: новый экземпляр `TranscriptionService`,
`loadModel(at:language:model:)` с кейсом `TranscriptionModel`, чтобы подхватился
CoreML-энкодер, ожидание окончания прогрева, затем на каждую запись
`transcribe(audio:language:)`. Сэмплы — тем же конвертером, что Retry в приложении
(`AudioCaptureService.loadSamples(from:)`, если это безопасно без старта записи — см. R1a).

**Таймкоды сегментов.** `TranscriptionOutcome` получает поле
`segments: [TimedSegment]` — сырые сегменты whisper до фильтра, с `startMs`/`endMs`
(у `SwiftWhisper.Segment` уже есть `startTime`/`endTime` в мс). Нужны B3 (где в записи
галлюцинация/повтор) и разбору ошибок. Прод поле не использует; поведение не меняется.

**Файл-бюджет.** `TranscriptionService.swift` — 1186 строк при пороге error 1200.
Первым шагом секции `// MARK: - Post-processing chain`, `// MARK: - Trim helper`,
`// MARK: - Pipeline stamp` (от `static func postProcess` до конца `pipelineStamp`,
~:1044–1180) переносятся **дословно** в `Sources/VoiceType/Services/TranscriptionService+PostProcess.swift`
как `extension TranscriptionService`. `postProcessingVersion` — `private static let`:
при переносе становится `static let` в том же расширении с сохранением комментария,
либо остаётся `private` внутри расширения, если все его пользователи переехали вместе.

**Выход — JSONL** в `VOICETYPE_REPLAY_OUT`, файл с правами `0600`; путь внутри рабочего
дерева репозитория отвергается (`XCTFail`) — транскрипты речи владельца, репозиторий
публичный (та же политика, что `scripts/history-report.py`). Схема — §5.K3.

**Исход.** Ошибка отдельной записи (нет аудио, ошибка чтения, `TranscriptionError`)
пишется в её строку `error` и прогон продолжается; в конце, если ошибок > 0, — `XCTFail`
с числом, поэтому `swift test` выходит ненулевым. Отсутствие модели/невозможность
загрузить — `XCTFail` сразу. **Ноль выбранных записей** после фильтров — `XCTFail`
(пустой каталог, `ONLY=saved` без сохранённых). `VOICETYPE_REPLAY_EXPECT=N` (опционально) —
число выбранных записей обязано быть равно N, иначе `XCTFail`.

**Отбор входа — чистая функция** в том же файле теста (`ReplayInput`: разбор строк
истории / листинг каталога → упорядоченный список `(key, audioURL, reference?, history?)`),
покрытая **обычными, не пропускаемыми** юнит-тестами на временных фикстурах: пустой вход,
фильтр `saved`, `LIMIT`, запись без `audioPath`, строка истории с `evalIssue` и без,
дубликат ключа в каталоге (`01.wav` + `01.caf` → разные ключи), битая JSON-строка →
ошибка с номером строки (не молчаливый пропуск).

**Ключ записи**: история — `id` (UUID); каталог — имя файла **с расширением**
(`01.wav`). Дубликаты ключей в одном прогоне — `XCTFail`.

**Выходной путь** канонизируется (`resolvingSymlinksInPath`, `standardizedFileURL`)
до проверки «не внутри репозитория»; корень репозитория берётся из `#filePath` теста,
тоже канонизированный.

**Допустимые побочные эффекты** (явный список; всё остальное — дефект): стандартные
логи whisper в stderr; запись в `~/Library/Logs/VoiceType/errors.log` на путях
ошибок/`removedTemplates` (продовое поведение `transcribe`); домен `UserDefaults`
тестового процесса (восстанавливается). Каталог `Models/` приложения не должен
измениться: shadow-symlink Metal-only пути (`TranscriptionService.swift:398–475`) при
выбранном CoreML-пути не создаётся — DoD сверяет листинг `Models/` до/после.

### R1a. Конфигурация сборки и запуска

По итогам спайка 2026-09-24 (Sonnet, worktree, 3 CAF из `audio/`):

- **Бэкенд в тестовом процессе = продовый**: и в debug, и в release —
  `whisper_backend_init_gpu: using MTL0 backend` + `Core ML model loaded`
  (`ggml-large-v3-turbo-encoder.mlmodelc`).
- **Скорость**: release asr 231–273 мс на 1,3–10 с аудио — в диапазоне живых
  `latencyMs.asr` приложения (~270–280 мс, s21 §14); debug 372–592 мс. Replay всегда
  запускается в **release**: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter ReplayHarnessTests`.
  `-DDEBUG` обязателен: без него тестовый таргет не компилируется
  (`ModelStatusTests` использует `_testSetModelStatus`/`_testModelLoadGeneration` под
  `#if DEBUG`). Флаг влияет только на Swift-код VoiceType (включает `#if DEBUG`-ветки),
  C-код whisper.cpp оптимизирован. `buildConfig` в JSONL = `"release"`.
- **Прогрев**: `loadModel` + `.warming → .ready` ≈ 1,0 с в release; харнесс ждёт
  `modelStatus == .ready` с таймаутом 120 с.
- **Сэмплы**: `AudioCaptureService().loadSamples(from:)` — чистое чтение `AVAudioFile`,
  микрофон/сессия не трогаются; использовать его (тот же конвертер, что Retry).
- **Побочные записи**: в спайке не обнаружены; `ErrorLogger.shared` пишет в реальный
  `errors.log` только на путях ошибок/`removedTemplates` — replay это допускает (журнал
  ротируется), но в отчёте T2 указать.
- ⚠️ **Без промпта результат разошёлся с историей**: 10-секундная запись дала `" а"`
  вместо полного текста из истории, короткая — тоже `" а"`. Гипотеза — не выставлен
  initial prompt (прод зовёт `applyInitialPrompt()` после `loadModel`,
  `AppDelegate.swift:697`). Поэтому **первый шаг T2 — сверка**: 5 записей истории с
  непустым текстом и штампом, совпадающим по `p<hash>` с промптом из домена приложения,
  прогнать с промптом; `raw` должен совпасть с `history.raw` хотя бы на 4 из 5. Если
  нет — СТОП и отчёт оркестратору с данными, остальное T2 не делать.

**Итоги реализации (2026-09-24, дополнение после T2):**
- ⚠️ Гипотеза про промпт была неверной. Настоящая причина мусора — сборка: `swift test`
  по умолчанию собирает через `swiftbuild`, в `SwiftWhisper_whisper_metal.bundle` лежит
  `default.metallib`, и декодер на Metal даёт мусор (WER 1,0 на bench; одинаково с
  CoreML и без). С `--build-system native` (как `build-app.sh`) — WER 0,178 на bench,
  совпадение `raw` с историей 23/24 сопоставимых. Команда replay:
  `swift test -c release --build-system native -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter ReplayHarnessTests`.
- Процесс xctest падает в atexit (`ggml-metal-device.m:622 GGML_ASSERT([rsets->data count] == 0)`):
  форк SwiftWhisper держит `Unmanaged.passRetained(self)` в `prepareCallbacks()` —
  `Whisper` не освобождается даже после `shutdown()` (он вернул `true`, strong-ссылка
  сервиса nil, weak-ссылка жива). Прод не задет: `applicationShouldTerminate` выходит
  через `_exit`. В харнессе не чинится → политика `replay.sh`: ненулевой код `swift test`
  (фактически `1`) считается успехом ТОЛЬКО если в stdout-логе есть
  `Test Suite 'ReplayHarnessTests' passed` строкой РАНЬШЕ строки ассерта; stdout/stderr
  пишутся в разные файлы. Проверено: чистый прогон → 0, битый файл → 1. Утечка `Whisper`
  в форке — долг (возможная утечка памяти в приложении при смене модели), вне инкремента.
- T3: вместо `Picker(.segmented)` — проектный `SegmentedControl` (нативный Picker в
  проекте заменён везде, codex audit P1); добавлен вариант `Not set` (контрол не умеет
  «ничего не выбрано»); вынесены `HistoryStore+EntryMutations.swift` и
  `EvalEditorView+SaveState.swift` (file_length 600 → иначе +2 warning).

### R2. `scripts/replay.sh` и `scripts/replay-compare.py`

- `replay.sh` — обёртка: копирует `history.jsonl` приложения во временный каталог вне
  репозитория (заморозка: владелец диктует во время прогона — gotcha s21) и **явно**
  передаёт `VOICETYPE_REPLAY_AUDIO_DIR=~/Library/Application Support/VoiceType/audio`
  (рядом с копией аудио нет), выставляет остальные переменные R1, запускает тест в конфигурации R1a, печатает путь к JSONL. Аргументы:
  `--out <файл>` (обязателен), `--only-saved`, `--limit N`, `--dir <каталог>` (режим
  каталога вместо истории), `--prompt-file`, `--model`. `set -euo pipefail`, shellcheck
  чистый. Ненулевой код теста → ненулевой код скрипта. Лог `swift test` пишется во
  временный файл вне репозитория (там могут быть тексты сегментов whisper) и после
  прогона проверяется. Временный каталог создаётся `mktemp -d` с `chmod 700`, лог — внутри
  него с `umask 077`; каталог удаляется `trap … EXIT` (JSONL в `--out` остаётся). Проверка: если в `run.coreMLRequested == true`, в логе обязана быть строка
  `Core ML model loaded` — иначе скрипт выходит с кодом ≠ 0 («CoreML запрошен, но не
  загружен — прогон не продовый»). Число строк `record` в JSONL обязано равняться
  `summary.records`; скрипт проверяет это сам. По умолчанию скрипт печатает только
  путь к JSONL и строку `summary`.
- `replay-compare.py A.jsonl [B.jsonl]` — только stdlib python3.
  С одним файлом: прогон против того, что лежит в истории (`history.raw`/`history.text`
  внутри A). С двумя: A против B по ключу записи. Печатает **только агрегаты** по
  умолчанию: число записей, ошибок; сколько изменилось `raw` и `final`; WER против
  эталона (эталон = `reference` строки, если есть) — среднее и по записям с эталоном;
  `transcribeMs` p50/p95 и RTF — с явной пометкой в выводе, что это время вызова
  `transcribe` (прогрев исключён, пост-обработка включена), а `latencyMs.asr` истории
  — от готовности сэмплов до конца ASR в приложении, и сравнивать их напрямую нельзя.
  Дубликаты ключей в любом из файлов, разная кратность — ошибка, exit ≠ 0. Тексты и diff — только с `--include-private-text`; `--out`
  внутрь рабочего дерева отвергается, файл `0600` (как в `history-report.py`). WER —
  функцией из `scripts/wer.py` (импорт), не копией.

### R3. Eval Collector: «всё верно», класс проблемы, сырой текст

`Sources/VoiceType/Views/Eval/EvalEditorView.swift`, `EvalEditorWindow.swift`,
`HistoryStore.swift` (+ `HistoryStore+FailedTranscriptions.swift`).

- **Сохранение без правок.** Кнопка футера больше не отключается при неизменённом
  тексте: без правок подпись — `Save as correct` (контрольный пример:
  `userCorrection = text`, `isSavedEval = true`), с правками — `Save eval pair` (как
  сейчас). Одна кнопка, стиль `ChecklistPrimaryButtonStyle`, `Cmd+Return` сохраняется;
  accessibilityLabel соответствует подписи. Для failed-записи (`status == .failed`, текст
  пустой) и при пустом поле исправления кнопка отключена.
- **Класс проблемы.** Новое опциональное поле `HistoryStore.Entry.evalIssue: String?`,
  значения ровно `"asr" | "postprocess" | "insertion" | "capture"`; `nil` — не указан
  или контрольный пример. Выбор — строка под полем исправления, видна только когда текст
  изменён: `Picker` в стиле `.segmented` с вариантами `ASR`, `Post-processing`,
  `Insertion`, `Capture`, без выбора по умолчанию (не выбрано = `nil`). При сохранении
  без правок `evalIssue` принудительно `nil`.
- **Сырой текст.** Если `entry.rawText != nil` (конвейер изменил вывод), над блоком
  `WHISPER OUTPUT` показывается read-only блок `RAW (BEFORE POST-PROCESSING)` в том же
  оформлении; существующий блок переименовывается в `FINAL TEXT`. Если `rawText == nil`
  — как сейчас, один блок, подпись `WHISPER OUTPUT`. Diff-подсветки нет (осознанно: без
  неё проще, raw рядом с final уже отвечает на вопрос «кто испортил»).
- **Модель данных.** `evalIssue` добавляется во ВСЕ места, строящие `Entry` через полный
  memberwise init (`withEvalSaved`, `withAudioPathCleared`, `withInsertOutcome`,
  `withTranscriptionResult`, `withLatency`, `withFailureReason` и любые другие — найти
  grep'ом `Entry(` по `Sources/`), каждое копирует поле без изменений, кроме
  `withEvalSaved(correction:issue:)`, который его выставляет. Старые записи без поля
  декодируются как `nil`.
- **Rotation.** Сохранение без правок идёт тем же `EvalEditorWindow.handleSave`: если
  запись исчезла из истории — ничего не пишется, окно не закрывается (как сейчас).
  Проверяется в живой приёмке (DoD 7) и тестом на уровне логики сохранения, если
  `handleSave` выносится в тестируемую функцию; UI-отключение кнопки — отдельными
  тестами вычисляемого состояния (вынести `saveButtonState(entry:correction:)` в
  чистую статическую функцию: `.saveAsCorrect | .saveEvalPair | .disabled`).
- **DESIGN.md** — запись в `## Decisions Log` (дата, что изменилось, почему: копились
  одни ошибки, контрольных примеров не было — replay нечем сравнивать).
- `evalIssue` читается `replay-compare.py` (разбивка WER по классу, агрегатом).

## 4. Декомпозиция и граф

| Задача | Содержание | Исполнитель | Где |
|---|---|---|---|
| T1 | Вынос секции пост-обработки + `TimedSegment` в `TranscriptionOutcome` | Sonnet A | worktree A |
| T2 | `ReplayHarnessTests` + `replay.sh` + `replay-compare.py` (зависит от T1) | Sonnet A (тот же, продолжение) | worktree A |
| T3 | Eval Collector (R3) + DESIGN.md | Sonnet B | worktree B |

`[T1 → T2] ∥ T3`. Пересечений по файлам нет: A не трогает `HistoryStore*`/`Views/Eval`
(историю читает через `HistoryStore.Entry: Decodable` — новое опциональное поле B
декодированию не мешает). Оркестратор переносит патчи A и B в основную копию, прогоняет
сборку, тесты, lint, затем replay-DoD вживую.

## 5. Контракты

**K1. TimedSegment и поле outcome** (`TranscriptionService.swift`, рядом с `TranscriptionOutcome`):
```swift
/// One raw whisper segment, before the hallucination filter. Times in ms from
/// the start of the audio (SwiftWhisper.Segment already converts from 10 ms units).
struct TimedSegment: Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct TranscriptionOutcome {
    // существующие поля без изменений …
    /// Raw whisper segments with timings, in decode order. Consumed by the replay
    /// harness only; the dictation path ignores it.
    let segments: [TimedSegment]
}
```
Заполняется в `transcribe` из `segments: [Segment]`, возвращённых `runNative`. Все
существующие места, создающие `TranscriptionOutcome` (включая тесты), получают аргумент.

**K2. Entry** (`HistoryStore.swift`):
```swift
/// Eval Collector: what went wrong, set by the user when saving a corrected
/// pair — "asr" | "postprocess" | "insertion" | "capture". nil = not set, or a
/// control example saved as correct. Legacy entries decode as nil.
let evalIssue: String?

func withEvalSaved(correction: String, issue: String?) -> Entry
```
`EvalEditorView.onSave: (_ correction: String, _ issue: String?) -> Void`.

**K3. Replay JSONL** (одна JSON-строка на объект, UTF-8, ключи ровно такие):
```
{"kind":"run","startedAt":"<ISO8601>","mode":"history|dir","input":"<путь>",
 "model":"<имя файла модели>","coreMLRequested":<bool>,"threads":<int>,"language":"<rawValue>",
 "pipelineStamp":"<штамп прогона>","promptHash":"<12 hex, как p… в штампе>","promptSource":"app-domain|file","swiftWhisperRevision":"<из Package.resolved>",
 "buildConfig":"debug|release","loadMs":<int>}
{"kind":"record","key":"<entry id (history) | имя файла с расширением (dir)>",
 "audioFile":"<имя>","audioSeconds":<double>,
 "raw":"<string>","final":"<string>","removedTemplates":[...],
 "segments":[{"text":"…","startMs":0,"endMs":1234}],
 "transcribeMs":<int>,"rtf":<double>,"promptMatchesHistory":<bool, только режим истории>,"comparableToHistory":<bool, только режим истории>,
 "reference":"<userCorrection | текст .txt | отсутствует>",
 "evalIssue":"<если есть>",
 "history":{"raw":"<rawText ?? text>","text":"<text>","pipelineStamp":"<…>",
            "model":"<…>","asrMs":<latencyMs.asr или отсутствует>,"status":"<…>"},
 "error":"<отсутствует | audio-missing | read-failed: … | transcription: …>"}
{"kind":"summary","records":<int>,"errors":<int>,"transcribeP50Ms":<int>,"transcribeP95Ms":<int>,
 "totalAudioSeconds":<double>,"totalTranscribeMs":<int>}
```
Отсутствующие значения — ключ опускается (не `null`). `history` — только в режиме
истории. `transcribeMs` — время вызова `transcribe` целиком после прогрева модели
(включает пост-обработку). С `latencyMs.asr` приложения (от `samplesReady` до конца
`runASR`, включая возможный `ensureModelLoaded`/повтор — `AppDelegate+Dictation.swift`)
напрямую не сравнивается — отсюда другое имя поля.

## 6. Риски

- **Тестовый процесс ≠ приложение** (Metal/CoreML/оптимизация C-кода в debug) — снимает
  спайк, R1a.
- **Побочные записи в реальные пути** при инициализации сервисов в тестовом процессе
  (`ErrorLogger.shared` → `~/Library/Logs/VoiceType/errors.log`, `AppSettings.shared` →
  домен xctest) — зафиксировать спайком; replay не должен писать в домен
  `com.voicetype.app` и в `history.jsonl`/`audio/` приложения ни при каких условиях.
- **Приватность** — транскрипты только вне репозитория, `0600`; в stdout теста и скриптов
  по умолчанию — ни строки речи.
- **Недетерминизм whisper** (temperature fallback) — DoD проверяет повтор; если тексты
  расходятся, это находка, а не повод ослаблять DoD молча.
- **Перенос полей Entry** — забытое поле в одном из `with…`-хелперов тихо теряет данные;
  тест на каждый хелпер.
- **Вставка текста/UI в Eval** — только экран разработчика, путь диктовки не затронут.

## 7. Definition of Done

1. `swift build -c debug` exit 0; `swift test` — 0 падений, число тестов ≥ 591 + новые,
   пропущенных — 3 + новые харнессы (skip без переменных); `swiftlint` — 0 errors,
   warnings ≤ 47; `shellcheck scripts/replay.sh` чисто.
2. `TranscriptionService.swift` < 1100 строк; перенос секции — дословный (diff показывает
   только перемещение + `TimedSegment`).
3. Replay на 10 записях истории: JSONL с `run` + 10 `record` + `summary`, `errors == 0`,
   `coreMLRequested == true` и `replay.sh` подтвердил `Core ML model loaded` в логе;
   повторный прогон — `replay-compare.py A B` показывает 0 изменённых `raw` и `final`.
   Прогон с `VOICETYPE_REPLAY_DIR` на пустом каталоге и с `--only-saved` при нуле
   сохранённых — exit ≠ 0 (проверка fail-closed).
4. Replay в режиме `--dir Tests/Fixtures/bench`: 25 записей, WER против `.txt` в выводе
   compare.
5. `replay-compare.py A` (против истории): на записях с `comparableToHistory == true`
   доля совпавших `raw` ≥ 80 % (ниже — СТОП, разбор оркестратором: значит replay не
   воспроизводит прод); записи с другим промптом — отдельным счётчиком, не в метрике.
   «Сопоставимая» запись = совпал `p<hash>` **и** флаги `-nofill`/`-nolex` штампа **и**
   `model` истории. Сопоставимых меньше 5 → `replay-compare.py` exit ≠ 0 («нечего
   сравнивать»), для DoD выбрать записи заново (свежие, после фиксации промпта).
6. Replay не изменил `history.jsonl`, `audio/`, листинг `Models/` и домен
   `com.voicetype.app` (сверка `shasum`/`ls -la`/`defaults export` до/после).
7a. После переноса обоих патчей — юнит-тест `ReplayInput` на строке истории с полем
   `evalIssue` (формат после T3) проходит.
7. Eval: юнит-тесты K2 (legacy decode, каждый `with…` сохраняет `evalIssue`,
   `withEvalSaved` без правок → `userCorrection == text`, `isSavedEval == true`,
   `evalIssue == nil`); живая проверка владельцем: Cmd+Opt+E → Save as correct → запись
   в истории помечена; правка + класс → оба поля в `history.jsonl`.
8. Code-review гейт — `ВЕРДИКТ: SHIP`.
