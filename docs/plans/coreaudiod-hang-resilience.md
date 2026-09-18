# Зависший coreaudiod не должен вешать VoiceType

## Цель

Когда системный аудиодемон `coreaudiod` перестаёт отвечать, VoiceType остаётся
отзывчивым и за ≤2 с говорит пользователю, что случилось и что делать. После
восстановления демона приложение снова работает без ручного вмешательства в сам
VoiceType.

## Контекст — диагностика 18.09.2026 (факты, не гипотезы)

- `coreaudiod` (pid 93313) ушёл в **deadlock** в 18:43:46. `spindump` владельца
  (`~/Desktop/coreaudiod-spindump.txt`): `Deadlocked: 2 threads`.
  - Поток A: `HALS_PlugInDevice::HandlePlugIn_RequestConfigChange` →
    `HALS_Tap::HandleGroupObjectPropertiesChanged` (держит гейт тапа) →
    `HALS_IOContext_Legacy_Impl::SetComposition` → `HALS_System::CopyTapByUUID` →
    ждёт системный мьютекс.
  - Поток B: `HALS_System::AddClient` (держит системный гейт) → ждёт мьютекс потока A.
  - Триггер — смена конфигурации агрегата Wave Link
    (`com.elgato.wavelink.aggregated-mixer`, построен на MultiTap) над
    Elgato Wave XLR MK.2. Баг самой macOS 26.6.2; VoiceType в тот момент не писал.
- Любой процесс, впервые обращающийся к HAL, висит в
  `HALSystem::CheckOutInstance()` → `HALC_ProxySystem::HALC_ProxySystem()` →
  `mach_msg2_trap`. Это процесс-глобальная инициализация: следом за ней встаёт
  **любой** HAL-вызов из **любого** потока, включая main.
- Что виснет при мёртвом демоне (замер Fable, изолированные пробы): любой
  `AudioObject*`, `AudioObjectAddPropertyListenerBlock`, `AVCaptureDevice(uniqueID:)`,
  `AVCaptureDevice.default(for:)`, `AVAudioPlayer.prepareToPlay()`, `NSSound.play()`.
  Не виснут: `AVCaptureDevice.authorizationStatus`, `AVCaptureSession()` init,
  `AVAudioFile` чтение/запись, `AVAudioConverter`, `NSSound.beep()`.
- Как это выглядело для пользователя:
  - Settings: `SettingsView.swift:292` `reloadInputDevices()` →
    `AudioDeviceService.inputDevices()` на main, плюс `observeChanges`
    (`AudioDeviceService.swift:192`) регистрирует listener с main → фриз, владелец
    снял процесс SIGKILL (20:01:28).
  - Хоткей: watchdog 1.4.1 сработал (`Recording start timed out after 4.2s` ×4), но
    фоновая операция не вернулась → сервис навсегда в `.abandoning` → каждый
    следующий старт — `.captureDeviceBusy` с текстом «Mic not responding · Check
    input», что неправда.
- Остановка: `AudioCaptureService.swift:726` `sessionQueue.sync { session?.stopRunning() }`
  с main — если демон зависнет во время записи, фриз на остановке.
- Восстановление (проверено на живом pid 17662): `sudo killall coreaudiod` (SIGTERM)
  демон в deadlock **не убивает**; `sudo killall -9 coreaudiod` — убивает, launchd
  поднимает новый. Застрявший в процессе VoiceType HAL-вызов после этого
  **вернулся сам** (с ошибкой `there is no system object`), попытка старта
  завершилась, сервис вернулся в `.idle`.
- Следующие HAL-вызовы в том же процессе после рестарта демона **работают**: в 20:45:54
  тот же pid 17662 без перезапуска поднял запись хоткеем за 0.169 с (встроенный
  микрофон — MicFX ещё не вернулся после рестарта Wave Link-драйвера).

## Решения

Совет Fable 5.1 (18.09.2026) принят с тремя поправками Orchestrator.

1. **Инвариант: main никогда не вызывает HAL.** Закрепляется трижды: lint-правило
   (где), `dispatchPrecondition` в HAL-функциях (на каком потоке), тесты.
2. **Шлюз `AudioHALGateway`** — своя последовательная очередь для запросов к
   системе (перечисление устройств, default device, listener'ы), срок на вызов,
   состояние здоровья, fail-fast.
   - *Поправка 1:* очередь шлюза **отдельна** от `sessionQueue` захвата (Fable
     предлагал слить). Иначе `startRunning()`, висящий на ОДНОМ неисправном
     устройстве (сценарий 1.4.1, MicFX), выглядел бы как «аудиосистема мертва».
     Здоровье шлюза отражает демон, а не устройство.
3. **Без внепроцессной пробы, без XPC, без кнопки «перезапустить coreaudiod»** —
   приложение информирует, не лечит систему (рвёт звук всем, требует пароль,
   триггер в стороннем драйвере). Вердикт Fable принят.
4. **Остановка — ограниченное ожидание**, сэмплы отдаются как есть.
   - *Поправка 2:* таймаут остановки **не** считается сбоем записи для
     пользователя — всё сказанное уже в файле. Только лог + «застой» шлюза.
5. **Команда восстановления в тексте — `sudo killall -9 coreaudiod`**.
   - *Поправка 3:* Fable предлагал без `-9`; проверено вживую — SIGTERM не
     убивает демон в deadlock.
6. **Самоперезапуск приложения не нужен** — in-process HAL-клиент оживает сам после
   рестарта демона (проверено 18.09.2026, см. «Контекст»). Восстановление — возврат
   застрявшего вызова закрывает застой шлюза → health `.healthy`.

## Файлы

| Файл | Что делаем | Задача |
|---|---|---|
| `Sources/VoiceType/Services/AudioHALGateway.swift` | новый: шлюз | 1 |
| `Sources/VoiceType/Services/AudioDeviceService.swift` | precondition очереди шлюза, async-API, подписка вне main | 1 |
| `Sources/VoiceType/Services/AudioCaptureError.swift` | кейс `audioSystemUnresponsive` | 1 |
| `.swiftlint.yml` | правило `hal_outside_gateway` | 1 |
| `Tests/VoiceTypeTests/AudioHALGatewayTests.swift` | новый | 1 |
| `Tests/VoiceTypeTests/AudioDeviceSelectionTests.swift` | живой тест через шлюз + skip | 1 |
| `Sources/VoiceType/Services/AudioCaptureService.swift` | гейт здоровья на старте, запросы через шлюз, ограниченная остановка | 2 |
| `Tests/VoiceTypeTests/AudioStartTimeoutTests.swift` (или новый `AudioSystemUnresponsiveTests.swift`) | тесты задачи 2 | 2 |
| `Sources/VoiceType/AppDelegate+AsyncStart.swift` | toast для `audioSystemUnresponsive` и `captureDeviceBusy` | 3 |
| `Sources/VoiceType/Views/Settings/SettingsView.swift` | асинхронная загрузка, строка «аудиосистема не отвечает», автовосстановление | 3 |
| `Sources/VoiceType/Views/Eval/EvalEditorView.swift` | плеер через шлюз | 3 |
| `DESIGN.md` | Error recovery arc + Decisions Log | 3 |
| `CHANGELOG.md` | секция `[Unreleased]` | 3 |

Граф: **1 → 2 → 3**, последовательно (одно рабочее дерево, общий `.build`;
2 и 3 зависят от контрактов 1; 3 зависит от поведения 2).

## Задача 1 — AudioHALGateway + AudioDeviceService

Контракт (дословно; внутреннее устройство — на усмотрение исполнителя):

```swift
/// Почему вызов через шлюз не дал результата.
enum AudioHALError: Error, Equatable {
    /// Не уложился в срок, либо шлюз уже в `.unresponsive` (fail-fast: работа
    /// в очередь НЕ ставилась).
    case unresponsive
    /// Работа выполнилась и бросила ошибку. `String(describing: error)`.
    case failed(String)
}

enum AudioSystemHealth: Equatable {
    case healthy
    case unresponsive(since: Date)
}

/// Identity внешнего застоя. Создаётся ЗАРАНЕЕ вызывающим, до решения, открывать ли
/// застой, — чтобы begin/end можно было звать вне своих замков в любом порядке.
final class AudioHALStallToken {
    init(label: String)
}

final class AudioHALGateway {
    static let shared: AudioHALGateway

    /// `log` — куда писать переходы здоровья; в проде errors.log, в тестах — перехват.
    init(
        label: String = "com.voicetype.audio.hal",
        defaultTimeout: TimeInterval = 2.0,
        log: @escaping (String) -> Void = { ErrorLogger.shared.log(message: $0, category: "audio") }
    )

    /// Последовательная очередь, на которой выполняется ВСЯ работа шлюза.
    /// Помечена `queue.setSpecific(key: AudioHALGateway.queueKey, value: ())`.
    let queue: DispatchQueue

    /// true, если текущий код исполняется на очереди ЛЮБОГО экземпляра шлюза
    /// (`DispatchQueue.getSpecific(key: queueKey) != nil`). Так проверка в
    /// AudioDeviceService работает и с шлюзом, подставленным в тестах.
    static var isOnGatewayQueue: Bool { get }

    /// Читается с любого потока (под замком).
    var health: AudioSystemHealth { get }

    /// Постится на main ровно на переходах healthy↔unresponsive; object — шлюз.
    static let healthDidChangeNotification: Notification.Name

    /// `completion` — РОВНО один раз, всегда на main, никогда inline.
    /// health == .unresponsive → сразу `.failure(.unresponsive)`, work не выполняется.
    /// work дольше timeout → `.failure(.unresponsive)`, открывается застой,
    /// health → .unresponsive; поздний результат отбрасывается; когда work вернётся —
    /// её застой закрывается.
    func perform<T>(
        _ label: String,
        timeout: TimeInterval? = nil,
        _ work: @escaping () throws -> T,
        completion: @escaping (Result<T, AudioHALError>) -> Void
    )

    /// То же синхронно, с ограниченным ожиданием. Запрещён на main и на `queue`
    /// (`dispatchPrecondition`).
    func performSync<T>(
        _ label: String,
        timeout: TimeInterval? = nil,
        _ work: @escaping () throws -> T
    ) -> Result<T, AudioHALError>

    /// Без срока и результата (снятие listener'ов). Ставится в очередь ВСЕГДА,
    /// даже при .unresponsive — выполнится, когда очередь освободится.
    func enqueueCleanup(_ label: String, _ work: @escaping () -> Void)

    /// Внешний застой (зависший stopRunning в AudioCaptureService): открыть →
    /// health .unresponsive; закрыть → если открытых застоев нет, .healthy.
    /// `endStall` идемпотентен и допустим ДО `beginStall`: токен помечается закрытым,
    /// и последующий `beginStall` с ним — no-op. Повторный `beginStall` — no-op.
    /// Вызывающий НЕ держит свои замки во время этих вызовов.
    func beginStall(_ token: AudioHALStallToken)
    func endStall(_ token: AudioHALStallToken)
}
```

Требования:

1. health = `.unresponsive`, пока открыт хотя бы один застой (собственный — от
   просроченной работы, или внешний — `beginStall`). Все застои закрыты → `.healthy`.
2. Переход в `.unresponsive` пишет в `log` ОДНУ строку: label, срок, список бандлов
   `/Library/Audio/Plug-Ins/HAL` (чтение ФС через `FileManager`, не HAL) и команду
   `sudo killall -9 coreaudiod`. Переход в `.healthy` — строку «recovered after N s».
   Повторные fail-fast-отказы в лог не пишутся.
3. Уведомление `healthDidChangeNotification` — на main, по одному на переход.
4. `AudioDeviceService.inputDevices()` и `systemDefaultInputUID()` остаются
   синхронными `throws`, но первой строкой —
   `precondition(AudioHALGateway.isOnGatewayQueue, "HAL — только через AudioHALGateway")`.
   НЕ `.onQueue(AudioHALGateway.shared.queue)`: это сломало бы инъецированный шлюз
   (ревью плана, P1). Тест: вызов через `performSync` НЕстандартного экземпляра шлюза
   проходит проверку (с подменой работы, без живого HAL — проверяется сам
   `isOnGatewayQueue` на очереди тестового шлюза и вне её).
5. Новые async-API для UI (дословно):
   ```swift
   extension AudioDeviceService {
       /// Через шлюз; completion на main ровно один раз.
       static func loadInputDevices(
           via gateway: AudioHALGateway = .shared,
           completion: @escaping (Result<[AudioInputDevice], AudioHALError>) -> Void
       )
   }
   ```
   `observeChanges` получает шлюз (дословно):
   `static func observeChanges(via gateway: AudioHALGateway = .shared, _ handler: @escaping () -> Void) -> AudioDeviceObservation`;
   `AudioDeviceObservation` хранит этот шлюз и регистрирует/снимает listener'ы только
   через него. handler по-прежнему на main.
6. `AudioDeviceObservation`: регистрация listener'ов — `gateway.perform` (fail-fast;
   при `.unresponsive` подписка остаётся пустой); `cancel()` и `deinit` — через
   `enqueueCleanup`, с main HAL не трогают. Очередь доставки listener-блоков —
   `DispatchQueue.main` (сами блоки HAL не трогают).
   **Реестр, а не completion** (ревью плана, раунд 3, P2): зарегистрированные listener'ы
   записываются в отдельный объект-реестр (reference type, свой замок: `isCancelled` +
   список `(address, block)`) ПО ХОДУ регистрации, внутри работы шлюза. Реестр
   захватывают сильно и работа регистрации, и работа cleanup; результат `perform`
   для учёта не используется. Поэтому:
   - регистрация перед каждым `Add…` проверяет `isCancelled` и, если отменено,
     прекращает;
   - cleanup (поставлен `enqueueCleanup` из `cancel()`/`deinit`, строго ПОСЛЕ
     регистрации по FIFO) ставит `isCancelled` и снимает всё, что в реестре на момент
     СВОЕГО выполнения, — включая listener'ы, добавленные регистрацией, чей completion
     шлюз отбросил по таймауту;
   - cleanup идемпотентен.
   Для теста — внутренний init с подставными `addListener`/`removeListener`
   (счётчики), чтобы не трогать живой HAL.
7. `AudioCaptureError`: добавить (дословно)
   ```swift
   /// coreaudiod не отвечает: вызов CoreAudio не уложился в срок шлюза, либо шлюз уже
   /// в `.unresponsive`. Не про конкретное устройство — про всю аудиосистему macOS.
   case audioSystemUnresponsive
   ```
   `caseIdentifier` — `"audioSystemUnresponsive"`. `errorDescription`: "The macOS audio
   service (coreaudiod) isn't responding, so VoiceType can't reach any microphone.
   Restart it in Terminal with “sudo killall -9 coreaudiod”, or restart your Mac."
   Добавление кейса ломает исчерпывающие `switch` — `default:` в
   `AppDelegate+AsyncStart.swift` его поглотит; UI-маппинг — задача 3.
8. Lint-правило в `.swiftlint.yml` → `custom_rules` (severity **error**):
   - `hal_outside_gateway`, regex по прямым HAL-API:
     `AudioObject(GetPropertyData|GetPropertyDataSize|SetPropertyData|HasProperty|IsPropertySettable|AddPropertyListener|AddPropertyListenerBlock|RemovePropertyListener|RemovePropertyListenerBlock)\s*\(`,
     `AudioHardware\w*\s*\(`, `AudioServicesPlay\w*\s*\(`,
     `AVCaptureDevice\s*\(`, `AVCaptureDevice\.default\b`, `AVCaptureDevice\.DiscoverySession`,
     `AVAudioPlayer\s*\(`, `AVAudioEngine\s*\(`, `NSSound\s*\(`.
     НЕ ловить `AVCaptureDevice.authorizationStatus`, `.requestAccess`,
     `.wasDisconnectedNotification` (TCC/NotificationCenter, не HAL).
   - `included: "Sources/VoiceType/.*\\.swift"`, исключены ровно файлы
     `Services/AudioHALGateway.swift`, `Services/AudioDeviceService.swift`,
     `Services/AudioCaptureService.swift`, `Services/AudioCaptureService+Start.swift`.
   - Комментарии и строки не ловить (`excluded_match_kinds: [comment, doccomment, string]`
     или эквивалент для SwiftLint 0.65.0).
   - `message` ссылается на этот план.
   - Нарушение в `EvalEditorView.swift` (`AVAudioPlayer(`) чинит задача 3; до неё —
     `// swiftlint:disable:next hal_outside_gateway` с комментарием «задача 3».
9. Живой тест `AudioDeviceSelectionTests.testCoreAudioEnumerationReturnsUsableUIDs`
   идёт через `loadInputDevices(via: testGateway)` — НЕстандартный экземпляр шлюза, —
   с ожиданием ≤5 с; `.unresponsive` → `XCTSkip` («coreaudiod не отвечает»), а не
   зависание прогона. Второй живой тест: `testGateway.performSync { try AudioDeviceService.systemDefaultInputUID() }`
   не трапает на precondition (реальные HAL-методы на очереди подставленного шлюза).
   Тесты `AudioDeviceObservation` на нестандартном шлюзе (подставные add/remove):
   - `cancel()` до выполнения регистрации (очередь шлюза занята блокирующей работой)
     → после освобождения очереди добавлено 0 либо всё добавленное снято;
   - регистрация добавила listener и заблокировалась дольше срока шлюза → completion
     `.unresponsive`; `cancel()`; после освобождения очереди: каждый добавленный
     listener снят ровно один раз, handler после этого не вызывается.

Тесты `AudioHALGatewayTests` (свой экземпляр шлюза, короткие сроки 0.1–0.3 с, работа
блокируется `DispatchSemaphore`, который тест отпускает):
- успех: значение, completion на main, ровно один раз, не inline;
- throw → `.failed`;
- таймаут → `.unresponsive`, health `.unresponsive`, одно уведомление, одна строка лога;
- при `.unresponsive` следующий `perform` падает сразу, work не выполняется (флаг);
- отпустили застрявшую работу → `.healthy`, уведомление, поздний результат не доставлен;
- `performSync` с фоновой очереди: успех и таймаут;
- `beginStall/endStall`: `.healthy` только когда закрыты ВСЕ застои (свой + внешний);
  повторный `endStall` без эффекта; `endStall` ДО `beginStall` → последующий
  `beginStall` — no-op, health остаётся `.healthy`, уведомлений нет;
- `enqueueCleanup` выполняется даже при `.unresponsive` (после освобождения очереди).

## Задача 2 — AudioCaptureService

1. Шов: `var halGateway: AudioHALGateway = .shared` (как `watchdogScheduler`).
2. `startRecording` — порядок отказов под `stateLock` (ревью плана, раунд 2, P1:
   нельзя отдать «система мертва», пока сервис реально пишет — AppDelegate уйдёт в
   idle при живой сессии):
   - `.starting` / `.recording` / `.stopping` → `.alreadyRecording` (как сейчас,
     здоровье не смотрим);
   - `.abandoning` → `halGateway.health != .healthy` ? `.audioSystemUnresponsive` :
     `.captureDeviceBusy`;
   - `.idle` и `halGateway.health != .healthy` → `.audioSystemUnresponsive`;
   - иначе — принять попытку, как сейчас.
   Все отказы — `completion` асинхронно на main (не inline), runner не вызывается,
   состояние не меняется. Тест: health `.unresponsive` при сервисе в `.recording` →
   `.alreadyRecording`, состояние `.recording` не тронуто.
3. `beginSessionAttempt`: оба запроса (`systemDefaultInputUID`, `inputDevices`) — одним
   `halGateway.performSync("resolveDevices") { … }`.
   - `.failure(.unresponsive)` → `return .failure(.audioSystemUnresponsive)` (до любых
     AVFoundation-вызовов);
   - `.failure(.failed)` → прежняя семантика (`systemDefaultUID = nil`, `available = []`);
   - успех → прежняя логика без изменений.
   Срок шлюза 2 с < watchdog 4 с: при мёртвом демоне попытка разрешается точной
   ошибкой, а `sessionQueue` освобождается (висит очередь шлюза, не сессии).
4. `handleWatchdogFired`: если в момент срабатывания `halGateway.health != .healthy`,
   исход — `.audioSystemUnresponsive`, иначе прежний `.sessionStartTimedOut`. Лог в
   errors.log — как сейчас.
5. Остановка (`stopRecordingCore`) — ограниченное ожидание. Порядок (дословно, обе ветки):
   1. `transition(.recording → .stopping)`; `stopMeterTimer()`;
      `removeInterruptionObservers()`; под `stateLock` снять `pendingInterruption` и
      `liveCandidateID` — как сейчас.
   2. На main: `let stoppingSession = session; session = nil` (поле перестаёт владеть
      сессией). Создать `StopToken` (identity этой остановки), при нём
      `stall = AudioHALStallToken(label: "stopRunning")`, и общий под `stateLock` флаг
      исхода `{ pending | completedInTime | timedOut }`.
   3. `sessionQueue.async`: `sessionStopper(stoppingSession)`; снять делегат со ВСЕХ
      её `AVCaptureAudioDataOutput` (`setSampleBufferDelegate(nil, queue: nil)`); затем
      под `stateLock` только решение: флаг `pending` → `completedInTime`; флаг
      `timedOut` → `wasTimedOut = true`, и если `state == .abandoning` и текущий
      абандон-токен === этот `StopToken` → `state = .idle`, токен сброшен. ВНЕ замка:
      если `wasTimedOut` → `halGateway.endStall(stall)`. Последний release
      `stoppingSession` — в этом блоке (dealloc тоже трогает HAL).
   4. Main ждёт `DispatchSemaphore` блока не дольше `stopTimeout`, затем под
      `stateLock` только решение: флаг уже `completedInTime` → ветка «в срок»; иначе
      флаг → `timedOut`, абандон-токен = этот `StopToken`. ВНЕ замка, в ветке
      «таймаут»: `halGateway.beginStall(stall)`, строка в errors.log. Если блок успел
      завершиться между решением и `beginStall`, его `endStall(stall)` уже закрыл
      токен, и `beginStall` — no-op по контракту шлюза. Ровно одна сторона видит
      «свой» переход флага; вызовы шлюза не держат `stateLock`.
   5. Барьер `sampleQueue.sync` — в ОБЕИХ ветках, как сейчас: `openGeneration = nil`,
      `activeOutput = nil`, `writer = nil` (освобождение дописывает заголовок). После
      него делегат, даже если ещё не снят (висящий `stopRunning`), падает на
      существующем guard идентичности `activeOutput`/`openGeneration`
      (`captureOutput`, ≈1097+) и ничего не пишет: ни в старый файл, ни в writer
      следующей записи (у неё другой `activeOutput`).
   6. Чтение файла, копия для eval, удаление, `CaptureResult` — как сейчас. Таймаут
      остановки **не** превращается в `failure` — звук в файле цел.
   7. Итоговое состояние: ветка «в срок» → `.idle` (как сейчас `defer`); ветка
      «таймаут» → `.abandoning` (его снимет блок из шага 3). `defer { setState(.idle) }`
      заменяется явной установкой по ветке; пути `throw` (нет файла и т.п.) обязаны
      поставить то же состояние, что и соответствующая ветка.
6. Не меняется: контракты `startRecording`/`cancelPendingStart`/`stopRecording`/
   `stopRecordingRetaining`, 17 требований `docs/plans/audio-start-hang.md`.

Тесты (переиспользовать инфраструктуру `AudioStartTimeoutTests`; если для попадания
в `.recording` не хватает шва — добавить минимальный и описать в отчёте):
- health `.unresponsive` → старт даёт `.audioSystemUnresponsive`, runner не вызван,
  состояние `.idle`;
- реальный `beginSessionAttempt` с заблокированной очередью шлюза → исход
  `.audioSystemUnresponsive` быстрее watchdog;
- watchdog при нездоровом шлюзе → `.audioSystemUnresponsive`;
- остановка с зависшим `sessionStopper` → возврат за ≤ `stopTimeout` + запас, сэмплы
  отданы, состояние `.abandoning`, шлюз `.unresponsive`; следующий старт →
  `.audioSystemUnresponsive`; отпустили стоппер → `.idle` и `.healthy`;
- остановка, где стоппер завершается сразу после таймаута (гонка шага 4) → итог
  детерминирован: либо `.idle` без застоя, либо `.abandoning` → `.idle` с закрытым
  застоем; никогда не «`.abandoning` навсегда» и не открытый застой;
- поздний буфер старого output после таймаута не пишется: если guard идентичности
  `activeOutput`/`openGeneration` уже покрыт тестом в `AudioCaptureServiceTests` —
  сослаться на него в отчёте; иначе добавить тест прямым вызовом `captureOutput` с
  синтетическим `CMSampleBuffer`, если выполнимо; невыполнимо — описать в отчёте;
- все тесты задачи 2 используют НЕстандартный экземпляр шлюза (`halGateway = testGateway`).

Дополнительно: `configureAndStartAttempt` первой строкой —
`dispatchPrecondition(condition: .onQueue(sessionQueue))` (там живут
`AVCaptureDevice(uniqueID:)`/`.default(for:)`, файл исключён из lint-правила).

## Задача 3 — UI

1. `AppDelegate+AsyncStart.swift`:
   - `.audioSystemUnresponsive` → `showErrorToast(title: "macOS audio isn't responding",
     body: "The system audio service is stuck. Restart it in Terminal: sudo killall -9 coreaudiod — or restart your Mac.")`,
     затем `hotkeyService.syncIsRecording(false)`, `appState = .idle`. Капсулу не показывать.
   - `.captureDeviceBusy` → toast вместо лживого inline: title "Microphone session is
     stuck", body "macOS hasn't released the previous recording session yet. Try again
     in a moment — if it keeps happening, quit and reopen VoiceType."
   - `.sessionStartTimedOut` — без изменений (устройство, не система).
2. `SettingsView.swift`:
   - `reloadInputDevices()` → `AudioDeviceService.loadInputDevices`; успех — прежняя логика;
     `.failed` — прежняя (`[]`, `didLoadInputDevices = true`); `.unresponsive` — флаг
     `@State audioSystemUnresponsive = true`, список и `didLoadInputDevices` не трогать.
   - При флаге — строка по образцу «Selected device unavailable»:
     `PrefsRow("macOS audio isn't responding", subtitle: "Can't list microphones. Restart the audio service in Terminal: sudo killall -9 coreaudiod — or restart your Mac.")`.
   - `.onReceive(NotificationCenter.default.publisher(for: AudioHALGateway.healthDidChangeNotification, object: AudioHALGateway.shared))`
     (фильтр по объекту — реагировать только на свой шлюз): переход в `.healthy` →
     сбросить флаг, пересоздать подписку, перезагрузить список.
   - Поколение загрузки: `@State private var deviceLoadGeneration = 0`. Каждый
     `reloadInputDevices()` инкрементирует его и захватывает значение; completion
     применяет результат (список, `didLoadInputDevices`, флаг unresponsive) ТОЛЬКО если
     захваченное значение == текущему. `onDisappear` инкрементирует поколение ДО
     `deviceObservation?.cancel()`. Так устаревший успех не сбросит свежий флаг
     `.unresponsive`, и наоборот.
   - Пикер: пока список не загружен и выбранный UID не в списке, добавить пункт с
     `selectedDeviceMenuTitle` под тегом выбранного UID (убирает SwiftUI-предупреждение
     «selection is invalid»).
3. `EvalEditorView.swift`: создание, `prepareToPlay()` и `play()` плеера —
   в `AudioHALGateway.shared.perform("evalPlayback")`, плеер сохраняется в completion
   на main; при `.unresponsive` — кнопка воспроизведения возвращается в исходное
   состояние (без toast). Остановка/пауза — `enqueueCleanup`. Снять
   `swiftlint:disable` из задачи 1, если конструкция ушла в шлюз; если текстово
   `AVAudioPlayer(` остаётся в файле — оставить disable с обоснованием «вызов внутри
   gateway.perform».
4. `DESIGN.md`: в «Error recovery arc» — две строки (audio system unresponsive → toast;
   stuck session → toast); в Decisions Log — запись 2026-09-18 со ссылкой на этот план.
5. `CHANGELOG.md`: секция `## [Unreleased]` → `### Fixed` — одна запись в стиле 1.4.1.

## Риски

- Здоровье «залипает» `.unresponsive`, если застрявший вызов не вернётся никогда
  (демон не перезапускали) — это верное поведение: система действительно мертва.
- Ложное `.unresponsive` на медленном, но живом вызове (>2 с). Самолечится при
  возврате вызова; 2 с — в 40× выше замеренных 1–50 мс перечисления.
- Остановка ждёт на main до 1 с один раз в патологии — компромисс против переписывания
  `handleRecordingStopped` в асинхронный.
- `dispatchPrecondition` в `AudioDeviceService` — трап в релизе при нарушении;
  ловится тестами и lint до релиза (так же устроен `startRecording`).
- Listener, чьё снятие застряло в очереди, живёт до освобождения очереди — безвреден
  (handler на main, HAL не трогает).

## Definition of Done

- `swift build -c debug` — exit 0.
- `swift test` — все зелёные, число тестов > baseline (514, из них 3 skipped —
  замер 18.09.2026 после установки Metal Toolchain для Xcode 27), живой тест не висит.
- `swiftlint lint` — 0 errors; warnings ≤ baseline (47).
- `grep -rnE "AudioObject(GetPropertyData|GetPropertyDataSize|SetPropertyData|HasProperty|IsPropertySettable|AddPropertyListener|AddPropertyListenerBlock|RemovePropertyListener|RemovePropertyListenerBlock)|AudioHardware[A-Za-z]*\(|AudioServicesPlay|AVCaptureDevice\(|AVCaptureDevice\.default|AVCaptureDevice\.DiscoverySession|AVAudioPlayer\(|AVAudioEngine\(|NSSound\(" Sources`
  — вне allowlist задачи 1 только `EvalEditorView.swift` с `AVAudioPlayer(` внутри
  замыкания `gateway.perform` (и `swiftlint:disable:next` с обоснованием).
- HAL-функции `AudioDeviceService` начинаются с `precondition(AudioHALGateway.isOnGatewayQueue…)`,
  `configureAndStartAttempt` — с `dispatchPrecondition(.onQueue(sessionQueue))`.
- Живой смоук (Orchestrator): сборка приложения, Settings показывает устройства,
  главный поток не касается HAL (`sample` через 10 с после запуска).
- Симуляция (владелец, sudo, опционально): `sudo killall -STOP coreaudiod` → Settings
  показывает строку ≤2 с, UI отзывчив; хоткей → toast ≤2 с; `sudo killall -9 coreaudiod`
  → Settings восстанавливается сам, запись работает.
- Ревью-гейт: `ВЕРДИКТ: SHIP`.
