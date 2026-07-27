#!/usr/bin/env python3
"""Метрика качества постобработки транскрипта по категориям ошибок.

Зачем отдельно от scripts/wer.py: тот приводит текст к нижнему регистру и
вырезает пунктуацию, то есть слеп именно к тому, что чинит постобработка. Плюс
не отличает «не исправил» от «исправил неправильно» и не видит порчи уже
правильного текста.

Корпус и формат разметки: Tests/Fixtures/eval-ru/{README.md,schema.json}.
Конвенция целевого выхода: docs/decisions/2026-07-27-transcript-postprocessing-convention.md

usage:
  categorized-eval.py --baseline
  categorized-eval.py --system-output <dir|jsonl>
  categorized-eval.py --self-test
"""

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

DEFAULT_CORPUS = Path(__file__).resolve().parent.parent / "Tests/Fixtures/eval-ru"

# Categories whose absolute counts are too small for percentages to mean
# anything on this corpus. Reported as x/n and flagged exploratory. The
# threshold is on eligible spans, not on records — a category can be rare in
# records but dense inside one of them.
EXPLORATORY_BELOW = 20

WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)


def words(text):
    """Word multiset used for collateral damage.

    Case and punctuation are deliberately stripped: changing them is a
    legitimate job (category `punct`), so counting it as collateral would
    penalise correct behaviour.
    """
    return [w.lower() for w in WORD_RE.findall(text)]


class CorpusError(Exception):
    """Raised for malformed annotation — surfaced as a message, not a traceback."""


def load_record(corpus, entry):
    """Load one record; returns (raw, ref, spans) or raises CorpusError."""
    n = entry["n"]
    data = corpus / "data"
    raw_path, ref_path, spans_path = (
        data / f"{n}.raw.txt", data / f"{n}.ref.txt", data / f"{n}.spans.json")
    if not raw_path.exists():
        raise CorpusError(f"{n}: нет {raw_path.name}")
    if not ref_path.exists():
        raise CorpusError(f"{n}: нет {ref_path.name}")
    if not spans_path.exists():
        raise CorpusError(f"{n}: нет {spans_path.name}")

    raw = raw_path.read_text(encoding="utf-8")
    ref = ref_path.read_text(encoding="utf-8")
    doc = json.loads(spans_path.read_text(encoding="utf-8"))
    if doc.get("n") != n:
        raise CorpusError(f"{n}: поле n в разметке = {doc.get('n')!r}, ожидалось {n!r}")

    spans = []
    for i, s in enumerate(doc.get("spans", [])):
        for key in ("start", "end", "category", "needsChange", "expected"):
            if key not in s:
                raise CorpusError(f"{n}: спан #{i} без обязательного поля {key!r}")
        start, end = s["start"], s["end"]
        # Offsets are Unicode code points, matching schema.json. Python string
        # slicing is already code-point based, so no conversion is needed —
        # but the bounds still have to be sane.
        if not 0 <= start < end <= len(raw):
            raise CorpusError(
                f"{n}: спан #{i} выходит за границы текста "
                f"[{start},{end}) при длине {len(raw)}")
        surface = raw[start:end]
        if not s["needsChange"] and surface != s["expected"]:
            raise CorpusError(
                f"{n}: спан #{i} помечен needsChange=false, но expected "
                f"{s['expected']!r} != текст спана {surface!r}")
        spans.append({**s, "surface": surface, "index": i})
    return raw, ref, spans


def score_record(raw, spans, out):
    """Classify every span against the system output.

    Alignment is by substring presence, not by offset: the output is a
    different string, so raw offsets do not carry over. Consequence, stated
    plainly: several spans with identical surface text inside one record are
    indistinguishable and get the same verdict. Acceptable here because the
    counts we report are per category, not per span occurrence.
    """
    per_cat = defaultdict(Counter)
    for s in spans:
        cat, surface, expected = s["category"], s["surface"], s["expected"]
        if s["needsChange"]:
            if not expected:
                # Deletion span (fillers): expected is the empty string, so
                # "fixed" means the surface is gone. Without this branch an
                # empty expected is falsy and a correct deletion is scored as
                # wrong_fix — caught by --self-test.
                per_cat[cat]["exact_fix" if surface not in out else "miss"] += 1
            elif expected in out:
                per_cat[cat]["exact_fix"] += 1
            elif surface in out:
                per_cat[cat]["miss"] += 1
            else:
                per_cat[cat]["wrong_fix"] += 1
        else:
            if surface in out:
                per_cat[cat]["kept"] += 1
            else:
                per_cat[cat]["regression"] += 1
    return per_cat


def collateral(raw, spans, out):
    """Words outside annotated spans that were changed, lost or added.

    This is the metric the plain WER masks: it is exactly where the damage
    observed in the LLM measurements showed up (a dropped «сам», an invented
    «мануал»).
    """
    covered = [False] * len(raw)
    for s in spans:
        for i in range(s["start"], s["end"]):
            covered[i] = True
    # Rebuild the unprotected part of the input, keeping word boundaries.
    outside = "".join(c if not covered[i] else " " for i, c in enumerate(raw))
    outside_words = Counter(words(outside))
    out_words = Counter(words(out))

    lost = sum(max(0, n - out_words.get(w, 0)) for w, n in outside_words.items())

    # A word counts as added only if it appears nowhere in the input and in no
    # expected value — otherwise a legitimate span fix would look like an
    # addition.
    allowed = Counter(words(raw))
    for s in spans:
        allowed.update(words(s["expected"]))
    added = sum(max(0, n - allowed.get(w, 0)) for w, n in out_words.items())

    total = sum(outside_words.values())
    return lost, added, total


def read_system_output(path):
    """Accept either a directory of NN.out.txt or a JSONL with n/text."""
    p = Path(path)
    if p.is_dir():
        return {f.name.split(".")[0]: f.read_text(encoding="utf-8")
                for f in p.glob("*.out.txt")}
    out = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        d = json.loads(line)
        if "n" in d and "text" in d:
            out[str(d["n"])] = d["text"]
    return out


def evaluate(corpus, get_output):
    manifest_path = corpus / "manifest.jsonl"
    if not manifest_path.exists():
        raise CorpusError(f"нет манифеста: {manifest_path}")
    entries = [json.loads(l) for l in manifest_path.read_text(
        encoding="utf-8").splitlines() if l.strip()]

    result = {"splits": {}, "skipped": [], "records": 0}
    buckets = {"dev": [], "holdout": []}
    for e in entries:
        try:
            raw, ref, spans = load_record(corpus, e)
        except CorpusError as err:
            result["skipped"].append(str(err))
            continue
        out = get_output(e["n"], raw, ref)
        if out is None:
            result["skipped"].append(f"{e['n']}: нет выхода системы")
            continue
        buckets["holdout" if e.get("holdout") else "dev"].append(
            (e, raw, spans, out))
        result["records"] += 1

    for split, items in buckets.items():
        if not items:
            continue
        cats = defaultdict(Counter)
        lost = added = outside_total = 0
        ratios = []
        for _e, raw, spans, out in items:
            for cat, counts in score_record(raw, spans, out).items():
                cats[cat].update(counts)
            l, a, t = collateral(raw, spans, out)
            lost += l
            added += a
            outside_total += t
            ratios.append(len(out) / max(len(raw), 1))
        result["splits"][split] = {
            "records": len(items),
            "categories": {c: dict(v) for c, v in sorted(cats.items())},
            "collateral": {"lost": lost, "added": added, "outside_words": outside_total,
                           "rate": (lost + added) / outside_total if outside_total else 0.0},
            "length_ratio": {"min": min(ratios), "median": statistics.median(ratios),
                             "max": max(ratios)},
        }
    return result


def print_report(result, title):
    print(f"\n=== {title} ===")
    print(f"записей учтено: {result['records']}, пропущено: {len(result['skipped'])}")
    for reason in result["skipped"]:
        print(f"   ПРОПУЩЕНО {reason}")
    if not result["splits"]:
        print("\nнечего считать: корпус не готов (нет ref/spans или нет выхода системы)")
        return

    for split in ("dev", "holdout"):
        s = result["splits"].get(split)
        if not s:
            continue
        print(f"\n--- {split} ({s['records']} записей) ---")
        header = (f"{'категория':18s} {'исправлено':>10s} {'пропущено':>10s} "
                  f"{'неверно':>8s} {'регрессий':>10s} {'fix rate':>10s}")
        print(header)
        for cat, c in s["categories"].items():
            need = c.get("exact_fix", 0) + c.get("miss", 0) + c.get("wrong_fix", 0)
            keep = c.get("kept", 0) + c.get("regression", 0)
            if need:
                rate = f"{c.get('exact_fix', 0)}/{need}"
                if need >= EXPLORATORY_BELOW:
                    rate += f" ({100 * c.get('exact_fix', 0) / need:.0f}%)"
            else:
                rate = "—"
            mark = "" if need >= EXPLORATORY_BELOW else "  ~"
            print(f"{cat:18s} {c.get('exact_fix', 0):10d} {c.get('miss', 0):10d} "
                  f"{c.get('wrong_fix', 0):8d} {c.get('regression', 0):10d} {rate:>10s}{mark}"
                  + (f"   [уже верных: {keep}]" if keep else ""))
        col = s["collateral"]
        print(f"\ncollateral damage: {col['rate'] * 100:.2f}% "
              f"(потеряно {col['lost']}, добавлено {col['added']}, "
              f"слов вне спанов {col['outside_words']})")
        lr = s["length_ratio"]
        print(f"отношение длин: min {lr['min']:.2f}, медиана {lr['median']:.2f}, "
              f"max {lr['max']:.2f}")
    print(f"\n~ — категория помечена exploratory: меньше {EXPLORATORY_BELOW} "
          f"размеченных случаев, процент не приводится")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--baseline", action="store_true",
                      help="выход = сырой текст (постобработки нет). Базовая линия.")
    mode.add_argument("--self-test", action="store_true",
                      help="выход = эталон. Проверка самой метрики.")
    mode.add_argument("--system-output",
                      help="каталог с NN.out.txt либо JSONL с полями n и text")
    ap.add_argument("--json", action="store_true", help="машинный вывод")
    args = ap.parse_args()

    corpus = Path(args.corpus)
    try:
        if args.baseline:
            result = evaluate(corpus, lambda n, raw, ref: raw)
            title = "БАЗОВАЯ ЛИНИЯ (постобработки нет)"
        elif args.self_test:
            result = evaluate(corpus, lambda n, raw, ref: ref)
            title = "САМОПРОВЕРКА МЕТРИКИ (выход = эталон)"
        else:
            outputs = read_system_output(args.system_output)
            result = evaluate(corpus, lambda n, raw, ref: outputs.get(n))
            title = f"ВЫХОД СИСТЕМЫ: {args.system_output}"
    except CorpusError as err:
        print(f"ошибка корпуса: {err}", file=sys.stderr)
        return 2

    if args.json:
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print_report(result, title)

    if args.self_test and result["splits"]:
        bad = []
        for split, s in result["splits"].items():
            for cat, c in s["categories"].items():
                if c.get("miss") or c.get("wrong_fix") or c.get("regression"):
                    bad.append(f"{split}/{cat}: {dict(c)}")
            if s["collateral"]["rate"] > 0:
                bad.append(f"{split}: collateral {s['collateral']['rate']:.4f} != 0")
        print("\nСАМОПРОВЕРКА: " + ("ПРОВАЛЕНА" if bad else "ПРОЙДЕНА"))
        for b in bad:
            print("   " + b)
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
