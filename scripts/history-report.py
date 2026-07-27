#!/usr/bin/env python3
"""Отчёт о том, что конвейер постобработки сделал на реальных диктовках.

Источник — `history.jsonl` приложения. `rawText` там пишется только когда выход
конвейера отличается от сырого вывода whisper (HistoryStore.swift:134), поэтому
«есть rawText» = «конвейер что-то изменил», без догадок.

Зачем это нужно. Оценка постобработки до сих пор держалась на корпусе eval-ru,
у которого holdout — девять записей, и его независимость уже израсходована
(handoff session 6, §12.7). Ежедневные диктовки владельца дают непрерывный поток
наблюдений на том же распределении речи, что и прод, — это самый дешёвый способ
видеть, что слой делает на самом деле.

⚠️ Приватность. `history.jsonl` — это расшифровки речи владельца, а репозиторий
публичный. Поэтому:

- по умолчанию печатаются **только агрегаты**: количества, доли, разбивка по
  штампам конвейера. Ни одной строки речи;
- сами правки и контексты показываются лишь по явному `--include-private-text`;
- `--out` внутрь рабочего дерева git отвергается (снять — `--allow-repo-output`),
  файл создаётся с правами `0600`;
- **не запускать с `--include-private-text` в CI и в выводе агентских
  инструментов**: stdout попадает в scrollback терминала, в логи и в транскрипты
  сессий, откуда его уже не убрать.

Примеры:
    python3 scripts/history-report.py
    python3 scripts/history-report.py --since 2026-07-20 --include-private-text
    python3 scripts/history-report.py --include-private-text --out ~/Desktop/report.md
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_HISTORY = (
    Path.home() / "Library" / "Application Support" / "VoiceType" / "history.jsonl"
)

# Токен = слово (буквы/цифры/дефис/апостроф) либо одиночный знак препинания.
# Пунктуация держится отдельными токенами намеренно: конвейер меняет швы
# («вот, допустим» → «допустим»), и без этого правка выглядела бы как замена
# целого куска текста.
TOKEN_RE = re.compile(r"\w+(?:[-'’]\w+)*|[^\w\s]", re.UNICODE)


def tokenize(text):
    return TOKEN_RE.findall(text)


def parse_timestamp(value):
    """ISO-8601 из истории ('2026-07-27T05:51:50Z') → aware datetime или None."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_date_bound(value, end_of_day=False):
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise SystemExit(f"Не разобрал дату: {value!r}. Формат: YYYY-MM-DD.")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    if end_of_day and len(value) == 10:
        parsed = parsed.replace(hour=23, minute=59, second=59)
    return parsed


def load_entries(path, since, until):
    """Читает jsonl, отбрасывая битые строки и записи вне окна дат."""
    if not path.exists():
        raise SystemExit(f"Файла истории нет: {path}")

    entries, malformed, out_of_window = [], 0, 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            if not isinstance(entry, dict) or "text" not in entry:
                malformed += 1
                continue

            stamp = parse_timestamp(entry.get("timestamp"))
            if since and (stamp is None or stamp < since):
                out_of_window += 1
                continue
            if until and (stamp is None or stamp > until):
                out_of_window += 1
                continue
            entries.append(entry)

    return entries, malformed, out_of_window


def diff_edits(raw, out):
    """Правки конвейера как список (вид, что_было, что_стало).

    Виды: 'замена', 'удаление', 'вставка'. Сопоставление токенное, поэтому
    удаление филлера и замена слова словарём не сливаются в один кусок.
    """
    raw_tokens, out_tokens = tokenize(raw), tokenize(out)
    matcher = difflib.SequenceMatcher(a=raw_tokens, b=out_tokens, autojunk=False)

    edits = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        before = " ".join(raw_tokens[i1:i2])
        after = " ".join(out_tokens[j1:j2])
        if tag == "replace":
            edits.append(("замена", before, after))
        elif tag == "delete":
            edits.append(("удаление", before, ""))
        elif tag == "insert":
            edits.append(("вставка", "", after))
    return edits


def snippet(text, fragment, width):
    """Кусок текста вокруг первого вхождения fragment — для примера правки."""
    if not fragment:
        return text[:width].strip()
    index = text.find(fragment)
    if index < 0:
        return text[:width].strip()
    start = max(0, index - width // 2)
    end = min(len(text), index + len(fragment) + width // 2)
    return ("…" if start > 0 else "") + text[start:end].strip() + ("…" if end < len(text) else "")


def build_report(entries, top, width):
    stamps = Counter()
    no_stamp = 0
    changed, unchanged = 0, 0
    edits_by_kind = defaultdict(Counter)
    examples = {}
    span_start, span_end = None, None

    for entry in entries:
        stamp = entry.get("pipelineStamp")
        timestamp = parse_timestamp(entry.get("timestamp"))
        if timestamp:
            span_start = timestamp if span_start is None else min(span_start, timestamp)
            span_end = timestamp if span_end is None else max(span_end, timestamp)

        # Записи до конвейера не имеют поля pipelineStamp вовсе — не null,
        # а отсутствует; в статистику правок они не идут (handoff §14.2).
        if stamp is None:
            no_stamp += 1
            continue
        stamps[stamp] += 1

        raw = entry.get("rawText")
        out = entry.get("text", "")
        if raw is None or raw == out:
            unchanged += 1
            continue

        changed += 1
        for kind, before, after in diff_edits(raw, out):
            key = f"{before} → {after}" if kind == "замена" else (before or after)
            edits_by_kind[kind][key] += 1
            examples.setdefault((kind, key), snippet(raw, before or after, width))

    return {
        "total": len(entries),
        "no_stamp": no_stamp,
        "stamps": stamps,
        "changed": changed,
        "unchanged": unchanged,
        "edits_by_kind": edits_by_kind,
        "examples": examples,
        "span": (span_start, span_end),
        "top": top,
    }


def format_report(report, source, malformed, out_of_window, include_text):
    lines = []
    add = lines.append

    add("# Что конвейер постобработки сделал на реальных диктовках")
    add("")
    add(f"Источник: `{source}`")
    span_start, span_end = report["span"]
    if span_start and span_end:
        add(f"Окно: {span_start:%Y-%m-%d %H:%M} — {span_end:%Y-%m-%d %H:%M} UTC")
    add("")
    if include_text:
        add("⚠️ Ниже — расшифровки речи владельца. В публичный репозиторий не коммитить.")
    else:
        add("Только агрегаты. Сами правки — с флагом `--include-private-text`.")
    add("")

    add("## Охват")
    add("")
    total = report["total"]
    add(f"- записей в окне: **{total}**")
    if malformed:
        add(f"- битых строк пропущено: {malformed}")
    if out_of_window:
        add(f"- записей вне окна дат: {out_of_window}")
    add(f"- без штампа конвейера (сборка до постобработки): {report['no_stamp']}")

    with_stamp = total - report["no_stamp"]
    add(f"- со штампом конвейера: **{with_stamp}**")
    for stamp, count in report["stamps"].most_common():
        add(f"  - `{stamp}` — {count}")

    if with_stamp:
        share = 100.0 * report["changed"] / with_stamp
        add(f"- из них конвейер изменил текст в **{report['changed']}** ({share:.1f}%)")
        add(f"- оставил без изменений: {report['unchanged']}")
    add("")

    if not report["changed"]:
        add("Правок в окне нет — сравнивать нечего.")
        return "\n".join(lines)

    add("## Правки")
    add("")
    for kind in ("замена", "удаление", "вставка"):
        counter = report["edits_by_kind"].get(kind)
        if not counter:
            continue
        add(f"### {kind.capitalize()} — {sum(counter.values())} всего, "
            f"{len(counter)} различных")
        add("")
        if not include_text:
            # Даже сам текст правки («хэндов → handoff») — это речь владельца,
            # поэтому без явного флага не печатается ни он, ни контекст.
            continue
        add("| правка | раз | пример |")
        add("|---|---:|---|")
        for key, count in counter.most_common(report["top"]):
            example = report["examples"].get((kind, key), "").replace("|", "\\|")
            add(f"| `{key}` | {count} | {example} |")
        if len(counter) > report["top"]:
            add(f"| _…ещё {len(counter) - report['top']} видов, скрыто "
                f"порогом --top_ | | |")
        add("")

    return "\n".join(lines)


def inside_repository(path):
    """True, если path лежит в рабочем дереве git-репозитория."""
    try:
        top = subprocess.run(
            ["git", "-C", str(path.parent), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return False
    return bool(top) and Path(top) in path.parents


def main():
    parser = argparse.ArgumentParser(
        description="Отчёт о правках конвейера постобработки по history.jsonl",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--path", type=Path, default=DEFAULT_HISTORY,
                        help=f"путь к history.jsonl (по умолчанию {DEFAULT_HISTORY})")
    parser.add_argument("--since", help="нижняя граница окна, YYYY-MM-DD")
    parser.add_argument("--until", help="верхняя граница окна, YYYY-MM-DD")
    parser.add_argument("--top", type=int, default=20,
                        help="сколько самых частых правок показывать в каждой таблице")
    parser.add_argument("--context", type=int, default=90,
                        help="ширина примера в символах")
    parser.add_argument("--include-private-text", action="store_true",
                        help="показать сами правки и контексты — это речь владельца")
    parser.add_argument("--out", type=Path,
                        help="записать отчёт в файл (создаётся с правами 0600)")
    parser.add_argument("--allow-repo-output", action="store_true",
                        help="разрешить --out внутри репозитория (он публичный)")
    args = parser.parse_args()

    since = parse_date_bound(args.since) if args.since else None
    until = parse_date_bound(args.until, end_of_day=True) if args.until else None
    if since and until and since > until:
        raise SystemExit("--since позже, чем --until")

    entries, malformed, out_of_window = load_entries(args.path, since, until)
    report = build_report(entries, top=args.top, width=args.context)
    text = format_report(report, args.path, malformed, out_of_window,
                         include_text=args.include_private_text)

    if args.out:
        destination = args.out.expanduser().resolve()
        if inside_repository(destination) and not args.allow_repo_output:
            raise SystemExit(
                f"Отказ писать внутрь репозитория: {destination}\n"
                "Отчёт может содержать речь владельца, репозиторий публичный. "
                "Выбери путь вне репозитория или передай --allow-repo-output осознанно."
            )
        # Права выставляются до записи, чтобы содержимое не успело полежать
        # доступным для чтения всей группе. fchmod обязателен отдельно: режим в
        # os.open действует только при создании, а перезапись существующего
        # файла с правами 0644 оставила бы их как есть.
        handle = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as out_file:
            out_file.write(text + "\n")
        print(f"Отчёт записан: {destination}", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
