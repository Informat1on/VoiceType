# План: аудио пустого результата (волна 2, s26, 2026-09-26)

Ветка `feat/reliable-dictation`, база `e406a26`. Решение владельца 26.09 («да, давай,
грамотно всё делаем по твоему плану»): на цифровой тишине аудио удалять; пустой ответ
whisper записывать в историю как сбойную запись с Retry. Существующие 98 сирот уже
перенесены в Корзину (лично, 26.09).

## §1 Цель

Прекратить появление осиротевшего аудио. Сейчас (`docs/plans/pre-release-wave.md` §3 T4):
`handleRecordingStopped` (`AppDelegate.swift:~897`) сохраняет `<UUID>.caf` ДО
распознавания, а ветка пустого результата `transcribeAndInject`
(`AppDelegate+Dictation.swift:~233`) показывает «Nothing heard» и выходит, не записывая
историю, — файл остаётся без владельца (1–6 в день).

## §2 Поведение после изменения

| Случай в `transcribeAndInject` | Капсула | Аудио | История |
|---|---|---|---|
| Запись была ПРЕРВАНА (`captureFailure != nil` в `handleRecordingStopped` — частичная запись после «Recording interrupted») и есть `audioPath` — независимо от тишины и длительности | «Nothing heard» (как сейчас) | остаётся | сбойная запись `reason: "empty"` + Retry |
| Запись прервана, но `audioPath == nil` (аудио не сохранилось) | «Nothing heard» | — | не пишется (Retry невозможен — аудио нет) |
| Цифровая тишина (гейт `DigitalSilenceGate`, RMS < 0,002) | «Nothing heard» (как сейчас) | удалить | не пишется |
| whisper вернул "" и `audioDuration ≥ 1,0 с` и есть `audioPath` | «Nothing heard» (как сейчас) | остаётся | сбойная запись `reason: "empty"` → в History «Transcription failed (no speech recognized)» + Retry |
| whisper вернул "" и (`audioDuration < 1,0 с` или нет длительности) | «Nothing heard» | удалить | не пишется |
| whisper вернул "" и `audioPath == nil` | «Nothing heard» | — | не пишется |

Порог 1,0 с: короче — случайное нажатие хоткея; такой обрывок некому и нечего
повторять, а сбойные записи в History засорились бы шумом (сбойных записей — до 20,
`maxFailedEntries`; это отдельный лимит, не общий лимит истории 100). Прерванную запись
не удаляем никогда: код захвата специально сохраняет частичный звук как принадлежащий
пользователю (`AudioCaptureService` ~875–980), удалять его необратимо — нельзя. Retry сбойной записи уже существует и умеет `recordRetryFailure(reason: "empty")`.

Капсула и тексты не меняются — DESIGN.md Interaction States не трогается; в
`## Decisions Log` — одна строка о судьбе аудио/истории пустого результата.

## §3 Контракты

**C1. Решение — чистая функция** (новый файл
`Sources/VoiceType/Services/EmptyResultAudioPolicy.swift`):
```swift
enum EmptyResultAudioPolicy {
    enum Action: Equatable { case discardAudio, recordFailedEntry, nothing }
    static let minimumRetryableSeconds: Double = 1.0
    static func decide(isDigitalSilence: Bool, wasInterrupted: Bool,
                       audioPath: String?, audioDurationSeconds: Double?) -> Action
}
```
- `audioPath == nil` → `.nothing`.
- `wasInterrupted` → `.recordFailedEntry` (приоритет над тишиной и порогом).
- `isDigitalSilence` → `.discardAudio`.
- иначе `audioDurationSeconds` есть, конечно и `≥ minimumRetryableSeconds` →
  `.recordFailedEntry`; иначе → `.discardAudio`.

**C2. Сигнал тишины из `runASR`.** `runASR(samples:)` (приватный,
`AppDelegate+Dictation.swift:~102`) должен сообщать, сработал ли гейт. Сигнатура:
`private func runASR(samples: [Float]) async throws -> ASRResult`, где
```swift
enum ASRResult { case digitalSilence, transcribed(TranscriptionOutcome) }
```
(объявить рядом, `private` или `fileprivate` в том же файле). Лог гейта
(`AppLog.transcription.notice("Digital silence — ASR skipped …")`) остаётся на месте.
`retryTranscription` трактует `.digitalSilence` как пустой результат —
`recordRetryFailure(id:, reason: "empty")`, `.emptyResult` — поведение Retry не меняется.
Аудио сбойной записи при Retry НЕ удаляется ни в каком случае (им владеет запись).

**C3. Удаление аудио без владельца** — новый метод в `HistoryStore`:
```swift
func discardUnreferencedAudio(named filename: String)
```
- Имя проходит ту же проверку, что в `deleteAudioFiles` (`isSafeAudioFilename`) —
  небезопасное → запись через `errorLogger` без имени, ничего не удаляется.
- Если имя упомянуто в `audioPath` любой записи кэша (после `loadIfNeeded()`) — не
  удалять (защита от удаления чужого аудио), лог через `errorLogger` без имени.
- Иначе `removeItem`; `fileNoSuchFile` — тихо; прочие ошибки — `errorLogger`.
- `@MainActor`, как весь `HistoryStore`.

**C5. Тестируемый обработчик** (в том же новом файле, что C1):
```swift
@MainActor
struct EmptyResultAudioHandler {
    enum EmptyReason: Equatable { case digitalSilence, whisperEmpty }
    let store: HistoryStore
    let recorder: HistoryRecorder
    /// Возвращает выбранное действие (для тестов и лога).
    @discardableResult
    func handle(reason: EmptyReason, wasInterrupted: Bool, audioPath: String?,
                audioDurationSeconds: Double?, failure: (String) -> HistoryRecorder.FailedTranscription)
        -> EmptyResultAudioPolicy.Action
}
```
`handle` вызывает `decide(isDigitalSilence: reason == .digitalSilence, …)` и выполняет
действие: `.discardAudio` → `store.discardUnreferencedAudio(named:)`;
`.recordFailedEntry` → `recorder.recordTranscriptionFailure(failure(audioPath))`
(замыкание строит `FailedTranscription` c `reason: "empty"` и контекстом приложения —
AppDelegate-специфичные поля остаются в AppDelegate). Если `HistoryRecorder` не
позволяет внедрить `HistoryStore` — исполнитель проверяет его init и использует
существующий шов; если шва нет — сообщает, не изобретает. Тесты C5 (с
`HistoryStore.test(..., errorLogger:)`): `.digitalSilence` → файл удалён, записи нет;
`.whisperEmpty` + 2 с → сбойная запись с полями из C4, файл на месте;
`.whisperEmpty` + 0,5 с → файл удалён; `wasInterrupted` + `.digitalSilence` + 0,3 с →
сбойная запись, файл на месте.

**C4. Встраивание в `transcribeAndInject`.** Новый параметр
`wasInterrupted: Bool` у `transcribeAndInject` — БЕЗ значения по умолчанию (компилятор
заставляет каждое место вызова передать его явно; ревьюер проверяет, что в
`handleRecordingStopped` это `captureFailure != nil`). Маппинг: `.digitalSilence` →
`EmptyReason.digitalSilence`; `.transcribed` с пустым `text` → `.whisperEmpty`; ветка
вызывает `EmptyResultAudioHandler.handle(...)`; `handleRecordingStopped`
(`AppDelegate.swift`) передаёт `captureFailure != nil` (тот же `captureFailure`, что
решает показ «Recording interrupted»). Ветка пустого результата (и новый случай
`.digitalSilence`) вызывает `EmptyResultAudioPolicy.decide(...)`:
`.discardAudio` → `HistoryStore.shared.discardUnreferencedAudio(named: audioPath)`;
`.recordFailedEntry` → `historyRecorder.recordTranscriptionFailure(FailedTranscription(…,
reason: "empty"))` с теми же полями, что в ветке ошибки ASR (`targetAppName`/
`targetAppBundleID` из `sessionTargetApp` с фолбэком на frontmost, `language`, `model`,
`audioPath`, `audioDurationSeconds`) — итоговая запись: `text == ""`,
`status == .failed`, `failureReason == "empty"`, тот же `audioPath`; `.nothing` →
ничего. Порядок (фиксированный): `show(state: .emptyResult)` → действие по аудио/
истории (синхронно, на MainActor, до выхода из функции) → `appState = .idle` →
отложенный `hide()` под защитой `capsuleSessionID` (как сейчас). Действие выполняется
ДО `appState = .idle`, поэтому новая диктовка не может начаться, пока оно не завершено;
отложенный `hide()` по-прежнему не скроет капсулу следующей диктовки.

## §4 Файлы

- `Sources/VoiceType/Services/EmptyResultAudioPolicy.swift` (новый)
- `Sources/VoiceType/AppDelegate+Dictation.swift` (runASR, transcribeAndInject, retryTranscription)
- `Sources/VoiceType/AppDelegate.swift` (только передача `wasInterrupted` в вызов `transcribeAndInject`)
- `Sources/VoiceType/Services/HistoryStore.swift` (метод C3)
- `Tests/VoiceTypeTests/EmptyResultAudioPolicyTests.swift` (новый)
- `Tests/VoiceTypeTests/HistoryStoreEdgeCasesTests.swift` или новый файл — тесты C3
- `DESIGN.md` — строка Decisions Log

Один исполнитель (Sonnet) в основной копии.

## §5 DoD

- Тесты C1: все ветки таблицы §2 + граница ровно 1,0 с (→ recordFailedEntry), 0,999 с,
  `nil`-длительность, NaN/∞ длительность (→ discardAudio); `wasInterrupted` + тишина,
  `wasInterrupted` + 0,3 с, `wasInterrupted` + nil-длительность → recordFailedEntry;
  `wasInterrupted` + `audioPath == nil` → nothing.
- Тесты C3: удаляет файл без владельца; НЕ удаляет файл с безопасным именем, на который
  ссылается запись истории (файл остаётся, во временном логе есть запись, и в ней нет
  имени файла); НЕ удаляет по `../x`, `.`, `..`, `.hidden`, `a/b`, пустой строке (файлы
  вне/внутри каталога остаются, в логе нет имени); отсутствующий файл — без записи в
  лог. Тесты используют `HistoryStore.test(..., errorLogger: makeTestErrorLogger(in:))`.
- `swift build -c debug` exit 0; `swift test --build-system native` — 0 failures;
  `swiftlint lint --quiet` — 0 errors, warnings ≤ 47.
- Оркестратор после интеграции: установка по слову владельца и живая проверка с
  baseline — до проверки: множество файлов `audio/` и множество `audioPath` истории
  (только имена, сироты = 0 после чистки 26.09); затем (а) короткое нажатие хоткея < 1 с
  → новых файлов нет; (б) «молчаливая» запись ≥ 1 с, на которой whisper вернул "" →
  новая запись истории `status == failed`, `failureReason == "empty"`, её `audioPath`
  существует, History показывает «no speech recognized» + Retry; после — сирот 0.
  Цифровую тишину вручную не получить: её ветка доказывается юнит-тестом C1 и
  однострочным отображением `ASRResult.digitalSilence → isDigitalSilence: true`
  (проверка ревьюером по diff). Если в (б) whisper что-то распознал — записать как
  «не воспроизведено», не подгонять.

## §6 Риски

- Удаление аудио — необратимо. Защита: только базовое имя, только файл без записи-
  владельца, только файл текущей диктовки (имя пришло из `handleRecordingStopped`).
- Засорение History сбойными записями «empty» — ограничено порогом 1 с и лимитом 20.
- Другие источники сирот (путь `catch` в `handleRecordingStopped`, если
  `stopRecordingRetaining` бросил после записи файла) — вне этой волны; исполнитель
  проверяет и сообщает, может ли файл остаться на этом пути.
- Известное ограничение (не меняется): если копирование в `audioDestination` не
  удалось, `savedDuration == nil` → `audioPath == nil` → `.nothing`; сироты нет, но и
  Retry для такой записи невозможен — как и сейчас.

## §7 Решения plan-review

**r1** (тред `20260926-112207-80274`) REVISE, 1×P1 / 3×P2 / 3×P3. Приняты все: P1 —
прерванная запись никогда не удаляется, всегда сбойная запись (параметр
`wasInterrupted`); фиксированный порядок действий относительно `appState`/`hide()`;
живая проверка с baseline и по конкретным файлам, ветка тишины — юнит-тестом; тест C3 на
безопасное имя с владельцем и отсутствие имени в логе; уточнён лимит «до 20 сбойных»;
поля сбойной записи в контракте; ограничение `savedDuration == nil` записано.

**r2** REVISE, 2×P2 / 1×P3. Приняты: тестируемый обработчик C5 с внедряемыми
store/recorder и явной причиной пустоты (проверка проводки тишины и прерывания без
AppDelegate); `wasInterrupted` без значения по умолчанию; строка таблицы «прервана, но
аудио нет». Retry `.digitalSilence` — тривиальный маппинг в `recordRetryFailure("empty")`,
аудио не трогается; проверяется ревьюером по diff (AppDelegate без шва для теста).

**r3** REVISE, 2×P2 / 1×P3 — уточнения контракта C5, приняты все и переданы
исполнителю: `failure` вызывается только на `.recordFailedEntry` с развёрнутым
`audioPath`; инвариант «store и recorder — один `HistoryStore`» (doc-комментарий, прод —
`.shared`); тесты C5 — обязательный пункт DoD, плюс сценарий `.nothing` с проверкой
невызова замыкания и возвращённого `Action`. Лимит 3 раунда → **override оркестратором**:
спора нет, все замечания приняты, архитектура не менялась.
