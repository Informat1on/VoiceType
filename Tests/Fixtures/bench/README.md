# Benchmark Recording Dataset

This directory holds reference WAV recordings + their text transcripts for WER/RTF
benchmarking. See `scripts/BENCH_PHRASES.md` for the phrase list and recording
instructions.

To record:
```
bash scripts/record-bench.sh
```

## Files

- `01.wav` ... `25.wav` — 16 kHz mono PCM WAV
- `01.txt` ... `25.txt` — exact reference text (UTF-8, no trailing newline)

These files are committed for reproducibility. Re-recording is encouraged when
your voice/microphone changes.
