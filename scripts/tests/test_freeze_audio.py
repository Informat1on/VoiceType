#!/usr/bin/env python3
"""Unit tests for scripts/freeze-audio.py — docs/plans/pre-release-wave.md §3 T1.

stdlib unittest only. Every case uses tempfile-created directories; never
touches the app's real history.jsonl / audio directory.

Run: python3 -m unittest discover -s scripts/tests -v
"""

import io
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
_MODULE_PATH = _SCRIPTS_DIR / "freeze-audio.py"
_spec = importlib.util.spec_from_file_location("freeze_audio", _MODULE_PATH)
fa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fa)


def write_history(path, lines):
    """`lines` is a list where each element is either a dict (JSON-encoded
    as one line) or a raw string (written verbatim, for malformed-JSON
    cases)."""
    with open(path, "w", encoding="utf-8") as handle:
        for line in lines:
            if isinstance(line, str):
                handle.write(line + "\n")
            else:
                handle.write(json.dumps(line) + "\n")


def run_freeze(history_path, src_dir, dst_dir):
    argv = ["freeze-audio.py", str(history_path), str(src_dir), str(dst_dir)]
    stdout = io.StringIO()
    stderr = io.StringIO()
    with mock.patch.object(sys, "argv", argv):
        with redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = fa.main()
    return exit_code, stdout.getvalue(), stderr.getvalue()


def parse_single_json_line(stdout_text):
    lines = [line for line in stdout_text.splitlines() if line.strip()]
    return lines, (json.loads(lines[0]) if lines else None)


class FreezeAudioTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        base = Path(self._tmp.name)
        self.history_path = base / "history.jsonl"
        self.src_dir = base / "src"
        self.dst_dir = base / "dst"
        self.src_dir.mkdir()
        self.dst_dir.mkdir()

    def write_src_file(self, name, content=b"audio-bytes"):
        path = self.src_dir / name
        path.write_bytes(content)
        return path


class TestBasicCopy(FreezeAudioTestCase):
    def test_copies_valid_audio(self):
        self.write_src_file("abc.caf", b"hello-audio")
        write_history(self.history_path, [{"audioPath": "abc.caf"}])

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        lines, result = parse_single_json_line(stdout)
        self.assertEqual(len(lines), 1)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})
        self.assertEqual(stderr, "")
        dst_file = self.dst_dir / "abc.caf"
        self.assertTrue(dst_file.is_file())
        self.assertEqual(dst_file.read_bytes(), b"hello-audio")

    def test_copied_file_has_0600_permissions(self):
        src = self.write_src_file("perm.caf")
        os.chmod(src, 0o644)
        write_history(self.history_path, [{"audioPath": "perm.caf"}])

        exit_code, _stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        mode = stat.S_IMODE(os.stat(self.dst_dir / "perm.caf").st_mode)
        self.assertEqual(mode, 0o600)

    def test_name_with_space_and_unicode_copies(self):
        name = "my recording Ω 日本語.caf"
        self.write_src_file(name, b"unicode-audio")
        write_history(self.history_path, [{"audioPath": name}])

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})
        self.assertTrue((self.dst_dir / name).is_file())

    def test_duplicate_audio_path_counted_once(self):
        self.write_src_file("dup.caf", b"once")
        write_history(
            self.history_path,
            [{"audioPath": "dup.caf"}, {"audioPath": "dup.caf"}, {"audioPath": "dup.caf"}],
        )

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})

    def test_null_and_absent_audio_path_are_skipped_not_counted(self):
        write_history(
            self.history_path,
            [{"audioPath": None}, {"text": "no audioPath key at all"}],
        )

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 0, "invalid": 0})
        self.assertEqual(stderr, "")
        self.assertEqual(list(self.dst_dir.iterdir()), [])


class TestMissingSource(FreezeAudioTestCase):
    def test_missing_source_is_not_an_error(self):
        # Referenced in history, never created in src_dir — simulates the
        # documented rotation race, not a bug.
        write_history(self.history_path, [{"audioPath": "gone.caf"}])

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 1, "invalid": 0})
        self.assertEqual(list(self.dst_dir.iterdir()), [])


class TestInvalidAudioPath(FreezeAudioTestCase):
    INVALID_VALUES = [
        ("parent-relative", "../x"),
        ("nested-path", "a/b"),
        ("backslash-path", "a\\b"),
        ("trailing-parent", "foo/.."),
        ("absolute-path", "/abs.caf"),
        ("hidden-file", ".hidden"),
        ("empty-string", ""),
        ("number", 5),
        ("array", [1, 2]),
        ("object", {"a": 1}),
    ]

    def test_each_invalid_variant(self):
        for label, value in self.INVALID_VALUES:
            with self.subTest(label=label):
                tmp = tempfile.TemporaryDirectory()
                self.addCleanup(tmp.cleanup)
                base = Path(tmp.name)
                history_path = base / "history.jsonl"
                src_dir = base / "src"
                dst_dir = base / "dst"
                src_dir.mkdir()
                dst_dir.mkdir()
                write_history(history_path, [{"audioPath": value}])

                exit_code, stdout, stderr = run_freeze(history_path, src_dir, dst_dir)

                self.assertEqual(exit_code, 2, f"{label}: expected exit 2")
                _lines, result = parse_single_json_line(stdout)
                self.assertEqual(
                    result, {"copied": 0, "missing": 0, "invalid": 1}, f"{label}: unexpected counts"
                )
                self.assertIn("invalid audioPath at line 1", stderr, f"{label}: missing stderr message")
                # Privacy: the offending value itself must never be printed.
                if isinstance(value, str) and value:
                    self.assertNotIn(value, stderr, f"{label}: value leaked into stderr")
                self.assertEqual(list(dst_dir.iterdir()), [], f"{label}: something got copied")

    def test_symlink_source_is_invalid_and_not_copied(self):
        real_target = self.src_dir / "real.caf"
        real_target.write_bytes(b"real-audio")
        link_path = self.src_dir / "link.caf"
        os.symlink(real_target, link_path)
        write_history(self.history_path, [{"audioPath": "link.caf"}])

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 0, "invalid": 1})
        self.assertFalse((self.dst_dir / "link.caf").exists())

    def test_directory_source_is_invalid(self):
        (self.src_dir / "dir.caf").mkdir()
        write_history(self.history_path, [{"audioPath": "dir.caf"}])

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 0, "invalid": 1})
        self.assertFalse((self.dst_dir / "dir.caf").exists())


class TestBadJson(FreezeAudioTestCase):
    def test_malformed_json_line_exits_2(self):
        write_history(self.history_path, ["{not valid json"])

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        self.assertIn("bad json at line 1", stderr)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 0, "invalid": 0})

    def test_json_value_not_an_object_exits_2(self):
        write_history(self.history_path, ["[1, 2, 3]"])

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        self.assertIn("bad json at line 1", stderr)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 0, "missing": 0, "invalid": 0})

    def test_bad_json_does_not_stop_processing_of_other_lines(self):
        self.write_src_file("ok.caf", b"still-copied")
        write_history(
            self.history_path,
            ["{not valid json", {"audioPath": "ok.caf"}],
        )

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        self.assertIn("bad json at line 1", stderr)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})
        self.assertTrue((self.dst_dir / "ok.caf").is_file())


class TestPermissionsAndNoLeaks(FreezeAudioTestCase):
    def test_dst_is_0600_even_under_a_hostile_umask(self):
        """os.open's mode argument alone is masked by the process umask —
        under umask 0o777 it would silently yield 0o000. The real
        guarantee is the os.fchmod call on the open descriptor, which
        umask cannot touch (review r2 P2)."""
        self.write_src_file("perm.caf")
        write_history(self.history_path, [{"audioPath": "perm.caf"}])

        old_umask = os.umask(0o777)
        try:
            exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)
        finally:
            os.umask(old_umask)

        self.assertEqual(exit_code, 0)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})
        mode = stat.S_IMODE(os.stat(self.dst_dir / "perm.caf").st_mode)
        self.assertEqual(mode, 0o600)

    def test_utf8_garbage_line_is_bad_json_and_does_not_crash(self):
        self.write_src_file("ok.caf", b"still-copied")
        with open(self.history_path, "wb") as handle:
            handle.write(b"\xff\xfe not valid utf-8 at all\n")
            handle.write(json.dumps({"audioPath": "ok.caf"}).encode("utf-8") + b"\n")

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        self.assertIn("bad json at line 1", stderr)
        _lines, result = parse_single_json_line(stdout)
        self.assertEqual(result, {"copied": 1, "missing": 0, "invalid": 0})
        self.assertTrue((self.dst_dir / "ok.caf").is_file())

    def test_permission_denied_source_does_not_leak_name_in_stderr(self):
        secret_name = "very-secret-recording-name.caf"
        src = self.write_src_file(secret_name)
        os.chmod(src, 0o000)
        self.addCleanup(os.chmod, src, 0o600)  # tempdir cleanup needs read/write back
        write_history(self.history_path, [{"audioPath": secret_name}])

        exit_code, stdout, stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 2)
        self.assertEqual(stdout, "")
        self.assertNotIn(secret_name, stderr)
        self.assertNotIn(str(self.src_dir), stderr)
        self.assertFalse((self.dst_dir / secret_name).exists())


class TestStdoutFormat(FreezeAudioTestCase):
    def test_stdout_is_exactly_one_line_with_expected_keys(self):
        self.write_src_file("a.caf")
        write_history(self.history_path, [{"audioPath": "a.caf"}, {"audioPath": "missing.caf"}])

        exit_code, stdout, _stderr = run_freeze(self.history_path, self.src_dir, self.dst_dir)

        self.assertEqual(exit_code, 0)
        lines = stdout.splitlines()
        self.assertEqual(len(lines), 1)
        parsed = json.loads(lines[0])
        self.assertEqual(set(parsed.keys()), {"copied", "missing", "invalid"})
        self.assertEqual(parsed, {"copied": 1, "missing": 1, "invalid": 0})


if __name__ == "__main__":
    unittest.main()
