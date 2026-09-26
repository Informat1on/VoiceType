# План: предрелизная волна (s26, 2026-09-26)

Ветка `feat/reliable-dictation`, база `ed70c28`. Решения владельца 26.09: состав волны —
все четыре задачи T1–T4; пуш ветки в публичный форк SwiftWhisper — разрешён после SHIP
code-review задачи T2.

## §1 Цель

Закрыть технические хвосты перед выпуском накопленных этапов 1+2 (v1.5.0, выпуск —
отдельная санкция): надёжный replay (T1), корректное освобождение контекста whisper
(T2), герметичные тесты (T3), понимание осиротевшего аудио (T4). Задачи независимы по
файлам и идут параллельно.

## §2 Граф

```
T1 (Sonnet, worktree) ─┐
T2 (Sonnet, worktree + ../SwiftWhisper) ─┼─→ code-review ×3 (параллельно) → интеграция (оркестратор) → волна 2
T3 (Sonnet, worktree) ─┤
T4 (оркестратор, только чтение) ─┘ → отчёт владельцу → решение по фиксу (волна 2)
```

Непересечение файлов:

| Задача | Разрешённые к правке файлы |
|---|---|
| T1 | `scripts/replay.sh`, новый `scripts/freeze-audio.py`, новый `scripts/tests/test_freeze_audio.py` |
| T2 | `../SwiftWhisper/**` (ветка `fix/whisper-context-release`); в VoiceType — только `Sources/VoiceType/Services/TranscriptionService.swift` и тесты `Tests/VoiceTypeTests/TranscriptionService*Tests.swift`, если корень там; временная правка `Package.swift` на `path:` — только для проверки, в итоговом diff её нет |
| T3 | `Sources/VoiceType/Services/HistoryStore.swift` (шов логгера + защита `deleteAudioFiles`), `Tests/VoiceTypeTests/**` кроме `TranscriptionService*Tests.swift` и `ReplayHarness*` |
| T4 | ничего (только чтение метаданных файлов) |

Общий ресурс — CPU/Metal при `swift test` (T2, T3): у каждой worktree свой `.build`,
конфликтов по файлам нет.

## §3 Задачи и контракты

### T1. Replay замораживает аудио вместе с историей

**Проблема.** `scripts/replay.sh` в режиме истории копирует `history.jsonl` в приватный
`WORK_DIR`, но аудио читает из живого `~/Library/Application Support/VoiceType/audio/`
(`replay.sh:125` `VOICETYPE_REPLAY_AUDIO_DIR="$AUDIO_DIR"`). Ротация истории приложения
(`HistoryStore.rotateAudioIfNeeded` `:425`, `deleteAudioFiles` `:453`) удаляет аудио
старейших записей при новой диктовке — прогон replay и последующий `shadow-analysis.py`
ломаются (случалось в s24, s25).

**Контракт `scripts/freeze-audio.py`** (новый, python3 stdlib):
```
freeze-audio.py <history.jsonl> <src-audio-dir> <dst-dir>
```
- Читает JSONL построчно; из каждой записи берёт поле `audioPath`. Отсутствует или
  `null` → запись без аудио, пропускается. Тексты записей не печатает и не логирует.
- Значение `audioPath` допустимо, только если это строка и базовое имя: не пустая, без
  `/` и `\`, не `.`/`..`, не начинается с `.`, не абсолютный путь. Любой другой тип
  (число, массив, объект, bool) или недопустимая строка → `invalid`, в stderr
  `invalid audioPath at line N` (без значения), файл не копируется.
- Исходник: проверяется `os.lstat`. Не существует → `missing` (не ошибка: ротация
  приложения может удалить файл между заморозкой истории и копированием — это
  документированная семантика, у записи в replay будет честная ошибка `audio-missing`).
  Существует, но не обычный файл (symlink, каталог, иное) → `invalid`.
  Копирование — `shutil.copyfile(src, dst, follow_symlinks=False)`, затем
  `os.chmod(dst, 0o600)`; файл назначения создаётся внутри umask 077. Исчез между
  `lstat` и копированием → `missing`. Любая другая ошибка ввода-вывода → exit 2.
- Порядок обработки: (1) пройти все строки, собрать `invalid` по строкам (каждая
  строка с недопустимым значением считается отдельно) и множество допустимых имён;
  (2) для каждого УНИКАЛЬНОГО допустимого имени — ровно одна попытка `lstat`/копирования,
  итог попадает ровно в один счётчик: `copied`, `missing` или `invalid` (не обычный
  файл). Сумма `copied + missing + invalid_из_шага_2` = число уникальных допустимых
  имён. Нормализации имён нет — сравнение строк как есть.
- Гонка «файл заменён между `lstat` и копированием»: приложение создаёт аудио под новыми
  именами `<UUID>.caf` и удаляет старые, существующие файлы не перезаписывает — поэтому
  замена содержимого на месте не ожидается; допустимая семантика — `missing`, если файл
  исчез, иначе копия того, что лежит на момент копирования. Документировать в шапке.
- `dst-dir` должен существовать (создаёт вызывающий).
- Нечитаемая/битая строка JSONL (или строка — не JSON-объект) → stderr `bad json at
  line N`, exit 2.
- stdout — ровно одна строка JSON: `{"copied": N, "missing": M, "invalid": K}` (и при
  exit 2 — если выполнение дошло до конца; при исключении ввода-вывода stdout может быть
  пуст).
- Exit: 0 — если `invalid == 0` и нет битых строк и ошибок ввода-вывода; иначе 2.

**Контракт `scripts/replay.sh`:**
- Новый флаг `--keep-audio <dir>`: допустим только в режиме истории; вместе с `--dir` →
  сообщение в stderr и `usage` (exit 1).
- `--keep-audio` без значения → `usage` (exit 1).
- `<dir>` при `--keep-audio` НЕ должен существовать (существующий — файл или каталог,
  даже пустой — ошибка exit 1: так права копии гарантированы). Родительский каталог
  должен существовать. Абсолютный путь (родитель через `cd … && pwd -P` + имя) не должен
  лежать внутри `REPO_DIR` → ошибка exit 1. Создаётся одной операцией `mkdir -m 700`
  (без `-p`; если между проверкой и созданием каталог появился — `mkdir` падает, exit 1).
  НЕ удаляется trap-ом при успехе.
- Если заморозка аудио завершилась ошибкой при `--keep-audio` — созданный этим запуском
  каталог удаляется (частичная копия не остаётся), replay прерывается.
- После успешной заморозки каталог `--keep-audio` сохраняется при ЛЮБОМ дальнейшем
  исходе (падение `swift test`, SIGINT) — это смысл флага; удаление — вручную
  вызывающим. Сказать об этом в шапке скрипта и в `usage`.
- Без `--keep-audio` копия аудио — `$WORK_DIR/audio` (`mkdir -m 700`), удаляется trap-ом
  вместе с `WORK_DIR`.
- Порядок: заморозка `history.jsonl` (как сейчас) → сразу `freeze-audio.py <frozen>
  "$AUDIO_DIR" <копия>` → `export VOICETYPE_REPLAY_AUDIO_DIR=<копия>`. Ненулевой exit
  `freeze-audio.py` → replay прерывается с тем же кодом.
- При успешной заморозке в stderr выводится строка-итог
  `frozen audio: copied=N missing=M dir=<путь>` (прочие строки stderr — диагностика
  ошибок и существующие сообщения скрипта — допустимы).
- Шапка скрипта: утверждение «Audio is read directly … never copied» заменить описанием
  заморозки и флага `--keep-audio`.
- Режим `--dir` не меняется.
- Дальнейший анализ по той же копии: `shadow-analysis.py <run.jsonl> --audio-dir <dir>`
  (флаг уже есть, не менять).

**DoD T1:** `shellcheck scripts/*.sh *.sh` — 0 замечаний; `python3 -m unittest discover
-s scripts/tests` — все OK, среди них новые тесты `test_freeze_audio.py`: копирование,
missing, invalid (`../x`, `a/b`, `a\b`, `foo/..`, `/abs.caf`, `.hidden`, пустая строка,
число, массив, объект), symlink в исходнике → invalid и цель symlink не скопирована,
каталог с допустимым именем → invalid, дубликаты `audioPath` → `copied` считает один
раз, имя с пробелом/Unicode копируется, битая строка JSON и строка-не-объект → exit 2,
права каждого скопированного файла 0600, stdout-формат; `bash -n scripts/replay.sh`;
проверка аргументов `replay.sh` без запуска swift test (`--keep-audio` с `--dir` → exit 1;
`--keep-audio` без значения → exit 1; существующий пустой каталог → exit 1;
путь внутри репозитория → exit 1; несуществующий родитель → exit 1) — командами,
приведёнными в отчёте (путь к истории для этих проверок не должен читаться: проверки
аргументов выполняются до обращения к `history.jsonl`). Живой прогон по истории делает оркестратор при
интеграции (исполнитель историю и аудио владельца не читает).

### T2. Освобождение контекста whisper и код возврата `whisper_full`

**Факты.** s23 §8: после успешного прогона `ReplayHarnessTests` процесс xctest падает в
atexit на `ggml-metal-device.m:622 GGML_ASSERT([rsets->data count] == 0)`; weak-ссылка на
`Whisper` жива после `TranscriptionService.shutdown()`. Исполнитель s23 предположил утечку
в `Whisper.prepareCallbacks()` (`Unmanaged.passRetained(self)`,
`../SwiftWhisper/Sources/SwiftWhisper/Whisper.swift:39`). Проверка оркестратора 26.09:
`transcribe` при каждом завершении зовёт `cleanupCallbacks()` → `release()` — гипотеза
не подтверждена; корень может быть в любом пути (async-обёртка/отмена в форке, ранние
выходы, удержание в `TranscriptionService`, прогрев `performWarmUp` → `runNative`).
`whisper_full` (`Whisper.swift:127`) — код возврата игнорируется.

**Первичный симптом — не weak-ссылка, а падение процесса.** Критерий «исправлено» —
процесс `swift test` с `ReplayHarnessTests` завершается кодом 0 и в его ПОЛНОМ выводе
(stdout+stderr) нет строки `GGML_ASSERT`. `scripts/replay.sh` для этого НЕ годится: он
намеренно принимает ненулевой exit при ассерте после успешного набора
(`replay.sh:163–205`) — проверять прямым вызовом `swift test` (см. DoD).

**Шаги (bug cycle):**
1. Воспроизвести падение прямым вызовом (DoD, команда А) на базе `ed70c28` — зафиксировать
   exit и наличие `GGML_ASSERT`.
2. Локализовать: тест, который создаёт `Whisper`, выполняет транскрипцию (и отдельно —
   путь отмены, если он есть в форке), дожидается completion И дренирует главную очередь,
   отпускает сильные ссылки и проверяет, что weak-ссылка стала `nil`. Критерий дренажа:
   все callback'и форка (`new_segment`, `progress`, `encoder_begin`) ставят работу через
   `DispatchQueue.main.async` во время `whisper_full`, т.е. ДО того, как фоновый closure
   ставит completion на main — очередь FIFO. Поэтому: ждать completion через
   `XCTestExpectation` + `wait(for:timeout:)`/`fulfillment(of:)` (они крутят run loop main,
   callback'и не блокируются; запрещено блокировать main семафором/`sync`); после
   completion поставить ещё один `DispatchQueue.main.async { exp2.fulfill() }` и дождаться
   его — к этому моменту все ранее поставленные замыкания выполнены. Тестовый delegate
   считает вызовы callback'ов; после второго barrier поставить третий и убедиться, что
   счётчики не изменились (обработчики форка на main новых задач не ставят — если
   ставят, дренировать до стабилизации счётчиков); затем
   `autoreleasepool`/выход из scope сильных ссылок и проверка weak. Если порядок в коде
   форка иной, чем описано, — сказать в отчёте и построить дренаж по фактическому порядку. Сначала в форке
   (`../SwiftWhisper/Tests/WhisperTests`, инфраструктура `ResourceDependentTestCase`);
   если в форке объект освобождается — такой же тест на уровне `TranscriptionService`
   (load → transcribe → shutdown → weak == nil) в VoiceType, а также путь прогрева
   `performWarmUp` → `runNative`.
3. Починить в том репозитории, где корень. Тест из шага 2 — красный до фикса и зелёный
   после; команда А — exit 0 и 0 строк `GGML_ASSERT` после (оба прогона в отчёте).
4. `whisper_full` ≠ 0 (C `int`, в Swift импортируется как `Int32` — тип кода `Int32`,
   преобразований нет) → `.failure(WhisperError.fullFailed(code: Int32))` (новый case).
   Обязательно на этом пути: сегменты не читаются; completion вызывается РОВНО ОДИН раз
   (через тот же `wrappedCompletionHandler`, т.е. `cleanupCallbacks` выполняется); сброс
   `inProgress = false`, `frameCount = nil` и обработка `cancelCallback` — те же, что на
   успешном пути (общий код выхода, не ранний `return` мимо него); следующая транскрипция
   на том же экземпляре работает. Тест на ошибку — если её можно вызвать
   детерминированно; если нельзя — сказать в отчёте, тест не выдумывать. Тест на
   `Equatable` нового case — обязателен.

**Контракт:** публичный API форка меняется только добавлением case
`WhisperError.fullFailed(code: Int32)`. VoiceType не использует `WhisperError` напрямую
(проверено grep 26.09) — компиляция не ломается. Освобождение контекста не должно
происходить во время работающего `whisper_full` (замыкание фоновой очереди держит `self`
сильно — это сохранить).

**Процедура с форком:** работать в `../SwiftWhisper` на новой ветке
`fix/whisper-context-release` от `198d330` (ревизия в `Package.swift`). Не коммитить, не
пушить. Проверка в VoiceType: временно заменить зависимость в `Package.swift` на
`.package(path: "../../SwiftWhisper")` (путь относительно worktree — уточнить по месту) и
вернуть обратно до отчёта. Итоговый diff VoiceType не содержит `Package.swift`.
Коммит, пуш форка и новая ревизия в `Package.swift` — оркестратор после SHIP.

**Команда А** (из корня worktree VoiceType, `<tmp>` — `mktemp -d` вне репозитория):
```
N=$(find Tests/Fixtures/bench -maxdepth 1 -type f \( -name '*.wav' -o -name '*.caf' \) | wc -l | tr -d ' ')
VOICETYPE_REPLAY_DIR=Tests/Fixtures/bench VOICETYPE_REPLAY_OUT=<tmp>/bench.jsonl \
VOICETYPE_REPLAY_BUILD_CONFIG=release VOICETYPE_REPLAY_EXPECT=$N \
swift test -c release --build-system native -Xswiftc -enable-testing -Xswiftc -DDEBUG \
  --filter ReplayHarnessTests > <tmp>/a.log 2>&1
# флаги -enable-testing -DDEBUG — как в replay.sh:268; без них тестовая цель в release
# не компилируется (_testIsWarmingUp и др. под #if DEBUG) — найдено при интеграции 26.09
test_exit=$?
assert_count=$(grep -c 'GGML_ASSERT' <tmp>/a.log || true)
passed=$(grep -c "^Test Suite 'ReplayHarnessTests' passed" <tmp>/a.log || true)
echo "test_exit=$test_exit assert_count=$assert_count passed=$passed N=$N"
python3 - "$N" <tmp>/bench.jsonl <<'PY'
import json, sys
n = int(sys.argv[1]); lines = [l for l in open(sys.argv[2]) if l.strip()]
s = json.loads(lines[-1])   # ReplaySummaryJSON — имена полей сверить по ReplayHarnessTests+JSONL.swift
rec, err = s["records"], s["errors"]   # если поле ошибок называется иначе — взять фактическое
print(f"summary records={rec} errors={err}")
sys.exit(0 if rec == n and err == 0 else 1)
PY
echo "summary_check=$?"
```
Команда А считается пройденной ТОЛЬКО если одновременно: `test_exit=0`,
`assert_count=0`, `passed≥1`, `summary_check=0` (машинная проверка сводки: `records == N`
и ошибок 0). `VOICETYPE_REPLAY_EXPECT` заставляет
харнесс упасть при несовпадении числа записей (`ReplayHarnessTests.swift`, ветка
`VOICETYPE_REPLAY_EXPECT`), так что пустой вход не пройдёт как успех. Промпт: харнесс
берёт `customVocabulary` из `com.voicetype.app` (только чтение) либо
`VOICETYPE_REPLAY_PROMPT_FILE`; при пустом словаре и без файла он падает (XCTFail) — это
исход «не пройдено», не ложный успех. Набор env сверить с `replay.sh:95–125`; если
режиму `--dir` чего-то не хватает — добавить и указать в отчёте. Содержимое `a.log` и
`bench.jsonl` целиком не печатать (тексты бенча) — только строку `echo` выше и поля
сводки `records`/ошибки.

**DoD T2:** в форке `swift test` зелёный (команда и итог в отчёте); тест шага 2 —
красный до / зелёный после; команда А: до фикса — зафиксированный исход, после фикса —
`exit=0` и `0`; в VoiceType (с временной path-зависимостью) `swift build -c debug`
exit 0, `swift test --build-system native` — 0 падений (строка `Executed`);
`Package.swift` и `Package.resolved` возвращены (`git diff --stat` в worktree VoiceType
их не содержит).

### T3. Герметичные тесты: `errors.log` и defaults-домены

**Факты.** `HistoryStore` пишет ошибки через `ErrorLogger.shared` (`HistoryStore.swift:320,
479, 525`); тестовый шов `HistoryStore.test(storeURL:audioDirectory:)` (`:270`) логгер не
принимает — тесты пишут в реальный `~/Library/Logs/VoiceType/errors.log`. У `ErrorLogger`
шов уже есть: `ErrorLogger.test(logsDirectory:)`. В `~/Library/Preferences` 271 файл
`voicetype.tests.*.plist` (26.09); тесты с `suiteName = "voicetype.tests.<UUID>"` —
`AudioDeviceSelectionTests.swift:99,115`, также `ModelPresetTests.swift`,
`ReplayHarnessTests.swift` используют `UserDefaults(suiteName:)`; `removePersistentDomain`
в `defer` есть, но файлы остаются.

**Контракт:**
- `HistoryStore`: хранимое `private let errorLogger: ErrorLogger`; прод-путь — `.shared`;
  шов `static func test(storeURL: URL, audioDirectory: URL? = nil, errorLogger: ErrorLogger)`
  — логгер ОБЯЗАТЕЛЕН в шве (без значения по умолчанию), все вызовы шва в `Tests/`
  передают `ErrorLogger.test(logsDirectory: <temp>)`. Три вызова `ErrorLogger.shared.log`
  в `HistoryStore` → `errorLogger.log`. Публичные методы не меняются.
- Защита удаления: `HistoryStore.deleteAudioFiles` (`:453`) удаляет только имена, которые
  являются базовыми (не пустые, без `/`, не `.`/`..`, не начинаются с `.`); прочие —
  пропускаются без удаления, с записью через `errorLogger` (имя в лог не писать,
  только факт) и НЕ возвращаются в очередь повторного удаления. Прод пишет только
  `<UUID>.caf`, но запись в `history.jsonl` может быть повреждена/отредактирована, и
  `appendingPathComponent("../…")` вышел бы за пределы `audio/`. Тест — обязателен.
- Найти все остальные тесты, которые пишут в реальный `errors.log` (не только
  `HistoryStore`), и сделать их герметичными тем же способом, если у соответствующего типа
  уже есть шов; если шва нет — перечислить в отчёте, не добавлять.
- defaults: тесты, создающие `UserDefaults(suiteName: "voicetype.tests.<UUID>")`,
  переводятся на общую тестовую вспомогательную функцию. Порядок: тест отпускает объект
  `UserDefaults` → `removePersistentDomain(forName:)` → `CFPreferencesAppSynchronize`
  для этого домена → удаление РОВНО файла `~/Library/Preferences/<этот suiteName>.plist`,
  если он есть (никаких glob/масок, чужие файлы не трогаются). Сначала выяснить
  фактическую причину остатков (может оказаться, что достаточно синхронизации) и
  описать её в отчёте. Критерий успеха — процессный (после завершения полного прогона),
  а не мгновенный сразу после helper. Существующие 271 файл НЕ удалять (разовую чистку делает
  оркестратор с согласия владельца). `ReplayHarnessTests` читает прод-домен
  `com.voicetype.app` только на чтение — вне правила, не трогать.

**DoD T3:** параметр `errorLogger` без умолчания — покрытие вызовов шва гарантирует
компиляция; `grep -rn 'ErrorLogger.shared' Tests` — 0 совпадений (или каждое оставшееся
объяснено в отчёте); новый тест,
который намеренно вызывает ошибочную ветку `HistoryStore` (например, нечитаемый файл
истории → `loadIfNeeded`) с `ErrorLogger.test(logsDirectory: <temp>)` и проверяет, что
запись появилась во временном логе (с учётом `@MainActor` у `ErrorLogger`); тест на
защиту `deleteAudioFiles`. Замер метаданных (`errors.log`, число
`voicetype.tests.*.plist`) исполнитель T3 НЕ делает: `~/Library` общий с параллельным T2,
замер был бы засорён. Его делает оркестратор при интеграции (§4 п.4), одним прогоном
без параллельных тестовых процессов. Исполнитель: полный `swift test --build-system
native` — 0 падений; `swiftlint lint --quiet` — 0 errors, warnings ≤ 47; `swift build -c debug`
exit 0.

### T4. Осиротевшее аудио — расследование (оркестратор)

Только метаданные: имена файлов `audio/`, их mtime/размер, поля `id`/`timestamp`/`audioPath`
из `history.jsonl` (тексты не читаются и не печатаются); в системном логе приложения —
только подсчёт фиксированных маркеров (`grep -o` по `Digital silence`, `empty text` и
т.п.), остальное содержимое лога не выводится.

**Итог (выполнено 26.09 до plan-review r2):** 200 файлов `.caf`, 98 без записи в истории
(16 МБ), записей с пропавшим аудио — 0. 6 сирот новее самого старого аудио истории; три
из них (25–26.09) совпадают по секунде с `Digital silence — ASR skipped` + `empty text`
в логе — путь пустого результата подтверждён. 92 сироты старше окна истории
(26.07–23.09, 1–6 в день); удаление аудио при вытеснении записей есть с `75ad2cc`
(27.07) — вероятно, тот же путь, по каждому файлу не доказано. Корреляция по возрасту
НЕ является основанием для удаления: разовая чистка — только отдельным решением
владельца, с перечнем файлов. Вопросы: даты сирот против
диапазона дат истории; есть ли сироты свежее самой старой записи истории (признак пути
`emptyResult`, `AppDelegate.swift:900` сохраняет аудио до распознавания,
`AppDelegate+Dictation.swift:235` не пишет запись); сверка с логами «Nothing heard»/
«Digital silence» по времени. Итог — отчёт владельцу с вариантами фикса (удалять аудио на
пустом результате / писать запись в историю для Retry) и предложением разовой чистки.
Фикс и чистка — волна 2, по решению владельца.

## §4 Интеграция (оркестратор)

1. Code-review каждой задачи отдельно (T1, T2, T3), параллельно; fix-loop — тем же тредом.
2. Перенос diff из worktree в основную копию (`git -C <wt> diff HEAD | git apply`,
   untracked — копированием); файлы не пересекаются.
3. T2 после SHIP: коммит в форке на ветке `fix/whisper-context-release`, пуш (санкция
   есть), новая ревизия в `Package.swift`, `swift package resolve`.
4. Общий прогон — ТОЛЬКО на объединённом дереве (T1+T2+T3 применены вместе; проверки
   в отдельных worktree совместимость не доказывают): команда А из T2 (exit 0,
   0 `GGML_ASSERT`), `swift build -c debug`, `swift test --build-system native` — этот
   прогон без каких-либо параллельных тестовых процессов, с замером до/после (только
   метаданные): размер `~/Library/Logs/VoiceType/errors.log` и число
   `~/Library/Preferences/voicetype.tests.*.plist` не выросли (DoD T3); `swiftlint`,
   `python3 -m unittest discover -s scripts/tests`, `shellcheck *.sh scripts/*.sh`;
   живой `replay.sh --keep-audio <K>` (`<K>` — несуществующий путь внутри `mktemp -d`
   вне репо) по истории → проверить: строка `frozen audio: copied=N…` с `N > 0`;
   `stat -f %Lp <K>` = 700 и у всех файлов 600; число файлов в `<K>` = `copied`; сводка
   replay `records` = числу записей замороженной истории, errors 0, ни у одной записи
   нет ошибки `audio-missing` (сверка по каждой записи JSONL, не по числу файлов —
   дубликаты `audioPath` дедуплицируются) → `shadow-analysis.py
   <run.jsonl> --audio-dir <K>` (ровно тот же путь) → `analysisErrors=0`, analyzed =
   records; удалить `<K>`.
5. Сборка в `/Applications` и коммит — только по слову владельца.

## §5 Риски

- **T2 меняет время жизни нативного контекста.** Освобождение `whisper_free` при
  преждевременном отпускании → падение. Защита: фоновая очередь держит `self`; тест на
  отмену/таймаут; `TranscriptionService.shutdown` и путь `_exit` не меняются.
- **T2 может не найти корень за разумный бюджет** — тогда отчёт с фактами и без фикса;
  не маскировать.
- **Копия речи владельца (T1)** — только вне репозитория, 0700/0600, удаляется по
  завершении без `--keep-audio`.
- **Параллельные `swift test`** — дольше по времени, не по корректности.
- **Агенты от `main`** — worktree агента создаётся от `main`; первая команда
  `git merge --ff-only ed70c28`.

## §6 Вне волны

Выпуск v1.5.0 (санкции на пуш/PR/релиз); фикс сирот и разовая чистка; возврат `replay.sh`
к правилу «exit 0 = успех» после T2 (обход ассерта в `replay.sh` остаётся в этой волне —
T1 и T2 не должны пересекаться по `replay.sh`); этап 3.

## §7 Решения plan-review

**r1** (тред `20260926-003600-56068`) REVISE, 7×P1 / 9×P2 / 2×P3. Приняты все:
ложно-зелёный DoD T2 через обход ассерта в `replay.sh` → прямая команда А; критерий T2
— чистое завершение процесса, weak-тест только для локализации, с дренажом main-очереди;
контракт ошибочного пути `whisper_full` (completion ровно раз, общий сброс состояния);
`--keep-audio` — только несуществующий каталог, `mkdir -m 700`, удаление частичной копии;
`audioPath` не-строка → invalid; symlink/не-файл → invalid, `follow_symlinks=False`;
гонка ротации — документированная семантика `missing`; stderr-итог только при успехе;
путь-обход в прод-удалении `HistoryStore.deleteAudioFiles` → в T3 (тот же файл, что и
шов логгера); грепабельный DoD и тест ошибочной ветки для T3; удаление ровно своего plist;
исключение `ReplayHarnessTests` из правила defaults; общий прогон только на объединённом
дереве; T4 — явное разрешение подсчёта маркеров в логе; расширенный набор invalid-имён;
тип кода `Int32` и тест `Equatable`.

**r2** REVISE, 3×P1 / 6×P2 / 2×P3. Приняты все: команда А — отдельный `test_exit`,
`VOICETYPE_REPLAY_EXPECT`, строка `passed`, сверка `records`/ошибок сводки, точный
паттерн `GGML_ASSERT`; формальный дренаж main-очереди (FIFO + второе expectation, без
блокировки main); порядок подсчёта дубликатов; гонка замены — документированная
семантика (приложение не перезаписывает файлы); `--keep-audio` сохраняется при любом
исходе после заморозки; lifecycle удаления defaults-домена и процессный критерий;
grep по `ErrorLogger.shared` вместо grep по вызовам шва; расширенные проверки
интеграционного прогона (copied > 0, права, тот же `--audio-dir`); запрет удаления сирот
по корреляции.

**r3** REVISE, 2×P1 / 2×P2 / 1×P3. Приняты все: машинная проверка сводки в команде А
(`summary_check`); замер герметичности T3 перенесён к оркестратору в интеграцию (общий
`~/Library` у параллельных T2/T3 засорял бы метрику); сверка `audio-missing` по каждой
записи; стабилизация счётчиков callback'ов при дренаже; подсчёт `.wav`+`.caf`. Лимит
3 раунда исчерпан → **override оркестратором**: спора нет, все замечания трёх раундов
приняты, правки уточняют проверки, архитектура плана не менялась.

## §8 Code-review и интеграция (26.09)

- **T1** (тред `20260926-005608-71023`): r1 FIX (P1 частичная копия при сигнале; P2 UTF-8/chmod → exit 2, имена в stderr, TOCTOU symlink) → r2 FIX (P1 trap мог удалить чужой каталог; P2 umask) → r3 **SHIP**.
- **T2-VoiceType** (тред `20260926-011554-90664`): корень утечки — не форк, а `NativeAbortSignal.swift` `race()`: задача таймера не отменялась при выигрыше operation, её `onTimeout` держал `whisper` до `max(30, audioSeconds)` с → `whisper_free` не вызывался → atexit `GGML_ASSERT`. Периметр T2 расширен оркестратором на `race()`. r1 **SHIP**.
- **T2-форк** (тред `20260926-011202-86717`): r1 FIX (P2 сброс состояния после completion, гонка cancelCallback) → r2 FIX (P1 освобождение удержания чужого прогона при рестарте из callback) → r3 **SHIP**. Коммит `8ed83b7` на ветке `fix/whisper-context-release`, запушен (санкция владельца); ревизия в `Package.swift` поднята.
- **T3** (тред `20260926-010601-80595`): r1 **SHIP** (+ P2 defer, P3 имя suite — исправлены). Интеграционный замер выявил остатки: plist от `withHermeticUserDefaults` (асинхронная перезапись cfprefsd) и записи `[app]`/`[toast]` в errors.log (у `AudioCaptureService`/`ErrorToastWindow` швы были, тесты их не ставили). Доработано; r2 FIX с двумя остаточными P2 (отложенная перезапись после финальной проверки; крах процесса до `defer`) → **override оркестратором**: только тестовый helper, прод не затронут, эмпирически 0/300 под нагрузкой и 0 прироста на интеграционном замере; крах процесса helper закрыть не может в принципе.
- **Интеграция (объединённое дерево, новый форк, без параллельных тестов):** `swift build -c debug` exit 0; `swift test --build-system native` 632 теста / 0 failures / 0 `GGML_ASSERT`; errors.log 143811→143811 байт, plist 292→292; swiftlint 47/0; shellcheck 0; python-тесты OK; команда А — `test_exit=0 assert_count=0 passed=1 summary_check=0` (флаги `-enable-testing -DDEBUG` добавлены в текст команды); живой `replay.sh --keep-audio` по истории — copied=102 missing=0, права 700/600, records 102 errors 0, audio-missing 0, shadow-analysis `analysisErrors=0 analyzed=102`, `GGML_ASSERT` 0, копия удалена.
