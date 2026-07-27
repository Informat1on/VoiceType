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
    """Все удаления филлеров из JSONL-отчёта харнесса, с контекстом."""
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        text = record.get("input", "")
        for edit in record.get("edits", []):
            if edit.get("stage") != "fillers":
                continue
            word = (edit.get("matched") or edit.get("original", "")).strip(" ,")
            out.append({"word": word, "original": edit.get("original", ""), "text": text})
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


def render(picked, total):
    lines = [
        "# Аудит удалений филлеров",
        "",
        f"Выборка {len(picked)} из {total} удалений, seed {SEED}.",
        "",
        "## Как размечать",
        "",
        "В каждом случае удаляемое слово выделено `[[ ]]`. Если удаление",
        "**портит смысл или звучит неверно** — поставь `x` в скобках: `[x]`.",
        "Если удаление правильное — оставь `[ ]` как есть.",
        "",
        "Файл локальный, в git не уходит: это рабочая речь, репозиторий публичный.",
        "",
        "---",
        "",
    ]
    for i, edit in enumerate(picked, 1):
        text = edit["text"]
        needle = edit["original"]
        at = text.find(needle)
        if at < 0:
            at = text.find(edit["word"])
            needle = edit["word"]
        left = text[max(0, at - CONTEXT):at].replace("\n", " ")
        right = text[at + len(needle):at + len(needle) + CONTEXT].replace("\n", " ")
        marked = f"…{left}[[{needle}]]{right}…"
        lines.append(f"{i}. [ ] `{edit['word']}` — {marked}")
        lines.append("")
    return "\n".join(lines)


def score(path):
    wrong, total = Counter(), Counter()
    pattern = re.compile(r"^\d+\.\s*\[(.)\]\s*`([^`]+)`")
    for line in open(path, encoding="utf-8"):
        m = pattern.match(line.strip())
        if not m:
            continue
        mark, word = m.group(1).strip().lower(), m.group(2)
        total[word] += 1
        if mark == "x":
            wrong[word] += 1

    n = sum(total.values())
    if n == 0:
        sys.exit("В файле не найдено размеченных случаев — не тот файл или не тот формат?")

    bad = sum(wrong.values())
    p = (n - bad) / n
    # Wilson-интервал: при p близком к 1 нормальное приближение даёт границу
    # выше единицы и создаёт ложное впечатление точности.
    z = 1.96
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom

    print(f"размечено: {n}, неверных: {bad}")
    print(f"precision: {p:.3f} (95% CI {max(0, centre - half):.3f}–{min(1, centre + half):.3f})")
    print()
    for word in sorted(total):
        w, t = wrong[word], total[word]
        print(f"  {word:<8} {t - w:3d}/{t:3d} верных" + (f", неверных {w}" if w else ""))
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
    args = ap.parse_args()

    if args.score:
        return score(args.score)

    edits = load_edits(args.sample)
    if not edits:
        sys.exit("В отчёте нет удалений филлеров — прогон делался с VOICETYPE_REMOVE_FILLERS=0?")
    picked = sample(edits, args.size, args.per_word_min)
    out = args.out or (args.sample + ".audit.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(picked, len(edits)))
    print(f"выборка: {len(picked)} случаев из {len(edits)} → {out}")
    print(Counter(e["word"] for e in picked))


if __name__ == "__main__":
    main()
