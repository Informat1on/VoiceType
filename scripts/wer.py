#!/usr/bin/env python3
"""WER calculator for VoiceType benchmark.

Uses jiwer if available, falls back to manual edit-distance implementation.

Usage:
  python3 scripts/wer.py --hyp "hypothesis text" --ref "reference text"
  python3 scripts/wer.py --hyp-file hyp.txt --ref-file ref.txt
"""

import argparse
import re
import sys


def normalize(text: str) -> str:
    """Normalize text for WER calculation.

    Steps:
    - Lowercase
    - Strip punctuation (keep word chars and spaces)
    - Collapse whitespace
    - Trim
    """
    text = text.lower()
    text = re.sub(r"[^\w\s]", "", text, flags=re.UNICODE)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def _edit_distance(ref_words: list, hyp_words: list) -> int:
    """Compute Levenshtein edit distance between two word lists."""
    n = len(ref_words)
    m = len(hyp_words)
    dp = list(range(m + 1))
    for i in range(1, n + 1):
        prev = dp[:]
        dp[0] = i
        for j in range(1, m + 1):
            if ref_words[i - 1] == hyp_words[j - 1]:
                dp[j] = prev[j - 1]
            else:
                dp[j] = 1 + min(prev[j - 1], prev[j], dp[j - 1])
    return dp[m]


def compute_wer(hypothesis: str, reference: str) -> float:
    """Return WER as a float [0.0, inf).

    Returns 0.0 if both hypothesis and reference are empty.
    Returns 1.0 if reference is empty but hypothesis is not.
    """
    hyp_norm = normalize(hypothesis)
    ref_norm = normalize(reference)

    if not ref_norm and not hyp_norm:
        return 0.0
    if not ref_norm:
        return 1.0

    try:
        import jiwer  # noqa: PLC0415

        return jiwer.wer(ref_norm, hyp_norm)
    except ImportError:
        pass

    ref_words = ref_norm.split()
    hyp_words = hyp_norm.split()
    if not ref_words:
        return 0.0
    dist = _edit_distance(ref_words, hyp_words)
    return dist / len(ref_words)


def main() -> None:
    parser = argparse.ArgumentParser(description="Compute WER between hypothesis and reference")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--hyp", type=str, help="Hypothesis text")
    group.add_argument("--hyp-file", type=str, help="File with hypothesis text (one utterance per line)")

    ref_group = parser.add_mutually_exclusive_group(required=True)
    ref_group.add_argument("--ref", type=str, help="Reference text")
    ref_group.add_argument("--ref-file", type=str, help="File with reference text (one utterance per line)")

    args = parser.parse_args()

    if args.hyp is not None:
        # Single utterance mode
        wer_val = compute_wer(args.hyp, args.ref)
        print(f"{wer_val:.3f}")
    else:
        # Batch mode: compute average WER across all lines
        with open(args.hyp_file, encoding="utf-8") as f:
            hyps = f.read().splitlines()
        with open(args.ref_file, encoding="utf-8") as f:
            refs = f.read().splitlines()
        if len(hyps) != len(refs):
            print(
                f"ERROR: line count mismatch: hyp={len(hyps)}, ref={len(refs)}",
                file=sys.stderr,
            )
            sys.exit(1)
        wers = [compute_wer(h, r) for h, r in zip(hyps, refs)]
        avg = sum(wers) / len(wers) if wers else 0.0
        print(f"{avg:.3f}")


if __name__ == "__main__":
    main()
