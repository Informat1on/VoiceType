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
#                      [--keep-audio <dir>]
#
# Default mode (no --dir): replays against the app's own history.jsonl — a
# FROZEN COPY of it, taken at the start of this run and held in a private
# temp directory outside the repo, since the owner may be dictating while the
# replay runs (docs/plans/quality-tools.md gotcha, session 21). Audio is
# ALSO frozen: history rotation (HistoryStore.rotateAudioIfNeeded) can delete
# the oldest records' audio out from under a running replay, so
# scripts/freeze-audio.py copies exactly the audio the frozen history.jsonl
# references into a private directory before the harness runs
# (docs/plans/pre-release-wave.md §3 T1). Without --keep-audio, that copy
# lives at $WORK_DIR/audio (mode 700, files 600) and is removed by the exit
# trap along with the rest of $WORK_DIR. With `--keep-audio <dir>` (history
# mode only — rejected together with --dir), the copy is made at <dir>
# instead: <dir> must not already exist (its parent must exist and must not
# be inside this repo), is created with `mkdir -m 700`, and — this is the
# point of the flag — is kept on disk after this script exits, on ANY exit
# path (success, swift test failure, SIGINT/SIGTERM/SIGHUP) ONCE THE FREEZE
# ITSELF HAS SUCCEEDED. If this script is interrupted (including by a
# signal) before the freeze finishes, the partial copy it created is
# removed instead — never left half-written. Deleting the completed copy
# afterwards is the caller's job. Use it
# to keep the same audio around for a later `shadow-analysis.py run.jsonl
# --audio-dir <dir>` pass over this run's output.
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
KEEP_AUDIO=""
# Set to 1 only immediately after THIS run's own `mkdir -m 700 "$KEEP_AUDIO"`
# succeeds — never based on merely observing the directory exists, since a
# racing process could have created it after our own pre-check and before
# our mkdir (which would then fail, leaving someone else's directory on
# disk for on_exit to find).
KEEP_AUDIO_CREATED=0
# Set to 1 only once freeze-audio.py has succeeded for THIS run's
# --keep-audio directory — see the on_exit trap below.
FREEZE_COMPLETE=0

usage() {
    echo "Usage: $0 --out <file> [--only-saved] [--limit N] [--dir <dir>]" \
        "[--prompt-file <file>] [--model <path>] [--keep-audio <dir>]" >&2
    echo "  --keep-audio <dir>  History mode only (not with --dir). <dir> must" \
        "not already exist; it is created (mkdir -m 700) and kept on disk" \
        "after this script exits, on any outcome — delete it yourself." >&2
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
        --keep-audio)
            if [ $# -lt 2 ]; then
                echo "--keep-audio requires a <dir> argument" >&2
                usage
            fi
            KEEP_AUDIO="$2"
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

# --- Argument validation (ALL of it, before anything touches history.jsonl) ---

if [ -n "$KEEP_AUDIO" ] && [ -n "$DIR_MODE" ]; then
    echo "--keep-audio is only valid in history mode (not with --dir)" >&2
    usage
fi

if [ -n "$KEEP_AUDIO" ]; then
    if [ -e "$KEEP_AUDIO" ]; then
        echo "--keep-audio target already exists: $KEEP_AUDIO" >&2
        exit 1
    fi
    KEEP_AUDIO_PARENT="$(dirname "$KEEP_AUDIO")"
    if [ ! -d "$KEEP_AUDIO_PARENT" ]; then
        echo "--keep-audio target's parent directory does not exist: $KEEP_AUDIO_PARENT" >&2
        exit 1
    fi
    KEEP_AUDIO_PARENT_ABS="$(cd "$KEEP_AUDIO_PARENT" && pwd -P)"
    KEEP_AUDIO_ABS="$KEEP_AUDIO_PARENT_ABS/$(basename "$KEEP_AUDIO")"
    case "$KEEP_AUDIO_ABS" in
        "$REPO_DIR"|"$REPO_DIR"/*)
            echo "--keep-audio target must be outside the repository: $KEEP_AUDIO_ABS" >&2
            exit 1
            ;;
    esac
fi

# Private temp working dir, OUTSIDE the repo, mode 700, auto-removed. Holds
# the swift test log (may contain whisper segment texts) and, in history
# mode, the frozen copy of history.jsonl. The --out JSONL is NOT in here —
# it lives wherever the caller pointed --out, and survives this trap.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voicetype-replay.XXXXXX")"
chmod 700 "$WORK_DIR"

# on_exit always removes WORK_DIR. It ALSO removes the --keep-audio
# directory, but ONLY when BOTH: (a) KEEP_AUDIO_CREATED is 1 — this run's
# own `mkdir` is what created it, not some other process racing us — and
# (b) FREEZE_COMPLETE is still 0 — the freeze this run started never
# finished. Once freeze-audio.py has succeeded, FREEZE_COMPLETE flips to 1
# and this directory is kept on any further exit, per --keep-audio's
# contract. The INT/TERM/HUP traps below just call `exit`, which always
# runs the EXIT trap in bash — so a signal mid-freeze is cleaned up the
# same as a normal failure.
on_exit() {
    rm -rf "$WORK_DIR"
    if [ -n "$KEEP_AUDIO" ] && [ "$KEEP_AUDIO_CREATED" -eq 1 ] && [ "$FREEZE_COMPLETE" -ne 1 ] \
        && [ -e "$KEEP_AUDIO" ]; then
        rm -rf "$KEEP_AUDIO"
    fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

    # Freeze the audio the frozen history.jsonl references, alongside it —
    # history.jsonl is a point-in-time copy, but AUDIO_DIR is still live and
    # subject to rotation for as long as this script runs
    # (docs/plans/pre-release-wave.md §3 T1).
    if [ -n "$KEEP_AUDIO" ]; then
        AUDIO_COPY_DIR="$KEEP_AUDIO"
    else
        AUDIO_COPY_DIR="$WORK_DIR/audio"
    fi
    mkdir -m 700 "$AUDIO_COPY_DIR"
    # Only reached if the mkdir above actually succeeded — i.e. this run,
    # not a racing process, is what created AUDIO_COPY_DIR. See
    # KEEP_AUDIO_CREATED's declaration and on_exit above.
    if [ -n "$KEEP_AUDIO" ]; then
        KEEP_AUDIO_CREATED=1
    fi

    FREEZE_EXIT=0
    FREEZE_OUTPUT="$("$SCRIPT_DIR/freeze-audio.py" "$FROZEN_HISTORY" "$AUDIO_DIR" "$AUDIO_COPY_DIR")" || FREEZE_EXIT=$?
    if [ "$FREEZE_EXIT" -ne 0 ]; then
        echo "freeze-audio.py failed (exit $FREEZE_EXIT)" >&2
        # on_exit removes AUDIO_COPY_DIR itself (KEEP_AUDIO_CREATED=1,
        # FREEZE_COMPLETE still 0) — no separate rm needed here.
        exit "$FREEZE_EXIT"
    fi

    # From here on, a --keep-audio directory is a COMPLETE freeze, not a
    # partial one — on_exit must stop removing it on any later exit
    # (swift test failure, SIGINT, ...), which is the whole point of the
    # flag.
    FREEZE_COMPLETE=1

    FREEZE_STATS="$(python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["copied"], d["missing"])' "$FREEZE_OUTPUT")"
    read -r FROZEN_COPIED FROZEN_MISSING <<< "$FREEZE_STATS"
    AUDIO_COPY_DIR_ABS="$(cd "$AUDIO_COPY_DIR" && pwd -P)"
    echo "frozen audio: copied=$FROZEN_COPIED missing=$FROZEN_MISSING dir=$AUDIO_COPY_DIR_ABS" >&2

    export VOICETYPE_REPLAY_AUDIO_DIR="$AUDIO_COPY_DIR_ABS"
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
# it. Kept separate so each stream's tail below is in its own true order
# (order BETWEEN the two streams is not recoverable either way).

# swift test's exit code is the verdict: any nonzero exit is a failure,
# diagnosed by the stdout/stderr tails below.
if [ "$TEST_EXIT" -ne 0 ]; then
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
