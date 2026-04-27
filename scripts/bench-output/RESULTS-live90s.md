# VoiceType Live 90s Benchmark

**Date:** 2026-04-27  
**Hardware:** Apple M4 Pro, 24 GB RAM  
**OS:** macOS 15 (Darwin 24.6.0)  
**Recording:** `live-20260427-185032/recording.wav` — 81.2 sec free-speech Russian/English dev vocabulary (real microphone, 16 kHz mono PCM)  
**Tool:** `whisper-cli -l ru -t 4 --no-timestamps`  
**RAM:** measured via `/usr/bin/time -l` peak RSS  
**Note:** No WER — no ground truth for this recording. Timing reflects full 81s segment processed in one call (no chunking).

---

## Live 81s Timing Comparison

| Model | Total time (s) | RTF | Disk (MB) | Peak RAM (MB) |
|-------|---------------|-----|-----------|---------------|
| **tiny**     |  **1.1s** | **74.6x** |  75 MB |  303 MB |
| base     |  1.6s | 50.8x | 141 MB |  412 MB |
| small-q5 |  2.6s | 31.2x | 181 MB |  558 MB |
| small    |  2.6s | 31.1x | 465 MB |  887 MB |
| turbo-q5 |  3.6s | 22.5x | 547 MB |  879 MB |
| turbo    |  3.6s | 22.5x | 1500 MB | 1914 MB |
| **medium**   |  **6.1s** | **13.2x** | 1400 MB | 2179 MB |

RTF = audio_duration / total_transcription_time. Higher = faster than real-time.

---

## Key observations

- **Fastest:** tiny at 1.1s total (RTF 74.6x) — processes 81s of audio in just over 1 second on M4 Pro with Metal.
- **Slowest:** medium at 6.1s (RTF 13.2x) — counterintuitively slower than turbo/turbo-q5 due to full attention over longer sequences.
- **turbo vs turbo-q5:** Identical on long audio (both 3.6s, RTF 22.5x). Q5 quantization has zero speed penalty on 81s segments.
- **small vs small-q5:** Identical speed (2.6s each, RTF ~31x). Disk footprint is 2.6x larger for small (465 MB vs 181 MB) with no speed benefit.
- **RAM cliff:** tiny/base/small-q5 stay under 600 MB peak RSS. small crosses 887 MB. medium/turbo cross 1.9-2.2 GB — relevant for 8 GB MacBooks with memory pressure.
- **medium anomaly:** medium is 69% slower than turbo-q5 (6.1s vs 3.6s) while also using more RAM (2.2 GB vs 0.9 GB) — a dominated position on every axis.
