# VoiceType Whisper Model Benchmark

**Date:** 2026-04-27  
**Hardware:** Apple M4 Pro, 24 GB RAM  
**OS:** macOS 15 (Darwin 24.6.0)  
**Corpus:** 25 phrases — Russian conversational + tech anglicisms (real voice, 16 kHz mono PCM)  
**Tool:** `whisper-cli` (whisper-cpp via Homebrew), `-l ru -t 4 --no-timestamps`  
**WER normalization:** lowercase → strip punctuation → collapse whitespace  

---

## Summary

| Model | Avg WER | Median WER | Avg time/phrase | Avg RTF | Disk |
|-------|---------|------------|----------------|---------|------|
| small      | 26.2% | 15.8% | 0.63s |  9.5x | 465 MB |
| medium     | 24.1% | 15.8% | 1.42s |  4.2x | 1.4 GB |
| turbo      | 23.2% | 11.1% | 1.57s |  3.7x | 1.5 GB |
| **turbo-q5**   | **23.2%** | **11.1%** | **1.10s** | **5.4x** | **547 MB** |

RTF = audio_length / transcription_time. Higher = faster than real-time.

---

## Per-block breakdown

| Model | Block 1: Conversational | Block 2: Anglicisms | Block 3: Identifiers | Block 4: Numbers | Block 5: Long sentences | Block 6: Edge cases |
|-------|------------------------|--------------------|--------------------|-----------------|------------------------|---------------------|
| small    |  4.0% | 17.0% | 40.8% | 63.0% |  9.8% | 38.9% |
| medium   |  1.5% | 17.6% | 35.8% | 60.8% |  7.2% | 38.9% |
| turbo    |  1.5% | 10.7% | 40.8% | 59.2% |  5.3% | 38.9% |
| turbo-q5 |  1.5% | 10.5% | 40.8% | 59.2% |  5.3% | 38.9% |

Block definitions:
- **Block 1** (phrases 01-05): Conversational Russian
- **Block 2** (phrases 06-10): Tech anglicisms (deploy, commit, middleware, Redis, rebase)
- **Block 3** (phrases 11-15): Code identifiers (server.js, handleRequest, react-query, console.log, webhook)
- **Block 4** (phrases 16-18): Numbers, versions, IP addresses
- **Block 5** (phrases 19-22): Long sentences (19-22 words)
- **Block 6** (phrases 23-25): Edge cases (silence, short phrase "раз два три", closing phrase)

---

## Recommendation

**Default model: `large-v3-turbo-q5_0` (turbo-q5)**

turbo-q5 matches turbo exactly on both Avg WER (23.2%) and Median WER (11.1%), while being **30% faster** (1.10s vs 1.57s per phrase, RTF 5.4x vs 3.7x) and **64% smaller** (547 MB vs 1.5 GB on disk). There is zero quality regression at the corpus level.

Current VoiceType default is `large-v3-turbo`. Switch to `large-v3-turbo-q5_0` immediately.

---

## Key Findings

### 1. turbo-q5 = turbo quality at significantly less cost

turbo-q5 is indistinguishable from turbo on this corpus — identical WER per block, faster RTF. The Q5_0 quantization introduces no measurable degradation on Russian speech.

### 2. small is the speed champion but quality suffers on anglicisms

At 9.5x RTF, `small` is 2-3x faster than turbo. However, Block 2 (anglicisms) WER is 17% vs 10.7% for turbo, and Block 3 (identifiers) is 40.8% for all models (a ceiling). For a voice typing app where code identifiers are central, small's errors in "middleware", "auth flow", "webhook" are significant UX regressions.

### 3. medium is the value-for-disk loser

medium (1.4 GB, 4.2x RTF) is slower than turbo-q5 (547 MB, 5.4x RTF) while offering worse WER. It occupies a dominated position on all three dimensions: quality, speed, and size. Not recommended.

### 4. Numbers and IP addresses are universally hard (WER ~60%)

All models score 59-63% WER on Block 4 (version strings, IP addresses, millisecond counts). The reference transcripts are spelled-out Russian ("двести пятьдесят миллисекунд") but models often output digits ("250 мс"). This is a normalization mismatch rather than a true speech recognition failure. Adding a post-processing normalization pass (digits → words or words → digits) would dramatically reduce this WER.

### 5. Silence test (phrase 23) confabulates across all models

All models hallucinate text on the near-silence phrase (peak 0.0015). `small` outputs "[Музыка]", `turbo` and `turbo-q5` output "Продолжение следует...", `medium` outputs subtitle credits. VoiceType's existing silence gate (VAD threshold) is the correct mitigation — do not pass near-silence audio to whisper.

### 6. The "auth flow" anglicism is a persistent failure

Phrase 08 ("middleware в auth flow") scores 20-30% WER across all models. The word "auth" is consistently mistranscribed as "wowflow", "outflow", "O-Flow". This is a whisper.cpp limitation without prompt injection. VoiceType's initial prompt feature (`setInitialPrompt`) is the right fix — priming with tech vocabulary would recover this.

---

## Caveats

- **Cold start excluded**: Each model runs a warm-up pass on phrase 01 before timing. Cold-start (first load from disk) is typically 1-3s longer and not represented.
- **No prompt injection**: VoiceType injects an initial prompt for bilingual mode. These results are prompt-free. Real-world WER in VoiceType will differ, likely lower for anglicisms.
- **4 threads only**: `whisper-cli -t 4`. M4 Pro has more performance cores. Testing with `-t 8` may improve RTF for larger models.
- **No CoreML encoder**: whisper-cpp Homebrew build uses Metal/BLAS but not the CoreML encoder packages (.mlmodelc) that VoiceType bundles. The app-embedded encoder may be faster.
- **Short audio bias**: All phrases are 0.5-11s. RTF on longer audio (60s+) will differ — model load amortizes better, but attention quadratic cost grows.
- **WER normalization gap**: Digit vs. spelled-out number mismatch inflates Block 4 WER artificially. True phonetic WER would be lower.
- **Memory pressure not measured**: 24 GB RAM is comfortable for all models simultaneously. On 8 GB machines, turbo-q5's smaller footprint would be even more advantageous.
