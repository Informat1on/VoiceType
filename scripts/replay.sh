#!/usr/bin/env bash
# scripts/replay.sh — VoiceType
#
# Wrapper around ReplayHarnessTests (Tests/VoiceTypeTests/ReplayHarnessTests.swift):
# runs the REAL production transcription path (model in memory, Metal/CoreML,
# the actual post-processing chain) over a corpus and writes JSONL.
# docs/plans/quality-tools.md §3.R2.
#
# Usage:
#   scripts/replay.sh --out <file> [--only-saved] [--limit N] [--dir <dir>]
#                      [--prompt-file <file>] [--model <path>]
#
# Default mode (no --dir): replays against the app's own history.jsonl — a
# FROZEN COPY of it, taken at the start of this run and held in a private
# temp directory outside the repo, since the owner may be dictating while the
# replay runs (docs/plans/quality-tools.md gotcha, session 21). Audio is read
# directly from the app's audio/ directory — never copied, since it is only
# ever read, not written.
#
# Exit code mirrors `swift test`'s: a nonzero test result (including the
# harness's own fail-closed XCTFails) makes this script fail too. Two extra
# checks run after a successful test: coreMLRequested in the JSONL must be
# backed by "Core ML model loaded" in the swift test log, and the JSONL's
# record-line count must equal summary.records.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_SUPPORT="$HOME/Library/Application Support/VoiceType"
HISTORY_FILE="$APP_SUPPORT/history.jsonl"
AUDIO_DIR="$APP_SUPPORT/audio"

OUT=""
ONLY_SAVED=0
LIMIT=""
DIR_MODE=""
PROMPT_FILE=""
MODEL_OVERRIDE=""

usage() {
    echo "Usage: $0 --out <file> [--only-saved] [--limit N] [--dir <dir>]" \
        "[--prompt-file <file>] [--model <path>]" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            OUT="$2"
            shift 2
            ;;
        --only-saved)
            ONLY_SAVED=1
            shift
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --dir)
            DIR_MODE="$2"
            shift 2
            ;;
        --prompt-file)
            PROMPT_FILE="$2"
            shift 2
            ;;
        --model)
            MODEL_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [ -z "$OUT" ]; then
    usage
fi

# Private temp working dir, OUTSIDE the repo, mode 700, auto-removed. Holds
# the swift test log (may contain whisper segment texts) and, in history
# mode, the frozen copy of history.jsonl. The --out JSONL is NOT in here —
# it lives wherever the caller pointed --out, and survives this trap.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voicetype-replay.XXXXXX")"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

TEST_LOG="$WORK_DIR/swift-test.log"
TEST_STDERR_LOG="$WORK_DIR/swift-test-stderr.log"
(umask 077; : > "$TEST_LOG"; : > "$TEST_STDERR_LOG")

export VOICETYPE_REPLAY_OUT="$OUT"
export VOICETYPE_REPLAY_BUILD_CONFIG="release"

if [ -n "$LIMIT" ]; then
    export VOICETYPE_REPLAY_LIMIT="$LIMIT"
fi
if [ "$ONLY_SAVED" = "1" ]; then
    export VOICETYPE_REPLAY_ONLY="saved"
fi
if [ -n "$PROMPT_FILE" ]; then
    export VOICETYPE_REPLAY_PROMPT_FILE="$PROMPT_FILE"
fi
if [ -n "$MODEL_OVERRIDE" ]; then
    export VOICETYPE_REPLAY_MODEL="$MODEL_OVERRIDE"
fi

if [ -n "$DIR_MODE" ]; then
    export VOICETYPE_REPLAY_DIR="$DIR_MODE"
else
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "No history.jsonl at $HISTORY_FILE" >&2
        exit 1
    fi
    FROZEN_HISTORY="$WORK_DIR/history.jsonl"
    (umask 077; cp "$HISTORY_FILE" "$FROZEN_HISTORY")
    export VOICETYPE_REPLAY_HISTORY="$FROZEN_HISTORY"
    export VOICETYPE_REPLAY_AUDIO_DIR="$AUDIO_DIR"
fi

echo "Running ReplayHarnessTests in release (first run may take a while to build)..." >&2

TEST_EXIT=0
(
    cd "$REPO_DIR"
    # --build-system native is required, not cosmetic: the default build
    # system (swiftbuild, Xcode 27) ships SwiftWhisper_whisper_metal.bundle
    # with a PRECOMPILED default.metallib instead of compiling
    # ggml-metal.metal from source. That stale/mismatched metallib runs
    # whisper's Metal decoder (used in BOTH CoreML and Metal-only policy —
    # CoreML only replaces the encoder) but produces near-empty garbage
    # output: measured WER 1.0 on the committed Tests/Fixtures/bench corpus
    # under swiftbuild, vs 0.00-0.08 under native, same audio/model/prompt.
    # build-app.sh already works around this for the shipped app the same
    # way — see its SWIFT_BUILD_ARGS. Confirmed --build-system native does
    # not conflict with a .build/ directory previously built by swiftbuild
    # (it just switches .build/.buildSystem_release and rebuilds as needed).
    swift test -c release --build-system native -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter ReplayHarnessTests
) > "$TEST_LOG" 2> "$TEST_STDERR_LOG" || TEST_EXIT=$?
# stdout/stderr captured SEPARATELY, not merged with 2>&1: when merged, the C
# library's block-buffered stdout (ggml's own fprintf/assert output) and
# Swift's line-buffered stderr interleave out of chronological order in the
# combined stream — confirmed live (2026-09-24): the crash trace appeared
# BEFORE "Test Suite ... passed" in a merged capture despite happening after
# it. Kept separate so the ordering check below is trustworthy.

# Known, investigated, harmless-to-replay atexit crash (2026-09-24): the
# vendored SwiftWhisper fork's Whisper.prepareCallbacks() leaves an
# Unmanaged.passRetained(self) outstanding after transcribe() (confirmed via
# a weak-reference probe: the Whisper instance is still alive after
# TranscriptionService.shutdown() returns true and drops its own strong
# reference), so its C context/Metal resource set is never freed by
# Whisper.deinit. ggml's own atexit teardown then aborts on
# `GGML_ASSERT([rsets->data count] == 0)` in ggml-metal-device.m — same
# assert TranscriptionService.shutdown()'s doc comment names, but this
# instance is NOT something shutdown() can prevent: it isn't the harness (or
# TranscriptionService) holding the reference, and the leak lives in a
# pinned third-party dependency this project does not own or modify. The app
# itself never hits this because AppDelegate always calls `_exit(0)` on quit
# (see AppDelegate.swift's applicationShouldTerminate), bypassing atexit
# entirely — xctest's own process teardown calls the ordinary exit(), which
# the harness cannot intercept.
#
# swift test's exit code for this crash is plain 1 (verified empirically —
# NOT the raw abort/signal code); nothing distinguishes it at the exit-code
# level from a genuine test failure. So exit 1 is only ever accepted here
# when the log PROVES it's this exact, already-investigated crash: the
# XCTest summary line for ReplayHarnessTests must show a clean pass, and
# that line must appear BEFORE the known assert text in the stdout log
# (order checked by line number, in the un-merged stdout capture).
KNOWN_ATEXIT_CRASH=0
if [ "$TEST_EXIT" -ne 0 ]; then
    # `|| true` on each: under `set -eo pipefail`, a bare assignment whose
    # command substitution ends in a no-match `grep` (exit 1) silently kills
    # the whole script right here — exactly the case a genuine (non-crash)
    # failure hits, since no "passed" line exists to find. Confirmed live:
    # without `|| true` this branch aborted with no diagnostic output at all.
    PASSED_LINE="$( (grep -n "^Test Suite 'ReplayHarnessTests' passed" "$TEST_LOG" || true) | head -n 1 | cut -d: -f1)"
    CRASH_LINE="$( (grep -n 'GGML_ASSERT(\[rsets->data count\] == 0) failed' "$TEST_LOG" || true) | head -n 1 | cut -d: -f1)"
    if [ -n "$PASSED_LINE" ] && [ -n "$CRASH_LINE" ] && [ "$PASSED_LINE" -lt "$CRASH_LINE" ]; then
        KNOWN_ATEXIT_CRASH=1
        echo "swift test exited $TEST_EXIT, but the log shows a clean ReplayHarnessTests pass " \
            "followed by the known SwiftWhisper atexit crash (GGML_ASSERT rsets) — treating as success." >&2
    fi
fi

if [ "$TEST_EXIT" -ne 0 ] && [ "$KNOWN_ATEXIT_CRASH" -ne 1 ]; then
    echo "swift test failed (exit $TEST_EXIT) — last 60 lines of stdout, then stderr:" >&2
    tail -n 60 "$TEST_LOG" >&2
    tail -n 60 "$TEST_STDERR_LOG" >&2
    exit "$TEST_EXIT"
fi

if [ ! -f "$OUT" ]; then
    echo "swift test succeeded but $OUT was not created" >&2
    exit 1
fi

# Post-checks: CoreML sanity (coreMLRequested must be backed by an actual
# "Core ML model loaded" line — otherwise this silently ran on Metal only,
# not the production path being measured) and record-count consistency.
# On success, this prints exactly what the script's default output is: the
# JSONL path, then the summary line.
python3 - "$OUT" "$TEST_LOG" <<'PYEOF'
import json
import sys

out_path, log_path = sys.argv[1], sys.argv[2]

records = 0
run_obj = None
summary = None
with open(out_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        kind = obj.get("kind")
        if kind == "run":
            run_obj = obj
        elif kind == "record":
            records += 1
        elif kind == "summary":
            summary = obj

if run_obj is None:
    print(f"ERROR: no 'run' line in {out_path}", file=sys.stderr)
    sys.exit(1)
if summary is None:
    print(f"ERROR: no 'summary' line in {out_path}", file=sys.stderr)
    sys.exit(1)
if records != summary.get("records"):
    print(
        f"ERROR: record count mismatch: {records} record line(s) vs "
        f"summary.records={summary.get('records')}",
        file=sys.stderr,
    )
    sys.exit(1)

if run_obj.get("coreMLRequested"):
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        log_text = handle.read()
    if "Core ML model loaded" not in log_text:
        print(
            "ERROR: coreMLRequested=true but 'Core ML model loaded' never appeared in the "
            "test log — this run was not on the production CoreML path",
            file=sys.stderr,
        )
        sys.exit(1)

print(out_path)
print(json.dumps(summary))
PYEOF
