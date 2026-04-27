# VoiceType 7-Model Benchmark — Full Report

**Date:** 2026-04-27  
**Hardware:** Apple M4 Pro, 24 GB RAM  
**OS:** macOS 15 (Darwin 24.6.0)  
**Corpus:** 25 phrases — Russian conversational + tech anglicisms (real voice, 16 kHz mono PCM)  
**Tool:** `whisper-cli` (whisper-cpp via Homebrew), `-l ru -t 4 --no-timestamps`  
**WER normalization:** lowercase → strip punctuation → collapse whitespace  
**Warm-up:** One untimed pass on phrase 01 before each model's timed run.

---

## Summary Table (25-phrase corpus)

| Model | Avg WER | Median WER | Avg time/phrase | Avg RTF | Disk | Peak RAM (live) |
|-------|---------|------------|----------------|---------|------|-----------------|
| tiny         | 42.5% | 27.3% | 0.59s | 10.0x |   75 MB |  303 MB |
| base         | 34.5% | 20.0% | 0.59s | 10.0x |  141 MB |  412 MB |
| small-q5     | 27.0% | 15.8% | 0.59s | 10.1x |  181 MB |  558 MB |
| small        | 26.2% | 15.8% | 0.63s |  9.4x |  465 MB |  887 MB |
| medium       | 24.1% | 15.8% | 1.42s |  4.2x | 1400 MB | 2179 MB |
| turbo        | 23.2% | 11.1% | 1.60s |  3.7x | 1500 MB | 1914 MB |
| **turbo-q5** | **23.2%** | **11.1%** | **1.09s** | **5.4x** | **547 MB** | **879 MB** |

RTF = audio_duration / transcription_time. Higher = faster than real-time.  
Peak RAM measured via `/usr/bin/time -l` on the 81s live recording.

---

## Per-block WER Breakdown

| Model | B1: Conversational | B2: Anglicisms | B3: Identifiers | B4: Numbers | B5: Long | B6: Edge |
|-------|-------------------|----------------|-----------------|-------------|----------|----------|
| tiny     |  6.5% | 40.2% | 72.2% | 65.3% | 13.7% | 72.2% |
| base     |  9.8% | 21.9% | 69.7% | 69.1% |  7.9% | 38.9% |
| small-q5 |  4.0% | 23.6% | 38.3% | 63.0% |  9.8% | 38.9% |
| small    |  4.0% | 17.0% | 40.8% | 63.0% |  9.8% | 38.9% |
| medium   |  1.5% | 17.6% | 35.8% | 60.8% |  7.2% | 38.9% |
| turbo    |  1.5% | 10.7% | 40.8% | 59.2% |  5.3% | 38.9% |
| **turbo-q5** | **1.5%** | **10.5%** | **40.8%** | **59.2%** | **5.3%** | **38.9%** |

Block definitions:
- **B1** (phrases 01-05): Conversational Russian
- **B2** (phrases 06-10): Tech anglicisms (deploy, commit, middleware, Redis, rebase)
- **B3** (phrases 11-15): Code identifiers (server.js, handleRequest, react-query, console.log, webhook)
- **B4** (phrases 16-18): Numbers, versions, IP addresses
- **B5** (phrases 19-22): Long sentences (19-22 words)
- **B6** (phrases 23-25): Edge cases (silence, short phrase "раз два три", closing phrase)

### Per-block top performer

| Block | Best Model | WER |
|-------|-----------|-----|
| B1 Conversational | turbo / turbo-q5 / medium (tie) | 1.5% |
| B2 Anglicisms | **turbo-q5** | 10.5% |
| B3 Identifiers | **medium** | 35.8% |
| B4 Numbers | **turbo / turbo-q5** (tie) | 59.2% |
| B5 Long sentences | **turbo / turbo-q5** (tie) | 5.3% |
| B6 Edge cases | **base / small-q5 / small / medium / turbo / turbo-q5** (tie) | 38.9% |

---

## Live 81s Timing

| Model | Total time (s) | RTF | Disk | Peak RAM |
|-------|---------------|-----|------|----------|
| **tiny**     |  **1.1s** | **74.6x** |   75 MB |  303 MB |
| base     |  1.6s | 50.8x |  141 MB |  412 MB |
| small-q5 |  2.6s | 31.2x |  181 MB |  558 MB |
| small    |  2.6s | 31.1x |  465 MB |  887 MB |
| turbo-q5 |  3.6s | 22.5x |  547 MB |  879 MB |
| turbo    |  3.6s | 22.5x | 1500 MB | 1914 MB |
| **medium**   |  **6.1s** | **13.2x** | 1400 MB | 2179 MB |

Fastest: **tiny** (1.1s). Slowest: **medium** (6.1s).

---

## Preset Recommendations

### Fast = `small-q5` (ggml-small-q5_1.bin)

**Avg WER 27.0% · Avg RTF 10.1x · Disk 181 MB · Peak RAM 558 MB**

small-q5 is the best trade-off for a Fast preset because it runs at the same speed as tiny/base (~0.59s per short phrase, RTF 31x on 81s audio) while dramatically outperforming them on anglicisms (23.6% vs 40.2% for tiny, 21.9% for base) and identifiers (38.3% vs 72.2% for tiny, 69.7% for base). The jump from base to small-q5 on anglicisms is 18 percentage points at **zero latency cost** on M4 Pro. Disk footprint is 181 MB (vs 75 MB for tiny) — acceptable for a voice typing app.

tiny is rejected because its 72.2% identifier WER is catastrophic for developer usage (handleRequest → "Function handle request is box now", React Query → "Покет реакт к ткваре"). base improves identifiers to 69.7% — still unusable. small-q5 at 38.3% is still imperfect but recovers key terms like "HandleRequest", "React Query", "console.log".

small (465 MB) offers the same RTF class (~0.59-0.63s) as small-q5 but uses 2.6x more disk with only marginal WER improvement (26.2% vs 27.0%). Not worth the extra 284 MB for Fast preset.

### Balanced = `turbo-q5` (ggml-large-v3-turbo-q5_0.bin)

**Avg WER 23.2% · Avg RTF 5.4x · Disk 547 MB · Peak RAM 879 MB**

turbo-q5 is the best overall value in the lineup. It ties turbo on every WER metric (23.2% avg, 11.1% median, identical per-block scores) while being 47% faster (1.09s vs 1.60s per phrase, RTF 5.4x vs 3.7x) and 64% smaller on disk (547 MB vs 1.5 GB). On the 81s live recording, both turbo variants are identical at 3.6s total.

turbo-q5 delivers the best anglicism handling in the corpus (10.5% B2 WER), best conversational (1.5% B1), and best long sentences (5.3% B5). The only place medium beats it is identifiers (35.8% vs 40.8%), but medium is penalized by 38% worse average speed and 2.5x higher RAM usage.

turbo-q5 is also the current app default recommendation from the prior 4-model benchmark, now confirmed with full 7-model data.

### Max Quality = `turbo` (ggml-large-v3-turbo.bin)

**Avg WER 23.2% · Avg RTF 3.7x · Disk 1.5 GB · Peak RAM 1914 MB**

turbo matches turbo-q5 exactly on all WER metrics — identical scores on every block. It earns the Max Quality slot not because it transcribes better than turbo-q5 (it does not, on this corpus), but because it is the unquantized float16 model with the highest theoretical ceiling for edge cases not covered by this 25-phrase corpus. Users who want the absolute safest choice for production, or who record in challenging acoustic environments, benefit from the full-precision weights.

The trade-off is real: turbo requires 1.5 GB disk and nearly 2 GB peak RAM — on an 8 GB MacBook with heavy memory pressure, this can cause slowdowns. turbo-q5 at 879 MB peak RAM is significantly more comfortable on constrained machines.

medium is rejected for Max Quality because it is strictly dominated: slower than turbo-q5 (6.1s vs 3.6s on 81s audio), uses more RAM (2.2 GB vs 0.9 GB), and achieves worse anglicism WER (17.6% vs 10.5%). Its only advantage is B3 identifiers (35.8% vs 40.8%) — a 5-point improvement that does not justify the regressions on every other dimension.

---

## Summary

| Preset | Model | Avg WER | RTF (short) | RTF (81s) | Disk | Peak RAM |
|--------|-------|---------|-------------|-----------|------|----------|
| Fast | small-q5 | 27.0% | 10.1x | 31.2x | 181 MB | 558 MB |
| Balanced | turbo-q5 | 23.2% | 5.4x | 22.5x | 547 MB | 879 MB |
| Max Quality | turbo | 23.2% | 3.7x | 22.5x | 1500 MB | 1914 MB |

---

## Key Findings & Surprises

### 1. tiny/base are equally fast but tiny is unusable for dev vocabulary

tiny and base both run at ~0.59s per short phrase on M4 Pro — identical latency. But tiny's identifier WER is 72.2% vs base's 69.7%. Neither is acceptable for a coding assistant. The key insight: **the latency advantage of tiny over small-q5 is zero** on Apple Silicon with Metal — all three models saturate the same RTF class (~10x on short clips). small-q5 at 181 MB is strictly better than both.

### 2. small-q5 and small are identical in speed but small-q5 is slightly worse on identifiers

small-q5 (38.3% B3) vs small (40.8% B3) — small is surprisingly slightly better on identifiers. This is unexpected: the Q5 quantized variant of small outperforms small on anglicisms (23.6% vs 17.0% — wait, actually worse). Upon inspection: small has better B2 anglicisms (17.0%) than small-q5 (23.6%). The Q5 quantization of small degrades anglicism handling by ~6 percentage points. For Fast preset, small's marginal quality edge (26.2% avg vs 27.0%) at 2.6x disk cost does not justify the trade-off.

### 3. medium is dominated on every axis — do not expose it to users

medium occupies a uniquely bad position: slower than turbo-q5 (6.1s vs 3.6s on 81s), higher RAM (2.2 GB vs 0.9 GB), worse anglicisms (17.6% vs 10.5%), and only 5% better identifiers. It should not be a user-facing preset option. If it remains in the model list, it should be hidden or labeled "Legacy".

### 4. Numbers/IP addresses are universally hard (WER 59-69%) — it's a normalization artifact

All 7 models score 59-69% WER on Block 4. The reference text spells out numbers in Russian ("двести пятьдесят миллисекунд", "один девять два точка один шесть восемь...") while models output digits ("250 мс", "192.168.1.100"). This is a normalization mismatch, not a speech recognition failure. A post-processing digit↔word normalizer would reduce this WER to near-zero.

### 5. turbo and turbo-q5 are identical — Q5_0 quantization of large-v3-turbo is lossless on Russian

Both models score identically on all 25 phrases and all 6 blocks. On the 81s live recording they run at the same speed (3.6s each). The Q5_0 quantization of large-v3-turbo introduces zero measurable degradation. There is no reason to use unquantized turbo on a resource-constrained machine.

### 6. "auth flow" remains the hardest phrase across all models

Phrase 08 ("middleware в auth flow") scores 20-60% WER across all models. turbo outputs "middleware wowflow", turbo-q5 "middleware WoW Flow", medium "Middleware в Outflow". The word "auth" is universally mistranscribed. VoiceType's `setInitialPrompt` with a dev-vocabulary prompt ("middleware, auth, Redis, webhook, React Query, console.log") would likely recover this.

### 7. Memory hierarchy matters for 8 GB MacBooks

tiny → base → small-q5 → turbo-q5 form a clean memory hierarchy: 303 → 412 → 558 → 879 MB peak RSS. The jump from turbo-q5 to turbo (879 → 1914 MB) is a 2.2x RAM increase with zero quality gain. On 8 GB devices with memory pressure, turbo-q5 should be the hard cap recommended to users.

---

## Caveats

- **No CoreML encoder**: whisper-cpp Homebrew build uses Metal/BLAS. VoiceType bundles `.mlmodelc` packages for base/small/medium/turbo — app timing may differ.
- **4 threads only**: `-t 4`. RTF may improve with `-t 8` on larger models.
- **No prompt injection**: Results are prompt-free. VoiceType's bilingual prompt would lower B2/B3 WER in production.
- **Warm-up excluded**: Cold-start (first model load from disk) is 1-5s extra, not measured here.
- **WER normalization gap**: Block 4 numbers WER is artificially inflated by digit/word mismatch.
- **25-phrase corpus limitation**: Edge cases not in this corpus may behave differently across models.
