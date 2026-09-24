#!/usr/bin/env python3
"""Shadow VAD + repeat-detector measurement — docs/plans/shadow-vad.md T2.

Reads a replay JSONL (produced by `scripts/replay.sh` /
`ReplayHarnessTests`) and measures, WITHOUT touching the production path in
`Sources/`, whether a VAD pre-filter (Silero + an energy gate) and a
repeat/hallucination detector would change anything if they were added.

This is a pure developer measurement tool. It does not modify the app, the
replay harness, or `HallucinationFilter` — the filter's rule is *replicated*
here in Python (see FILTER_TEMPLATES / normalize_for_filter / filter_split
below, ported verbatim from
Sources/VoiceType/Services/HallucinationFilter.swift) purely so this script
can cross-check its replica against what the real filter already removed
(`record.removedTemplates`), catching drift between the two.

Privacy (docs/plans/shadow-vad.md §2): the corpus may be the owner's real
speech (history mode). By default this prints ONLY aggregates to stdout —
no transcript text, ever. Per-record text (segments, raw, final, reference)
is written only with --include-private-text, and only to the file named by
--out, which must sit outside the repository working tree and is created
with 0600 permissions. All stdout/stderr is plain ASCII (see safe_print) so
that any non-ASCII byte in the output is itself evidence of a leak.

Usage:
  scripts/shadow-analysis.py run.jsonl --audio-dir DIR
  scripts/shadow-analysis.py run.jsonl --include-private-text --out /outside/repo/markup.txt

Exit codes: 0 clean; 1 analysis/replay errors were found (report still
printed); 2 argument/input error (bad JSONL, missing model/utility, refused
private-mode request, or zero analyzable records).
"""

import argparse
import contextlib
import hashlib
import importlib.util
import math
import os
import re
import subprocess
import sys
import tempfile
import wave
from array import array
from pathlib import Path

# ---------------------------------------------------------------------------
# Reuse replay-compare.py's JSONL loader/validator and repo-path guard rather
# than duplicating them (docs/plans/shadow-vad.md T2). importlib because the
# filename has a dash and isn't a valid module name.
_REPLAY_COMPARE_PATH = Path(__file__).resolve().parent / "replay-compare.py"
_spec = importlib.util.spec_from_file_location("_shadow_analysis_replay_compare", _REPLAY_COMPARE_PATH)
_replay_compare = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_replay_compare)
load_replay = _replay_compare.load_replay
index_by_key = _replay_compare.index_by_key
inside_repository = _replay_compare.inside_repository


DEFAULT_VAD_MODEL = Path.home() / ".cache" / "voicetype" / "ggml-silero-v6.2.0.bin"
DEFAULT_VAD_UTILITY = Path("/opt/homebrew/bin/whisper-vad-speech-segments")
DEFAULT_VAD_THRESHOLDS = "0.3,0.5"
DEFAULT_RMS_GATES = "0.002,0.005,0.01"
DEFAULT_SILENCE_OVERLAP = "0.2"
DEFAULT_HISTORY_AUDIO_DIR = Path.home() / "Library" / "Application Support" / "VoiceType" / "audio"

# Fixed reference points used by specific report sections regardless of what
# --vad-thresholds the caller passed (docs/plans/shadow-vad.md §4 T2
# "перекрёсток" / "чувствительность"):
CROSSTAB_VAD_THRESHOLD = 0.5
SENSITIVITY_OVERLAPS = (0.1, 0.2, 0.5)

FRAME_MS = 20
VAD_TIMEOUT_S = 60
AFCONVERT_TIMEOUT_S = 60

COHORTS = ("current", "legacy", "total")


# ---------------------------------------------------------------------------
# HallucinationFilter replica (Sources/VoiceType/Services/HallucinationFilter.swift)
# ---------------------------------------------------------------------------

# Copied verbatim from Sources/VoiceType/Services/HallucinationFilter.swift:44-55
# (`templates`, already lower-cased/normalized form). Keep in sync manually —
# `verify_filter_replica` below catches drift by reconciling against each
# record's own `removedTemplates`.
FILTER_TEMPLATES = {
    "продолжение следует",
    "субтитры сделал dimatorzok",
    "субтитры создавал dimatorzok",
    "субтитры и перевод сделал dimatorzok",
    "редактор субтитров а.синецкая",
    "корректор а.кулакова",
}

_FILTER_TRAILING_PUNCT = ".…!?"


def normalize_for_filter(segment):
    """Ports Sources/VoiceType/Services/HallucinationFilter.swift:101-126
    (`normalize(_:)`) verbatim: collapse whitespace, strip a trailing run of
    sentence punctuation, trim again, lowercase. This is the filter's own
    normalization — NOT the repeat-detector normalization in normalize_repeat
    below (different rule, different purpose, per docs/plans/shadow-vad.md
    §4 T2 item 5's explicit "не нормализация детектора повторов из п.6")."""
    collapsed = " ".join(segment.split())
    trimmed = collapsed
    while trimmed and trimmed[-1] in _FILTER_TRAILING_PUNCT:
        trimmed = trimmed[:-1]
    return trimmed.strip().lower()


def filter_split(texts):
    """Ports Sources/VoiceType/Services/HallucinationFilter.swift:76-99
    (`split(segments:)`) verbatim. Returns (kept, removed, bounds) where
    `removed` is texts[:keep_start] + texts[keep_end:] (prefix run then
    suffix run, each in original order — matches the Swift concatenation
    order) and `bounds` is (keep_start, keep_end) for is_removed_index."""
    n = len(texts)
    if n == 0:
        return [], [], (0, 0)

    is_template = [normalize_for_filter(t) in FILTER_TEMPLATES for t in texts]

    leading = 0
    while leading < n and is_template[leading]:
        leading += 1

    trailing = 0
    while trailing < n and is_template[n - 1 - trailing]:
        trailing += 1

    keep_start = leading
    keep_end = n - trailing
    if keep_start >= keep_end:
        return [], list(texts), (keep_start, keep_end)

    removed = list(texts[:keep_start]) + list(texts[keep_end:])
    kept = list(texts[keep_start:keep_end])
    return kept, removed, (keep_start, keep_end)


def is_removed_index(idx, bounds):
    keep_start, keep_end = bounds
    return not (keep_start <= idx < keep_end)


# ---------------------------------------------------------------------------
# Repeat-detector normalization (docs/plans/shadow-vad.md §4 T2 item 6) —
# deliberately separate from normalize_for_filter above.
# ---------------------------------------------------------------------------

_PUNCT_RE = re.compile(r"[^\w\s]|_", re.UNICODE)
_WS_RE = re.compile(r"\s+")


def normalize_repeat(text):
    """Lowercase, yo-to-ye, punctuation to space, collapse whitespace.

    `_` is treated as punctuation too (P2 review): Python's `\\w` includes
    it, so `[^\\w\\s]` alone would leave underscores untouched — "да_да"
    must normalize the same as "да да", not stay as one token."""
    lowered = text.lower().replace("ё", "е")  # ё -> е
    cleaned = _PUNCT_RE.sub(" ", lowered)
    return _WS_RE.sub(" ", cleaned).strip()


# Edge-template candidate lists (item 6): strict = filter templates (via the
# item-6 normalization, not the filter's own) plus "спасибо за просмотр";
# risky = phrases that occur as genuine speech and the filter deliberately
# leaves alone.
_EDGE_STRICT_RAW = FILTER_TEMPLATES | {"спасибо за просмотр"}
_EDGE_RISKY_RAW = {"спасибо", "спасибо за внимание", "подписывайтесь на канал"}
EDGE_STRICT = {normalize_repeat(t) for t in _EDGE_STRICT_RAW}
EDGE_RISKY = {normalize_repeat(t) for t in _EDGE_RISKY_RAW}


def compute_dup_pairs(norm_texts):
    """Adjacent-pair dupSegment detection over already-normalized (via
    normalize_repeat) segment texts. Returns [(i, i+1, 'single'|'multi'), ...]
    for each equal, non-empty adjacent pair, classified by token count."""
    pairs = []
    for i in range(len(norm_texts) - 1):
        a, b = norm_texts[i], norm_texts[i + 1]
        if a and a == b:
            token_class = "single" if len(a.split()) == 1 else "multi"
            pairs.append((i, i + 1, token_class))
    return pairs


def edge_flags(norm_repeat, is_first, is_last):
    """Whether a segment (already normalize_repeat'd) at the start/end of the
    array matches the strict or risky edge-template candidate list. A
    segment strictly in the middle (is_first=is_last=False) never flags,
    even on a verbatim template match."""
    if not (is_first or is_last):
        return False, False
    return norm_repeat in EDGE_STRICT, norm_repeat in EDGE_RISKY


def detect_loop(tokens):
    """n-gram (n=2..6) repeated >=3 times consecutively, OR a single token
    repeated >=4 times consecutively."""
    n_tok = len(tokens)

    run = 1
    for i in range(1, n_tok):
        if tokens[i] == tokens[i - 1]:
            run += 1
            if run >= 4:
                return True
        else:
            run = 1

    for n in range(2, 7):
        span = n * 3
        if n_tok < span:
            continue
        i = 0
        while i + span <= n_tok:
            g1 = tokens[i:i + n]
            g2 = tokens[i + n:i + 2 * n]
            g3 = tokens[i + 2 * n:i + 3 * n]
            if g1 == g2 == g3:
                return True
            i += 1
    return False


# ---------------------------------------------------------------------------
# Silero VAD output parsing
# ---------------------------------------------------------------------------

_DETECTED_LINE_RE = re.compile(r"^Detected\s+(\d+)\s+speech segments:\s*$")
_SEGMENT_LINE_RE = re.compile(
    r"^Speech segment\s+(\d+):\s*start\s*=\s*([^,\s]+)\s*,\s*end\s*=\s*(\S+)\s*$"
)


class AnalysisError(Exception):
    """Raised for any per-record failure — message must never contain
    transcript text (docs/plans/shadow-vad.md "Диагностика без текста")."""


def parse_vad_output(stdout):
    """Strict line-by-line parse of whisper-vad-speech-segments' stdout
    (docs/plans/shadow-vad.md §3). Blank lines are ignored; every other line
    must be either THE 'Detected N speech segments:' line (exactly one) or a
    'Speech segment <i>: start = X, end = Y' line — any other non-blank line
    is a hard error (P1 review: the previous regex-finditer scan silently
    skipped garbage between valid lines instead of failing on it).

    The 'Detected' header must come first — a 'Speech segment' line before it
    is an error (P1 review), and a second 'Detected' line anywhere (before OR
    after segment lines) is also an error. Segment indices must appear in
    strict order 0..N-1 (a skipped or repeated index is an error), X/Y must
    be finite and 0 <= X <= Y (in hundredths of a second), and the parsed
    segment count must equal the header's N. Returns [(startMs, endMs), ...]."""
    detected_n = None
    parsed = []  # [(index, start_ms, end_ms), ...] in the order encountered

    for lineno, raw_line in enumerate(stdout.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue

        det_match = _DETECTED_LINE_RE.match(line)
        if det_match:
            if detected_n is not None:
                raise AnalysisError(f"vad output line {lineno}: second 'Detected N speech segments' line")
            detected_n = int(det_match.group(1))
            continue

        seg_match = _SEGMENT_LINE_RE.match(line)
        if seg_match:
            if detected_n is None:
                raise AnalysisError(
                    f"vad output line {lineno}: 'Speech segment' line before the 'Detected' header"
                )
            idx = int(seg_match.group(1))
            try:
                start_raw = float(seg_match.group(2))
                end_raw = float(seg_match.group(3))
            except ValueError:
                raise AnalysisError(f"vad output line {lineno}: non-numeric start/end")
            if not (math.isfinite(start_raw) and math.isfinite(end_raw)):
                raise AnalysisError(f"vad output line {lineno}: non-finite start/end")
            if not (0 <= start_raw <= end_raw):
                raise AnalysisError(f"vad output line {lineno}: start > end or negative start")
            parsed.append((idx, round(start_raw * 10), round(end_raw * 10)))
            continue

        raise AnalysisError(f"vad output line {lineno}: neither a 'Detected' nor a 'Speech segment' line")

    if detected_n is None:
        raise AnalysisError("vad output missing 'Detected N speech segments' line")
    if len(parsed) != detected_n:
        raise AnalysisError(
            f"vad segment count mismatch: header said {detected_n}, parsed {len(parsed)}"
        )
    for expected_idx, (idx, _start_ms, _end_ms) in enumerate(parsed):
        if idx != expected_idx:
            raise AnalysisError(
                f"vad segment index out of order: expected {expected_idx}, got {idx}"
            )
    return [(start_ms, end_ms) for _idx, start_ms, end_ms in parsed]


def run_vad(utility_path, model_path, threshold, wav_path):
    """Runs whisper-vad-speech-segments and returns [(startMs, endMs), ...]
    (raw, unmerged — see normalize_intervals for the merge/clip step callers
    must apply before using them). stderr is Metal init noise and is
    discarded, never inspected or relayed."""
    try:
        proc = subprocess.run(
            [str(utility_path), "-vm", str(model_path), "-vt", repr(threshold), "-f", str(wav_path)],
            capture_output=True, text=True, timeout=VAD_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        raise AnalysisError(f"vad timed out at threshold {threshold!r}")
    except OSError as exc:
        raise AnalysisError(f"vad exec failed at threshold {threshold!r}: {exc.__class__.__name__}")

    if proc.returncode != 0:
        raise AnalysisError(f"vad exited {proc.returncode} at threshold {threshold!r}")

    try:
        return parse_vad_output(proc.stdout)
    except AnalysisError as exc:
        raise AnalysisError(f"{exc} (threshold {threshold!r})")


# ---------------------------------------------------------------------------
# Audio decode + energy
# ---------------------------------------------------------------------------

def decode_to_wav(src_path, dst_path):
    """afconvert to mono 16kHz 16-bit little-endian PCM WAV. CAF doesn't
    read directly (docs/plans/shadow-vad.md §3); WAV input is re-encoded too,
    for a uniform decode path."""
    try:
        proc = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(src_path), str(dst_path)],
            capture_output=True, text=True, timeout=AFCONVERT_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        raise AnalysisError("afconvert timed out")
    except OSError as exc:
        raise AnalysisError(f"afconvert exec failed: {exc.__class__.__name__}")
    if proc.returncode != 0:
        raise AnalysisError(f"afconvert exited {proc.returncode}")
    if not dst_path.is_file():
        raise AnalysisError("afconvert produced no output file")


def read_pcm16_mono(wav_path):
    with contextlib.closing(wave.open(str(wav_path), "rb")) as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)

    if sampwidth != 2:
        raise AnalysisError(f"unexpected sample width {sampwidth} (expected 16-bit PCM)")

    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()

    if n_channels > 1:
        # Defensive downmix: afconvert was asked for -c 1, but if it ever
        # doesn't, average channels rather than misreading interleaved
        # samples as mono.
        usable = len(samples) - (len(samples) % n_channels)
        samples = array("h", (
            sum(samples[i:i + n_channels]) // n_channels
            for i in range(0, usable, n_channels)
        ))

    return samples, framerate


def percentile(sorted_values, pct):
    """Nearest-rank percentile — same formula as replay-compare.py's."""
    if not sorted_values:
        return None
    idx = max(0, min(len(sorted_values) - 1, round(pct / 100 * (len(sorted_values) - 1))))
    return sorted_values[idx]


def energy_stats(samples, framerate):
    if len(samples) == 0:
        raise AnalysisError("decoded audio has zero samples")

    frame_len = max(1, int(framerate * FRAME_MS / 1000))
    frame_rms = []
    total_sq = 0.0
    for i in range(0, len(samples), frame_len):
        chunk = samples[i:i + frame_len]
        if not chunk:
            continue
        sq_sum = sum((s / 32768.0) ** 2 for s in chunk)
        total_sq += sq_sum
        frame_rms.append(math.sqrt(sq_sum / len(chunk)))

    record_rms = math.sqrt(total_sq / len(samples))
    frame_rms.sort()
    frame_p95 = percentile(frame_rms, 95) or 0.0
    frame_max = frame_rms[-1] if frame_rms else 0.0
    return record_rms, frame_p95, frame_max


def normalize_intervals(intervals_ms, audio_ms):
    """Clips each interval to [0, audio_ms], drops any that collapse to
    zero/negative length, sorts by start, and merges overlapping or touching
    (start <= previous end) intervals. Silero's own segments can overlap or
    run past the audio's own duration; overlap_fraction/speech_fraction
    assume disjoint, in-bounds intervals — without this step a segment
    overlapped by two Silero intervals could report >100% coverage (P1
    review, e.g. 0-600ms + 400-1000ms over a 0-1000ms segment -> 1.2 instead
    of 1.0)."""
    clipped = []
    for start, end in intervals_ms:
        clipped_start = max(0.0, min(start, audio_ms))
        clipped_end = max(0.0, min(end, audio_ms))
        if clipped_end > clipped_start:
            clipped.append((clipped_start, clipped_end))
    clipped.sort()

    merged = []
    for start, end in clipped:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def overlap_fraction(seg_start_ms, seg_end_ms, intervals_ms):
    """Fraction of [seg_start_ms, seg_end_ms) covered by any interval. A
    zero-or-negative-length segment has no coverage by definition (0.0) —
    there is no natural denominator otherwise."""
    duration = seg_end_ms - seg_start_ms
    if duration <= 0:
        return 0.0
    total = 0
    for i_start, i_end in intervals_ms:
        lo = max(seg_start_ms, i_start)
        hi = min(seg_end_ms, i_end)
        if hi > lo:
            total += hi - lo
    return total / duration


def speech_fraction(intervals_ms, audio_ms):
    if audio_ms <= 0:
        return 0.0
    total = sum(e - s for s, e in intervals_ms if e > s)
    return total / audio_ms


def silence_lead_trail_ms(intervals_ms, audio_ms):
    if not intervals_ms:
        return audio_ms, audio_ms
    ordered = sorted(intervals_ms)
    lead = max(0.0, ordered[0][0])
    trail = max(0.0, audio_ms - ordered[-1][1])
    return lead, trail


# ---------------------------------------------------------------------------
# ASCII-safe output (docs/plans/shadow-vad.md "Язык отчёта" / "Диагностика")
# ---------------------------------------------------------------------------

def safe_text(text):
    """Belt-and-suspenders ASCII guard: escapes any non-ASCII byte so the
    printed report is ASCII even if a code path upstream forgot to wrap a
    path in ascii(). Paths/filenames are additionally wrapped with the
    builtin ascii() at the call site per spec, as the primary mechanism;
    this is the safety net, not a substitute for it."""
    return text.encode("ascii", "backslashreplace").decode("ascii")


def safe_print(text, file=None):
    # `file` must be looked up lazily (not defaulted at def-time) so that
    # test harnesses using contextlib.redirect_stdout/redirect_stderr — which
    # replace sys.stdout/sys.stderr after this module is imported — are
    # honored instead of being bypassed by a stale bound default.
    if file is None:
        file = sys.stdout
    print(safe_text(text), file=file)


def error_exit(code, message):
    safe_print(f"shadow-analysis: {message}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Per-record analysis
# ---------------------------------------------------------------------------

def is_number(value):
    """int/float, excluding bool (isinstance(True, int) is True in Python,
    which would otherwise let a JSON `true`/`false` sneak past a numeric
    check) and excluding NaN/+-Infinity (P1 review: json.loads happily
    accepts the bare literals NaN/Infinity/-Infinity per Python's — non-
    standard-JSON — default, and every downstream arithmetic/comparison in
    this script assumes finite numbers)."""
    if isinstance(value, bool):
        return False
    if not isinstance(value, (int, float)):
        return False
    return math.isfinite(value)


def validate_record_shape(record):
    """Fail-closed type check of a record's analysis-relevant fields, BEFORE
    any of them is touched (P2 review: `segments: [null]`, a non-numeric
    `startMs`, etc. previously fell through to a raw AttributeError/TypeError
    traceback — which risks the traceback's repr of the bad value leaking
    transcript-shaped content, on top of just being ugly). Every failure
    raises AnalysisError naming only the record key, the field, and the nature
    of the problem — never the field's actual value."""
    key = record.get("key")

    def bad(msg):
        raise AnalysisError(f"record {ascii(str(key))}: {msg}")

    if record.get("audioSeconds") is not None and not is_number(record.get("audioSeconds")):
        bad("audioSeconds is not numeric")
    if record.get("raw") is not None and not isinstance(record.get("raw"), str):
        bad("raw is not a string")
    if record.get("final") is not None and not isinstance(record.get("final"), str):
        bad("final is not a string")
    if record.get("reference") is not None and not isinstance(record.get("reference"), str):
        bad("reference is not a string")

    removed = record.get("removedTemplates")
    if removed is not None:
        if not isinstance(removed, list) or not all(isinstance(x, str) for x in removed):
            bad("removedTemplates is not a list of strings")

    segments = record.get("segments")
    if segments is not None:
        if not isinstance(segments, list):
            bad("segments is not a list")
        for i, seg in enumerate(segments):
            if not isinstance(seg, dict):
                bad(f"segment {i} is not an object")
            if not isinstance(seg.get("text"), str):
                bad(f"segment {i}.text is not a string")
            if not is_number(seg.get("startMs")):
                bad(f"segment {i}.startMs is not numeric")
            if not is_number(seg.get("endMs")):
                bad(f"segment {i}.endMs is not numeric")


def analyze_record(record, idx, audio_dir, vad_thresholds, silence_overlap, utility_path, model_path,
                    tmp_dir, mode):
    key = record.get("key")

    def fail(msg):
        raise AnalysisError(f"record {ascii(str(key))}: {msg}")

    validate_record_shape(record)

    audio_file = record.get("audioFile")
    src_path = audio_dir / audio_file
    if not src_path.is_file():
        fail(f"audio file not found: {ascii(str(audio_file))}")

    audio_seconds = record.get("audioSeconds")
    if not is_number(audio_seconds) or audio_seconds <= 0:
        fail("missing or non-positive audioSeconds")
    audio_ms = audio_seconds * 1000.0

    dst_path = tmp_dir / f"{idx:06d}.wav"
    try:
        decode_to_wav(src_path, dst_path)
    except AnalysisError as exc:
        fail(str(exc))

    try:
        samples, framerate = read_pcm16_mono(dst_path)
        record_rms, frame_p95, frame_max = energy_stats(samples, framerate)
    except AnalysisError as exc:
        fail(str(exc))

    intervals_by_threshold = {}
    for t in vad_thresholds:
        try:
            raw_intervals = run_vad(utility_path, model_path, t, dst_path)
        except AnalysisError as exc:
            fail(str(exc))
        intervals_by_threshold[t] = normalize_intervals(raw_intervals, audio_ms)

    raw_segments = record.get("segments") or []
    texts = [s.get("text", "") for s in raw_segments]
    kept, removed, bounds = filter_split(texts)
    json_removed = record.get("removedTemplates") or []
    if removed != json_removed:
        fail(
            "removedTemplates replica mismatch "
            f"(computed {len(removed)} removed, jsonl has {len(json_removed)})"
        )

    n_segments = len(raw_segments)
    seg_infos = []
    for i, seg in enumerate(raw_segments):
        text = seg.get("text", "")
        start_ms = seg.get("startMs")
        end_ms = seg.get("endMs")
        if not is_number(start_ms) or not is_number(end_ms):
            # Unreachable given validate_record_shape's upfront check; kept
            # as defense in depth.
            fail(f"segment {i}: missing startMs/endMs")

        overlaps = {t: overlap_fraction(start_ms, end_ms, intervals_by_threshold[t]) for t in vad_thresholds}
        in_silence = {t: overlaps[t] < silence_overlap for t in vad_thresholds}
        beyond_audio = end_ms > audio_ms + 100
        is_first = i == 0
        is_last = i == n_segments - 1
        removed_by_filter = is_removed_index(i, bounds)
        norm_repeat = normalize_repeat(text)
        edge_strict, edge_risky = edge_flags(norm_repeat, is_first, is_last)

        seg_infos.append({
            "index": i,
            "text": text,
            "startMs": start_ms,
            "endMs": end_ms,
            "durationMs": end_ms - start_ms,
            "overlaps": overlaps,
            "inSilence": in_silence,
            "beyondAudio": beyond_audio,
            "isFirst": is_first,
            "isLast": is_last,
            "removedByFilter": removed_by_filter,
            "normRepeat": norm_repeat,
            "edgeStrict": edge_strict,
            "edgeRisky": edge_risky,
        })

    dup_pairs = compute_dup_pairs([s["normRepeat"] for s in seg_infos])

    raw_text = record.get("raw") or ""
    loop_tokens = normalize_repeat(raw_text).split()
    has_loop = detect_loop(loop_tokens)

    if mode == "dir":
        cohort = "current"
    else:
        cohort = "current" if record.get("comparableToHistory") is True else "legacy"

    return {
        "key": key,
        "cohort": cohort,
        "audioSeconds": audio_seconds,
        "recordRms": record_rms,
        "frameRmsP95": frame_p95,
        "frameRmsMax": frame_max,
        "intervals": intervals_by_threshold,
        "segments": seg_infos,
        "dupPairs": dup_pairs,
        "hasDupSingle": any(tc == "single" for _, _, tc in dup_pairs),
        "hasDupMulti": any(tc == "multi" for _, _, tc in dup_pairs),
        "hasLoop": has_loop,
        "hasEdgeStrict": any(s["edgeStrict"] for s in seg_infos),
        "hasEdgeRisky": any(s["edgeRisky"] for s in seg_infos),
        "hasBeyondAudio": any(s["beyondAudio"] for s in seg_infos),
        "hasInSilence": {t: any(s["inSilence"][t] for s in seg_infos) for t in vad_thresholds},
        "final": record.get("final"),
        "removedTemplates": json_removed,
        "reference": record.get("reference"),
        "raw": raw_text,
    }


def has_repeat_flag(rec):
    """dupSegment || loop || edgeTemplate (strict or risky) — the 'repeat
    detector' flags from docs/plans/shadow-vad.md §4 T2 item 6. Deliberately
    EXCLUDES beyondAudio (a VAD-timing fact, not a repeat-detector finding):
    the any-repeat-flag x inSilence crosstab is about the repeat detector's
    own candidates, not about anything else this script also happens to flag
    (P1 review)."""
    return (
        rec["hasDupSingle"] or rec["hasDupMulti"] or rec["hasLoop"]
        or rec["hasEdgeStrict"] or rec["hasEdgeRisky"]
    )


def any_flag(rec):
    """has_repeat_flag() plus beyondAudio — used for markup-list selection,
    where beyondAudio remains a legitimate candidate-for-labeling flag."""
    return has_repeat_flag(rec) or rec["hasBeyondAudio"]


def fixed_by_filter(rec, category, threshold=None):
    """Whether at least one of the segments that TRIGGERED `category` for
    this record was already removed by the (replicated) filter. n/a for
    'loop', which is a raw-text-level flag, not tied to a segment."""
    if category == "loop":
        return None
    if category == "dup":
        idxs = set()
        for a, b, _ in rec["dupPairs"]:
            idxs.add(a)
            idxs.add(b)
    elif category in ("dupSingle", "dupMulti"):
        wanted_class = "single" if category == "dupSingle" else "multi"
        idxs = set()
        for a, b, token_class in rec["dupPairs"]:
            if token_class == wanted_class:
                idxs.add(a)
                idxs.add(b)
    elif category == "edgeStrict":
        idxs = {s["index"] for s in rec["segments"] if s["edgeStrict"]}
    elif category == "edgeRisky":
        idxs = {s["index"] for s in rec["segments"] if s["edgeRisky"]}
    elif category == "inSilence":
        idxs = {s["index"] for s in rec["segments"] if s["inSilence"][threshold]}
    elif category == "beyondAudio":
        idxs = {s["index"] for s in rec["segments"] if s["beyondAudio"]}
    else:
        raise ValueError(category)
    return any(s["removedByFilter"] for s in rec["segments"] if s["index"] in idxs)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def select_cohort(records, cohort):
    if cohort == "total":
        return records
    return [r for r in records if r["cohort"] == cohort]


def frac_str(n, d):
    if d <= 0:
        return f"{n}/0 (n/a)"
    return f"{n}/{d} ({100.0 * n / d:.1f}%)"


def frac_of(n, d, label):
    """Like frac_str, but names its own denominator ('n/d of <label>
    (p%)') — P1 review: printing a single 'fixed=' fraction forced a choice
    of denominator (share of flagged records, or share of all analyzed
    records) that silently discarded the other; callers with two
    denominators of interest print both, explicitly labeled, side by side."""
    if d <= 0:
        return f"{n}/0 of {label} (n/a)"
    return f"{n}/{d} of {label} ({100.0 * n / d:.1f}%)"


def stat_str(values):
    values = sorted(values)
    if not values:
        return "n/a (0 records)"
    return (
        f"min={values[0]:.4f} p5={percentile(values, 5):.4f} "
        f"p50={percentile(values, 50):.4f} p95={percentile(values, 95):.4f}"
    )


def stat_str_ms(values):
    values = sorted(values)
    if not values:
        return "n/a (0 records)"
    return f"p50={percentile(values, 50):.0f}ms p95={percentile(values, 95):.0f}ms"


def build_report(args, run, model_path, model_sha256, utility_path, mode,
                  coverage, vad_thresholds, rms_gates, silence_overlap, analyzed_records):
    lines = []
    add = lines.append

    add("# shadow-analysis report")
    add("")
    add(f"replay: {ascii(str(args.replay))}")
    add(f"utility: {ascii(str(utility_path))}")
    add(f"model: {ascii(str(model_path))} sha256={model_sha256}")
    add(f"audio-dir: {ascii(str(args.audio_dir_resolved))}")
    add(f"mode={mode} pipelineStamp={ascii(str(run.get('pipelineStamp')))}")
    add(
        f"vad-thresholds={vad_thresholds} rms-gates={rms_gates} "
        f"silence-overlap={silence_overlap}"
    )
    add("")
    add(
        "coverage: selected={selected} noAudioField={noAudioField} "
        "replayErrors={replayErrors} analysisErrors={analysisErrors} analyzed={analyzed}".format(**coverage)
    )
    add(
        "cohorts (of analyzed): current={0} legacy={1}".format(
            len(select_cohort(analyzed_records, "current")),
            len(select_cohort(analyzed_records, "legacy")),
        )
    )
    add("")

    if not analyzed_records:
        add("No analyzed records — nothing further to report.")
        return "\n".join(lines)

    for cohort in COHORTS:
        recs = select_cohort(analyzed_records, cohort)
        add(f"## cohort={cohort} (analyzed={len(recs)})")
        if not recs:
            add("(no records)")
            add("")
            continue

        add(f"- RMS per record: {stat_str([r['recordRms'] for r in recs])}")
        for t in vad_thresholds:
            frac_values = [speech_fraction(r["intervals"][t], r["audioSeconds"] * 1000.0) for r in recs]
            lead_trail = [
                silence_lead_trail_ms(r["intervals"][t], r["audioSeconds"] * 1000.0) for r in recs
            ]
            lead_values = [lt[0] for lt in lead_trail]
            trail_values = [lt[1] for lt in lead_trail]
            add(f"- speech fraction @ vad={t}: {stat_str(frac_values)}")
            add(f"  silence-lead @ vad={t}: {stat_str_ms(lead_values)}  silence-trail: {stat_str_ms(trail_values)}")

        add("")
        add("  main table (share of analyzed in this cohort; 'fixed' = filter already removed a triggering segment):")
        rows = [("dupSegment (any)", "dup", None, lambda r: r["hasDupSingle"] or r["hasDupMulti"])]
        rows.append(("  dupSegment (1-token)", "dupSingle", None, lambda r: r["hasDupSingle"]))
        rows.append(("  dupSegment (>=2-token)", "dupMulti", None, lambda r: r["hasDupMulti"]))
        rows.append(("loop", "loop", None, lambda r: r["hasLoop"]))
        rows.append(("edgeTemplate strict", "edgeStrict", None, lambda r: r["hasEdgeStrict"]))
        rows.append(("edgeTemplate risky", "edgeRisky", None, lambda r: r["hasEdgeRisky"]))
        for t in vad_thresholds:
            rows.append((f"inSilence(vad={t})", "inSilence", t, (lambda r, t=t: r["hasInSilence"][t])))
        rows.append(("beyondAudio", "beyondAudio", None, lambda r: r["hasBeyondAudio"]))

        n = len(recs)
        for label, category, threshold, predicate in rows:
            flagged = [r for r in recs if predicate(r)]
            count = len(flagged)
            if category is None:
                add(f"    {label}: {frac_str(count, n)}")
                continue
            if category == "loop":
                add(f"    {label}: {frac_str(count, n)}  fixed=n/a")
            else:
                fixed = sum(1 for r in flagged if fixed_by_filter(r, category, threshold))
                add(
                    f"    {label}: {frac_str(count, n)}  "
                    f"fixed={frac_of(fixed, count, 'flagged')}, {frac_of(fixed, n, 'analyzed')}"
                )
        add("")

        # Crosstab @ CROSSTAB_VAD_THRESHOLD.
        if CROSSTAB_VAD_THRESHOLD in vad_thresholds:
            t = CROSSTAB_VAD_THRESHOLD
            repeat_flagged = [r for r in recs if has_repeat_flag(r)]
            both = sum(1 for r in repeat_flagged if r["hasInSilence"][t])
            add(
                f"  crosstab: any-repeat-flag AND inSilence(vad={t}): "
                f"{frac_of(both, len(repeat_flagged), 'repeat-flagged')}, {frac_of(both, n, 'analyzed')}"
            )

            pos_counts = {"first": 0, "middle": 0, "last": 0}
            dur_counts = {"<1s": 0, ">=1s": 0}
            for r in recs:
                for s in r["segments"]:
                    if not s["inSilence"][t]:
                        continue
                    if s["isFirst"]:
                        pos_counts["first"] += 1
                    if s["isLast"]:
                        pos_counts["last"] += 1
                    if not s["isFirst"] and not s["isLast"]:
                        pos_counts["middle"] += 1
                    if s["durationMs"] < 1000:
                        dur_counts["<1s"] += 1
                    else:
                        dur_counts[">=1s"] += 1
            add(
                f"  inSilence(vad={t}) segments by position: first={pos_counts['first']} "
                f"middle={pos_counts['middle']} last={pos_counts['last']}"
            )
            add(
                f"  inSilence(vad={t}) segments by duration: <1s={dur_counts['<1s']} "
                f">=1s={dur_counts['>=1s']}"
            )
        else:
            add(f"  crosstab @ vad={CROSSTAB_VAD_THRESHOLD}: skipped (0.5 not in --vad-thresholds)")
        add("")

        add("  sensitivity: segments with overlap < cutoff, by vad threshold x silence-overlap cutoff:")
        for t in vad_thresholds:
            counts = []
            for cutoff in SENSITIVITY_OVERLAPS:
                n_below = sum(
                    1 for r in recs for s in r["segments"] if s["overlaps"][t] < cutoff
                )
                counts.append(f"cutoff={cutoff}:{n_below}")
            add(f"    vad={t}: " + " ".join(counts))
        add("")

        add("  simulation: energy gate (record RMS < threshold) -> final outcome:")
        for gate in rms_gates:
            below = [r for r in recs if r["recordRms"] < gate]
            nonempty = sum(1 for r in below if (r["final"] or "") != "")
            empty_filter = sum(
                1 for r in below if (r["final"] or "") == "" and r["removedTemplates"]
            )
            empty_other = len(below) - nonempty - empty_filter
            add(
                f"    rms<{gate}: {frac_str(len(below), n)}  "
                f"final-nonempty={nonempty} final-empty-by-filter={empty_filter} final-empty-other={empty_other}"
            )
        add("")

        add("  simulation: silero gate (zero speech intervals) -> final outcome:")
        for t in vad_thresholds:
            zero = [r for r in recs if len(r["intervals"][t]) == 0]
            nonempty = sum(1 for r in zero if (r["final"] or "") != "")
            empty_filter = sum(
                1 for r in zero if (r["final"] or "") == "" and r["removedTemplates"]
            )
            empty_other = len(zero) - nonempty - empty_filter
            add(
                f"    vad={t} zero-speech: {frac_str(len(zero), n)}  "
                f"final-nonempty={nonempty} final-empty-by-filter={empty_filter} final-empty-other={empty_other}"
            )
        add("")

        with_reference = sum(1 for r in recs if r.get("reference") is not None)
        add(f"  records with a reference: {with_reference}/{n}")
        add("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Private markup listing (--include-private-text)
# ---------------------------------------------------------------------------

def needs_markup(rec, vad_thresholds):
    if any_flag(rec):
        return True
    t = CROSSTAB_VAD_THRESHOLD if CROSSTAB_VAD_THRESHOLD in vad_thresholds else (
        vad_thresholds[0] if vad_thresholds else None
    )
    return t is not None and rec["hasInSilence"].get(t, False)


def render_private_block(rec, vad_thresholds):
    lines = [f"### key={rec['key']} cohort={rec['cohort']}"]
    lines.append(f"audioSeconds={rec['audioSeconds']:.3f} recordRms={rec['recordRms']:.5f}")

    if CROSSTAB_VAD_THRESHOLD in vad_thresholds:
        lines.append(f"silero(vad={CROSSTAB_VAD_THRESHOLD}) intervals(ms): {rec['intervals'][CROSSTAB_VAD_THRESHOLD]}")
    else:
        lines.append(f"silero(vad={CROSSTAB_VAD_THRESHOLD}) intervals(ms): n/a (not in --vad-thresholds)")

    lines.append("segments:")
    for s in rec["segments"]:
        flags = []
        if s["beyondAudio"]:
            flags.append("beyondAudio")
        if s["edgeStrict"]:
            flags.append("edgeTemplateStrict")
        if s["edgeRisky"]:
            flags.append("edgeTemplateRisky")
        if any(s["inSilence"].values()):
            flags.append("inSilence")
        overlap_str = ", ".join(f"vad={t}:{s['overlaps'][t]:.2f}" for t in vad_thresholds)
        lines.append(
            f"  [{s['index']}] {s['startMs']:.0f}-{s['endMs']:.0f}ms overlap({overlap_str}) "
            f"removedByFilter={s['removedByFilter']} flags={','.join(flags) or '-'} text={s['text']!r}"
        )

    dup_str = ", ".join(f"{a}-{b}({tc})" for a, b, tc in rec["dupPairs"]) or "-"
    lines.append(f"dupPairs: {dup_str}  loop={rec['hasLoop']}")
    lines.append(f"final: {rec['final']!r}")
    if rec.get("reference") is not None:
        lines.append(f"reference: {rec['reference']!r}")
    lines.append("OWNER LABEL: ")
    return "\n".join(lines)


def write_private_file(path, records, vad_thresholds):
    flagged = [r for r in records if needs_markup(r, vad_thresholds)]
    blocks = [render_private_block(r, vad_thresholds) for r in flagged]
    content = ("\n\n".join(blocks) + "\n") if blocks else "(no flagged records)\n"

    handle = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(handle, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as out_file:
        out_file.write(content)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_float_list(raw, flag_name):
    try:
        values = [float(x.strip()) for x in raw.split(",") if x.strip()]
    except ValueError:
        error_exit(2, f"invalid {flag_name}: {ascii(raw)}")
        return []  # unreachable, keeps linters happy
    if not values:
        error_exit(2, f"{flag_name} must list at least one value")
    # float("nan")/float("inf") parse without raising — reject explicitly
    # (P1 review), same reasoning as is_number()'s guard on JSONL fields.
    if not all(math.isfinite(v) for v in values):
        error_exit(2, f"{flag_name} must be finite numbers: {ascii(raw)}")
    return values


def build_arg_parser():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("replay", metavar="replay.jsonl", type=Path, help="replay JSONL to analyze")
    parser.add_argument("--audio-dir", type=Path, default=None,
                         help="directory holding the audio referenced by each record's audioFile")
    parser.add_argument("--vad-model", type=Path, default=DEFAULT_VAD_MODEL,
                         help=f"Silero VAD ggml model (default: {DEFAULT_VAD_MODEL})")
    parser.add_argument("--vad-thresholds", default=DEFAULT_VAD_THRESHOLDS,
                         help=f"comma-separated Silero VAD thresholds (default: {DEFAULT_VAD_THRESHOLDS})")
    parser.add_argument("--rms-gates", default=DEFAULT_RMS_GATES,
                         help=f"comma-separated energy-gate RMS thresholds (default: {DEFAULT_RMS_GATES})")
    parser.add_argument("--silence-overlap", default=DEFAULT_SILENCE_OVERLAP,
                         help=f"overlap-fraction cutoff for inSilence (default: {DEFAULT_SILENCE_OVERLAP})")
    parser.add_argument("--include-private-text", action="store_true",
                         help="write a per-record markup listing (transcript text) to --out; "
                              "never printed to stdout/stderr")
    parser.add_argument("--out", type=Path, default=None,
                         help="destination for the private markup listing (required with "
                              "--include-private-text; refused inside the repository)")
    return parser


def resolve_private_out(args):
    """Validates --include-private-text/--out per docs/plans/shadow-vad.md
    §4 T2 'Приватный режим'. Returns the canonical out path, or None. Exits
    2 on any violation, BEFORE any file is touched."""
    if args.include_private_text and not args.out:
        error_exit(2, "--include-private-text requires --out")
    if args.out and not args.include_private_text:
        error_exit(2, "--out requires --include-private-text")
    if not args.out:
        return None
    out_path = args.out.expanduser().resolve()
    if inside_repository(out_path):
        error_exit(2, f"--out must be outside the repository working tree: {ascii(str(out_path))}")
    return out_path


def main():
    """Thin wrapper: `_main_impl` does the real work and exits via SystemExit
    (0/1/2, all deliberate). Anything else escaping it is, by definition, a
    bug we didn't anticipate — P2 review: without this, an unhandled
    exception would print a Python traceback that can embed a repr() of
    whatever record/field triggered it, which may be transcript text. Caught
    here, at the top, for every input path, and reported with only the
    exception's type name and the record's key (if any) — never its
    message/args, which could themselves echo a bad value."""
    try:
        _main_impl()
    except SystemExit:
        raise
    except Exception as exc:
        error_exit(2, f"unexpected {exc.__class__.__name__} — aborting")


def _main_impl():
    args = build_arg_parser().parse_args()

    out_path = resolve_private_out(args)

    model_path = args.vad_model.expanduser()
    if not model_path.is_file():
        error_exit(2, f"VAD model not found: {ascii(str(model_path))}")

    if DEFAULT_VAD_UTILITY.is_file() and os.access(str(DEFAULT_VAD_UTILITY), os.X_OK):
        utility_path = DEFAULT_VAD_UTILITY
    else:
        found = None
        for path_entry in os.environ.get("PATH", "").split(os.pathsep):
            candidate = Path(path_entry) / "whisper-vad-speech-segments"
            if candidate.is_file() and os.access(str(candidate), os.X_OK):
                found = candidate
                break
        if found is None:
            error_exit(2, "whisper-vad-speech-segments not found (checked /opt/homebrew/bin and PATH)")
        utility_path = found

    vad_thresholds = parse_float_list(args.vad_thresholds, "--vad-thresholds")
    rms_gates = parse_float_list(args.rms_gates, "--rms-gates")
    try:
        silence_overlap = float(args.silence_overlap)
    except ValueError:
        error_exit(2, f"invalid --silence-overlap: {ascii(str(args.silence_overlap))}")
        return
    if not math.isfinite(silence_overlap):
        error_exit(2, f"--silence-overlap must be a finite number: {ascii(str(args.silence_overlap))}")
        return

    try:
        run, records, summary = load_replay(str(args.replay))
    except SystemExit as exc:
        error_exit(2, str(exc.code))
        return
    try:
        index_by_key(records, str(args.replay))
    except SystemExit as exc:
        error_exit(2, str(exc.code))
        return

    if summary.get("records") != len(records):
        error_exit(
            2,
            f"summary.records={summary.get('records')} but JSONL has {len(records)} record line(s)",
        )
    error_count_jsonl = sum(1 for r in records if r.get("error") is not None)
    if summary.get("errors") != error_count_jsonl:
        error_exit(
            2,
            f"summary.errors={summary.get('errors')} but {error_count_jsonl} "
            "record(s) carry an 'error' field",
        )

    mode = run.get("mode")
    if mode not in ("history", "dir"):
        error_exit(2, f"unknown run mode: {ascii(str(mode))}")

    if args.audio_dir is not None:
        audio_dir = args.audio_dir.expanduser()
    elif mode == "history":
        audio_dir = DEFAULT_HISTORY_AUDIO_DIR
    else:
        error_exit(2, "--audio-dir is required in dir mode")
        return
    if not audio_dir.is_dir():
        error_exit(2, f"--audio-dir not found or not a directory: {ascii(str(audio_dir))}")
    args.audio_dir_resolved = audio_dir

    selected = len(records)
    no_audio_field = 0
    replay_errors = 0
    analysis_errors = 0
    analyzed_records = []

    with tempfile.TemporaryDirectory(prefix="shadow-analysis-") as tmp_dir_name:
        tmp_dir = Path(tmp_dir_name)
        for idx, record in enumerate(records):
            if record.get("error") is not None:
                replay_errors += 1
                continue
            audio_file = record.get("audioFile")
            if audio_file is None:
                # docs/plans/shadow-vad.md: "audioFile отсутствует/null" —
                # no audio was ever saved for this record, a legitimate skip.
                no_audio_field += 1
                continue
            if not isinstance(audio_file, str) or audio_file == "":
                # Present but not a usable filename (empty string, or a
                # non-string from a malformed JSONL) is NOT "no audio field"
                # (P1 review) — it's a broken record, counted as an analysis
                # error like any other.
                analysis_errors += 1
                safe_print(
                    f"shadow-analysis: record {ascii(str(record.get('key')))}: "
                    "audioFile is present but not a non-empty string",
                    file=sys.stderr,
                )
                continue
            try:
                analyzed_records.append(
                    analyze_record(
                        record, idx, audio_dir, vad_thresholds, silence_overlap,
                        utility_path, model_path, tmp_dir, mode,
                    )
                )
            except AnalysisError as exc:
                analysis_errors += 1
                safe_print(f"shadow-analysis: {exc}", file=sys.stderr)
            except Exception as exc:
                # Genuinely unanticipated (a bug, not a known-bad-input case
                # validate_record_shape already turns into an AnalysisError):
                # abort immediately rather than risk a traceback whose repr()
                # of some field could be transcript text (P2 review). Report
                # only the exception's type and the record's key.
                error_exit(
                    2,
                    f"unexpected {exc.__class__.__name__} while analyzing record "
                    f"{ascii(str(record.get('key')))} — aborting",
                )

    analyzed = len(analyzed_records)
    coverage = {
        "selected": selected,
        "noAudioField": no_audio_field,
        "replayErrors": replay_errors,
        "analysisErrors": analysis_errors,
        "analyzed": analyzed,
    }

    if analyzed == 0:
        safe_print(
            "coverage: selected={selected} noAudioField={noAudioField} "
            "replayErrors={replayErrors} analysisErrors={analysisErrors} analyzed={analyzed}".format(
                **coverage
            )
        )
        error_exit(2, "analyzed == 0 — nothing to report")
        return

    model_sha256 = hashlib.sha256(model_path.read_bytes()).hexdigest()
    report = build_report(
        args, run, model_path, model_sha256, utility_path, mode,
        coverage, vad_thresholds, rms_gates, silence_overlap, analyzed_records,
    )
    safe_print(report)

    if args.include_private_text:
        write_private_file(out_path, analyzed_records, vad_thresholds)
        safe_print(f"private markup written: {ascii(str(out_path))}", file=sys.stderr)

    sys.exit(1 if (replay_errors > 0 or analysis_errors > 0) else 0)


if __name__ == "__main__":
    main()
