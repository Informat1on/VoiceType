#!/usr/bin/env bash
# VoiceType Whisper model benchmark
# Runs whisper-cli over 25 phrase recordings × N models, outputs CSV + markdown summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Models to benchmark: label|filename|size_mb
MODELS=(
    "small|ggml-small.bin|465"
    "medium|ggml-medium.bin|1400"
    "turbo|ggml-large-v3-turbo.bin|1500"
    "turbo-q5|ggml-large-v3-turbo-q5_0.bin|547"
)

MODEL_DIR="$HOME/Library/Application Support/VoiceType/Models"
BENCH_DIR="$REPO_DIR/Tests/Fixtures/bench"
OUT_DIR="$REPO_DIR/scripts/bench-output"
PYTHON="${BENCH_PYTHON:-/tmp/bench-venv/bin/python3}"

mkdir -p "$OUT_DIR"

RESULTS_CSV="$OUT_DIR/results.csv"
echo "model,phrase,wer,transcribe_time_s,audio_duration_s,rtf" > "$RESULTS_CSV"

echo "VoiceType Benchmark — $(date)"
echo "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo "RAM: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
echo ""

for entry in "${MODELS[@]}"; do
    IFS='|' read -r LABEL MODELFILE SIZE_MB <<< "$entry"
    MODEL_PATH="$MODEL_DIR/$MODELFILE"

    if [ ! -f "$MODEL_PATH" ]; then
        echo "SKIP $LABEL: $MODELFILE not found at $MODEL_PATH"
        continue
    fi

    echo ""
    echo "=== Model: $LABEL ($SIZE_MB MB) ==="

    # Warm-up: run on phrase 01 once, discard result (Metal/CoreML/RAM cache)
    echo "  [warm-up on 01.wav...]"
    whisper-cli \
        -m "$MODEL_PATH" \
        -f "$BENCH_DIR/01.wav" \
        -l ru \
        -t 4 \
        --output-txt \
        -of "/tmp/warmup_bench_$$" \
        --no-timestamps \
        > /dev/null 2>&1 || true
    rm -f "/tmp/warmup_bench_$$.txt"

    for i in $(seq -f "%02g" 1 25); do
        WAV="$BENCH_DIR/${i}.wav"
        REF_FILE="$BENCH_DIR/${i}.txt"
        REF=$(cat "$REF_FILE" 2>/dev/null || echo "")

        # Audio duration via sox
        AUDIO_DUR=$(sox "$WAV" -n stat 2>&1 | awk '/^Length/{print $NF}' | head -1)
        if [ -z "$AUDIO_DUR" ] || [ "$AUDIO_DUR" = "0" ]; then
            AUDIO_DUR="0.001"
        fi

        TMPOUT="/tmp/bench_${LABEL}_${i}_$$"

        # Time transcription — use python3 for portable sub-second timing
        START=$("$PYTHON" -c "import time; print(f'{time.time():.6f}')")
        whisper-cli \
            -m "$MODEL_PATH" \
            -f "$WAV" \
            -l ru \
            -t 4 \
            --output-txt \
            -of "$TMPOUT" \
            --no-timestamps \
            > /dev/null 2>&1 || true
        END=$("$PYTHON" -c "import time; print(f'{time.time():.6f}')")
        ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.3f", e-s}')

        # Read transcript
        HYP=$(cat "${TMPOUT}.txt" 2>/dev/null | tr -d '\n' | xargs)
        rm -f "${TMPOUT}.txt"

        # WER
        WER=$("$PYTHON" "$SCRIPT_DIR/wer.py" --hyp "$HYP" --ref "$REF" 2>/dev/null || echo "1.000")

        # RTF (audio_length / transcribe_time) — higher = faster
        RTF=$(awk -v a="$AUDIO_DUR" -v t="$ELAPSED" \
            'BEGIN{ if (t+0 > 0) printf "%.2f", a/t; else print "0.00" }')

        echo "$LABEL,$i,$WER,$ELAPSED,$AUDIO_DUR,$RTF" >> "$RESULTS_CSV"
        printf "  phrase %s  hyp=\"%s\"  WER=%s  time=%ss  RTF=%sx\n" \
            "$i" "${HYP:0:40}" "$WER" "$ELAPSED" "$RTF"
    done
done

echo ""
echo "Results written to $RESULTS_CSV"
echo ""
echo "Per-model summary:"
"$PYTHON" "$SCRIPT_DIR/bench-summary.py" "$RESULTS_CSV"
