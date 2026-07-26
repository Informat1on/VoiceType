# VoiceType — Whisper backend benchmark на Apple M5 Pro

**Дата:** 2026-07-26
**Железо:** MacBook Pro, Apple M5 Pro (6P + 12E, 18 ядер), 64 GB, macOS 26.5.2 (25F84)
**Модель:** `ggml-large-v3-turbo-q5_0` (574 MB)
**Аудио:** `short` = `Tests/Fixtures/bench/05.wav` (5.4 с), `long` = `bench-output/live-20260427-185032/recording.wav` (90 с)
**Параметры:** `-l ru -t 4 --no-timestamps`, медиана 3 прогонов, прогретый кеш
**Инструмент:** `whisper-cli`, собранный из двух версий whisper.cpp — v1.7.5 (та, что в форке `Informat1on/SwiftWhisper`) и v1.9.1 (upstream master, commit `080bbbe`)

> Обе сборки делались с `-DGGML_METAL_EMBED_LIBRARY=OFF` и без Metal-toolchain
> (на машине только Command Line Tools, Xcode нет) — шейдер компилируется в рантайме
> из `ggml-metal.metal`. Это то же самое, что делает приложение.

---

## Главная находка: Metal в приложении не работает вообще

Лог запуска установленного `/Applications/VoiceType.app`:

```
register_device: registered device Metal (Apple M5 Pro)
ggml_metal_load_library: default.metallib not found, loading from source
ggml_metal_load_library: loading '…/.build/arm64-apple-macosx/release/SwiftWhisper_whisper_metal.bundle/ggml-metal.metal'
ggml_metal_load_library: error: … "The file “ggml-metal.metal” couldn’t be opened because there is no such file."
ggml_metal_init: error: metal library is nil
whisper_backend_init_gpu: failed to initialize Metal backend
```

Две причины, обе нужно чинить:

1. **Битый симлинк в ресурсном бандле.** В форке `Sources/whisper_metal/ggml-metal.metal` — символическая
   ссылка на `../../whisper.cpp/ggml/src/ggml-metal/ggml-metal.metal`. SwiftPM копирует симлинк
   в `SwiftWhisper_whisper_metal.bundle` как есть, не резолвя его, и относительный путь
   внутри бандла ведёт в никуда.
2. **`build-app.sh` не копирует SPM resource bundles в `.app`.** В `Contents/Resources`
   лежит только `VoiceType.icns`. Ни `SwiftWhisper_whisper_metal.bundle`,
   ни `VoiceType_VoiceType.bundle` (шрифты Geist) туда не попадают — установленное
   приложение ищет их по абсолютному пути в `.build` разработчика.

Следствие: транскрибация идёт на CPU-бэкенде ggml. Энкодер спасает CoreML (`.mlmodelc`
на ANE), декодер целиком на CPU.

## Neural Accelerators M5: не поддерживаются, но упираются в версию

Tensor API (Metal 4 / `mpp::tensor_ops::matmul2d`, он же «нейроакселераторы» в GPU-ядрах)
появился в ggml уже после v1.7.5. В форке — whisper.cpp **v1.7.5 (март 2025)**, в котором
`ggml-metal` ещё монолитный `.m`-файл без tensor-кода. Upstream — **v1.9.1**.

На M5 Pro upstream включает его автоматически:

```
ggml_metal_device_init: GPU family: MTLGPUFamilyMetal4  (5002)
ggml_metal_device_init: has bfloat            = true
ggml_metal_device_init: has tensor            = true
```

Гейт в `ggml-metal-device.m`: `supportsFamily:MTLGPUFamilyMetal4` **и** имя устройства
содержит `M5`/`M6`/`A19`/`A20` (для более старых чипов упомянутая реализация давала
+0…−5%, поэтому по умолчанию выключена). Переключатели — `GGML_METAL_TENSOR_DISABLE` /
`GGML_METAL_TENSOR_ENABLE`.

---

## Результаты

Все значения — миллисекунды, медиана 3 прогонов.

### long (90 с аудио)

| # | Конфигурация | encode | batchd | total |
|---|--------------|-------:|-------:|------:|
| A2 | **v1.7.5, CPU + CoreML/ANE — то, что работает сейчас** | 832 | 2700 | **4544** |
| A | v1.7.5, CPU-only, без CoreML (нижняя граница) | 9946 | 2633 | 13189 |
| B | v1.7.5, Metal починен, без CoreML | 1481 | 641 | 2603 |
| C | v1.9.1, Metal, tensor **off**, без CoreML | 1213 | 557 | 2209 |
| G | v1.9.1, Metal, tensor off, + CoreML | 741 | 562 | 1979 |
| F | v1.9.1, Metal, tensor **on**, + CoreML | 724 | 563 | 1970 |
| D | **v1.9.1, Metal, tensor on, без CoreML** | **612** | 553 | **1591** |

### short (5.4 с аудио — типичный диктант)

| # | Конфигурация | encode | batchd | total |
|---|--------------|-------:|-------:|------:|
| A2 | **v1.7.5, CPU + CoreML — сейчас** | 431 | 149 | **972** |
| F | v1.9.1, Metal + tensor + CoreML | 402 | 33 | 855 |
| G | v1.9.1, Metal, tensor off, + CoreML | 404 | 33 | 830 |
| D | **v1.9.1, Metal + tensor, без CoreML** | **214** | 32 | **420** |

---

## Выводы

1. **Вклад нейроакселераторов измерен: энкодер 1213 → 612 мс (1.98×)** — сценарии C→D,
   ровно тот порядок «2–3× на prompt processing», который заявлен для M5. На коротком
   аудио 404 → 214 мс.
2. **Прирост есть только когда энкодер идёт через Metal.** С CoreML-энкодером (F vs G)
   разница 724 vs 741 мс — в пределах шума: ANE и Neural Accelerators это разные блоки,
   whisper использует что-то одно.
3. **На M5 Pro Metal + tensor API обгоняет CoreML/ANE:** 612 vs 724 мс на энкодере,
   1591 vs 1970 мс по total. То есть CoreML-энкодер на M5 можно не тянуть вообще —
   это минус скачиваемый артефакт (~+40% к весу модели), минус баг распаковки
   (`Failed to unzip CoreML model model=small-q5_1` в `errors.log`), минус
   cherry-pick `f7502dca` про conv-scheduler в форке.
4. **Суммарно от текущего состояния: 972 → 420 мс (2.3×) на короткой фразе,
   4544 → 1591 мс (2.9×) на 90 секундах.** Из них ~⅔ выигрыша даёт починка Metal +
   апгрейд, ~⅓ — собственно нейроакселераторы.
5. Часть выигрыша v1.9.1 не связана с M5: с v1.8.0 flash attention включён по умолчанию
   (`flash attn = 1`), плюс переработанные Metal-ядра — это видно в `batchd` 2700 → 557 мс.

## Порядок работ

| Шаг | Что | Ожидаемый эффект (long) | Оценка |
|-----|-----|------------------------|--------|
| 1 | Починить доставку `ggml-metal.metal`: реальный файл вместо симлинка в форке + копирование `*.bundle` в `.app` в `build-app.sh` | 4544 → ~2600 мс | часы |
| 2 | Апгрейд submodule whisper.cpp v1.7.5 → v1.9.x + переписать список исходников в `Package.swift` форка под новую структуру ggml | → ~2200 мс | дни |
| 3 | Tensor API — включается сам на M5 после шага 2; проверить, что на не-M5 машинах ничего не ломается (гейт по имени GPU) | → ~1600 мс | часы |
| 4 | Решить судьбу CoreML-энкодера: на M5 он проигрывает Metal; на старых чипах — нужен замер | упрощение продукта | обсудить |

Замечания к шагу 1: рантайм-компиляция шейдера из исходника занимает ~5.8 с при первом
запуске процесса (дальше системный кеш Metal). В приложении это попадает в загрузку
модели и покрывается warm-up, но стоит проверить, что `.warming` не растягивается.
Альтернатива — предкомпилированный `default.metallib`, но для этого нужен Xcode
с Metal toolchain на машине сборки (сейчас только CLT).
