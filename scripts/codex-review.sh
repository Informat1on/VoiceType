#!/usr/bin/env bash
# VoiceType — Codex CLI review wrapper
# Runs `codex review` against a commit or range with 24h result caching.
#
# Usage:
#   codex-review.sh                     Review HEAD (last commit) vs HEAD^
#   codex-review.sh <base-sha|branch>   Review HEAD vs <base>
#   codex-review.sh --range <base>..[head]
#                                     Review base..HEAD; <head> if given must equal current HEAD
#   codex-review.sh --no-cache [...]    Bypass cache, force fresh review
#   codex-review.sh --help              Show this help
#
# Exit codes:
#   0  success
#   1  codex error (non-zero exit from codex)
#   2  usage error (bad flags, not a git repo, codex not installed)
#
# Caching note:
#   `codex review` streams output to stdout; there is no built-in caching.
#   We capture the full output to a temp file, then copy to the cache path
#   on success.  Cache files live in ~/.cache/voicetype-codex-review/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$HOME/.cache/voicetype-codex-review"
CACHE_TTL_SECONDS=86400   # 24 h

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    # Print the leading comment block (lines 2..first non-comment line)
    awk '/^[^#]/{exit} NR>1{sub(/^# ?/,""); print}' "$0"
    exit 0
}

die_usage() {
    echo "error: $*" >&2
    echo "Run '$0 --help' for usage." >&2
    exit 2
}

log() {
    echo "$*" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

NO_CACHE=0
RANGE_MODE=0
BASE_REF=""
HEAD_REF="HEAD"
RANGE_RAW=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            ;;
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        --range)
            [[ $# -ge 2 ]] || die_usage "--range requires an argument (e.g. abc123..def456)"
            RANGE_RAW="$2"
            RANGE_MODE=1
            shift 2
            ;;
        --*)
            die_usage "unknown option: $1"
            ;;
        *)
            [[ -z "$BASE_REF" ]] || die_usage "unexpected argument: $1"
            BASE_REF="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------

git -C "$REPO_DIR" rev-parse --git-dir > /dev/null 2>&1 \
    || { echo "error: not inside a git repository" >&2; exit 2; }

command -v codex > /dev/null 2>&1 \
    || { echo "error: 'codex' not found in PATH" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Resolve refs
# ---------------------------------------------------------------------------

if [[ "$RANGE_MODE" -eq 1 ]]; then
    # Parse <base>..<head> — both parts are optional (default to HEAD^/HEAD)
    if [[ "$RANGE_RAW" == *..* ]]; then
        BASE_REF="${RANGE_RAW%%\.\.*}"
        HEAD_REF="${RANGE_RAW##*\.\.}"
        [[ -n "$BASE_REF" ]] || BASE_REF="HEAD^"
        [[ -n "$HEAD_REF" ]] || HEAD_REF="HEAD"
    else
        die_usage "--range value must contain '..' (e.g. abc123..def456)"
    fi
fi

# Default: last commit
if [[ -z "$BASE_REF" ]]; then
    BASE_REF="HEAD^"
fi

# Resolve to full SHAs for stable cache keys.  Peel to ^{commit} so annotated
# tags (e.g. v1.2) compare equal to the underlying commit SHA, otherwise the
# RANGE guard below would reject a tag that points at the current HEAD.
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse --verify "${HEAD_REF}^{commit}" 2>/dev/null)" \
    || die_usage "cannot resolve HEAD ref to a commit: $HEAD_REF"
BASE_SHA="$(git -C "$REPO_DIR" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null)" \
    || die_usage "cannot resolve base ref to a commit: $BASE_REF"

# `codex review` always reviews against the working tree's HEAD.  If the user
# passed --range with a head that isn't the current HEAD, the cached output
# would be labeled with a SHA that was never actually reviewed.  Refuse the
# request and tell the user what to do instead.
if [[ "$RANGE_MODE" -eq 1 ]]; then
    CURRENT_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
    if [[ "$HEAD_SHA" != "$CURRENT_HEAD" ]]; then
        die_usage "--range <base>..<head> requires <head> to be the currently checked-out HEAD ($CURRENT_HEAD), got $HEAD_SHA. Check out <head> first, or omit it to default to HEAD."
    fi
fi

# ---------------------------------------------------------------------------
# Diff size check
# ---------------------------------------------------------------------------

DIFF_STAT="$(git -C "$REPO_DIR" diff --shortstat "$BASE_SHA" "$HEAD_SHA" 2>/dev/null || true)"
if [[ -n "$DIFF_STAT" ]]; then
    # Extract total lines changed (insertions + deletions)
    INS="$(echo "$DIFF_STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    DEL="$(echo "$DIFF_STAT" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' || echo 0)"
    TOTAL_LINES=$(( INS + DEL ))
    log "diff size: $TOTAL_LINES lines changed ($DIFF_STAT)"
    if [[ "$TOTAL_LINES" -gt 2000 ]]; then
        log "warning: diff exceeds 2000 lines — Codex review may be slow or truncated"
    fi
fi

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

mkdir -p "$CACHE_DIR"
CACHE_KEY="${HEAD_SHA}-vs-${BASE_SHA}.txt"
CACHE_FILE="$CACHE_DIR/$CACHE_KEY"

if [[ "$NO_CACHE" -eq 0 ]] && [[ -f "$CACHE_FILE" ]]; then
    # Check age — stat -f on macOS, stat -c on Linux
    if stat -f "%m" "$CACHE_FILE" > /dev/null 2>&1; then
        FILE_MTIME="$(stat -f "%m" "$CACHE_FILE")"
    else
        FILE_MTIME="$(stat -c "%Y" "$CACHE_FILE")"
    fi
    NOW="$(date +%s)"
    AGE=$(( NOW - FILE_MTIME ))
    if [[ "$AGE" -lt "$CACHE_TTL_SECONDS" ]]; then
        log "cache hit: $CACHE_FILE (age ${AGE}s)"
        cat "$CACHE_FILE"
        exit 0
    else
        log "cache expired (age ${AGE}s > ${CACHE_TTL_SECONDS}s); running fresh review"
    fi
fi

# ---------------------------------------------------------------------------
# Invoke codex review
# ---------------------------------------------------------------------------

# Strategy: use --commit when reviewing exactly the commit introduced by HEAD_SHA
# (i.e. base == HEAD^), and --base otherwise for multi-commit ranges.
# `codex review --commit <SHA>` reviews the diff that commit introduced.
# `codex review --base <ref>` reviews HEAD vs that base.
#
# Unsupported configurations are rejected above (--range with head != current
# HEAD exits with code 2 and a clear message), so by the time we reach here
# HEAD_SHA is always the current HEAD.

COMMIT_TITLE="$(git -C "$REPO_DIR" log --oneline -1 "$HEAD_SHA" 2>/dev/null || true)"

if [[ "$HEAD_REF" == "HEAD" ]] && \
   [[ "$(git -C "$REPO_DIR" rev-parse HEAD^)" == "$BASE_SHA" ]]; then
    # Single-commit fast path: --commit is cleanest
    log "mode: single-commit review (--commit $HEAD_SHA)"
    CODEX_ARGS=(review --commit "$HEAD_SHA" --title "$COMMIT_TITLE")
else
    # Multi-commit or explicit range: use --base
    log "mode: range review (--base $BASE_SHA, HEAD=$HEAD_SHA)"
    CODEX_ARGS=(review --base "$BASE_SHA" --title "Range ${BASE_SHA:0:7}..${HEAD_SHA:0:7}")
fi

log "invoking: codex ${CODEX_ARGS[*]}"

TMPOUT="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$TMPOUT'" EXIT

EXIT_CODE=0
codex "${CODEX_ARGS[@]}" > "$TMPOUT" 2>&1 || EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 0 ]]; then
    log "codex exited with code $EXIT_CODE"
    cat "$TMPOUT"
    exit 1
fi

# Cache successful output
cp "$TMPOUT" "$CACHE_FILE"
CACHE_SIZE="$(wc -c < "$CACHE_FILE" | tr -d ' ')"
log "cache miss: wrote $CACHE_SIZE bytes to $CACHE_FILE"

cat "$CACHE_FILE"
