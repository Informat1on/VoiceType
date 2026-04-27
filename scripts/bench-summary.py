#!/usr/bin/env python3
"""Aggregate bench CSV → markdown summary table.

Usage:
  python3 scripts/bench-summary.py scripts/bench-output/results.csv
"""

import csv
import statistics
import sys
from collections import defaultdict


# Map phrase index → block name
# Block 1: conversational Russian (01-05)
# Block 2: tech anglicisms (06-10)
# Block 3: code identifiers (11-15)
# Block 4: numbers/versions (16-18)
# Block 5: long sentences (19-22)
# Block 6: edge cases (23-25)
BLOCKS = {
    "1-conversational": list(range(1, 6)),
    "2-anglicisms": list(range(6, 11)),
    "3-identifiers": list(range(11, 16)),
    "4-numbers": list(range(16, 19)),
    "5-long-sentences": list(range(19, 23)),
    "6-edge-cases": list(range(23, 26)),
}


def fmt_size(mb: int) -> str:
    if mb >= 1000:
        return f"{mb / 1000:.1f} GB"
    return f"{mb} MB"


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: bench-summary.py results.csv", file=sys.stderr)
        sys.exit(1)

    csv_path = sys.argv[1]

    # data[model][phrase_idx] = {"wer": float, "time": float, "rtf": float}
    data: dict[str, dict[int, dict]] = defaultdict(dict)
    model_sizes: dict[str, str] = {}

    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            model = row["model"]
            phrase = int(row["phrase"])
            try:
                wer = float(row["wer"])
                time_s = float(row["transcribe_time_s"])
                rtf = float(row["rtf"])
            except (ValueError, KeyError):
                continue
            data[model][phrase] = {"wer": wer, "time": time_s, "rtf": rtf}

            # Infer size from model name if not stored
            if model not in model_sizes:
                sizes = {
                    "base": "141 MB",
                    "small-q5": "181 MB",
                    "small": "465 MB",
                    "medium": "1.4 GB",
                    "turbo-q5": "547 MB",
                    "turbo": "1.5 GB",
                }
                model_sizes[model] = sizes.get(model, "?")

    if not data:
        print("No data found in CSV.", file=sys.stderr)
        sys.exit(1)

    # Preserve order of first appearance
    models = list(data.keys())

    print("\n## Summary\n")
    print("| Model | Avg WER | Median WER | Avg time/phrase | Avg RTF | Disk |")
    print("|-------|---------|-----------|----------------|---------|------|")

    for model in models:
        phrases = data[model]
        wers = [v["wer"] for v in phrases.values()]
        times = [v["time"] for v in phrases.values()]
        rtfs = [v["rtf"] for v in phrases.values() if v["rtf"] > 0]

        avg_wer = statistics.mean(wers) if wers else 0.0
        med_wer = statistics.median(wers) if wers else 0.0
        avg_time = statistics.mean(times) if times else 0.0
        avg_rtf = statistics.mean(rtfs) if rtfs else 0.0
        size = model_sizes.get(model, "?")

        print(
            f"| {model:<12} | {avg_wer*100:>5.1f}% | {med_wer*100:>6.1f}% "
            f"| {avg_time:>6.2f}s | {avg_rtf:>5.1f}x | {size} |"
        )

    print("\n## Per-block breakdown\n")

    block_header = "| Model | " + " | ".join(BLOCKS.keys()) + " |"
    block_sep = "|-------|" + "|".join(["-------"] * len(BLOCKS)) + "|"
    print(block_header)
    print(block_sep)

    for model in models:
        phrases = data[model]
        row_parts = [f" {model:<12} "]
        for block_name, indices in BLOCKS.items():
            block_wers = [phrases[i]["wer"] for i in indices if i in phrases]
            if block_wers:
                avg = statistics.mean(block_wers)
                row_parts.append(f" {avg*100:.1f}% ")
            else:
                row_parts.append(" N/A ")
        print("|" + "|".join(row_parts) + "|")

    print()


if __name__ == "__main__":
    main()
