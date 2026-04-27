#!/usr/bin/env bash
# compare-live.sh — Live A/B comparison: large-v3-turbo vs large-v3-turbo-q5_0
# Records a speech sample and runs both models head-to-head with timing + word diff.
# Usage: bash scripts/compare-live.sh [--duration 60|90|120]
set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'
C_RED='\033[0;31m'
C_YELLOW='\033[0;33m'
C_BOLD='\033[1m'
C_DIM='\033[2m'

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
if ! command -v ffmpeg &>/dev/null; then
    printf '%b\n' "${C_RED}Error:${C_RESET} ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v whisper-cli &>/dev/null; then
    printf '%b\n' "${C_RED}Error:${C_RESET} whisper-cli not found. Install with: brew install whisper-cpp"
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_DIR="${REPO_ROOT}/Tests/Fixtures/bench"
DEVICE_FILE="${BENCH_DIR}/.bench-device"
MODEL_DIR="$HOME/Library/Application Support/VoiceType/Models"
TURBO_MODEL="${MODEL_DIR}/ggml-large-v3-turbo.bin"
TURBOQ5_MODEL="${MODEL_DIR}/ggml-large-v3-turbo-q5_0.bin"

# Output directory timestamped per run
RUN_TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${SCRIPT_DIR}/bench-output/live-${RUN_TS}"
mkdir -p "${OUT_DIR}"

# ---------------------------------------------------------------------------
# Duration argument
# ---------------------------------------------------------------------------
DURATION=90
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            DURATION="${2:?--duration requires a value}"
            shift 2
            ;;
        *)
            printf '%b\n' "${C_RED}Unknown argument:${C_RESET} $1"
            printf 'Usage: bash compare-live.sh [--duration 60|90|120]\n'
            exit 1
            ;;
    esac
done

if [[ "${DURATION}" != "60" && "${DURATION}" != "90" && "${DURATION}" != "120" ]]; then
    printf '%b\n' "${C_RED}Error:${C_RESET} --duration must be 60, 90, or 120 (got: ${DURATION})"
    exit 1
fi

# ---------------------------------------------------------------------------
# Check model files exist
# ---------------------------------------------------------------------------
MISSING_MODELS=()
if [[ ! -f "${TURBO_MODEL}" ]];   then MISSING_MODELS+=("ggml-large-v3-turbo.bin"); fi
if [[ ! -f "${TURBOQ5_MODEL}" ]]; then MISSING_MODELS+=("ggml-large-v3-turbo-q5_0.bin"); fi

if [[ ${#MISSING_MODELS[@]} -gt 0 ]]; then
    printf '%b\n' "${C_RED}Error:${C_RESET} Missing model files in ${MODEL_DIR}:"
    for m in "${MISSING_MODELS[@]}"; do
        printf '  - %s\n' "${m}"
    done
    printf '\nDownload them from VoiceType Settings → Models tab.\n'
    exit 1
fi

# ---------------------------------------------------------------------------
# Audio device selection (shared cache with record-bench.sh)
# ---------------------------------------------------------------------------
select_audio_device() {
    if [[ -f "${DEVICE_FILE}" ]]; then
        AUDIO_DEVICE=$(cat "${DEVICE_FILE}")
        printf '%b\n' "${C_BOLD}Cached audio device:${C_RESET} index ${C_GREEN}${AUDIO_DEVICE}${C_RESET} (from .bench-device)"
        printf '%b' "Press ${C_GREEN}Enter${C_RESET} to keep, or ${C_YELLOW}c${C_RESET} to change: "
        read -r resp
        if [[ "${resp}" != "c" && "${resp}" != "C" ]]; then
            return
        fi
    fi

    printf '%b\n' "${C_BOLD}Detecting audio devices...${C_RESET}"
    raw=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true)
    audio_section=$(printf '%s\n' "${raw}" | awk '/AVFoundation audio devices/{flag=1; next} flag{print}')

    if [[ -z "${audio_section}" ]]; then
        printf '%b\n' "${C_RED}Error:${C_RESET} Could not detect audio devices via ffmpeg."
        exit 1
    fi

    printf '\n%b\n' "${C_BOLD}Available audio inputs:${C_RESET}"
    printf '%s\n' "${audio_section}" | grep -E '\[[0-9]+\]' | sed -E 's/.*\[([0-9]+)\] (.*)/  [\1] \2/'
    printf '\n'
    printf '%b' "Enter audio device index (e.g. ${C_GREEN}1${C_RESET}): "
    read -r AUDIO_DEVICE

    if ! [[ "${AUDIO_DEVICE}" =~ ^[0-9]+$ ]]; then
        printf '%b\n' "${C_RED}Invalid index.${C_RESET} Aborting."
        exit 1
    fi

    mkdir -p "${BENCH_DIR}"
    printf '%s' "${AUDIO_DEVICE}" > "${DEVICE_FILE}"
    printf 'Saved device choice to %s\n\n' "${DEVICE_FILE}"
}

select_audio_device

# ---------------------------------------------------------------------------
# Speech scenario
# ---------------------------------------------------------------------------
printf '\n'
printf '%b\n' "${C_BOLD}╔══════════════════════════════════════════════════════════════════╗${C_RESET}"
printf '%b\n' "${C_BOLD}║     СЦЕНАРИЙ ДЛЯ РЕЧИ — читай вслух, естественным темпом        ║${C_RESET}"
printf '%b\n' "${C_BOLD}║     ~${DURATION} секунд, старт по Enter                                 ║${C_RESET}"
printf '%b\n' "${C_BOLD}╚══════════════════════════════════════════════════════════════════╝${C_RESET}"
printf '\n'
printf '%b\n' "${C_CYAN} 1. Запусти Sonnet агента который добавит warm-up в TranscriptionService.${C_RESET}"
printf '%b\n' "${C_CYAN} 2. Прогони этот diff через Codex review с reasoning medium.${C_RESET}"
printf '%b\n' "${C_CYAN} 3. Сделай commit и push на origin main, потом создай release на GitHub.${C_RESET}"
printf '%b\n' "${C_CYAN} 4. Cherry-pick этот коммит на main, разреши конфликт в Package.swift вручную.${C_RESET}"
printf '%b\n' "${C_CYAN} 5. Через TaskCreate отметь прогресс, потом TaskUpdate когда закончишь.${C_RESET}"
printf '%b\n' "${C_CYAN} 6. В TranscriptionService нужно добавить isWarmingUp флаг и проверить race condition.${C_RESET}"
printf '%b\n' "${C_CYAN} 7. Status indicator в menu bar показывает loading, warming или ready состояние.${C_RESET}"
printf '%b\n' "${C_CYAN} 8. Slay, давай прогоним свежий бенчмарк через jiwer, посмотрим WER на этих 25 фразах.${C_RESET}"
printf '%b\n' "${C_CYAN} 9. ffmpeg avfoundation device захватывает голос с микрофона MacBook Pro.${C_RESET}"
printf '%b\n' "${C_CYAN}10. Я не уверен что это лучшее решение, но попробуем сделать через cherry-pick и rebase.${C_RESET}"
printf '%b\n' "${C_CYAN}11. Слушай, давай посмотрим в чём тут проблема, потом починим warm-up race в Whisper.swift.${C_RESET}"
printf '%b\n' "${C_CYAN}12. Открой ctx_read TranscriptionService.swift на строке 340 и посмотри что там в performWarmUp.${C_RESET}"
printf '%b\n' "${C_CYAN}13. Запушь форк SwiftWhisper на GitHub под аккаунтом Informat1on, обнови URL в Package.swift.${C_RESET}"
printf '%b\n' "${C_CYAN}14. Окей понял, тогда давай делать через worktree, sonnet агент закоммитит сам.${C_RESET}"
printf '%b\n' "${C_CYAN}15. Финальная фраза: задеплоим версию один точка два точка ноль с включённым Q5 turbo как дефолт.${C_RESET}"
printf '\n'
printf '%b\n' "${C_DIM}Покрытие: Sonnet/Codex, git workflow, TranscriptionService/Whisper.swift,${C_RESET}"
printf '%b\n' "${C_DIM}ffmpeg/jiwer, TaskCreate/ctx_read, GitHub/Informat1on, разговорные мостики${C_RESET}"
printf '\n'

printf '%b' "Нажми ${C_GREEN}Enter${C_RESET} для начала записи (${DURATION}s)... "
read -r _

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------
WAV_FILE="/tmp/compare-live-$(date +%s).wav"
printf '\n%b\n' "${C_RED}⬤ ЗАПИСЬ${C_RESET} — говори сейчас! (${DURATION}s)"
printf '%b\n\n' "${C_DIM}(ffmpeg захватывает device :${AUDIO_DEVICE})${C_RESET}"

ffmpeg \
    -f avfoundation \
    -i ":${AUDIO_DEVICE}" \
    -t "${DURATION}" \
    -ar 16000 \
    -ac 1 \
    -y \
    -loglevel error \
    "${WAV_FILE}"

printf '%b\n' "${C_GREEN}Запись завершена:${C_RESET} ${WAV_FILE}"

# Copy recording to output dir
cp "${WAV_FILE}" "${OUT_DIR}/recording.wav"

# ---------------------------------------------------------------------------
# Transcription helper
# ---------------------------------------------------------------------------
run_model() {
    local model_path="$2"
    local out_base="$3"

    local t_start t_end elapsed transcript

    t_start=$(python3 -c "import time; print(f'{time.time():.6f}')")
    whisper-cli \
        -m "${model_path}" \
        -f "${WAV_FILE}" \
        -l ru \
        -t 4 \
        --output-txt \
        -of "${out_base}" \
        --no-timestamps \
        > /dev/null 2>&1 || true
    t_end=$(python3 -c "import time; print(f'{time.time():.6f}')")

    elapsed=$(awk -v s="${t_start}" -v e="${t_end}" 'BEGIN{printf "%.2f", e-s}')
    transcript=$(cat "${out_base}.txt" 2>/dev/null | tr -d '\n' | xargs || echo "")

    printf '%s' "${elapsed}"$'\x1F'"${transcript}"
}

# ---------------------------------------------------------------------------
# Run both models
# ---------------------------------------------------------------------------
printf '\n%b\n' "${C_BOLD}Прогоняю через TURBO...${C_RESET}"
TURBO_RESULT=$(run_model "turbo" "${TURBO_MODEL}" "${OUT_DIR}/turbo")
TURBO_TIME="${TURBO_RESULT%%$'\x1F'*}"
TURBO_TEXT="${TURBO_RESULT#*$'\x1F'}"

printf '%b\n' "${C_BOLD}Прогоняю через TURBO-Q5...${C_RESET}"
Q5_RESULT=$(run_model "turbo-q5" "${TURBOQ5_MODEL}" "${OUT_DIR}/turbo-q5")
Q5_TIME="${Q5_RESULT%%$'\x1F'*}"
Q5_TEXT="${Q5_RESULT#*$'\x1F'}"

# Save transcripts to output dir (whisper-cli already wrote .txt files there)
# also save named copies for clarity
printf '%s\n' "${TURBO_TEXT}" > "${OUT_DIR}/transcript-turbo.txt"
printf '%s\n' "${Q5_TEXT}"    > "${OUT_DIR}/transcript-turbo-q5.txt"

# ---------------------------------------------------------------------------
# RTF calculation: audio_duration / transcribe_time (higher = faster)
# ---------------------------------------------------------------------------
TURBO_RTF=$(awk -v a="${DURATION}" -v t="${TURBO_TIME}" \
    'BEGIN{ if (t+0 > 0) printf "%.1f", a/t; else print "0.0" }')
Q5_RTF=$(awk -v a="${DURATION}" -v t="${Q5_TIME}" \
    'BEGIN{ if (t+0 > 0) printf "%.1f", a/t; else print "0.0" }')

# ---------------------------------------------------------------------------
# Side-by-side display
# ---------------------------------------------------------------------------
printf '\n'
printf '%b\n' "${C_BOLD}┌─────────────────────────────────────────────────────────────────────┐${C_RESET}"
printf '%b\n' "${C_BOLD}│        РЕЗУЛЬТАТЫ — TURBO vs TURBO-Q5 (прямое сравнение)            │${C_RESET}"
printf '%b\n' "${C_BOLD}├───────────────────────────────────┬─────────────────────────────────┤${C_RESET}"
printf "│ %-33s │ %-31s │\n" \
    "$(printf '%b' "${C_BOLD}TURBO${C_RESET} (1.5 GB)")" \
    "$(printf '%b' "${C_BOLD}TURBO-Q5${C_RESET} (547 MB)")"
printf "│ %-33s │ %-31s │\n" \
    "time: ${TURBO_TIME}s   RTF: ${TURBO_RTF}x" \
    "time: ${Q5_TIME}s   RTF: ${Q5_RTF}x"
printf '%b\n' "${C_BOLD}├───────────────────────────────────┴─────────────────────────────────┤${C_RESET}"
printf '%b\n' "${C_BOLD}│ Транскрипт TURBO:                                                   │${C_RESET}"

# Word-wrap TURBO transcript at ~69 chars
printf '%s\n' "${TURBO_TEXT}" | fold -s -w 69 | while IFS= read -r line; do
    printf "│ %-69s │\n" "${line}"
done

printf '%b\n' "${C_BOLD}├─────────────────────────────────────────────────────────────────────┤${C_RESET}"
printf '%b\n' "${C_BOLD}│ Транскрипт TURBO-Q5:                                                │${C_RESET}"

printf '%s\n' "${Q5_TEXT}" | fold -s -w 69 | while IFS= read -r line; do
    printf "│ %-69s │\n" "${line}"
done

printf '%b\n' "${C_BOLD}└─────────────────────────────────────────────────────────────────────┘${C_RESET}"

# ---------------------------------------------------------------------------
# Word diff
# ---------------------------------------------------------------------------
printf '\n%b\n' "${C_BOLD}=== Word diff (turbo → turbo-q5) ===${C_RESET}"
printf '%b\n' "${C_DIM}(- только в turbo, + только в turbo-q5)${C_RESET}"

TURBO_WORDS="${OUT_DIR}/.words-turbo.txt"
Q5_WORDS="${OUT_DIR}/.words-q5.txt"

# One word per line for a readable diff
printf '%s\n' "${TURBO_TEXT}" | tr -s ' ' '\n' > "${TURBO_WORDS}"
printf '%s\n' "${Q5_TEXT}"    | tr -s ' ' '\n' > "${Q5_WORDS}"

if diff --color=always -u "${TURBO_WORDS}" "${Q5_WORDS}" 2>/dev/null; then
    printf '%b\n' "${C_GREEN}Транскрипты идентичны — расхождений нет.${C_RESET}"
else
    printf '\n'
fi

# Also a compact inline diff for the saved report
diff -u "${TURBO_WORDS}" "${Q5_WORDS}" > "${OUT_DIR}/word-diff.txt" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
SPEEDUP=$(awk -v t="${TURBO_TIME}" -v q="${Q5_TIME}" \
    'BEGIN{ if (q+0 > 0) printf "%.0f%%", (1 - q/t)*100; else print "N/A" }')

printf '\n%b\n' "${C_BOLD}=== Итог ===${C_RESET}"
printf '  TURBO    : %ss  RTF %sx\n' "${TURBO_TIME}" "${TURBO_RTF}"
printf '  TURBO-Q5 : %ss  RTF %sx  (%s быстрее)\n' "${Q5_TIME}" "${Q5_RTF}" "${SPEEDUP}"
printf '\n'
printf '%b\n' "Результаты сохранены в: ${C_GREEN}${OUT_DIR}${C_RESET}"
printf '  recording.wav          — исходная запись\n'
printf '  transcript-turbo.txt   — транскрипт turbo\n'
printf '  transcript-turbo-q5.txt — транскрипт turbo-q5\n'
printf '  word-diff.txt          — diff по словам\n'
printf '\n'
printf '%b\n' "${C_DIM}Примечание: первая модель может быть cold-start (без warm-up).${C_RESET}"
printf '%b\n' "${C_DIM}Для fair comparison запусти скрипт повторно — Metal/ANE кэши прогреются.${C_RESET}"
