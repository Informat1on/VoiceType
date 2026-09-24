#!/usr/bin/env python3
"""Compare replay JSONL output(s) — docs/plans/quality-tools.md §3.R2.

Two modes, by argument count:
  - ONE file:  compares the replay against what's already baked into it —
    `history.raw`/`history.text` on each record (history mode only). This is
    "did replay reproduce what the app itself produced".
  - TWO files: compares run A against run B by record `key` — "did the exact
    same settings + audio produce the exact same output twice" (determinism)
    or "did this code change move the needle" (before/after).

Only stdlib + `wer.py` (this directory) — no third-party dependencies.

Privacy: the corpus is the owner's real speech (docs/plans/quality-tools.md
§6). By default this prints ONLY aggregates — counts, percentages, WER,
timing. Actual transcript text (raw/final/reference/diffs) is printed only
with --include-private-text, and NEVER by default. --out is refused inside
the repository working tree (same policy as scripts/history-report.py) and
is written with 0600 permissions.

Usage:
  scripts/replay-compare.py run-a.jsonl
  scripts/replay-compare.py run-a.jsonl run-b.jsonl
  scripts/replay-compare.py run-a.jsonl --include-private-text
  scripts/replay-compare.py run-a.jsonl --out ~/Desktop/report.md
"""

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wer import compute_wer  # noqa: E402

MIN_COMPARABLE_AGAINST_HISTORY = 5


def load_replay(path):
    """Reads a replay JSONL file into (run, records, summary)."""
    run, summary = None, None
    records = []
    with open(path, encoding="utf-8") as handle:
        for lineno, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno}: malformed JSON: {exc}")
            kind = obj.get("kind")
            if kind == "run":
                run = obj
            elif kind == "record":
                records.append(obj)
            elif kind == "summary":
                summary = obj
    if run is None:
        raise SystemExit(f"{path}: missing a 'run' line — not a replay JSONL file")
    if summary is None:
        raise SystemExit(f"{path}: missing a 'summary' line — truncated or incomplete run")
    return run, records, summary


def index_by_key(records, path):
    """Maps key -> record, raising if any key repeats (fail-closed: a replay
    JSONL should never contain the same record twice — see
    docs/plans/quality-tools.md §3.R1 "Дубликаты ключей ... — XCTFail")."""
    by_key = {}
    for record in records:
        key = record.get("key")
        if key in by_key:
            raise SystemExit(f"{path}: duplicate record key {key!r} — refusing to compare")
        by_key[key] = record
    return by_key


def percentile(sorted_values, pct):
    """Nearest-rank percentile — same formula as scripts/history-report.py's,
    for the same reason: report-level precision doesn't need interpolation,
    and this is simpler and deterministic."""
    if not sorted_values:
        return None
    idx = max(0, min(len(sorted_values) - 1, round(pct / 100 * (len(sorted_values) - 1))))
    return sorted_values[idx]


def timing_stats(records):
    ms_values = sorted(
        r["transcribeMs"] for r in records if isinstance(r.get("transcribeMs"), (int, float))
    )
    rtf_values = [r["rtf"] for r in records if isinstance(r.get("rtf"), (int, float))]
    return {
        "p50": percentile(ms_values, 50),
        "p95": percentile(ms_values, 95),
        "n": len(ms_values),
        "rtfMean": (sum(rtf_values) / len(rtf_values)) if rtf_values else None,
    }


def wer_stats(records):
    """Mean WER (record.final vs record.reference) over records that carry a
    reference, plus a breakdown by evalIssue (T3's classification field —
    absent on records with no reference or on an unclassified control pair,
    grouped under "(none)")."""
    scored = [
        (r, compute_wer(r.get("final") or "", r["reference"]))
        for r in records
        if r.get("reference") is not None and r.get("final") is not None
    ]
    if not scored:
        return None
    mean = sum(w for _, w in scored) / len(scored)
    by_issue = defaultdict(list)
    for record, wer_value in scored:
        by_issue[record.get("evalIssue") or "(none)"].append(wer_value)
    by_issue_stats = {
        issue: (sum(values) / len(values), len(values)) for issue, values in by_issue.items()
    }
    return {"mean": mean, "n": len(scored), "byIssue": by_issue_stats}


def compare_against_history(records, path):
    """Single-file mode: replay vs the history snapshot baked into each
    record. Only `comparableToHistory == true` records enter the metric —
    the rest (different prompt/pipeline/model) are a separate counter, per
    docs/plans/quality-tools.md §3.R1's "не в метрике"."""
    comparable = [r for r in records if r.get("comparableToHistory") is True]
    not_comparable = len(records) - len(comparable)
    if len(comparable) < MIN_COMPARABLE_AGAINST_HISTORY:
        raise SystemExit(
            f"Only {len(comparable)} record(s) with comparableToHistory==true in {path} — "
            f"nothing to compare (need >= {MIN_COMPARABLE_AGAINST_HISTORY}, DoD 5). Pick a "
            "different/larger --limit, or records whose pipeline stamp matches the current prompt."
        )
    raw_matches = [
        r for r in comparable if r.get("history") and r["history"].get("raw") == r.get("raw")
    ]
    final_matches = [
        r for r in comparable if r.get("history") and r["history"].get("text") == r.get("final")
    ]
    return {
        "comparable": len(comparable),
        "notComparable": not_comparable,
        "rawMatches": len(raw_matches),
        "finalMatches": len(final_matches),
        "mismatched": [r for r in comparable if r not in raw_matches],
    }


def compare_two_runs(records_a, records_b, path_a, path_b):
    """Two-file mode: A vs B by record key — determinism (same settings twice)
    or before/after (a code change)."""
    by_a = index_by_key(records_a, path_a)
    by_b = index_by_key(records_b, path_b)
    keys_a, keys_b = set(by_a), set(by_b)
    if keys_a != keys_b:
        only_a, only_b = keys_a - keys_b, keys_b - keys_a
        raise SystemExit(
            f"Record sets differ between {path_a} and {path_b}: {len(only_a)} key(s) only in A, "
            f"{len(only_b)} only in B — not the same corpus, refusing a 1:1 comparison."
        )
    raw_changed, final_changed = [], []
    for key in keys_a:
        record_a, record_b = by_a[key], by_b[key]
        if record_a.get("raw") != record_b.get("raw"):
            raw_changed.append(key)
        if record_a.get("final") != record_b.get("final"):
            final_changed.append(key)
    return {
        "common": len(keys_a),
        "rawChanged": raw_changed,
        "finalChanged": final_changed,
        "byKey": (by_a, by_b),
    }


def inside_repository(path):
    """True if `path` lies inside a git working tree — same check as
    scripts/history-report.py's `inside_repository`, duplicated locally
    (both are small stdlib-only scripts; not worth an import coupling)."""
    try:
        top = subprocess.run(
            ["git", "-C", str(path.parent), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return False
    return bool(top) and Path(top) in path.parents


def format_report(args, run_a, summary_a, timing_a, wer_a, extra):
    lines = []
    add = lines.append

    add("# Replay comparison")
    add("")
    add(f"A: `{args.a}`")
    if args.b:
        add(f"B: `{args.b}`")
    add("")
    add(f"mode={run_a.get('mode')} model={run_a.get('model')} coreMLRequested={run_a.get('coreMLRequested')} "
        f"pipelineStamp={run_a.get('pipelineStamp')}")
    add(f"records={summary_a.get('records')} errors={summary_a.get('errors')}")
    add("")

    add("## Timing (A) — transcribeMs is the production `transcribe` call only "
        "(warm-up excluded, post-processing included). NOT directly comparable to history's "
        "`latencyMs.asr`, which also spans capture-ready-to-ASR-done in the live app, including "
        "any ensureModelLoaded/retry leg.")
    add(f"- p50={timing_a['p50']}ms p95={timing_a['p95']}ms n={timing_a['n']} "
        f"meanRTF={timing_a['rtfMean']}")
    add("")

    if wer_a:
        add(f"## WER vs reference (A) — mean={wer_a['mean']:.3f} over {wer_a['n']} record(s) with a reference")
        for issue, (mean, n) in sorted(wer_a["byIssue"].items()):
            add(f"  - {issue}: mean={mean:.3f} n={n}")
    else:
        add("## WER vs reference (A) — no record carries a `reference`, not computed")
    add("")

    if args.b:
        add(f"## A vs B — {extra['common']} common record(s) (by key)")
        add(f"- raw changed: {len(extra['rawChanged'])}")
        add(f"- final changed: {len(extra['finalChanged'])}")
        if args.include_private_text:
            add("")
            add("### Changed records (--include-private-text)")
            by_a, by_b = extra["byKey"]
            for key in sorted(set(extra["rawChanged"]) | set(extra["finalChanged"])):
                add(f"- `{key}`")
                add(f"  - A.raw:   {by_a[key].get('raw')!r}")
                add(f"  - B.raw:   {by_b[key].get('raw')!r}")
                add(f"  - A.final: {by_a[key].get('final')!r}")
                add(f"  - B.final: {by_b[key].get('final')!r}")
    elif extra is not None:
        share = 100.0 * extra["rawMatches"] / extra["comparable"]
        add(f"## A vs history — {extra['comparable']} comparable, {extra['notComparable']} "
            "not comparable (different prompt/pipeline/model — excluded from the metric)")
        add(f"- raw matched history.raw: {extra['rawMatches']}/{extra['comparable']} ({share:.1f}%)")
        add(f"- final matched history.text: {extra['finalMatches']}/{extra['comparable']}")
        if args.include_private_text:
            add("")
            add("### Mismatched records (--include-private-text)")
            for record in extra["mismatched"]:
                add(f"- `{record.get('key')}`")
                add(f"  - replay.raw: {record.get('raw')!r}")
                add(f"  - history.raw: {(record.get('history') or {}).get('raw')!r}")
    else:
        add(f"## mode={run_a.get('mode')} — no embedded history and no B file; "
            "WER above (if any) is the full comparison.")

    return "\n".join(lines)


def write_output(text, out_arg):
    destination = out_arg.expanduser().resolve()
    if inside_repository(destination):
        raise SystemExit(
            f"Refusing to write inside the repository: {destination}\n"
            "This report may contain transcript text (with --include-private-text), and the "
            "repository is public. Choose a path outside the working tree."
        )
    handle = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(handle, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as out_file:
        out_file.write(text + "\n")
    print(f"Report written: {destination}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("a", metavar="A.jsonl", type=Path, help="replay JSONL to report on")
    parser.add_argument("b", metavar="B.jsonl", type=Path, nargs="?", help="second run, for A vs B")
    parser.add_argument("--include-private-text", action="store_true",
                        help="show the actual transcript text of changed/mismatched records — this is the "
                             "owner's speech, never print it in CI or agent tool output")
    parser.add_argument("--out", type=Path, help="write the report to a file (0600); refused inside the repo")
    args = parser.parse_args()

    run_a, records_a, summary_a = load_replay(args.a)
    # Duplicate-key check always runs on A, even in single-file mode — a
    # replay JSONL should never repeat a key regardless of how it's compared.
    index_by_key(records_a, args.a)

    timing_a = timing_stats(records_a)
    wer_a = wer_stats(records_a)

    if args.b:
        _run_b, records_b, _summary_b = load_replay(args.b)
        extra = compare_two_runs(records_a, records_b, args.a, args.b)
    elif run_a.get("mode") == "history":
        extra = compare_against_history(records_a, args.a)
    else:
        # mode=dir has no embedded history to compare against — WER vs the
        # sibling .txt reference (already computed into wer_a above) is the
        # whole report; there is no "A vs ..." section to add.
        extra = None

    report = format_report(args, run_a, summary_a, timing_a, wer_a, extra)

    if args.out:
        write_output(report, args.out)
    else:
        print(report)


if __name__ == "__main__":
    main()
