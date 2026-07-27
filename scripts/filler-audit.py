#!/usr/bin/env python3
"""Выборочный аудит удалений филлеров: генерация выборки и подсчёт precision.

Зачем отдельно от categorized-eval.py
--------------------------------------
Метрика сопоставляет спаны по количеству одинаковых поверхностей, а не по
позиции, и сама это признаёт. Для замен это терпимо — поверхности редкие. Для
удалений это качественный дефект: в одной записи бывает восемь вхождений «вот»,
и удаление не того, которое размечено, засчитывается как успех.

Здесь источник истины другой — журнал правок самого конвейера
(`TranscriptionService.postProcess` → `PostProcessResult.stages`), который
несёт позиции. Метрика остаётся для замен, этот скрипт отвечает за удаления.

Зачем выборка, а не корпус целиком
-----------------------------------
Holdout корпуса `eval-ru` даёт по филлерам четыре наблюдения — на них нельзя
оценить точность правила, которое срабатывает 1541 раз. Единственный доступный
источник истины для остальных — владелец: он автор этой речи. 200 случаев он
размечает за приемлемое время, и это даёт настоящий доверительный интервал
вместо спора о четырёх примерах.

Приватность: выборка содержит рабочую речь владельца, а репозиторий публичный.
Скрипт коммитится, его вывод — никогда. Пути по умолчанию ведут за пределы
репозитория намеренно.

Использование:
    # 1. прогнать конвейер по корпусу (см. §13 handoff)
    VOICETYPE_JSONL_IN=~/Desktop/voicetype-export/corpus.jsonl \
    VOICETYPE_JSONL_OUT=/tmp/n2-prod.jsonl \
      swift test --filter testDumpJSONLCorpus

    # 2. сгенерировать выборку для разметки
    python3 scripts/filler-audit.py --sample /tmp/n2-prod.jsonl \
        --out ~/Desktop/filler-audit.md

    # 3. разметить файл (см. инструкцию в его шапке), затем
    python3 scripts/filler-audit.py --score ~/Desktop/filler-audit.md
"""

import argparse
import json
import math
import random
import re
import sys
from collections import Counter

# Фиксированный seed: выборка обязана воспроизводиться, иначе повторный прогон
# после ужесточения правила сравнивается с другой выборкой и разница
# необъяснима.
SEED = 20260727

CONTEXT = 40


def load_edits(path):
    """Все удаления филлеров из JSONL-отчёта харнесса.

    Позиции берутся из отчёта, а НЕ ищутся в тексте: в записи бывает восемь
    «вот», и `text.find` показал бы первое из них, даже если конвейер удалил
    третье. Ровно эта позиционная ложь и есть причина, по которой журнал правок
    вообще появился, — воспроизводить её в аудите бессмысленно.

    Каждая правка несёт вход СВОЕЙ стадии (`stageInput`): офсеты стадии
    филлеров относятся к тексту после фильтра галлюцинаций, а не к исходному.
    """
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        for edit in record.get("edits", []):
            if edit.get("stage") != "fillers":
                continue
            if "matchStart" not in edit or "stageInput" not in edit:
                sys.exit(
                    "В отчёте нет полей matchStart/stageInput — он снят старой версией "
                    "харнесса. Перепрогони CorpusDumpTests."
                )
            matched = (edit.get("matched") or "").strip(" ,")
            # Серия подряд идущих филлеров («ну вот», «вот, ну») — своя страта:
            # она удаляется одной правкой и оценивается целиком, а дробить её на
            # 16 микрогрупп по составу бессмысленно (в самой крупной 7 случаев).
            stratum = "серия" if (" " in matched or "," in matched) else matched
            out.append({
                "word": stratum,
                "matched": matched,
                "original": edit.get("original", ""),
                "text": edit["stageInput"],
                "start": edit["editStart"],
                "end": edit["editEnd"],
            })
    return out


def sample(edits, size, per_word_min):
    """Стратифицированная выборка: доля по словам сохраняется, но редкое слово
    получает не меньше `per_word_min` случаев (или все, если их меньше).

    Без этого «короче» (70 из 1541) попал бы в выборку девять раз, и оценка по
    нему была бы бессмысленной, хотя профиль риска у трёх слов разный.
    """
    rng = random.Random(SEED)
    by_word = {}
    for edit in edits:
        by_word.setdefault(edit["word"], []).append(edit)

    picked = []
    for word, group in sorted(by_word.items()):
        share = max(per_word_min, round(size * len(group) / len(edits)))
        take = min(len(group), share)
        picked += rng.sample(group, take)
    rng.shuffle(picked)
    return picked


def render(picked, total, population):
    stats = ",".join(f"{w}={n}" for w, n in sorted(population.items()))
    lines = [
        "# Аудит удалений филлеров",
        "",
        f"<!-- population: {stats} -->",
        "",
        f"Выборка {len(picked)} из {total} удалений, seed {SEED}.",
        "",
        "## Как размечать",
        "",
        "В каждом случае удаляемое слово выделено `[[ ]]`. Проставь в скобках:",
        "",
        "* `[y]` — удаление правильное;",
        "* `[x]` — удаление портит смысл или звучит неверно.",
        "",
        "Пустые `[ ]` не считаются согласием: скрипт откажется считать precision,",
        "пока остались неразмеченные случаи. Иначе нетронутый файл давал бы",
        "идеальный результат — замечание код-ревью.",
        "",
        "Файл локальный, в git не уходит: это рабочая речь, репозиторий публичный.",
        "",
        "---",
        "",
    ]
    for i, edit in enumerate(picked, 1):
        text = edit["text"]
        start, end = edit["start"], edit["end"]
        left = text[max(0, start - CONTEXT):start].replace("\n", " ")
        right = text[end:end + CONTEXT].replace("\n", " ")
        marked = f"…{left}[[{text[start:end]}]]{right}…"
        lines.append(f"{i}. [ ] `{edit['matched']}` — {marked}")
        lines.append("")
    return "\n".join(lines)


def wilson(good, total):
    """Интервал Уилсона: при доле около единицы нормальное приближение уходит
    за 1 и создаёт ложное впечатление точности."""
    if total == 0:
        return (0.0, 1.0)
    p = good / total
    z = 1.96
    denom = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denom
    half = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def score(path, population):
    """Взвешенная оценка precision.

    Выборка стратифицирована и НЕ пропорциональна: «короче» намеренно
    переотобрано (25 случаев из 70), иначе по нему было бы девять наблюдений и
    оценка по слову с собственным профилем риска ничего бы не значила. Поэтому
    простая доля по 216 наблюдениям — смещённая оценка для 1541 удаления:
    редкое слово в ней весит больше, чем в реальности.

    Общая precision считается как Σ (N_слова / N_всего) · p_слова, интервал —
    из дисперсии этой взвешенной суммы. Замечание код-ревью.
    """
    wrong, total = Counter(), Counter()
    blank = 0
    pattern = re.compile(r"^\d+\.\s*\[([^\]]*)\]\s*`([^`]+)`")
    for line in open(path, encoding="utf-8"):
        m = pattern.match(line.strip())
        if not m:
            continue
        mark, matched = m.group(1).strip().lower(), m.group(2)
        word = "серия" if (" " in matched or "," in matched) else matched
        if mark == "":
            blank += 1
            continue
        if mark not in ("y", "x"):
            sys.exit(f"Непонятная отметка [{mark}] — допустимы только [y] и [x].")
        total[word] += 1
        if mark == "x":
            wrong[word] += 1

    n = sum(total.values())
    if blank:
        sys.exit(
            f"Не размечено {blank} случаев из {n + blank}. "
            "Пустая отметка не считается согласием — размечай или удали строку."
        )
    if n == 0:
        sys.exit("В файле не найдено размеченных случаев — не тот файл или не тот формат?")

    print(f"размечено: {n}, неверных: {sum(wrong.values())}")
    print()

    weighted, variance, unweighted_note = 0.0, 0.0, []
    for word in sorted(total):
        w, t = wrong[word], total[word]
        good = t - w
        p = good / t
        lo, hi = wilson(good, t)
        share = population.get(word)
        if share is None:
            unweighted_note.append(word)
        print(f"  {word:<8} {good:3d}/{t:3d} = {p:.3f} (95% CI {lo:.3f}–{hi:.3f})"
              + (f", в корпусе {share}" if share else ""))
        if share:
            weight = share / sum(population.values())
            weighted += weight * p
            variance += (weight ** 2) * p * (1 - p) / t

    print()
    if unweighted_note:
        print(f"⚠️  нет размеров страт для: {', '.join(unweighted_note)} — "
              "передай --population, иначе общая оценка не считается")
        return
    half = 1.96 * math.sqrt(variance)
    print(f"precision по корпусу (взвешенно): {weighted:.3f} "
          f"(95% CI {max(0, weighted - half):.3f}–{min(1, weighted + half):.3f})")
    print()
    print("Гейт: ≥0.98 — оставляем включённым по умолчанию;")
    print("      0.95–0.98 — ужесточать по слову с худшим профилем;")
    print("      <0.95 — категория смысловая, оставить только бесспорное подмножество.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--sample", metavar="JSONL", help="отчёт харнесса — сгенерировать выборку")
    g.add_argument("--score", metavar="MD", help="размеченный файл — посчитать precision")
    ap.add_argument("--out", help="куда писать выборку (по умолчанию рядом с JSONL)")
    ap.add_argument("--size", type=int, default=200)
    ap.add_argument("--per-word-min", type=int, default=25)
    ap.add_argument("--population", help="размеры страт в корпусе, например 'вот=983,ну=488,короче=70' — "
                                         "без них взвешенная оценка не считается")
    args = ap.parse_args()

    if args.score:
        # Размеры страт записаны в шапку файла при генерации — руками их
        # вводить не нужно и незачем: рассинхрон с прогоном давал бы тихо
        # смещённую оценку.
        population = {}
        for line in open(args.score, encoding="utf-8"):
            m = re.match(r"<!--\s*population:\s*(.+?)\s*-->", line.strip())
            if m:
                for part in m.group(1).split(","):
                    word, _, count = part.partition("=")
                    population[word.strip()] = int(count)
                break
        if args.population:
            for part in args.population.split(","):
                word, _, count = part.partition("=")
                population[word.strip()] = int(count)
        return score(args.score, population)

    edits = load_edits(args.sample)
    if not edits:
        sys.exit("В отчёте нет удалений филлеров — прогон делался с VOICETYPE_REMOVE_FILLERS=0?")
    picked = sample(edits, args.size, args.per_word_min)
    population = Counter(e["word"] for e in edits)
    out = args.out or (args.sample + ".audit.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(picked, len(edits), population))
    print(f"выборка: {len(picked)} случаев из {len(edits)} → {out}")
    print(Counter(e["word"] for e in picked))


if __name__ == "__main__":
    main()
