#!/usr/bin/env python3
"""freeze-audio.py — copy the audio referenced by a frozen history.jsonl into
a private directory, so a replay run doesn't read from the app's live
audio/ directory while it can still be rotated out from under it.
docs/plans/pre-release-wave.md §3 T1.

Usage:
  freeze-audio.py <history.jsonl> <src-audio-dir> <dst-dir>

Reads history.jsonl line by line and collects each record's `audioPath`.
A missing key or `null` means "no audio for this record" and is silently
skipped — not an error. Record text is never printed or logged.

`audioPath` is only accepted when it is a string AND a bare basename: not
empty, contains no `/` or `\\`, is not `.` or `..`, and does not start with
`.` (this also rejects any absolute path, since those always contain `/`).
Any other JSON type (number, array, object, bool) or a string that fails
this check is `invalid`; nothing is copied for it, and stderr gets
`invalid audioPath at line N` (the value itself is never printed). A line
that isn't valid JSON, whose JSON value isn't an object, or that isn't
valid UTF-8, is a separate failure class: `bad json at line N`, and forces
exit 2, but does not stop the run — remaining lines are still processed and
the summary is still printed (see PI plan-review r2: bad lines must not
silently truncate the copy). The file is read as raw bytes and decoded one
line at a time specifically so a UTF-8 error on one line can't abort or
misalign the read of the rest.

Processing is two-phase:
  1. Walk every line once, classifying each `audioPath` value as skipped
     (absent/null), invalid (wrong type or shape — counted per LINE, no
     dedup: two invalid lines count as two), or valid (added to a set of
     unique basenames — no normalization, compared as plain strings).
  2. For each UNIQUE valid basename, exactly one copy attempt is made (in
     sorted order, only so error messages can name a stable ordinal — see
     below), and its outcome lands in exactly one of `copied` / `missing` /
     `invalid`. So `copied + missing + invalid_from_phase_2` always equals
     the number of unique valid basenames; duplicate `audioPath` values
     across records are copied (and counted) once.

Source resolution for phase 2, per name — no path ever follows a symlink,
including under a TOCTOU race:
  - Open the source with `os.open(path, O_RDONLY | O_NOFOLLOW)`. Not found
    -> `missing` (not an error: the app's history rotation can delete audio
    between freezing history.jsonl and this copy step — a normal race, see
    below). The last component is a symlink (O_NOFOLLOW -> ELOOP) ->
    `invalid`. Any other failure to open (e.g. permission denied) is fatal.
  - `os.fstat` the open descriptor (not `os.lstat` the path — no window
    between checking and opening for a swap to matter). Not a regular file
    -> `invalid`.
  - Create the destination with
    `os.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)`, then
    `os.fchmod` the open descriptor to 0o600 — the `os.open` mode argument
    alone is not a guarantee, since the process umask can mask bits out of
    it (an unusual umask like 0o777 would silently yield 0o000); `fchmod`
    on the descriptor is immune to umask and to any path-swap race. A
    failing `fchmod` is fatal like any other I/O error in this phase: the
    partially-written destination is removed.
  - Copy bytes between the two descriptors. If the source disappears after
    the open (rare, but the same descriptor can still hit an I/O error),
    or the copy itself fails, the partially-written destination file is
    removed and the run is fatal.
  - Any other I/O error at any step is fatal: exit 2 (stdout ends up empty
    in this case — the one-line summary is only guaranteed when the run
    reaches its end normally, including the "exit 2 because of
    invalid/bad-json lines" case above). Fatal messages never print a path
    or filename — only the errno and the 1-based ordinal (position in the
    sorted set of unique valid names) of the entry being copied, so a
    stderr log can't leak which recording failed.

Rotation race, documented semantics: the app writes new audio under fresh
`<UUID>.caf` names and deletes old ones; it never overwrites an existing
file's content in place. So the only race this script can hit is "the file
is gone by copy time" (-> `missing`); a file this script does manage to
open is never a half-written replacement of a different recording.

stdout is exactly one line, printed once processing reaches the end:
  {"copied": N, "missing": M, "invalid": K}
Exit 0 only if invalid == 0 and there were no bad-JSON lines and no I/O
errors; otherwise exit 2.

stdlib only.
"""
import errno
import json
import os
import shutil
import stat
import sys


def is_valid_basename(value):
    """True only for a bare, safe basename string — see module docstring."""
    if not isinstance(value, str):
        return False
    if value == "":
        return False
    if "/" in value or "\\" in value:
        return False
    if value in (".", ".."):
        return False
    if value.startswith("."):
        return False
    return True


class FatalCopyError(Exception):
    """Raised for any I/O failure during phase 2 that isn't the documented
    missing/invalid outcome. Carries only an errno and an ordinal — never a
    path or filename, so the caller can report it without leaking which
    recording was involved."""

    def __init__(self, errno_value, ordinal):
        super().__init__(errno_value, ordinal)
        self.errno_value = errno_value
        self.ordinal = ordinal


def copy_one(src_dir, dst_dir, name, ordinal):
    """Copies exactly one basename from src_dir to dst_dir. Returns
    "copied", "missing", or "invalid". Raises FatalCopyError for any other
    I/O error. Never follows a symlink for either the source or the
    destination path."""
    src_path = os.path.join(src_dir, name)
    dst_path = os.path.join(dst_dir, name)

    try:
        src_fd = os.open(src_path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "missing"
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return "invalid"
        raise FatalCopyError(exc.errno, ordinal) from None

    try:
        try:
            st = os.fstat(src_fd)
        except OSError as exc:
            raise FatalCopyError(exc.errno, ordinal) from None

        if not stat.S_ISREG(st.st_mode):
            return "invalid"

        try:
            dst_fd = os.open(
                dst_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
        except OSError as exc:
            raise FatalCopyError(exc.errno, ordinal) from None

        try:
            try:
                # os.open's mode argument is masked by the process umask
                # (a hostile/unusual umask, e.g. 0o777, would silently
                # yield 0o000 with no chmod to correct it) — os.fchmod on
                # the still-open descriptor is NOT subject to umask and is
                # immune to any TOCTOU path-swap, so it is the actual
                # permission guarantee, not the os.open mode argument.
                os.fchmod(dst_fd, 0o600)
                with os.fdopen(src_fd, "rb", closefd=False) as src_f, os.fdopen(
                    dst_fd, "wb", closefd=False
                ) as dst_f:
                    shutil.copyfileobj(src_f, dst_f)
            except OSError as exc:
                raise FatalCopyError(exc.errno, ordinal) from None
        except FatalCopyError:
            os.close(dst_fd)
            try:
                os.remove(dst_path)
            except OSError:
                pass
            raise
        else:
            os.close(dst_fd)
    finally:
        os.close(src_fd)

    return "copied"


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: freeze-audio.py <history.jsonl> <src-audio-dir> <dst-dir>",
            file=sys.stderr,
        )
        return 2

    history_path, src_dir, dst_dir = sys.argv[1], sys.argv[2], sys.argv[3]

    invalid_lines = 0
    bad_json_lines = 0
    valid_names = set()

    try:
        with open(history_path, "rb") as handle:
            for lineno, raw_bytes in enumerate(handle, start=1):
                raw_bytes = raw_bytes.rstrip(b"\r\n")
                if not raw_bytes.strip():
                    continue

                try:
                    line = raw_bytes.decode("utf-8")
                except UnicodeDecodeError:
                    print(f"bad json at line {lineno}", file=sys.stderr)
                    bad_json_lines += 1
                    continue

                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    print(f"bad json at line {lineno}", file=sys.stderr)
                    bad_json_lines += 1
                    continue
                if not isinstance(obj, dict):
                    print(f"bad json at line {lineno}", file=sys.stderr)
                    bad_json_lines += 1
                    continue

                audio_path = obj.get("audioPath")
                if audio_path is None:
                    continue

                if not is_valid_basename(audio_path):
                    print(f"invalid audioPath at line {lineno}", file=sys.stderr)
                    invalid_lines += 1
                    continue

                valid_names.add(audio_path)
    except OSError as exc:
        print(f"cannot read history file (errno {exc.errno})", file=sys.stderr)
        return 2

    copied = 0
    missing = 0
    invalid_targets = 0

    for ordinal, name in enumerate(sorted(valid_names), start=1):
        try:
            outcome = copy_one(src_dir, dst_dir, name, ordinal)
        except FatalCopyError as exc:
            print(
                f"I/O error (errno {exc.errno_value}) copying audio entry #{exc.ordinal}",
                file=sys.stderr,
            )
            return 2

        if outcome == "copied":
            copied += 1
        elif outcome == "missing":
            missing += 1
        else:
            invalid_targets += 1

    total_invalid = invalid_lines + invalid_targets
    result = {"copied": copied, "missing": missing, "invalid": total_invalid}
    print(json.dumps(result))

    if total_invalid == 0 and bad_json_lines == 0:
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
