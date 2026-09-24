#!/usr/bin/env python3
"""Unit tests for scripts/shadow-analysis.py — docs/plans/shadow-vad.md T3.

stdlib unittest only. External programs (afconvert, whisper-vad-speech-segments)
are always replaced by mocks — no real audio, no real Silero model is used.

Run: python3 -m unittest discover -s scripts/tests -v
"""

import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
_MODULE_PATH = _SCRIPTS_DIR / "shadow-analysis.py"
_spec = importlib.util.spec_from_file_location("shadow_analysis", _MODULE_PATH)
sa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sa)


def make_stdout_proc(returncode, stdout):
    return subprocess.CompletedProcess(args=["vad"], returncode=returncode, stdout=stdout, stderr="metal noise")


class TestVadParser(unittest.TestCase):
    """docs/plans/shadow-vad.md T3: 'парсер вывода Silero'."""

    def test_hundredths_converted_to_ms(self):
        stdout = "Detected 1 speech segments:\nSpeech segment 0: start = 93.00, end = 541.00\n"
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, stdout)):
            result = sa.run_vad("util", "model", 0.5, "file.wav")
        self.assertEqual(result, [(930, 5410)])

    def test_two_segments(self):
        stdout = (
            "Detected 2 speech segments:\n"
            "Speech segment 0: start = 10.00, end = 20.00\n"
            "Speech segment 1: start = 30.50, end = 40.25\n"
        )
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, stdout)):
            result = sa.run_vad("util", "model", 0.3, "file.wav")
        self.assertEqual(result, [(100, 200), (305, round(40.25 * 10))])

    def test_zero_segments_ok(self):
        stdout = "Detected 0 speech segments:\n"
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, stdout)):
            result = sa.run_vad("util", "model", 0.5, "file.wav")
        self.assertEqual(result, [])

    def test_garbage_line_causes_count_mismatch(self):
        stdout = "Detected 1 speech segments:\nnot a segment line at all\n"
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, stdout)):
            with self.assertRaises(sa.AnalysisError):
                sa.run_vad("util", "model", 0.5, "file.wav")

    def test_empty_stdout_raises(self):
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, "")):
            with self.assertRaises(sa.AnalysisError):
                sa.run_vad("util", "model", 0.5, "file.wav")

    def test_nonzero_exit_raises(self):
        stdout = "Detected 1 speech segments:\nSpeech segment 0: start = 1.00, end = 2.00\n"
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(1, stdout)):
            with self.assertRaises(sa.AnalysisError):
                sa.run_vad("util", "model", 0.5, "file.wav")

    def test_segment_count_more_than_header(self):
        stdout = (
            "Detected 1 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "Speech segment 1: start = 3.00, end = 4.00\n"
        )
        with mock.patch.object(sa.subprocess, "run", return_value=make_stdout_proc(0, stdout)):
            with self.assertRaises(sa.AnalysisError):
                sa.run_vad("util", "model", 0.5, "file.wav")

    # -- P1 review additions: strict line-by-line parsing (parse_vad_output) --

    def test_garbage_line_between_valid_segments_raises(self):
        stdout = (
            "Detected 2 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "this line is garbage, not a segment\n"
            "Speech segment 1: start = 3.00, end = 4.00\n"
        )
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_skipped_index_raises(self):
        stdout = (
            "Detected 2 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "Speech segment 2: start = 3.00, end = 4.00\n"
        )
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_repeated_index_raises(self):
        stdout = (
            "Detected 2 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "Speech segment 0: start = 3.00, end = 4.00\n"
        )
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_start_greater_than_end_raises(self):
        stdout = "Detected 1 speech segments:\nSpeech segment 0: start = 5.00, end = 2.00\n"
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_second_detected_line_raises(self):
        stdout = (
            "Detected 1 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "Detected 1 speech segments:\n"
        )
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_segment_before_detected_header_raises(self):
        stdout = "Speech segment 0: start = 1.00, end = 2.00\nDetected 1 speech segments:\n"
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_detected_header_after_segments_raises(self):
        # A well-formed run followed by a second (bogus) header line.
        stdout = (
            "Detected 1 speech segments:\n"
            "Speech segment 0: start = 1.00, end = 2.00\n"
            "Detected 2 speech segments:\n"
        )
        with self.assertRaises(sa.AnalysisError):
            sa.parse_vad_output(stdout)

    def test_blank_lines_allowed(self):
        stdout = "\nDetected 1 speech segments:\n\nSpeech segment 0: start = 1.00, end = 2.00\n\n"
        self.assertEqual(sa.parse_vad_output(stdout), [(10, 20)])


class TestOverlapFraction(unittest.TestCase):
    def test_full_overlap(self):
        self.assertEqual(sa.overlap_fraction(0, 1000, [(0, 1000)]), 1.0)

    def test_partial_overlap(self):
        self.assertAlmostEqual(sa.overlap_fraction(0, 1000, [(500, 1500)]), 0.5)

    def test_zero_overlap(self):
        self.assertEqual(sa.overlap_fraction(0, 1000, [(2000, 3000)]), 0.0)

    def test_zero_length_segment(self):
        self.assertEqual(sa.overlap_fraction(500, 500, [(0, 1000)]), 0.0)

    def test_multiple_intervals_summed(self):
        self.assertAlmostEqual(sa.overlap_fraction(0, 1000, [(0, 200), (800, 1000)]), 0.4)


class TestNormalizeIntervals(unittest.TestCase):
    """docs/plans/shadow-vad.md T3 (P1 review): overlapping/out-of-bounds
    Silero intervals must be merged/clipped before overlap_fraction or
    speech_fraction ever see them, or coverage can exceed 1.0."""

    def test_overlapping_intervals_merged_before_overlap_fraction(self):
        merged = sa.normalize_intervals([(0, 600), (400, 1000)], audio_ms=1000)
        self.assertEqual(merged, [(0, 1000)])
        self.assertEqual(sa.overlap_fraction(0, 1000, merged), 1.0)

    def test_touching_intervals_merged(self):
        merged = sa.normalize_intervals([(0, 500), (500, 1000)], audio_ms=1000)
        self.assertEqual(merged, [(0, 1000)])

    def test_out_of_order_input_sorted(self):
        merged = sa.normalize_intervals([(800, 1000), (0, 200)], audio_ms=1000)
        self.assertEqual(merged, [(0, 200), (800, 1000)])

    def test_clipped_to_audio_bounds(self):
        merged = sa.normalize_intervals([(-500, 200), (900, 5000)], audio_ms=1000)
        self.assertEqual(merged, [(0, 200), (900, 1000)])

    def test_speech_fraction_never_exceeds_one(self):
        merged = sa.normalize_intervals([(0, 600), (400, 1000), (700, 1500)], audio_ms=1000)
        frac = sa.speech_fraction(merged, 1000)
        self.assertLessEqual(frac, 1.0)
        self.assertEqual(frac, 1.0)

    def test_degenerate_interval_dropped(self):
        merged = sa.normalize_intervals([(500, 500), (0, 100)], audio_ms=1000)
        self.assertEqual(merged, [(0, 100)])


class TestNormalizeRepeat(unittest.TestCase):
    def test_lowercase_yo_punctuation_whitespace(self):
        self.assertEqual(sa.normalize_repeat("Ёлка,  В  Лесу!!!"), "елка в лесу")

    def test_empty_stays_empty(self):
        self.assertEqual(sa.normalize_repeat("   "), "")

    def test_underscore_treated_as_punctuation(self):
        # P2 review: Python's \w includes '_', so a naive [^\w\s] class would
        # leave "да_да" as a single token instead of splitting it like any
        # other punctuation-joined pair.
        self.assertEqual(sa.normalize_repeat("да_да"), "да да")


class TestDupSegment(unittest.TestCase):
    def test_single_token_pair(self):
        pairs = sa.compute_dup_pairs(["да", "да", "нет"])
        self.assertEqual(pairs, [(0, 1, "single")])

    def test_multi_token_pair(self):
        pairs = sa.compute_dup_pairs(["привет мир", "привет мир"])
        self.assertEqual(pairs, [(0, 1, "multi")])

    def test_empty_texts_never_dup(self):
        pairs = sa.compute_dup_pairs(["", "", "да"])
        self.assertEqual(pairs, [])

    def test_no_dup_when_different(self):
        pairs = sa.compute_dup_pairs(["да", "нет"])
        self.assertEqual(pairs, [])


class TestLoopDetector(unittest.TestCase):
    def test_two_repeats_not_loop(self):
        self.assertFalse(sa.detect_loop(["да", "да"]))

    def test_three_single_token_repeats_not_loop(self):
        self.assertFalse(sa.detect_loop(["да", "да", "да"]))

    def test_four_single_token_repeats_is_loop(self):
        self.assertTrue(sa.detect_loop(["да", "да", "да", "да"]))

    def test_ngram_times_three_is_loop(self):
        self.assertTrue(sa.detect_loop(["a", "b", "a", "b", "a", "b"]))

    def test_ngram_times_two_not_loop(self):
        self.assertFalse(sa.detect_loop(["a", "b", "a", "b"]))

    def test_six_token_ngram_times_three(self):
        tokens = list("abcdef") * 3
        self.assertTrue(sa.detect_loop(tokens))

    def test_unrelated_tokens_not_loop(self):
        self.assertFalse(sa.detect_loop(["один", "два", "три", "четыре", "пять"]))


class TestEdgeTemplate(unittest.TestCase):
    def test_strict_template_at_first(self):
        norm = sa.normalize_repeat("Продолжение следует.")
        strict, risky = sa.edge_flags(norm, is_first=True, is_last=False)
        self.assertTrue(strict)
        self.assertFalse(risky)

    def test_strict_template_at_last(self):
        norm = sa.normalize_repeat("Продолжение следует.")
        strict, risky = sa.edge_flags(norm, is_first=False, is_last=True)
        self.assertTrue(strict)

    def test_middle_never_flags_even_if_template(self):
        norm = sa.normalize_repeat("Продолжение следует.")
        strict, risky = sa.edge_flags(norm, is_first=False, is_last=False)
        self.assertFalse(strict)
        self.assertFalse(risky)

    def test_risky_candidate(self):
        norm = sa.normalize_repeat("Спасибо")
        strict, risky = sa.edge_flags(norm, is_first=True, is_last=False)
        self.assertFalse(strict)
        self.assertTrue(risky)

    def test_risky_candidate_subscribe(self):
        norm = sa.normalize_repeat("Подписывайтесь на канал")
        strict, risky = sa.edge_flags(norm, is_first=False, is_last=True)
        self.assertTrue(risky)
        self.assertFalse(strict)

    def test_non_template_no_flag(self):
        norm = sa.normalize_repeat("Обычная речь")
        strict, risky = sa.edge_flags(norm, is_first=True, is_last=False)
        self.assertFalse(strict)
        self.assertFalse(risky)


class TestFilterSplitReplica(unittest.TestCase):
    """docs/plans/shadow-vad.md T3: 'реплика фильтра по позициям'."""

    def test_prefix_removed(self):
        texts = ["Продолжение следует.", "Реальный текст"]
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, ["Реальный текст"])
        self.assertEqual(removed, ["Продолжение следует."])
        self.assertTrue(sa.is_removed_index(0, bounds))
        self.assertFalse(sa.is_removed_index(1, bounds))

    def test_suffix_removed(self):
        texts = ["Реальный текст", "Продолжение следует."]
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, ["Реальный текст"])
        self.assertEqual(removed, ["Продолжение следует."])
        self.assertFalse(sa.is_removed_index(0, bounds))
        self.assertTrue(sa.is_removed_index(1, bounds))

    def test_both_edges_removed_middle_kept(self):
        texts = ["Продолжение следует.", "Реальный текст", "Продолжение следует."]
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, ["Реальный текст"])
        self.assertEqual(removed, ["Продолжение следует.", "Продолжение следует."])
        self.assertTrue(sa.is_removed_index(0, bounds))
        self.assertFalse(sa.is_removed_index(1, bounds))
        self.assertTrue(sa.is_removed_index(2, bounds))

    def test_same_template_at_edge_and_middle_only_edge_removed(self):
        texts = ["Продолжение следует.", "Продолжение следует.", "Настоящая речь", "хвост"]
        # is_template = [T, T, F, F] -> leading=2, trailing=0 -> keep_start=2, keep_end=4
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, ["Настоящая речь", "хвост"])
        self.assertEqual(removed, ["Продолжение следует.", "Продолжение следует."])

    def test_template_in_strict_middle_protected(self):
        texts = ["Настоящая речь", "Продолжение следует.", "Другая речь"]
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, texts)
        self.assertEqual(removed, [])
        for i in range(3):
            self.assertFalse(sa.is_removed_index(i, bounds))

    def test_all_templates_all_removed(self):
        texts = ["Продолжение следует.", "Продолжение следует."]
        kept, removed, bounds = sa.filter_split(texts)
        self.assertEqual(kept, [])
        self.assertEqual(removed, texts)
        self.assertTrue(sa.is_removed_index(0, bounds))
        self.assertTrue(sa.is_removed_index(1, bounds))

    def test_empty_segments(self):
        kept, removed, bounds = sa.filter_split([])
        self.assertEqual((kept, removed), ([], []))


# ---------------------------------------------------------------------------
# main()-level coverage / exit-code / privacy tests. External programs are
# always mocked; no real audio and no real VAD model are used.
# ---------------------------------------------------------------------------

def _fake_decode_to_wav(src_path, dst_path):
    pass  # no-op: read_pcm16_mono is mocked too, so dst_path's content is never read


def _fake_read_pcm16_mono(wav_path):
    from array import array
    return array("h", [1000] * 16000), 16000


def _fake_run_vad(utility_path, model_path, threshold, wav_path):
    return [(0, 900)]


def _fake_energy_stats(samples, framerate):
    return 0.05, 0.06, 0.07  # well above the default RMS gates (0.002/0.005/0.01)


class ShadowAnalysisMainTestCase(unittest.TestCase):
    """Base class wiring up a hermetic --vad-model / utility path and the
    mocked external-program call sites shared by every main()-driving test."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self._tmp.name)

        self.fake_model = self.tmp_path / "fake-model.bin"
        self.fake_model.write_bytes(b"not-a-real-model")

        self.fake_utility = self.tmp_path / "fake-vad-utility"
        self.fake_utility.write_text("#!/bin/sh\nexit 0\n")
        self.fake_utility.chmod(self.fake_utility.stat().st_mode | stat.S_IEXEC)

        self.audio_dir = self.tmp_path / "audio"
        self.audio_dir.mkdir()

        self._patches = [
            mock.patch.object(sa, "DEFAULT_VAD_UTILITY", self.fake_utility),
            mock.patch.object(sa, "decode_to_wav", _fake_decode_to_wav),
            mock.patch.object(sa, "read_pcm16_mono", _fake_read_pcm16_mono),
            mock.patch.object(sa, "run_vad", _fake_run_vad),
            mock.patch.object(sa, "energy_stats", _fake_energy_stats),
        ]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)

        self.addCleanup(self._tmp.cleanup)

    def write_jsonl(self, name, run, record_lines, summary):
        path = self.tmp_path / name
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps({"kind": "run", **run}) + "\n")
            for rec in record_lines:
                f.write(json.dumps({"kind": "record", **rec}) + "\n")
            f.write(json.dumps({"kind": "summary", **summary}) + "\n")
        return path

    def touch_audio(self, name):
        (self.audio_dir / name).write_bytes(b"")

    def run_main(self, argv):
        """Runs sa.main() with argv, capturing stdout/stderr and exit code."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["shadow-analysis.py"] + argv):
            with redirect_stdout(out), redirect_stderr(err):
                with self.assertRaises(SystemExit) as cm:
                    sa.main()
        return cm.exception.code, out.getvalue(), err.getvalue()

    def base_run_header(self, mode="dir"):
        return {
            "startedAt": "2026-09-24T00:00:00Z", "mode": mode, "input": "bench",
            "model": "m", "coreMLRequested": False, "threads": 4, "language": "ru",
            "pipelineStamp": "stamp", "promptHash": "h", "promptSource": "s",
            "swiftWhisperRevision": "r", "buildConfig": "release", "loadMs": 1,
        }


class TestCoverage(ShadowAnalysisMainTestCase):
    def test_missing_audio_file_is_analysis_error_exit1(self):
        self.touch_audio("ok.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "missing", "audioFile": "missing.wav", "audioSeconds": 1.0,
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [{"text": "text2", "startMs": 0, "endMs": 500}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("analyzed=1", out)

    def test_analyzed_zero_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)

    def test_summary_records_mismatch_exit2(self):
        records = [{
            "key": "a", "audioFile": "a.wav", "audioSeconds": 1.0,
            "raw": "x", "final": "x", "removedTemplates": None,
            "segments": [{"text": "x", "startMs": 0, "endMs": 100}],
        }]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)

    def test_duplicate_key_exit2(self):
        rec = {
            "key": "dup", "audioFile": "a.wav", "audioSeconds": 1.0,
            "raw": "x", "final": "x", "removedTemplates": None,
            "segments": [{"text": "x", "startMs": 0, "endMs": 100}],
        }
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [rec, dict(rec)],
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)

    def test_empty_audio_file_is_analysis_error_not_skip(self):
        # docs/plans/shadow-vad.md T3 (P1 review): audioFile == "" must NOT
        # be counted as noAudioField (that's reserved for missing/None) — it
        # is a broken record, an analysis error.
        self.touch_audio("ok.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "empty-audio-file", "audioFile": "", "audioSeconds": 1.0,
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [{"text": "text2", "startMs": 0, "endMs": 500}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("noAudioField=0", out)
        self.assertIn("analyzed=1", out)

    def test_filter_replica_mismatch_is_analysis_error(self):
        self.touch_audio("ok.wav")
        self.touch_audio("bad.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                # filter_split would compute removed=["Продолжение следует."],
                # but the JSONL claims nothing was removed -> mismatch.
                "key": "mismatch", "audioFile": "bad.wav", "audioSeconds": 1.0,
                "raw": "Продолжение следует. реальная речь",
                "final": "реальная речь", "removedTemplates": None,
                "segments": [
                    {"text": "Продолжение следует.", "startMs": 0, "endMs": 500},
                    {"text": "реальная речь", "startMs": 500, "endMs": 1000},
                ],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)

    def test_null_segment_is_analysis_error_no_traceback(self):
        # docs/plans/shadow-vad.md T3 (P2 review): a malformed `segments`
        # element must become a clean AnalysisError, never an unhandled
        # AttributeError/traceback.
        self.touch_audio("ok.wav")
        self.touch_audio("bad.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "null-segment", "audioFile": "bad.wav", "audioSeconds": 1.0,
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [None],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("analyzed=1", out)
        self.assertNotIn("Traceback", err)

    def test_non_numeric_start_ms_is_analysis_error_no_traceback(self):
        self.touch_audio("ok.wav")
        self.touch_audio("bad.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "bad-startms", "audioFile": "bad.wav", "audioSeconds": 1.0,
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [{"text": "text2", "startMs": "a", "endMs": 500}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("analyzed=1", out)
        self.assertNotIn("Traceback", err)


class TestReportDenominators(ShadowAnalysisMainTestCase):
    """docs/plans/shadow-vad.md T3 (P1 review): 'fixed=' and the crosstab
    line must print BOTH denominators (share of flagged/repeat-flagged, and
    share of all analyzed), explicitly labeled, never just one."""

    def test_main_table_and_crosstab_print_both_denominators(self):
        self.touch_audio("plain.wav")
        self.touch_audio("template.wav")
        records = [
            {
                "key": "plain", "audioFile": "plain.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                # edge-template-strict flag, and thus also any_flag() ->
                # counted in both the main table's "fixed=" row and the
                # any-repeat-flag x inSilence crosstab.
                "key": "templ", "audioFile": "template.wav", "audioSeconds": 1.0,
                "raw": "Продолжение следует.", "final": "",
                "removedTemplates": ["Продолжение следует."],
                "segments": [{"text": "Продолжение следует.", "startMs": 0, "endMs": 500}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 0)
        self.assertIn("analyzed=2", out)

        # Main table: both "of flagged" and "of analyzed" must appear on the
        # edgeTemplate strict row, with their own denominators (1 flagged, 2
        # analyzed) — not one fraction silently standing in for the other.
        self.assertIn("edgeTemplate strict: 1/2", out)
        self.assertIn("of flagged", out)
        self.assertIn("of analyzed", out)
        self.assertRegex(out, r"fixed=\d+/1 of flagged \([\d.]+%\), \d+/2 of analyzed \([\d.]+%\)")

        # Crosstab: both "of repeat-flagged" and "of analyzed".
        self.assertIn("of repeat-flagged", out)
        self.assertRegex(
            out,
            r"crosstab: any-repeat-flag AND inSilence\(vad=0\.5\): "
            r"\d+/1 of repeat-flagged \([\d.]+%\), \d+/2 of analyzed \([\d.]+%\)",
        )

        # loop stays n/a (no denominator ambiguity there — not segment-tied).
        self.assertIn("loop: 0/2 (0.0%)  fixed=n/a", out)

    def test_dup_segment_subrows_print_both_denominators(self):
        # docs/plans/shadow-vad.md T3 (P2 review): the "1-token"/">=2-token"
        # dupSegment sub-rows must format 'fixed=' the same as every other
        # row, not the bare frac_str they used to fall back to.
        self.touch_audio("single.wav")
        self.touch_audio("multi.wav")
        records = [
            {
                "key": "single", "audioFile": "single.wav", "audioSeconds": 1.0,
                "raw": "да да", "final": "да да", "removedTemplates": None,
                "segments": [
                    {"text": "да", "startMs": 0, "endMs": 100},
                    {"text": "да", "startMs": 100, "endMs": 200},
                ],
            },
            {
                "key": "multi", "audioFile": "multi.wav", "audioSeconds": 1.0,
                "raw": "привет мирпривет мир", "final": "привет мирпривет мир",
                "removedTemplates": None,
                "segments": [
                    {"text": "привет мир", "startMs": 0, "endMs": 100},
                    {"text": "привет мир", "startMs": 100, "endMs": 200},
                ],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 0)
        self.assertRegex(
            out, r"dupSegment \(1-token\): 1/2 \([\d.]+%\)  "
                 r"fixed=\d+/1 of flagged \([\d.]+%\), \d+/2 of analyzed \([\d.]+%\)",
        )
        self.assertRegex(
            out, r"dupSegment \(>=2-token\): 1/2 \([\d.]+%\)  "
                 r"fixed=\d+/1 of flagged \([\d.]+%\), \d+/2 of analyzed \([\d.]+%\)",
        )


class TestRepeatFlagPredicate(unittest.TestCase):
    """docs/plans/shadow-vad.md T3 (P1 review): has_repeat_flag() must NOT
    include beyondAudio, unlike any_flag() (used for markup selection, where
    beyondAudio remains a legitimate candidate)."""

    @staticmethod
    def _rec(**overrides):
        base = {
            "hasDupSingle": False, "hasDupMulti": False, "hasLoop": False,
            "hasEdgeStrict": False, "hasEdgeRisky": False, "hasBeyondAudio": False,
        }
        base.update(overrides)
        return base

    def test_beyond_audio_only_is_not_a_repeat_flag(self):
        rec = self._rec(hasBeyondAudio=True)
        self.assertFalse(sa.has_repeat_flag(rec))
        self.assertTrue(sa.any_flag(rec))  # still a markup candidate

    def test_dup_segment_is_a_repeat_flag(self):
        rec = self._rec(hasDupSingle=True)
        self.assertTrue(sa.has_repeat_flag(rec))
        self.assertTrue(sa.any_flag(rec))

    def test_no_flags_at_all(self):
        rec = self._rec()
        self.assertFalse(sa.has_repeat_flag(rec))
        self.assertFalse(sa.any_flag(rec))


class TestNonFiniteNumbers(ShadowAnalysisMainTestCase):
    """docs/plans/shadow-vad.md T3 (P1 review): is_number() and the CLI's
    float parsing must reject NaN/+-Infinity, not just non-numeric types."""

    def test_audio_seconds_nan_is_analysis_error(self):
        self.touch_audio("ok.wav")
        self.touch_audio("nan.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "nan-seconds", "audioFile": "nan.wav", "audioSeconds": float("nan"),
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [{"text": "text2", "startMs": 0, "endMs": 500}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("analyzed=1", out)

    def test_end_ms_infinity_is_analysis_error(self):
        self.touch_audio("ok.wav")
        self.touch_audio("inf.wav")
        records = [
            {
                "key": "ok", "audioFile": "ok.wav", "audioSeconds": 1.0,
                "raw": "text", "final": "text", "removedTemplates": None,
                "segments": [{"text": "text", "startMs": 0, "endMs": 500}],
            },
            {
                "key": "inf-endms", "audioFile": "inf.wav", "audioSeconds": 1.0,
                "raw": "text2", "final": "text2", "removedTemplates": None,
                "segments": [{"text": "text2", "startMs": 0, "endMs": float("inf")}],
            },
        ]
        path = self.write_jsonl("run.jsonl", self.base_run_header(), records,
                                 {"records": 2, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)
        self.assertIn("analysisErrors=1", out)
        self.assertIn("analyzed=1", out)

    def test_rms_gates_nan_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model),
                                         "--rms-gates", "nan"])
        self.assertEqual(code, 2)

    def test_vad_thresholds_infinity_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model),
                                         "--vad-thresholds", "inf"])
        self.assertEqual(code, 2)

    def test_silence_overlap_nan_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model),
                                         "--silence-overlap", "nan"])
        self.assertEqual(code, 2)


class TestPrivateOutValidation(ShadowAnalysisMainTestCase):
    def test_private_text_without_out_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        code, out, err = self.run_main([str(path), "--include-private-text",
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)

    def test_out_without_private_text_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        out_path = self.tmp_path / "report.txt"
        code, out, err = self.run_main([str(path), "--out", str(out_path),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)

    def test_out_inside_repository_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        inside_path = _SCRIPTS_DIR / "tests" / "_shadow_analysis_test_should_not_exist.txt"
        self.addCleanup(lambda: inside_path.unlink(missing_ok=True))
        code, out, err = self.run_main([str(path), "--include-private-text",
                                         "--out", str(inside_path),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)
        self.assertFalse(inside_path.exists())

    def test_out_symlink_to_inside_repository_exit2(self):
        path = self.write_jsonl("run.jsonl", self.base_run_header(), [],
                                 {"records": 0, "errors": 0})
        inside_target = _SCRIPTS_DIR / "tests" / "_shadow_analysis_symlink_target.txt"
        self.addCleanup(lambda: inside_target.unlink(missing_ok=True))
        outside_link = self.tmp_path / "link.txt"
        os.symlink(str(inside_target), str(outside_link))

        code, out, err = self.run_main([str(path), "--include-private-text",
                                         "--out", str(outside_link),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 2)
        self.assertFalse(inside_target.exists())
        # the symlink itself must be untouched (still a symlink, not a real file)
        self.assertTrue(os.path.islink(str(outside_link)))


class TestPrivacy(ShadowAnalysisMainTestCase):
    """docs/plans/shadow-vad.md T3: full privacy test with four synthetic
    records, checked for zero leakage in both normal and private-text mode.

    Record (d) (P1 review addition) is a flagged record (dupSegment: two
    identical segments) whose EACH field — every segments[].text, final, and
    reference — carries its OWN distinct marker, so the private-mode
    assertion can check that each field individually made it into the
    private file, not just "at least one marker somewhere" (the previous,
    weaker assertion the review flagged as a false-green risk: it could pass
    even if e.g. segment text were silently dropped from the render)."""

    MARKERS_ASCII = ["PRIVMARK1", "PRIVMARK2", "PRIVMARK3"]
    RECORD_D_FIELD_MARKERS = ["PRIVMARK4SEG", "PRIVMARK4FINAL", "PRIVMARK4REF"]
    MARKER_CYR = "ПРИВМЕТКА"  # ПРИВМЕТКА

    def _build_jsonl(self):
        m1, m2, m3 = self.MARKERS_ASCII
        cyr = self.MARKER_CYR

        # (a) ordinary record: markers everywhere, nothing template-matched.
        seg_a1 = f"Здравствуй {m1} {cyr}1 мир"
        seg_a2 = f"вторая часть {m1} {cyr}1"
        record_a = {
            "key": "rec-a", "audioFile": "a.wav", "audioSeconds": 1.0,
            "raw": seg_a1 + seg_a2, "final": seg_a1 + seg_a2,
            "removedTemplates": None,
            "segments": [
                {"text": seg_a1, "startMs": 0, "endMs": 500},
                {"text": seg_a2, "startMs": 500, "endMs": 1000},
            ],
            "comparableToHistory": True,
            "reference": f"reference with {m1} {cyr}1",
            "history": {"raw": f"hist raw {m1} {cyr}1", "text": f"hist text {m1} {cyr}1"},
        }

        # (b) all segments are the verbatim filter template -> final empty,
        # markers only in reference/history (never in a template segment,
        # or the filter-replica reconciliation in analyze_record would fail).
        record_b = {
            "key": "rec-b", "audioFile": "b.wav", "audioSeconds": 1.0,
            "raw": "Продолжение следует.Продолжение следует.",
            "final": "", "removedTemplates": ["Продолжение следует.", "Продолжение следует."],
            "segments": [
                {"text": "Продолжение следует.", "startMs": 0, "endMs": 500},
                {"text": "Продолжение следует.", "startMs": 500, "endMs": 1000},
            ],
            "comparableToHistory": False,
            "reference": f"reference with {m2} {cyr}2",
            "history": {"raw": f"hist raw {m2} {cyr}2", "text": f"hist text {m2} {cyr}2"},
        }

        # (c) audioFile missing on disk -> analysis error before any field
        # is ever read into the report; markers present to prove the bail-out
        # happens before that.
        seg_c = f"третий сегмент {m3} {cyr}3"
        record_c = {
            "key": "rec-c", "audioFile": "missing_c.wav", "audioSeconds": 1.0,
            "raw": seg_c, "final": seg_c, "removedTemplates": None,
            "segments": [{"text": seg_c, "startMs": 0, "endMs": 500}],
            "comparableToHistory": True,
            "reference": f"reference with {m3} {cyr}3",
            "history": {"raw": f"hist raw {m3} {cyr}3", "text": f"hist text {m3} {cyr}3"},
        }

        # (d) flagged via dupSegment (two identical segments) — every
        # segments[].text, final, and reference carry a DISTINCT marker so
        # the private-mode test can check each field landed individually.
        seg_d = f"привет {self.RECORD_D_FIELD_MARKERS[0]} {cyr}4SEG привет"
        record_d = {
            "key": "rec-d", "audioFile": "d.wav", "audioSeconds": 1.0,
            "raw": seg_d + seg_d,
            "final": f"{self.RECORD_D_FIELD_MARKERS[1]} {cyr}4FINAL final text",
            "removedTemplates": None,
            "segments": [
                {"text": seg_d, "startMs": 0, "endMs": 500},
                {"text": seg_d, "startMs": 500, "endMs": 1000},
            ],
            "comparableToHistory": True,
            "reference": f"{self.RECORD_D_FIELD_MARKERS[2]} {cyr}4REF reference text",
            "history": {"raw": "hist raw d", "text": "hist text d"},
        }

        self.touch_audio("a.wav")
        self.touch_audio("b.wav")
        self.touch_audio("d.wav")
        # a/b/d's decode is mocked anyway; content is irrelevant.

        path = self.write_jsonl(
            "history.jsonl", self.base_run_header(mode="history"),
            [record_a, record_b, record_c, record_d], {"records": 4, "errors": 0},
        )
        return path

    def _assert_no_leak(self, combined_output):
        for marker in self.MARKERS_ASCII + self.RECORD_D_FIELD_MARKERS:
            self.assertNotIn(marker, combined_output)
        self.assertNotIn(self.MARKER_CYR, combined_output)
        self.assertNotIn("продолжение следует", combined_output.lower())
        for ch in combined_output:
            self.assertLess(ord(ch), 128, f"non-ASCII character leaked: {ch!r}")

    def test_normal_mode_no_leak(self):
        path = self._build_jsonl()
        code, out, err = self.run_main([str(path), "--audio-dir", str(self.audio_dir),
                                         "--vad-model", str(self.fake_model)])
        self.assertEqual(code, 1)  # rec-c is an analysis error
        self._assert_no_leak(out + err)

    def test_private_mode_no_stdout_leak_but_file_has_every_marker_and_is_0600(self):
        path = self._build_jsonl()
        out_file = self.tmp_path / "outside-repo-markup.txt"
        code, out, err = self.run_main([
            str(path), "--audio-dir", str(self.audio_dir),
            "--vad-model", str(self.fake_model),
            "--include-private-text", "--out", str(out_file),
        ])
        self.assertEqual(code, 1)
        self._assert_no_leak(out + err)

        self.assertTrue(out_file.is_file())
        content = out_file.read_text(encoding="utf-8")

        # record (d) is flagged (dupSegment) -> must be in the private
        # listing, with EACH of its three per-field markers present
        # individually (segments[].text via SEG, final via FINAL, reference
        # via REF) — not just "some marker somewhere".
        for marker in self.RECORD_D_FIELD_MARKERS:
            self.assertIn(marker, content, f"private file missing field marker {marker}")
        self.assertIn(f"{self.MARKER_CYR}4SEG", content)
        self.assertIn(f"{self.MARKER_CYR}4FINAL", content)
        self.assertIn(f"{self.MARKER_CYR}4REF", content)

        mode = stat.S_IMODE(out_file.stat().st_mode)
        self.assertEqual(mode, 0o600)


if __name__ == "__main__":
    unittest.main()
