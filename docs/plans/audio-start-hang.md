# Старт записи не должен вешать приложение

## Цель

`startRecording` никогда не блокирует главный поток. Аудиоустройство, которое не
поднимает IO-поток, даёт понятную ошибку за ≤4 с вместо многоминутного фриза всего
приложения.

## Контекст — что именно ломается (диагностика 15.09.2026)

Факты из системного лога, не гипотезы:

- Вход в настройках — `preferredInputDeviceUID = 3144390B-D496-4308-B90E-029C0B6A1536`
  = **Elgato Wave Link MicFX** (виртуальный драйвер `WaveLink3VirtualAudio.driver`),
  он же системный default input.
- `coreaudiod`: `HALS_IOContext_Legacy_Impl::StartIOThread: got an error ... Error: 0x3C`
  (0x3C = 60 = ETIMEDOUT). Клиентская сторона: `HALC_ProxyIOContext::IOWorkLoop:
  the server failed to start`. Ретраится **бесконечно**, каждые ~14 с: 14.09 с 09:12:39
  до 09:16:39 — 17 таймаутов на одну попытку записи.
- Цепочка вызова целиком на main: `HotkeyService.swift:195` (`Thread.isMainThread` →
  выполняем прямо здесь) → `AppDelegate.swift:738` `handleRecordingStarted` →
  `AppDelegate.swift:770` `startRecording` → `AudioCaptureService.swift:238`
  `try sessionQueue.sync { … session.startRunning() }`.
- Следствие: `spindump … hang likely` (13.09, 15.09 ×2), `slow hid response (395.0s)`
  (13.09). Крэшей нет — каждый раз процесс завершал владелец вручную.
- Встроенный фолбэк не срабатывает: он уходит на системный default input, а это
  то же самое MicFX (`AudioDeviceResolver.resolve` отдаёт `.useSystemDefault`, ветка
  `preferredUID == systemDefaultUID`).

## Файлы

| Файл | Что делаем |
|---|---|
| `Sources/VoiceType/Services/AudioCaptureService.swift` | неблокирующий старт, watchdog, identity попытки, attempt-owned cleanup |
| `Sources/VoiceType/Services/AudioCaptureError.swift` | три новых кейса ошибки |
| `Sources/VoiceType/AppDelegate.swift` | асинхронный исход старта, состояние `.starting`, отмена, UI ошибок |
| `Sources/VoiceType/Views/MenuBar/MenuBarView.swift` | новый `MenuBarState.starting` — иначе не соберётся |
| `Sources/VoiceType/Services/HotkeyService.swift` | шов, делающий toggle/stop проверяемыми тестом |
| `Tests/VoiceTypeTests/AudioStartTimeoutTests.swift` | новый файл, тесты без живого микрофона |
| `Tests/VoiceTypeTests/MenuBarStateTests.swift` | тесты на `.starting` |
| `Tests/VoiceTypeTests/HotkeyServiceSyncTests.swift` | тест menu-start → hotkey-stop |

## Задача 1 — AudioCaptureService: старт без блокировки main

Новый публичный контракт (дословно):

```swift
/// Идентичность попытки старта. `public`, потому что возвращается из
/// публичного метода: без этого сигнатура не скомпилируется.
public struct StartAttemptID: Equatable, Sendable { /* непрозрачное значение */ }

/// Запускает запись. Возвращается немедленно; вызывать только с main.
/// `completion` вызывается РОВНО один раз и всегда на main — включая отмену.
///
/// ⚠️ `completion` НИКОГДА не вызывается inline, даже для немедленных отказов
/// (`.alreadyRecording`, `.captureDeviceBusy`): он всегда ставится на main
/// асинхронно и потому гарантированно приходит ПОСЛЕ возврата метода. Иначе
/// вызывающий не успел бы сохранить возвращённый `StartAttemptID`, сверка
/// identity в колбэке отбросила бы законный отказ, и `AppDelegate` навсегда
/// остался бы в `.starting`.
///
/// `timeout` — предельный срок ВСЕЙ попытки (разрешение устройства, создание
/// входа, конфигурация сессии, `startRunning()`), а не только последнего шага.
/// 4 с выбраны потому, что собственный таймаут CoreAudio — 14 с, и ждать его
/// означает тот самый фриз, который эта задача устраняет.
@discardableResult
func startRecording(
    preferredDeviceUID: String?,
    timeout: TimeInterval = 4.0,
    completion: @escaping (Result<Void, AudioCaptureError>) -> Void
) -> StartAttemptID

/// Отменяет незавершённый старт (пользователь отпустил хоткей, пока сессия
/// поднималась). Идемпотентна, безопасна в любом состоянии. Если старт ещё не
/// разрешился, его `completion` получает `.failure(.startCancelled)` — ровно
/// один раз, как и любой другой исход.
func cancelPendingStart()
```

Требования:

1. **В пути старта нет ни одного `sessionQueue.sync`, вызванного с main.** Конфигурация
   сессии и `session.startRunning()` уходят на `sessionQueue` асинхронно.
2. **У каждой попытки есть идентичность** (`StartAttemptID` — монотонный счётчик либо
   UUID). Проверки одного лишь состояния недостаточно: попытку A отменили или она
   отвалилась по таймауту, пользователь начал B, и поздний результат A обязан быть
   отброшен, а не принят за результат B. Идентичность сверяется и внутри сервиса, и
   в колбэке `AppDelegate`.
3. **Ровно один терминальный исход на попытку.** Watchdog, `cancelPendingStart()`,
   успех и синхронный сбой атомарно соревнуются за него под одним замком; проигравшие
   не трогают ни состояние, ни UI, ни `completion`.
4. **Состояние попытки — одна защищённая запись**, а не набор независимых флагов:
   identity, признак разрешённости, признак живой фоновой операции, сам `completion`.
   Иначе возможны: watchdog переводит сервис в `.idle`, пока фон публикует `.recording`;
   cancel и watchdog оба зовут `completion`; busy снят до конца cleanup и стартует
   вторая сессия; старый cleanup затирает `session`/`writer`/`output` новой записи.
5. **Ресурсы принадлежат попытке, а не сервису.** Cleanup заброшенной попытки трогает
   только её собственные session/output/writer/URL и не чистит общие поля сервиса.
6. **Busy снимается только после полного завершения cleanup.** Пока заброшенная попытка
   жива, новый старт немедленно получает `.failure(.captureDeviceBusy)`. Двух живых
   `AVCaptureSession` не бывает никогда; main не блокируется ни при каких условиях.
7. Повторный `startRecording` в `.starting` → `completion(.failure(.alreadyRecording))`,
   без ожидания.
8. **Публикация устройства attempt-scoped.** `publishDevice`
   (`AudioCaptureService.swift:307-311`) пишет глобальные `activeDeviceUID` и
   `fallbackReason` асинхронно — заброшенная попытка не имеет права их публиковать и
   затирать данные следующей.
9. **Наблюдатели привязаны к своей сессии.** Сейчас подписка идёт с `object: nil`
   (`AudioCaptureService.swift:448-467`), а `reportInterruption` проверяет только
   глобальное `.recording` (`:496-509`) — уже летящее уведомление старой сессии способно
   оборвать новую запись ложным «Recording interrupted». Подписывать с `object: session`
   и дополнительно сверять attempt identity в обработчике.
10. **Успех публикуется только после выхода стартовой операции из `sessionQueue`.**
    Иначе main получит success, немедленно вызовет остановку и снова упрётся в занятую
    очередь — тот же фриз с другого конца.
11. `stopRecording` / `stopRecordingRetaining` — контракт не меняется (синхронные,
    возвращают сэмплы). Они достижимы только из `.recording`, куда теперь попадаем
    исключительно после подтверждённого старта.
12. Существующая механика не ломается: барьер `sampleQueue` на остановке, сверка
    идентичности `activeOutput` и `openGeneration` в делегате, единственное событие
    прерывания на запись, каденция метра 50 мс.
13. **Логировать фактическую длительность успешных стартов** — без этих данных порог
    4 с невозможно ни подтвердить, ни пересмотреть на реальных устройствах.
14. **Существующий fallback запрещён для терминально заброшенной попытки.** Сейчас
    `beginSession` (`AudioCaptureService.swift:166-178`) ловит ошибку preferred-устройства
    и запускает вторую попытку на системном default. Если зависший `startRunning()`
    вернётся уже после watchdog, эта ветка подняла бы ещё одну — возможно, тоже
    зависающую — сессию и продлила busy. Перед fallback сверять, что попытка всё ещё
    актуальна и не разрешена; иначе — только cleanup.
15. **Диагностику пишет сервис, а не колбэк.** Колбэк несёт `Result<Void, AudioCaptureError>`,
    и display name устройства в нём нет; читать глобальное опубликованное свойство нельзя
    (требование 8 запрещает заброшенной попытке публиковать, а следующая попытка успеет
    его изменить). Поэтому attempt-owned диагностику (UID, имя, фактическая длительность)
    логирует сам сервис, пока запись попытки ещё жива.
16. **Финализация успеха сериализуется одним блоком на main**: переход в `.recording`,
    запуск метра и вызов `completion` — неразрывно. Иначе сервис успеет принять
    interruption как относящийся к `.recording`, пока `AppDelegate` ещё в `.starting`;
    тот отбросит уведомление своим guard (`AppDelegate+CaptureInterruption.swift:22`),
    а следом пришедший success переведёт UI в запись с уже остановившейся сессией.
17. **Судьба прерывания, пришедшего ДО финализации успеха, определена явно.** Одной
    сериализации из требования 16 мало: наблюдатели ставятся ещё до `startRunning()`, а
    `reportInterruption` (`AudioCaptureService.swift:496-509`) принимает событие только
    в `.recording`. Значит `runtimeError` или `didStopRunning`, пришедший во время
    `startRunning()` либо после его возврата, но до main-блока успеха, был бы молча
    отброшен в состоянии `.starting` — и приложение объявило бы мёртвую сессию успешно
    пишущей. Требуется **attempt-scoped буфер первого прерывания**: событие, полученное
    в `.starting`, сохраняется в записи попытки (ровно одно, первое) и обрабатывается
    сразу после публикации success; если попытка успехом не разрешилась — уходит вместе
    с её cleanup. Вариант «просто проигнорировать» недопустим. Guard в
    `AppDelegate+CaptureInterruption.swift:22` при этом остаётся как есть: к моменту
    доставки владелец уже в `.recording`.

## Задача 2 — AudioCaptureError

Добавить (дословно):

```swift
case sessionStartTimedOut(uid: String?, seconds: Double)
case captureDeviceBusy
case startCancelled
```

`errorDescription` — по-английски, в тоне соседних кейсов: называть устройство и
срок ожидания, не предлагать действий, которых в UI нет. `startCancelled` — не ошибка
для пользователя: он сам отпустил хоткей, показывать ему нечего. Кейс существует
только для того, чтобы у отмены был однозначный терминальный исход и `completion`
нельзя было «просто не вызвать», удержав замыкание и его владельца навсегда.

## Задача 3 — AppDelegate

- В `AppState` добавить `case starting` (сейчас `idle / recording / transcribing / injecting`).
- `handleRecordingStarted()`: `appState = .starting`, вызов асинхронного старта.
  Капсулу `.recording` показывать **только** в `.success`.
- **`hotkeyService.syncIsRecording(true)` для menu-start выставляется СРАЗУ при принятии
  старта, а не в success-колбэке.** Сейчас `startRecordingFromMenu()`
  (`AppDelegate.swift:793-798`) выставляет флаг, только если сразу после вызова состояние
  уже `.recording`; с асинхронным стартом там будет `.starting`, флаг останется `false`,
  и menu-started запись станет невозможно остановить хоткеем (`canStartRecording`
  отвергнет ветку старта на `HotkeyService.swift:316-330`). Это ровно тот регресс,
  который стережёт `HotkeyServiceSyncTests`. Откладывать выставление до success нельзя
  по той же причине: хоткей, нажатый в эти 4 секунды, не отменил бы попытку.
- Семантика `HotkeyService.isRecording` во время `.starting` — **`true` для обоих
  источников старта**, иначе хоткей перестаёт быть симметричным способом остановки.
  При старте хоткеем флаг уже выставляет `startRecordingInternal`
  (`HotkeyService.swift:298`); при старте из меню — пункт выше. Так отпускание хоткея и
  второе нажатие превращаются в stop и отменяют старт. Сбрасывать только при отмене и
  терминальном сбое; успех оставляет `true`, и в success-колбэке любая синхронизация
  выполняется ТОЛЬКО после сверки актуального `StartAttemptID`. На coalescing-логику
  (`HotkeyService.swift:206-259`) как на защиту от гонок не рассчитывать:
  `processPendingAction()` очищает pending немедленно.
- `handleRecordingStopped()`: ветка `.starting` идёт **до** существующего
  `guard appState == .recording` и его defensive-вызова `stopRecording()`
  (`AppDelegate.swift:838-842`) — `cancelPendingStart()`, скрыть капсулу,
  `appState = .idle`, `hotkeyService.syncIsRecording(false)`. Это push-to-talk-случай:
  хоткей отпустили, пока сессия поднималась.
- `forceResetToIdle()` (`AppDelegate.swift:957-966`) и `applicationWillTerminate`
  (`AppDelegate.swift:151-157`) реагируют сейчас только на `.recording` — обе обязаны
  отменять незавершённый старт, иначе попытка переживёт сброс состояния.
- Успех старта, пришедший после отмены (попытка больше не актуальна по identity) —
  немедленно остановить запись и ничего не транскрибировать.
- **Сообщения об ошибках различать по кейсу.** Единый текст на любой `.failure` вводил
  бы в заблуждение: `.deviceUnavailable`, `.sessionConfigurationFailed` и
  `.recordingFileMissing` означают другое и сохраняют существующие формулировки. Новый
  текст — только для `.sessionStartTimedOut` и `.captureDeviceBusy`:
  `.errorInline(message: "Mic not responding · Check input")` +
  `scheduleErrorInlineDismiss()`. `.startCancelled` не показывает ничего.
- В `errors.log` писать UID и имя устройства, **уже разрешённые фоновой попыткой**, и
  фактическую длительность ожидания. Повторно опрашивать CoreAudio с main в колбэке
  нельзя — это возвращает тот класс риска, который задача устраняет.

Обоснование UI-решения по `DESIGN.md`:
- `DESIGN.md` §Error Handling & Logging → UI treatment rule: solvable → inline 4 с,
  unsolvable → toast 6 с. Неотвечающее устройство решается сменой входа в Settings,
  то есть solvable → **errorInline**, не toast.
- ⚠️ Клик по капсуле в коде **не реализован** (`onTapGesture` есть только в
  `HistorySection.swift:136`), хотя DESIGN обещает «click to fix». Поэтому текст
  обязан быть самодостаточным и не обещать нажатие. Длина в габаритах
  `"Mic denied · Open Privacy"`.

## Задача 4 — MenuBar (иначе проект не соберётся)

`MenuBarStateMachine.derive` (`Sources/VoiceType/Views/MenuBar/MenuBarView.swift:54-61`)
содержит exhaustive `switch appState` без `default` — новый case ломает сборку. Это
единственный switch по `AppState`: остальные в том же файле (`:158, :327, :340, :351,
:368, :387`) переключаются по `MenuBarState` (проверено).

Решение: **добавить отдельный `MenuBarState.starting`** (enum объявлен на
`MenuBarView.swift:19-24`) и обработать его во всех switch по `MenuBarState`:
`stateContent` (`:158`), `tallyColor` (`:327`), `tallyAccessibilityLabel` (`:340`),
`titleText` (`:351`), `subLineText` (`:368`). У `showModelStatusDot` (`:387`) есть
`default`, поэтому сборку он не сломает, — но для `.starting` выбрать явное `true`:
sub-line там такой же, как в `.idle`, и точка статуса модели уместна.

Наполнение: title `Starting recording`, VoiceOver-label то же, tally обычный (НЕ красный),
sub-line как у idle, в теле — та же кнопка **Stop**, что и при записи (она же отмена).

⚠️ Прежний вариант этого плана предлагал алиас `.starting → .recording(elapsed: 0)`, и
обоснование было неверным: он ссылался на уже показанную капсулу, тогда как задача 3
показывает капсулу только после success. Алиас объявлял бы «Recording» голосом VoiceOver
и красным tally в момент, когда запись ещё не идёт и аудио не пишется. Отсюда отдельный
case, а не переиспользование.

## Задача 5 — тесты

Новый файл `Tests/VoiceTypeTests/AudioStartTimeoutTests.swift` плюс один тест на derive
для `.starting` в `Tests/VoiceTypeTests/MenuBarStateTests.swift`.

**Форма шва зафиксирована**, иначе тесты окажутся фикцией, проверяющей отдельный
координатор вместо реального владения ресурсами:

- Инъецируемый **runner стартовой операции**, который можно удержать, а затем завершить
  успехом или сбоем. Runner отдаёт **attempt-owned resource bundle** (session/output/
  writer/URL/observer-токены) либо наблюдаемый fake resource handle с удерживаемым
  cleanup — без этого пункты 6 и 8 ниже проверяют только флаги, а не владение.
- Инъецируемый **планировщик watchdog** (виртуальные часы).
- **Шов в `HotkeyService`** для пункта 9: сейчас `toggleRecordingInternal` и
  `stopRecordingInternal` приватны (`HotkeyService.swift:303-332`), а `AppDelegate`
  держит `let audioCaptureService = AudioCaptureService()` concrete-полем
  (`AppDelegate.swift:29`), поэтому полный путь «меню → сервис → хоткей» из теста
  недостижим. Минимальное решение: открыть эти действия для тестов (internal + пометка,
  что это шов) и прогнать реальную ветку toggle с подставным `canStartRecording`,
  отражающим `.starting`/`.recording`. DI-точку в `AppDelegate` НЕ вводим — это отдельная
  задача, и её цена выше выигрыша здесь.

Без живого микрофона обязательны:

1. Публичный метод возвращается ДО завершения runner — main не блокируется.
2. `completion` приходит ровно один раз и всегда на main — в каждом сценарии ниже.
3. Таймаут отдаёт `.sessionStartTimedOut`, сервис возвращается в `.idle`.
4. Успех, пришедший ПОСЛЕ таймаута, не зовёт `completion` второй раз и не переводит
   сервис в `.recording`.
5. Cancel против watchdog и cancel против success — в обоих порядках.
6. Повторный старт до конца cleanup → `.captureDeviceBusy`; после cleanup — разрешён.
   Busy снимается именно по завершении cleanup, а не по результату runner.
7. Поздний результат отменённой попытки не меняет состояние следующей; cleanup попытки A
   трогает только bundle A и не задевает продвинутый bundle B.
8. Позднее уведомление старой сессии не обрывает новую запись.
9. Menu-start, завершившийся асинхронным успехом, останавливается хоткеем (регресс,
   который стережёт `HotkeyServiceSyncTests`). Хоткей, нажатый ВО ВРЕМЯ menu-start,
   отменяет попытку.
   ⚠️ Граница теста названа честно: он доказывает, что при предварительно выставленном
   `syncIsRecording(true)` реальная ветка toggle уходит в stop и не обращается к
   `canStartRecording`. А то, что `startRecordingFromMenu()` действительно выставляет
   флаг и что терминальный сбой его сбрасывает, остаётся на проверке кода и code-review:
   полного пути «меню → сервис → хоткей» из теста не достать без DI в `AppDelegate`,
   от которой мы осознанно отказались.
10. Немедленный отказ (`.captureDeviceBusy`) приходит асинхронно, после возврата метода,
    и его `StartAttemptID` совпадает с возвращённым — то есть сверка identity у
    вызывающего не отбрасывает законный отказ.
11. Прерывание, пришедшее в `.starting` до финализации успеха, не теряется: оно
    доставляется сразу после success, а если успеха не случилось — уходит с cleanup
    попытки и не всплывает на следующей записи (требование 17).

Существующие тесты (`AudioCaptureServiceTests`, `AudioDeviceSelectionTests`,
`CaptureFormatValidatorTests`, `MenuBarStateTests`) не трогать и не ломать.

## Вне области

- `CaptureFormatValidator.swift` и `AudioCaptureError.unexpectedCaptureFormat(detail:)`
  — незакоммиченная работа про другой баг (формат буферов Wave XLR MK.2). Не трогать.
- Путь остановки, барьеры `sampleQueue`, конверсия сэмплов — не менять.
- **Авто-фолбэк на другое устройство по таймауту не добавляем.** 4 с уже потеряны;
  вторая попытка добавит ещё столько же и запишет не с того микрофона, о котором
  человек думает. Существующий фолбэк «выбранного устройства нет в системе» остаётся.
- Не коммитить, не менять публичные сигнатуры вне перечисленного, не рефакторить соседнее.

## Definition of Done

- `swift build -c debug` → exit 0
- `swift test` → зелёные. База до изменений — **496 тестов, 0 падений, 3 пропущено**
  (замерено 15.09.2026); после — та же база плюс новые.
- `swiftlint lint` → **не больше 47 warnings, 0 errors** (фактическая база на
  15.09.2026; число 54 в `CLAUDE.md` устарело)
- Затронутые файлы: `AudioCaptureService.swift`, `AudioCaptureError.swift`,
  `AppDelegate.swift`, `MenuBarView.swift`, `HotkeyService.swift`,
  `AudioStartTimeoutTests.swift` (новый), `MenuBarStateTests.swift`,
  `HotkeyServiceSyncTests.swift`. Потребуется тронуть что-то ещё — сказать об этом в
  отчёте, а не расширять область молча.
- Живая проверка: вход = Wave Link MicFX, нажать хоткей → ошибка за ≤4 с, меню-бар
  и Settings остаются отзывчивыми, повторное нажатие не вешает приложение.

## Риски

- Два `AVCaptureSession` одновременно (заброшенная + новая) — отсюда `captureDeviceBusy`
  и снятие busy строго после cleanup.
- Ложное «Recording interrupted» на новой записи от уведомления старой сессии.
  ⚠️ Существующая сверка `activeOutput`/`openGeneration` здесь **не помогает**: она живёт
  только в sample-buffer делегате (`AudioCaptureService.swift:702+`), тогда как
  наблюдатели подписаны с `object: nil` (`:448-467`) и проверяют лишь глобальное
  состояние (`:496-509`). Отсюда требование 9 задачи 1.
- Гонка «успех старта пришёл после того, как пользователь отпустил хоткей».
- `stopRecordingCore` по-прежнему делает `sessionQueue.sync`. Он безопасен только при
  выполнении требования 10 задачи 1 (успех публикуется после выхода операции из
  очереди) и порядка ветвей в `handleRecordingStopped`. Инвариант зафиксировать
  комментарием в коде, а не держать в голове.
- Порог 4 с не проверен на Bluetooth HFP и холодном старте USB-интерфейса. Это
  осознанный продуктовый предел; фактические длительности успешных стартов логируются
  (требование 13), чтобы его можно было пересмотреть по данным, а не по ощущению.
