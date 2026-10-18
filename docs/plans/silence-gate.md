# Гейт цифровой тишины в прод-пути (этап 2, задача A после B3)

Дата: 2026-09-24. Ветка `feat/reliable-dictation`, база `2ee0a41`.

## 1. Цель

Запись, которая целиком является цифровой тишиной, не отдаётся whisper: вместо
галлюцинации (вставленной пользователю) показывается существующее состояние
`emptyResult` («Nothing heard»). Основание — `docs/plans/shadow-vad.md` §8: на всей
истории 2 записи с RMS ≈ 0,00002 дали вставленную галлюцинацию, фильтр их не снял;
самая тихая настоящая речь — RMS 0,0104. Самая тихая речь в ~5 раз выше порога 0,002,
тишина — в ~100 раз ниже.

## 2. Ограничения

- Модель, custom prompt, фильтр галлюцинаций, нормализатор — не менять.
- `TranscriptionService.transcribe` не менять: прогрев модели
  (`TranscriptionService.performWarmUp`, `TranscriptionService.swift:~720-755`) гоняет
  8000 нулей через `runNative` напрямую — ни `transcribe`, ни `runASR` он не проходит
  (сверено 24.09); гейт в `runASR` его не задевает.
- UI/DESIGN.md: новое состояние не вводится; `emptyResult` «Nothing heard» уже описан
  в DESIGN.md (Interaction States, строка «whisper returned ""»; Decisions Log
  2026-04-24 «confirms app ran when hotkey fired accidentally») — смысл совпадает.
  Строку таблицы Interaction States уточнить («whisper returned "" или вход — цифровая
  тишина») + запись в Decisions Log.
- Приватность: в лог — только числа (RMS, длительность), никакого текста.

## 3. Дизайн

### T1. `Sources/VoiceType/Services/DigitalSilenceGate.swift` (новый)

```swift
/// docs/plans/shadow-vad.md §8, docs/plans/silence-gate.md.
enum DigitalSilenceGate {
    /// RMS всей записи по float-сэмплам [-1, 1], ниже которого запись — цифровая тишина.
    static let rmsThreshold: Double = 0.002

    /// Единственный API гейта и единственная точка решения — ОДИН проход по массиву.
    /// И прод (`runASR`), и replay зовут только её; тесты проверяют `Decision`.
    /// `rms` = sqrt(Σ Double(x)·Double(x) / Double(count)), без промежуточных массивов
    /// и копий; пустой массив → rms 0.
    /// `isDigitalSilence` ⇔ samples непуст, rms конечен и rms < rmsThreshold (строго).
    /// Пустой массив → false (решение о пустой записи принимается выше по стеку).
    /// Нечисловой RMS (NaN/Inf в сэмплах) → false: при сомнении распознаём (fail-open
    /// в сторону прежнего поведения).
    struct Decision: Equatable { let rms: Double; let isDigitalSilence: Bool }
    static func evaluate(_ samples: [Float]) -> Decision
}
```

Других публичных методов нет (ни `rms`, ни `isDigitalSilence` отдельно). `evaluate` —
`nonisolated static` (проект в Swift 6 strict concurrency — исполнитель
сверяет с соседними чистыми функциями, например `AppDelegate.insertionTargetDecision`).

### T2. `runASR` (`Sources/VoiceType/AppDelegate+Dictation.swift:103-117`)

Первой строкой `runASR(samples:)` — `let decision = DigitalSilenceGate.evaluate(samples)`
(один проход). Если тишина:
- `AppLog.transcription.notice("Digital silence — ASR skipped …")` с `rms`, `sampleCount`
  и длительностью (`samples.count/16000`), `privacy: .public` только для чисел;
- возврат `TranscriptionOutcome` с пустыми `rawText`/`text`, `removedTemplates: []`,
  `segments: []`, `pipelineStamp: ""` — без вызова `ensureModelLoaded` и `transcribe`.

Обоснование: обе вызывающие стороны уже корректно обрабатывают пустой `text`
(живая диктовка — ветка `emptyResult`, `:209-226`; повтор из History —
`recordRetryFailure(reason: "empty")` → `.emptyResult`, `:462-465`), поэтому им правки
не нужны. Источник `samples` в обоих путях один и тот же по устройству: живая
диктовка — `stopRecordingRetaining` закрывает временный CAF и читает его через
`loadSamples` (`AppDelegate.swift:895-900`, `AudioCaptureService+FileIO.swift:36-67`);
повтор и replay — тот же `loadSamples` по сохранённому файлу. Живая диктовка по-прежнему не пишет запись в историю при пустом результате
(прежнее поведение `emptyResult`).

### T3. Replay (`Tests/VoiceTypeTests/ReplayHarnessTests.swift:487+`, `+JSONL.swift:43`)

Replay обязан воспроизводить прод-конвейер (контракт s23). В `transcribeOne` после
`loadSamples` — тот же `DigitalSilenceGate.evaluate(samples)`; при `isDigitalSilence`:
whisper не вызывается, `raw: ""`, `final: ""`, `removedTemplates: []`, `segments: []`,
`transcribeMs: 0`, `rtf: 0`, `error: nil`. Контракт JSONL (Swift-сторона):
- `ReplayRecordJSON` (`+JSONL.swift:43`) — новое поле `silenceGated: Bool?` (true/false во
  всех записях с `error == nil`; nil — во ВСЕХ записях с ошибкой: отсутствие аудио,
  ошибка чтения, ошибка whisper);
- `RecordOutcome` (`+Support.swift:46`) — флаг `silenceGated: Bool`;
- `ReplaySummaryCounts` (`+Support.swift:58`) и `ReplaySummaryJSON` (`+JSONL.swift:62`) —
  счётчик `silenceGated: Int`. Семантика агрегатов сводки (`runAllRecords` ~`:441-467`):
  `records` — все record lines (gated входят); `errors` — только записи с ошибкой;
  `silenceGated` — число gated; `totalAudioSeconds` — все успешно прочитанные аудио,
  ВКЛЮЧАЯ gated (это агрегат длительности, не работы whisper); `totalTranscribeMs`,
  `transcribeP50Ms`/`P95Ms` и производный RTF — только записи, где whisper реально
  вызывался (gated исключены). Исполнитель сверяет фактические имена полей в коде.

`scripts/replay-compare.py`:
- в отчёт — строка `silenceGated=<N>` из summary (старые JSONL без поля → `n/a`, не
  падение) и список ключей записей с `silenceGated: true` (ключи — UUID/имена файлов,
  не текст);
- fail-closed проверка консистентности одиночного прогона, exit ≠ 0 с перечнем
  нарушений: (1) у каждой записи с `silenceGated: true` — `final == ""`, `raw == ""`,
  `transcribeMs == 0` (реальный вызов whisper всегда ≥ 1 мс — косвенное доказательство,
  что ASR не вызывался); (2) если в summary есть `silenceGated` — он равен числу
  record lines с `silenceGated: true`; (3) если в summary есть `silenceGated` (маркер
  новой схемы) — у КАЖДОЙ записи с `error == null` поле `silenceGated` присутствует и
  является Boolean, у записей с ошибкой — отсутствует или null. Нет поля в summary →
  legacy-режим: проверки (1)–(3) пропускаются, в отчёте `silenceGated=n/a`;
- опция `--expect-gated-keys <файл>` (JSON-массив ключей): fail-closed сравнение
  множества ключей с `silenceGated: true` с ожидаемым; расхождение → exit ≠ 0 с
  перечнем лишних/недостающих ключей;
- тесты в `scripts/tests/` на обе ветки (есть поле / нет поля), на каждое нарушение
  консистентности (включая успешную запись без поля при новой схеме) и на `--expect-gated-keys` (совпало / лишний / недостающий).

`scripts/shadow-analysis.py`: опция `--keys-below-rms <порог> <файл>` — пишет в файл
JSON-массив ключей (`key` из replay) записей с `recordRms < порог`, отсортированный. Ключи
не приватны (UUID/имена файлов), поэтому ограничение `--out` (вне репозитория) на неё не
распространяется, но текст в файл не пишется. Тест в `scripts/tests/`.

### T4. Тесты `Tests/VoiceTypeTests/DigitalSilenceGateTests.swift` (новый)

- (все проверки через `evaluate(...)`) 8000 нулей → isDigitalSilence true; пустой массив → false; массив с NaN → false;
- синус амплитуды A с RMS = 0,0104 (A = 0,0104·√2), 16000 сэмплов → false;
- «шум» RMS ≈ 0,00002 → true;
- граница: `let c = Float(0.002)`; ожидание строится от фактического
  `evaluate([c,…]).rms` через сравнение с `rmsThreshold` (тест не утверждает «ровно 0,002»);
  константа `Float(0.0019)` → true; `Float(0.0021)` → false;
- `+Inf`, `-Inf`, смесь конечных и NaN → false;
- `Decision.rms` на константе c → |Double(c)| с допуском 1e-9;
- длинный массив (15 мин = 14 400 000 нулей) → true, без таймаута теста.

## 4. Порядок

T1 → (T2 ∥ T3 ∥ T4) — всё мелкое, один Sonnet-исполнитель в основной копии,
последовательно. DESIGN.md правит он же (строка таблицы + Decisions Log).

## 5. Definition of Done

1. `swift build -c debug` exit 0.
2. `swift test --build-system native` — все тесты зелёные, включая новые (сверить
   число тестов до/после).
3. `swiftlint lint --quiet | grep -c 'warning:'` ≤ 47 (baseline 24.09), 0 errors.
4. `python3 -m unittest discover -s scripts/tests` — exit 0, все прежние тесты плюс новые.
5. Replay по истории (оркестратор, лично): один прогон `scripts/replay.sh` новой кодовой
   базой, сразу за ним `scripts/shadow-analysis.py` на той же замороженной копии
   (урок s24 §3.1 — ротация аудио) с `--keys-below-rms 0.002 <scratch>/expected.json`.
   Проверки машинные: (а)+(б) `replay-compare.py <replay.jsonl> --expect-gated-keys
   <scratch>/expected.json` exit 0 — консистентность gated-записей, счётчик сводки и
   равенство множества `silenceGated: true` множеству `recordRms < 0.002` из
   shadow-analysis (он считает RMS независимо, по
   WAV через afconvert; зазор данных ~5×/~100× от порога делает расхождение шкал
   нормализации Int16.max vs 32768 несущественным); (в) `analysisErrors=0`, error-записей
   replay 0. На 24.09 ожидается ровно одна такая запись (`E7B4985C…` или `0618E3A9…`;
   вторая выбыла ротацией). Сравнение «до/после» двумя прогонами whisper не
   используется: негейтованные записи идут неизменённым путём по построению, а
   прогоны whisper не строго детерминированы (s23: 31/32).
6. Сборка `./build-app.sh --install` — по слову владельца; ручная проверка владельцем:
   обычная диктовка работает; повтор из History прежний.

## 6. Риски

- **Шкала анализа ≠ шкала приложения.** Анализ: afconvert → WAV 16-bit, деление на
  32768, целочисленный downmix. Приложение: `loadSamples` (AVAudioConverter, деление на
  `Int16.max`, downmix в Float). Расхождение — доли процента, против зазора ~5× — не
  влияет; DoD п.5(б) сверяет обе шкалы на реальных данных.
- **Прерванная запись ниже порога** — toast «Recording interrupted» и затем
  `emptyResult`. Та же пара уже возникает сегодня, когда whisper возвращает пусто на
  частичной записи; «Nothing heard» для цифровой тишины — правда. Не меняется.
- **Ложное срабатывание на очень тихом микрофоне.** Зазор ~5× до самой тихой речи на
  одном микрофоне владельца. Лог RMS даёт данные для пересмотра порога.
- **Осиротевшее аудио.** При пустом результате аудио уже сохранено, а запись в историю
  не пишется — файл остаётся без владельца (на 24.09 таких 93 из 195 в каталоге). Это
  существующий долг, гейт его не увеличивает сверх прежнего пути `emptyResult`. Вне
  рамок; отдельный пункт долга.

## 7. Ревью плана

Раунд 1 (pi-run `20260924-172740-80172`, REVISE, 0 P1 / 7 P2 / 3 P3). Принято: P2.1
(источник samples, риск шкал), P2.2 (контракт JSONL на Swift-стороне), P2.3 (fail-closed
консистентность + DoD без A/B-прогонов), P2.5 (численные края), P2.6 (один проход),
P2.7 частично (sampleCount, «ASR skipped»), P3.2. Отклонено: P2.4 — пара toast +
emptyResult уже существует для пустого результата на частичной записи, новое поведение не
вводится (см. §6); P2.7 `source=live|retry`, `interrupted` — потребовали бы менять сигнатуру
`runASR` ради лога редкого случая; P3.1 — сборка это проверит; P3.3 — grep-проверка
(единственный прод-вызов `transcribe`) достаточна, архитектурный тест на вызывающих
несоразмерен.

Раунд 2 (тот же тред, REVISE, 0 P1 / 4 P2). Принято: P2.1 (`evaluate` — один проход),
P2.2 (`--keys-below-rms` + `--expect-gated-keys`, DoD 5 машинный), P2.3 (семантика
агрегатов сводки, проверка счётчика). P2.4 принято частично: косвенное доказательство
пропуска ASR — `transcribeMs == 0` у gated-записей (fail-closed в replay-compare);
spy-seam вокруг `TranscriptionService`/`runASR` отклонён — ради одного `if` в начале
функции он потребовал бы протокола над сервисом и рефакторинга `AppDelegate`; пропуск в
приложении проверяется код-ревью и строкой лога «ASR skipped». Прогрев не менялся
(`runNative`), что видно в diff.

Раунд 3 (тот же тред, REVISE, 0 P1 / 2 P2 / 1 P3). Принято всё: обязательность
`silenceGated` при новой схеме (маркер — поле в summary; legacy — `n/a`), единственный
API `evaluate` (без `rms`/`isDigitalSilence`). Лимит 3 раунда исчерпан; спора нет, все
замечания раундов 2–3 — сужение контракта проверок, правки механические → override
оркестратором, дальнейшая защита — code-review.

## 8. Код-ревью и проверка

- Код-ревью r1 (pi-run `20260924-175624-10636`): FIX — P2 тайминги отчёта replay-compare
  включали gated-записи, P3 формулировка комментария; оркестратор добавил: файл
  `--keys-below-rms` писался при ошибках анализа (сделан атомарным и fail-closed),
  неточный комментарий в `runASR`. r2 (тот же тред): **SHIP**, новых замечаний нет.
- DoD: swift build exit 0; swift test --build-system native 628 тестов, 0 падений
  (до правок r1 — они затронули в Swift только комментарий); swiftlint 47 warnings /
  0 errors; python unittest 102 OK.
- DoD 5 (24.09, лично): replay 102 записи, errors 0, `silenceGated` 1 —
  `0618E3A9…`; `replay-compare.py --expect-gated-keys` exit 0 (множество совпало с
  `recordRms < 0.002`). shadow-analysis: 101/102 — аудио одной записи (`7AE36A6A…`,
  290 с речи, по replay `silenceGated: false`) удалила ротация во время прогона
  (известная проблема, s24 §12-B); по плану п.5(в) формально — отступление, принято
  оркестратором: запись заведомо речь.
