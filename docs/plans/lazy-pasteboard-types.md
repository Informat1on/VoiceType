# Вставка вместо печати при «ленивых» типах WebKit в буфере

Статус: реализовано (2026-10-19), code-review SHIP r1, проверено владельцем вживую.

## 1. Проблема

Владелец: «иногда вместо вставки, выбранной в настройках, идёт построчная печать; через
какое-то время проходит само». Режим вставки в настройках — paste.

Корень (проверено по логам `~/Library/Logs/VoiceType/errors*.log`): все 11 событий перехода
на печать за 12–19.10 — одной причины:

```
Clipboard snapshot unavailable (incomplete: unreadable types iOS rich content paste
pasteboard type, Apple Web Archive pasteboard type) — typing instead to keep clipboard intact
```

Других причин печати в логах нет. Код: `TextInjectionService.insertViaPastePreservingClipboard`
(`Sources/VoiceType/Services/TextInjectionService.swift:208–222`) берёт
`PasteboardSnapshot.capture`; при любом результате, кроме `.captured`, буфер не трогается и
текст печатается. `PasteboardSnapshot.materialize`
(`Sources/VoiceType/Services/PasteboardSnapshot.swift`) возвращает `.incomplete`, если хоть
один заявленный тип вернул `nil` из `data(forType:)` (решение D1, `docs/plans/reliable-dictation.md`
§ D1 — не выдавать частичный снимок за полный).

Копирование из Safari/WebKit кладёт в элемент буфера, помимо `public.html` / `public.rtf` /
`public.utf8-plain-text`, ещё веб-архив и «iOS rich content» — типы, которые источник отдаёт
лениво и на чтение снимком возвращает `nil`. Пока владелец не скопирует что-то другое, каждая
диктовка идёт печатью — отсюда «через какое-то время проходит». С нагрузкой не связано.

## 2. Решение (одобрено владельцем 19.10: «давай дальше, исправление багов»)

Закрытый список «избыточных ленивых» типов — данных, которые являются альтернативным
представлением того же фрагмента, уже представленного читаемыми текстовыми типами:

```swift
enum PasteboardSnapshot { // внутри struct, static
    /// Raw values. Закрытый список — расширять только по факту из логов.
    static let redundantLazyTypes: Set<String> = [
        "Apple Web Archive pasteboard type",
        "com.apple.webarchive",
        "iOS rich content paste pasteboard type",
    ]
    /// Хотя бы один из них должен быть прочитан в ТОМ ЖЕ элементе.
    static let textFallbackTypes: Set<String> = [
        "public.html", "public.rtf", "public.utf8-plain-text",
    ]
}
```

Правило в `materialize`, **по каждому элементу отдельно**: нечитаемый тип `t` элемента
считается «отброшенным избыточным», если `t ∈ redundantLazyTypes` И в этом же элементе
прочитан непустыми данными хотя бы один тип из `textFallbackTypes`. Иначе `t` — нечитаемый,
как сейчас. Итог:

- есть хоть один нечитаемый (не отброшенный) тип → `.incomplete(unreadableTypes:)`,
  в список попадают ВСЕ нечитаемые типы, включая избыточные (для лога) — поведение как сейчас;
- иначе → `.captured(snapshot)`, отброшенные типы не попадают в `items` и перечисляются в
  новом поле `PasteboardSnapshot.droppedRedundantTypes: [String]` (raw values, без повторов,
  в порядке первого появления; для пустого/обычного буфера — `[]`).

Порядок проверок `tooLarge → changedDuringCapture → incomplete` не меняется.

**Алгоритм (отложенное решение по элементу, r1 P2).** Для каждого элемента: читать все его
типы как сейчас; нечитаемые типы ЭТОГО элемента копить в локальный список (порядок появления).
После обхода всех типов элемента: `hasTextFallback` = в `captured` этого элемента есть тип из
`textFallbackTypes` с `!data.isEmpty` (r1 P1: пустой `Data()` fallback'ом НЕ считается, хотя
сам тип в `items` сохраняется как сейчас). Затем каждый локальный нечитаемый тип: если
`hasTextFallback && redundantLazyTypes.contains(t.rawValue)` → в глобальный
`droppedRedundantTypes` (дедуп по raw value, порядок первого появления по всему буферу), иначе
→ установить глобальный флаг `hasBlockingUnreadable = true`. Независимо от классификации
КАЖДЫЙ нечитаемый тип сразу при обнаружении добавляется в глобальный `allUnreadableTypes`
(дедуп/порядок первого появления — ровно как текущий `unreadableTypes`). Итог (r2 P2):
`hasBlockingUnreadable` → `.incomplete(unreadableTypes: allUnreadableTypes)` (включая
отброшенные; `droppedRedundantTypes` при этом выбрасывается — частичного снимка нет, лога
об отброшенных нет, только существующий лог «typing instead»); иначе →
`.captured(PasteboardSnapshot(items:, changeCount:, droppedRedundantTypes:))`.
Элемент, у которого прочитанных типов нет, по-прежнему не попадает в `items` (но тогда у него
нет fallback и его ленивые типы — ошибка → `.incomplete`, так что элемент молча не теряется).
Сравнение raw value — точное, регистрозависимое; варианты не из списка сознательно остаются
`.incomplete` (зафиксировать в doc-комментарии).

**Логирование (r1 P2).** `AppLog.insertion.notice` пишется ТОЛЬКО после того, как снимок
реально использован для paste — т.е. после успешной проверки `shouldWriteClipboard`, перед
записью нашего текста в буфер; при переходе на печать по `changeCount` — не пишется. Формат:
`"Clipboard snapshot dropped redundant lazy types: \(list, privacy: .public)"`, где `list` —
`droppedRedundantTypes.joined(separator: ", ")` (имена типов, уже дедуплицированы и упорядочены;
содержимое буфера — никогда). В `errors.log` не писать — это не ошибка. Unit-проверки лога нет
(os_log не перехватывается в тестах); проверяется вживую.

**Документация инварианта (r1 P1).** `.captured` больше не означает «все заявленные типы» —
означает «все заявленные типы, кроме перечисленных в `droppedRedundantTypes`». Обновить:
doc-комментарии `PasteboardSnapshotResult.incomplete`, `PasteboardSnapshot`, `materialize`;
`docs/plans/reliable-dictation.md` § D1 — абзац-исключение со ссылкой на этот план.

Цена (принята владельцем): после вставки восстановленный буфер содержит HTML/RTF/текст
фрагмента, но без веб-архива и iOS rich content; повторная вставка того же фрагмента в
Safari/Notes/Mail может потерять часть вёрстки или встроенные картинки.

Отвергнуто: увеличить таймаут/читать на main — типы отдают `nil`, а не медлят (результат
`.incomplete`, не `.timedOut`); замедлит каждую вставку и не гарантирует успех.

## 3. Файлы и задачи (одна Sonnet-задача)

1. `Sources/VoiceType/Services/PasteboardSnapshot.swift` — константы, поле
   `var droppedRedundantTypes: [String] = []` (объявлено с дефолтом в теле struct ПОСЛЕ
   `changeCount`, чтобы memberwise init `PasteboardSnapshot(items:changeCount:)` у
   существующих вызовов компилировался без изменений; Equatable остаётся синтезированным),
   правило в `materialize` по алгоритму §2, doc-комментарии. `docs/plans/reliable-dictation.md`
   § D1 — абзац-исключение.
2. `Sources/VoiceType/Services/TextInjectionService.swift` — notice-лог при непустом списке.
3. `Tests/VoiceTypeTests/PasteboardSnapshotTests.swift` — тесты (через `NSPasteboardItemDataProvider`,
   как существующий `PartiallyUnreadableDataProvider`):
   - T1: html+plain читаемы, webarchive и iOS rich content нечитаемы → `.captured`; в `items`
     есть html и plain, нет webarchive; `droppedRedundantTypes` = оба типа в порядке появления;
     `write` + повторный `materialize` round-trip сохраняет html и plain.
   - T2: только webarchive нечитаем, читаем лишь `public.png` → `.incomplete(["Apple Web Archive pasteboard type"])`.
   - T3: webarchive и неизвестный тип нечитаемы, html читаем → `.incomplete` с обоими типами.
   - T4: два элемента — первый html + нечитаемый webarchive, второй только нечитаемый
     webarchive → `.incomplete` (правило по элементу, не по буферу).
   - T5: обычный буфер без отброшенных → `droppedRedundantTypes == []`.
   - T6: async `capture` на T1-буфере → `.captured`.
   - T7 (r1 P1): `public.html` читается как пустой `Data()`, других fallback нет, webarchive
     нечитаем → `.incomplete(["Apple Web Archive pasteboard type"])`.
   - T8 (r1 P2): ленивый тип объявлен в элементе РАНЬШЕ fallback-типа → всё равно `.captured`;
     в тесте ассерт, что `pasteboard.pasteboardItems![0].types` действительно начинается с
     ленивого типа (r2 P3) — иначе фикстура не моделирует сценарий.
   - T9 (r1 P2): три элемента, у каждого html + нечитаемые ленивые типы в разном порядке
     (эл.1: webarchive, iOS rich; эл.2: iOS rich, webarchive; эл.3: webarchive) →
     `.captured`, `droppedRedundantTypes == ["Apple Web Archive pasteboard type",
     "iOS rich content paste pasteboard type"]`, `items.count == 3`; `write` на чистый
     pasteboard + `materialize` → 3 элемента в исходном порядке (различимы по html-данным),
     ни в одном нет ленивых типов, `droppedRedundantTypes == []`.
   - T7b (r3): html = `Data()`, plain непустой, webarchive нечитаем → `.captured`, пустой html
     сохранён в `items`.
   - T10 (r3): два элемента с повторяющимися ленивыми и неизвестным типом → `.incomplete`,
     порядок первого появления без повторов.
   Отклонено r3: интеграционный тест `insertViaPastePreservingClipboard` (нужны Accessibility
   и CGEvent, в unit-тестах недоступны) — место лога проверяется code-review и вживую.
   Plan-review: r1–r3 REVISE, в r3 P1 нет → OVERRIDE ГЕЙТА оркестратором (r3 P2 о тестах
   учтены T7b/T10, прочее — ясность формулировок).
4. `DESIGN.md` не затрагивается (нет UI). CHANGELOG — строка в Unreleased/Fixed.

## 4. Риски

- Неизвестные будущие ленивые типы — остаются на печати (закрытый список, осознанно).
- Тип из списка, который в каком-то источнике несёт уникальное содержимое (напр. картинку
  без текстового эквивалента) — защищает условие «в том же элементе прочитан текстовый тип».
- Реальное поведение Safari не воспроизводится в unit-тестах — живая проверка обязательна.

## 5. DoD

- `swift build -c debug` exit 0; `swift test --build-system native` — 0 падений, тестов больше,
  чем до изменения (на `c6bc97f` — 662), на число новых;
  `swiftlint lint` — 0 errors, новых warnings нет.
- Code-review гейт `ВЕРДИКТ: SHIP`.
- Живая проверка владельцем: скопировать абзац со ссылкой из Safari → продиктовать в T3 Code →
  текст вставлен разом (не печатается); после этого Cmd+V в TextEdit (rich) даёт абзац со
  ссылкой; в Console/`log show` — notice про отброшенные типы; Cmd+V в Notes даёт абзац со
  ссылкой и форматированием (проверка заявленной цены, r1 P2).
- Одноразовая ручная диагностика агента при живой проверке (не артефакт репозитория, r2 P3):
  `swift /tmp/vt-pb/pb.swift` печатает `<индекс элемента> <тип> <N B|NIL>` (без содержимого)
  до и после диктовки; ожидание — после диктовки те же элементы и типы, кроме ленивых.
