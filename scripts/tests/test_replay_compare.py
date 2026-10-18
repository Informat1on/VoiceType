#!/usr/bin/env python3
"""Unit tests for scripts/replay-compare.py's silenceGated support —
docs/plans/silence-gate.md T3(d).

stdlib unittest only, no real replay data. Run:
  python3 -m unittest discover -s scripts/tests -v
"""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
_MODULE_PATH = _SCRIPTS_DIR / "replay-compare.py"
_spec = importlib.util.spec_from_file_location("replay_compare", _MODULE_PATH)
rc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rc)


def base_run_header(mode="dir"):
    return {
        "startedAt": "2026-09-24T00:00:00Z", "mode": mode, "input": "bench",
        "model": "m", "coreMLRequested": False, "threads": 4, "language": "ru",
        "pipelineStamp": "stamp", "promptHash": "h", "promptSource": "s",
        "swiftWhisperRevision": "r", "buildConfig": "release", "loadMs": 1,
    }


def base_record(key, **overrides):
    """A normal, non-gated, non-error record. `silenceGated: False` is the
    default here (matching the new-schema contract that every error==None
    record carries a boolean silenceGated) — pass silenceGated=... explicitly
    to override, or use missing_silence_gated_record() to omit the key
    entirely."""
    record = {
        "key": key, "audioFile": f"{key}.caf", "audioSeconds": 1.0,
        "raw": "hello", "final": "hello", "removedTemplates": [],
        "segments": [], "transcribeMs": 50, "rtf": 20.0,
        "promptMatchesHistory": None, "comparableToHistory": None,
        "reference": None, "evalIssue": None, "history": None, "error": None,
        "silenceGated": False,
    }
    record.update(overrides)
    return record


def missing_silence_gated_record(key, **overrides):
    """Like base_record, but with the silenceGated key entirely absent —
    the shape a pre-silence-gate replay JSONL would actually have."""
    record = base_record(key, **overrides)
    del record["silenceGated"]
    return record


def error_record(key, **overrides):
    """An error record: no silenceGated key by default (the correct new-schema
    shape — absent/null on every record carrying an error)."""
    record = missing_silence_gated_record(
        key, error="read-failed: boom", audioSeconds=None,
        raw=None, final=None, removedTemplates=None, segments=None,
        transcribeMs=None, rtf=None,
    )
    record.update(overrides)
    return record


def gated_record(key, **overrides):
    fields = {
        "raw": "", "final": "", "removedTemplates": [], "segments": [],
        "transcribeMs": 0, "rtf": 0, "silenceGated": True,
    }
    fields.update(overrides)
    return base_record(key, **fields)


class ReplayCompareTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write_jsonl(self, name, run, record_lines, summary):
        path = self.tmp_path / name
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"kind": "run", **run}) + "\n")
            for rec in record_lines:
                handle.write(json.dumps({"kind": "record", **rec}) + "\n")
            handle.write(json.dumps({"kind": "summary", **summary}) + "\n")
        return path

    def write_expected_keys(self, name, keys):
        path = self.tmp_path / name
        path.write_text(json.dumps(keys), encoding="utf-8")
        return path

    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        code = 0
        with mock.patch.object(sys, "argv", ["replay-compare.py"] + argv):
            with redirect_stdout(out), redirect_stderr(err):
                try:
                    rc.main()
                except SystemExit as exc:
                    code = exc.code if isinstance(exc.code, int) else 1
        return code, out.getvalue(), err.getvalue()


class TestLegacySchema(ReplayCompareTestCase):
    """No `silenceGated` field in summary — legacy JSONL, checks skipped."""

    def test_missing_field_reports_n_a_and_exits_zero(self):
        records = [base_record("k1")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 0)
        self.assertIn("silenceGated=n/a", out)
        self.assertEqual(err, "")

    def test_legacy_gated_like_record_is_not_checked(self):
        # Even a record that LOOKS gated (final/raw empty, transcribeMs 0,
        # no silenceGated key at all) triggers no violation when summary
        # lacks the marker field.
        records = [missing_silence_gated_record("k1", final="", raw="", transcribeMs=0)]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 0)
        self.assertEqual(err, "")


class TestNewSchemaConsistent(ReplayCompareTestCase):
    def test_consistent_run_exits_zero(self):
        records = [base_record("k1"), gated_record("k2")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 2, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 0)
        self.assertIn("silenceGated=1", out)
        self.assertIn("`k2`", out)
        self.assertEqual(err, "")

    def test_error_record_with_absent_silence_gated_is_fine(self):
        records = [base_record("k1"), error_record("k2")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 2, "errors": 1, "silenceGated": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 0)
        self.assertEqual(err, "")


class TestConsistencyViolations(ReplayCompareTestCase):
    def test_gated_record_nonempty_final_violates(self):
        records = [gated_record("k1", final="oops")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("gated-final-empty", err)
        self.assertIn("'k1'", err)

    def test_gated_record_nonempty_raw_violates(self):
        records = [gated_record("k1", raw="oops")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("gated-raw-empty", err)

    def test_gated_record_nonzero_transcribe_ms_violates(self):
        records = [gated_record("k1", transcribeMs=5)]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("gated-transcribems-zero", err)

    def test_summary_count_mismatch_violates(self):
        records = [gated_record("k1")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("summary-gated-count", err)

    def test_success_record_missing_silence_gated_violates(self):
        records = [missing_silence_gated_record("k1")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("silenceGated-present-on-success", err)

    def test_error_record_with_silence_gated_present_violates(self):
        records = [error_record("k1", silenceGated=False)]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 1, "silenceGated": 0})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertIn("silenceGated-absent-on-error", err)

    def test_violation_message_never_echoes_field_values(self):
        # The leaked-value regression this check guards against: a gated
        # record whose 'final' actually holds transcript-shaped text.
        records = [gated_record("k1", final="this is definitely not empty text")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path)])
        self.assertEqual(code, 1)
        self.assertNotIn("this is definitely not empty text", err)
        self.assertNotIn("this is definitely not empty text", out)


class TestExpectGatedKeys(ReplayCompareTestCase):
    def test_matching_set_exits_zero(self):
        records = [base_record("k1"), gated_record("k2")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 2, "errors": 0, "silenceGated": 1})
        keys_path = self.write_expected_keys("expected.json", ["k2"])
        code, out, err = self.run_main([str(path), "--expect-gated-keys", str(keys_path)])
        self.assertEqual(code, 0)
        self.assertEqual(err, "")

    def test_missing_key_violates(self):
        records = [base_record("k1"), gated_record("k2")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 2, "errors": 0, "silenceGated": 1})
        keys_path = self.write_expected_keys("expected.json", ["k2", "k3"])
        code, out, err = self.run_main([str(path), "--expect-gated-keys", str(keys_path)])
        self.assertEqual(code, 1)
        self.assertIn("missing=['k3']", err)
        self.assertIn("extra=[]", err)

    def test_extra_key_violates(self):
        records = [base_record("k1"), gated_record("k2")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 2, "errors": 0, "silenceGated": 1})
        keys_path = self.write_expected_keys("expected.json", [])
        code, out, err = self.run_main([str(path), "--expect-gated-keys", str(keys_path)])
        self.assertEqual(code, 1)
        self.assertIn("missing=[]", err)
        self.assertIn("extra=['k2']", err)

    def test_works_without_new_schema_marker(self):
        # --expect-gated-keys is unconditional — it doesn't require the
        # summary.silenceGated marker (a legacy run trivially has zero
        # gated keys, so an empty expectation matches).
        records = [base_record("k1")]
        path = self.write_jsonl("run.jsonl", base_run_header(), records,
                                 {"records": 1, "errors": 0})
        keys_path = self.write_expected_keys("expected.json", [])
        code, out, err = self.run_main([str(path), "--expect-gated-keys", str(keys_path)])
        self.assertEqual(code, 0)


class TestTimingStatsExcludesGated(ReplayCompareTestCase):
    """Code review round 1, P2: gated records (transcribeMs=0, rtf=0) must
    not pull timing_stats' n/p50/p95/meanRTF toward zero."""

    def test_mixed_run_times_only_normal_records(self):
        records = [
            base_record("normal1", transcribeMs=100, rtf=10.0),
            base_record("normal2", transcribeMs=200, rtf=5.0),
            gated_record("gated1"),
            gated_record("gated2"),
        ]
        stats = rc.timing_stats(records)
        self.assertEqual(stats["n"], 2)
        self.assertEqual(stats["p50"], 100)
        self.assertEqual(stats["p95"], 200)
        self.assertAlmostEqual(stats["rtfMean"], 7.5)

    def test_legacy_records_without_field_are_all_timed(self):
        records = [
            missing_silence_gated_record("a", transcribeMs=100, rtf=10.0),
            missing_silence_gated_record("b", transcribeMs=0, rtf=0.0),
        ]
        stats = rc.timing_stats(records)
        self.assertEqual(stats["n"], 2)

    def test_report_reflects_gated_exclusion_for_a_and_b(self):
        records_a = [base_record("k1", transcribeMs=100, rtf=10.0), gated_record("k2")]
        records_b = [base_record("k1", transcribeMs=300, rtf=3.0), gated_record("k2")]
        path_a = self.write_jsonl("a.jsonl", base_run_header(), records_a,
                                   {"records": 2, "errors": 0, "silenceGated": 1})
        path_b = self.write_jsonl("b.jsonl", base_run_header(), records_b,
                                   {"records": 2, "errors": 0, "silenceGated": 1})
        code, out, err = self.run_main([str(path_a), str(path_b)])
        self.assertEqual(code, 0)
        self.assertIn("p50=100ms p95=100ms n=1", out)


if __name__ == "__main__":
    unittest.main()
