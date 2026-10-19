# План: исправить последнюю диктовку и вставить заново (этап 3, C1; s26, 2026-10-19)

База `main` `566ff58`. Решение владельца 19.10: «автономно продолжай, дальше делаем»;
UI-часть (кнопка, текст тоста) — показать владельцу до реализации (`CLAUDE.md`: визуальные
решения — по `DESIGN.md` и с одобрения владельца).

## §1 Цель

Владелец диктует по-русски с английскими терминами; фонетические ошибки whisper
(слово, разбитое на два, или созвучная подмена) он сейчас правит руками в целевом поле. Цель —
исправить текст в Eval-редакторе (Cmd+Opt+E уже открывает его на последней диктовке) и
одной командой вставить исправленный вариант туда, где диктовали; пара «было/стало»
сохраняется как eval-пример (растёт эталонный набор для сравнения моделей).

Автозамену уже вставленного текста НЕ делаем (терминалы, редакторы — недетерминированно).
Приём замены: пользователь выделяет ошибочный фрагмент перед Cmd+Opt+E — paste в
восстановленном окне заменяет выделение (поведение самих приложений).

**Объём сужен после plan-review r1:** History (Re-insert, Copy, отображение правки) — НЕ
меняется в этой задаче; отдельный шаг C1b (§7).

## §2 Поведение

| Действие | Результат |
|---|---|
| Cmd+Opt+E при фронтмост-приложении ≠ VoiceType | снимок фокуса (приложение + AX-окно) этого момента прикрепляется к окну редактора |
| Редактор открыт из History или снимок не удался (фронтмост — VoiceType) | кнопки «Save & Insert» нет вообще (не disabled — отсутствует) |
| Правка + «Save & Insert» (⌘⇧↩) | пара сохранена (как «Save eval pair»); окно закрыто; фокус восстановлен ИЗ СНИМКА (activate + AX raise/focus окна — тот же код, что Focus Return); через 150 мс исправленный текст вставлен paste с сохранением буфера; VoiceOver-анонс «Corrected text inserted» |
| Без правки | «Save & Insert» disabled (`saveState != .saveEvalPair`) |
| Приложение из снимка завершилось (до или во время задержки) | текст в буфер обмена (результат `setString` проверяется); тост «Couldn't insert into <app> · Copied to clipboard»; при неудаче записи — тост «Couldn't insert · Clipboard unavailable» |
| Приложение живо, но после восстановления на переднем плане НЕ оно или не окно из снимка | НЕ вставлять (иначе текст уйдёт не туда); буфер + тот же тост «Couldn't insert into <app> · Copied to clipboard» |
| Редактор этой записи уже открыт и открывается снова (любым путём) | **побеждает последнее открытие**: снимок заменяется значением этого открытия — Cmd+Opt+E из другого приложения → новая цель; из History или при фронтмосте VoiceType → nil, кнопки нет |
| Ошибка вставки | `ErrorLogger` category `insertion` (один владелец — сервис) + тост «Couldn't insert · <описание>» |
| Повторное нажатие / второй Save & Insert, пока первый не закончил | игнорируется: in-flight флаг в сервисе; кнопка после нажатия сразу disabled, окно закрывается |

Живая диктовка, общий захват `FocusCaptureService.shared.capture()/restore()`,
`TextInjectionService`, `insertionTargetDecision`, History — не меняются.

Перезапись буфера в ветке «приложение закрыто» — осознанная (текст иначе потеряется;
DESIGN.md Implementation Plan шаг 9 предписывает то же для History) — фиксируется в
Decisions Log. Тост идёт через `showErrorToast` (он логирует в `errors.log` категорию
`app`) — для ветки «скопировано» принимается: событие редкое, лог полезен.

## §3 Контракты

**C1. `Sources/VoiceType/Services/FocusCaptureService.swift`** — добавить, не меняя
существующего API и общего состояния:
```swift
/// Value snapshot of the frontmost (non-VoiceType) app and its focused AX window.
struct FocusSnapshot { let app: NSRunningApplication; let window: AXUIElement? }

extension FocusCaptureService {
    /// Same frontmost/self-capture rules as capture(), but returns a value and does
    /// NOT touch capturedApp/capturedWindow/suppression. nil when VoiceType is frontmost
    /// or there is no frontmost app.
    func snapshot() -> FocusSnapshot?
    /// Same activation + AX raise/main/focused sequence as restore(), applied to
    /// `snapshot`. Returns false (and does nothing) when snapshot.app.isTerminated.
    @discardableResult func restore(_ snapshot: FocusSnapshot) -> Bool
    /// snapshot.app is frontmost (pid) and, when snapshot.window != nil, the app's
    /// kAXFocusedWindowAttribute is CFEqual to it.
    func isFocused(_ snapshot: FocusSnapshot) -> Bool
}
```
Реализация переиспользует `focusedWindowInfo(for:)` и тело `restore()` (общий приватный
хелпер `raise(app:window:)`; `restore()` вызывает его же — поведение без изменений).

**C2. Новый `Sources/VoiceType/Services/ReinsertService.swift`:**
```swift
enum ReinsertOutcome: Equatable { case inserted, copied, failed(String), busy }

@MainActor
final class ReinsertService {
    static let shared = ReinsertService()
    typealias Restorer = @MainActor (FocusSnapshot) -> Bool
    typealias Inserter = @MainActor (String) async throws -> Void
    typealias Copier = @MainActor (String) -> Bool   // true = written
    /// true only when snapshot.app is frontmost (pid match) AND, if snapshot.window != nil,
    /// the app's AX focused window is CFEqual to it. Default reads NSWorkspace + AX.
    typealias FocusVerifier = @MainActor (FocusSnapshot) -> Bool

    init(restorer: @escaping Restorer = { FocusCaptureService.shared.restore($0) },
         inserter: @escaping Inserter = { _ = try await TextInjectionService().insertText($0, mode: .paste, pressEnterAfter: false) },
         copier: @escaping Copier = { let pb = NSPasteboard.general; pb.clearContents(); return pb.setString($0, forType: .string) },
         verifier: @escaping FocusVerifier = { FocusCaptureService.shared.isFocused($0) },
         activationDelay: Duration = .milliseconds(150))

    private(set) var isInFlight = false
    /// isInFlight → .busy (nothing done). restorer false → copy. restorer true →
    /// sleep(activationDelay) → snapshot.app.isTerminated || !verifier(snapshot) → copy;
    /// else inserter; throw → ErrorLogger.shared.log(error, category: "insertion") +
    /// .failed(localizedDescription).
    /// copy: copier true → .copied; false → .failed("Clipboard unavailable").
    /// isInFlight reset on every exit path (defer).
    func reinsert(_ text: String, into snapshot: FocusSnapshot) async -> ReinsertOutcome
}
```
Буфер обмена в успешной ветке — забота `TextInjectionService` (сохранение/восстановление
уже покрыто `PasteboardSnapshotTests`); сервис его не трогает. Тесты подменяют все три
замыкания; `NSRunningApplication` для `FocusSnapshot` в тестах —
`NSRunningApplication.current`.

**C3. Тост и анонс.** `AppDelegate.showErrorToast(title:body:)` (`AppDelegate.swift:1017`, он
же даёт VoiceOver-анонс): `.copied` → title «Couldn't insert into <app>», body «Copied to clipboard», где `<app>` —
`snapshot.app.localizedName ?? "the app"`, взятое окном из снимка ДО вызова сервиса; `.failed(m)` → «Couldn't insert», body `m`. `.inserted` → только VoiceOver-анонс
«Corrected text inserted» через `NSAccessibility.post(element: NSApp, notification:
.announcementRequested, userInfo: [.announcement: …, .priority: NSAccessibilityPriorityLevel.high.rawValue])`
(как в `RecordingWindow.swift:48`). `.busy` — ничего.

**C4. Открытие редактора.** `AppDelegate.openEvalEditor()` (хоткей, `AppDelegate.swift:318`)
берёт `FocusCaptureService.shared.snapshot()` ДО открытия окна и передаёт в
`openEvalEditorForEntry(_:focus:)` (новый параметр `focus: FocusSnapshot? = nil`;
вызов из History — без него). Снимок живёт в
`@MainActor final class EvalEditorFocusModel: ObservableObject { @Published private(set) var snapshot: FocusSnapshot?; var canInsert: Bool { snapshot != nil }; func update(_ s: FocusSnapshot?) }`
(новый тип в `EvalEditorWindow.swift`). `EvalEditorWindow.open(entryID:focus:)` создаёт
модель; `EvalEditorWindow.updateFocus(_:)` вызывает `model.update`. Если окно записи уже
открыто, `openEvalEditorForEntry` ВСЕГДА вызывает `updateFocus(снимок этого открытия)`
(в т.ч. nil — из History или при фронтмосте VoiceType), затем `orderFrontRegardless`.
Старая цель никогда не переживает новое открытие. `EvalEditorView`
наблюдает модель (`@ObservedObject`) и получает `onSaveAndInsert`; при вставке берётся
`model.snapshot` на момент нажатия (C6).

**C5. Футер** (`EvalEditorView.swift:~447`): при `canInsert` — `Button("Save & Insert")`
слева от основной, `VoiceTypeSecondaryButtonStyle`, `.keyboardShortcut(.return, modifiers:
[.command, .shift])`, `.disabled(saveState != .saveEvalPair)` (повтор гасит `isSubmitting` окна, C6; окно сразу закрывается),
`.help("Saves the pair, returns to <targetAppName> and inserts the corrected text. Select the wrong text before ⌘⌥E to replace it.")`,
`accessibilityLabel` «Save and insert corrected text», `accessibilityHint` «Returns to the
app you dictated into and inserts this text». Основная кнопка и ⌘↩ — без изменений.

**C6. `EvalEditorWindow.handleSaveAndInsert(correction:issue:)`:** первым делом
`guard !isSubmitting else { return }; isSubmitting = true` (свойство окна; сбрасывается,
только если окно остаётся открытым из-за вытесненной записи); затем guard вытесненной
записи как в `handleSave` (окно остаётся); `withEvalSaved` + `HistoryStore.shared.update`
(та же семантика, что у существующего Save — атомарности сверх неё не добавляем);
ДО `close()`: `guard let snapshot = focusModel.snapshot else { return }` и `let appName =
snapshot.app.localizedName ?? "the app"` — локальные константы; затем сохранение, `close()`,
`Task { @MainActor in let outcome = await ReinsertService.shared.reinsert(correction, into:
snapshot); <C3 по outcome и appName> }`.

**C7. DESIGN.md** — `## Decisions Log`: строка 2026-10-19 (Save & Insert, снимок фокуса на
Cmd+Opt+E, перезапись буфера при закрытом приложении, кнопка отсутствует без снимка).

## §4 Файлы

Новые: `Services/ReinsertService.swift`, `Tests/VoiceTypeTests/ReinsertServiceTests.swift`.
Изменяемые: `Services/FocusCaptureService.swift`, `AppDelegate.swift` (openEvalEditor,
openEvalEditorForEntry), `Views/Eval/EvalEditorWindow.swift`, `Views/Eval/EvalEditorView.swift`,
`DESIGN.md`. History и прочее — нет.

## §5 DoD

- `ReinsertServiceTests`: restorer true → inserter вызван с текстом ПОСЛЕ restorer
  (порядок фиксируется журналом вызовов), `.inserted`, copier не вызван; restorer false +
  copier true → `.copied`, inserter не вызван; restorer false + copier false →
  `.failed("Clipboard unavailable")`; inserter бросает → `.failed`; второй вызов во время
  первого (inserter приостановлен на continuation) → `.busy`, после завершения
  `isInFlight == false`; `activationDelay: .zero` в тестах.
- `FocusCaptureService`: `restore()` после рефакторинга ведёт себя как раньше
  (существующие `FocusCaptureServiceTests` зелёные); `restore(snapshot)` с завершённым
  приложением → false (если в тесте получится честно получить завершённый
  `NSRunningApplication` — иначе пункт снимается с пометкой в отчёте; ветка закрытого
  приложения покрыта через подменяемый `restorer` в `ReinsertServiceTests`).
- `ReinsertServiceTests` дополнительно: verifier false → copier, inserter не вызван,
  `.copied`. Завершение приложения во время задержки даёт тот же `.copied` (одна причина
  на обе ветки), отдельный тест не нужен.
- `EvalEditorFocusModel`: init nil → `canInsert == false`; `update(снимок)` → true;
  «открыт по Cmd+Opt+E со снимком → update(nil)» (повторное открытие из History) →
  `canInsert == false`, `snapshot == nil` — старая цель не переживает новое открытие.
- `swift build -c debug`, `swift test` — 0 падений; `swiftlint` — без новых
  предупреждений в изменённых файлах.
- Живая проверка (оркестратор): TextEdit — набрать текст, выделить слово, Cmd+Opt+E,
  правка, ⌘⇧↩ → выделение заменено, буфер обмена прежний; повтор с закрытием TextEdit до
  ⌘⇧↩ → тост, текст в буфере; редактор из History → кнопки нет.
- **Гейт владельца:** до реализации владелец одобряет кнопку, шорткат, тексты тостов.

## §6 Риски

- AX-снимок окна может не восстановить выделение в отдельных приложениях — тогда вставка
  в позицию курсора; документировано в подсказке.
- `AXUIElement` окна может «протухнуть» (окно закрыто) — `AXUIElementPerformAction` вернёт
  ошибку, активация приложения всё равно произойдёт (как в нынешнем Focus Return).
- **Остаточная гонка (принята, plan-review r3):** между `verifier` и фактическим paste
  внутри `TextInjectionService.insertText` (снимок буфера, ~десятки мс) пользователь может
  сам переключить окно — тогда текст уйдёт в новое окно. Та же гарантия у живой
  диктовки (`insertionTargetDecision` → `injectText`); атомарность потребовала бы правки
  `TextInjectionService` (анти-scope).
- Анти-scope: живая диктовка, общий захват/восстановление фокуса, `TextInjectionService`,
  History, хоткеи, капсула.

## §7 Отложено

**C1b History:** Re-insert вставляет правку, Copy/отображение показывают правку,
«App not running → буфер+тост», guard повторного нажатия, закрытие листа до активации —
замечания plan-review r1 P1-1, P1-2 (для History), P2 «Copy/отображение».

## §8 Plan-review

r5 REVISE (2×P1, 1×P2) — упрощение политики: «побеждает последнее открытие», nil тоже
записывается (C4, §2); `shouldUpdateFocus` удалён; снимок и имя приложения фиксируются
локально до `close()` (C6); тест stale-снимка (§5).

r4 REVISE (1×P1, 1×P2, 1×P3) — упрощение: `isInserting` убран из C5 (guard окна); две
причины копирования свёрнуты в одну `.copied` с одним тостом; имя приложения — из снимка в
UI (C3).

r3 REVISE (2×P1, 1×P2) — серия не сходится (3 раунда подряд с новым P1), метод сменён на
упрощение: P1 рассинхрон `.copiedTargetClosed` в §5 — исправлен (`.copied`);
P1 гонка внутри `insertText` — **отклонено**: та же гарантия, что у живой диктовки, фикс
требует правки `TextInjectionService` (анти-scope), риск записан в §6; P2 двойное
сохранение — флаг `isSubmitting` до сохранения (C6).

r2 REVISE (1×P1, 2×P2, 1×P3) — приняты все: P1 обновление снимка при повторном
Cmd+Opt+E → `EvalEditorFocusModel` + `updateFocus` (C4); P2 гонка завершения и P2 «AX не
восстановил окно» → проверка `isFocused` перед вставкой, иначе копия в буфер (C1, C2); P3
тесты модели и хелпера (§5).

r1 REVISE (5×P1, 6×P2, 3×P3). Принято: P1 фокус по bundleID → снимок окна на Cmd+Opt+E
(C1, C4); P1 лист History → History вне объёма (§7); P1 повторное нажатие → in-flight
(C2); P1 ложная гарантия буфера → pasteboard-параметр убран, буфер успешной ветки —
ответственность `TextInjectionService` (C2); P1 `setString` → проверяется (C2); P2
Sendable/изоляция → `@MainActor` typealias’ы, класс `@MainActor` (C2); P2 активация →
`restorer` подменяем целиком (C2); P2 логирование → владелец сервис (C2); P2 VoiceOver →
C3/C5; P3 гейт владельца → §5. Отклонено с причиной: P2 «тост логируется как ошибка» —
принято как есть (§2); P3 атомарный compare-and-update — существующий Save той же
семантики, ротация вытесняет старейшие записи, а редактор открыт на последней.
