#!/usr/bin/env bash
# record-bench.sh — Interactive benchmark dataset recorder for VoiceType WER/RTF testing.
# Records 25 phrases as 16 kHz mono WAV files into Tests/Fixtures/bench/.
# Usage: bash scripts/record-bench.sh

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

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v ffmpeg &>/dev/null; then
    printf '%b\n' "${C_RED}Error:${C_RESET} ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
fi

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_DIR="${REPO_ROOT}/Tests/Fixtures/bench"
mkdir -p "${BENCH_DIR}"

# ---------------------------------------------------------------------------
# Phrase list (index 0 = phrase 01)
# ---------------------------------------------------------------------------
PHRASES=(
    "Сегодня хочу поработать над проектом и посмотреть как оно работает в реальных условиях."
    "Нам нужно подумать как улучшить производительность приложения."
    "Я не уверен что эта идея сработает но попробовать стоит."
    "Завтра встреча с командой по поводу нового функционала."
    "Проверь пожалуйста этот код и напиши свой отзыв."
    "Запушь этот commit в main и создай pull request."
    "Деплой пока упал на стейджинге, нужно посмотреть в логах что произошло."
    "Я добавил новый middleware в auth flow для проверки токена."
    "Откатим этот merge и попробуем заново через rebase."
    "В кэше Redis висят старые ключи, нужно сделать flush."
    "Открой файл server.js и поменяй порт на восемь тысяч."
    "В функции handleRequest есть баг с null проверкой."
    "Пакет react-query обновили, нужно перенести useQuery на новый api."
    "Убери console.log из production кода и проверь линтером."
    "Настрой webhook на endpoint slash api slash events."
    "Версия один точка два точка три, билд номер пятьсот двадцать четыре."
    "Запрос обработался за двести пятьдесят миллисекунд, это в три раза быстрее."
    "Сервер на ip адресе сто девяносто два точка один шестьдесят восемь точка один точка сто."
    "Я тут смотрел документацию и понял что нам надо переписать вот этот сервис потому что он слишком медленно работает с большим количеством запросов одновременно."
    "Если ты успеешь до пятницы то давай мы это в релиз включим иначе перенесём на следующий спринт там посмотрим."
    "Окей я понял что ты имеешь в виду давай тогда так и сделаем."
    "Бэкенд возвращает четыреста четвёртую ошибку только когда юзер не авторизован при этом фронт показывает белый экран без какой-либо информации."
    ""
    "Раз два три."
    "Это последняя фраза в нашем тесте, спасибо что записали все двадцать пять."
)

# Reference texts written to .txt (index 0 = phrase 01).
# Phrase 23 (index 22) is silence — reference is empty.
REFS=(
    "Сегодня хочу поработать над проектом и посмотреть как оно работает в реальных условиях."
    "Нам нужно подумать как улучшить производительность приложения."
    "Я не уверен что эта идея сработает но попробовать стоит."
    "Завтра встреча с командой по поводу нового функционала."
    "Проверь пожалуйста этот код и напиши свой отзыв."
    "Запушь этот commit в main и создай pull request."
    "Деплой пока упал на стейджинге, нужно посмотреть в логах что произошло."
    "Я добавил новый middleware в auth flow для проверки токена."
    "Откатим этот merge и попробуем заново через rebase."
    "В кэше Redis висят старые ключи, нужно сделать flush."
    "Открой файл server.js и поменяй порт на восемь тысяч."
    "В функции handleRequest есть баг с null проверкой."
    "Пакет react-query обновили, нужно перенести useQuery на новый api."
    "Убери console.log из production кода и проверь линтером."
    "Настрой webhook на endpoint slash api slash events."
    "Версия один точка два точка три, билд номер пятьсот двадцать четыре."
    "Запрос обработался за двести пятьдесят миллисекунд, это в три раза быстрее."
    "Сервер на ip адресе сто девяносто два точка один шестьдесят восемь точка один точка сто."
    "Я тут смотрел документацию и понял что нам надо переписать вот этот сервис потому что он слишком медленно работает с большим количеством запросов одновременно."
    "Если ты успеешь до пятницы то давай мы это в релиз включим иначе перенесём на следующий спринт там посмотрим."
    "Окей я понял что ты имеешь в виду давай тогда так и сделаем."
    "Бэкенд возвращает четыреста четвёртую ошибку только когда юзер не авторизован при этом фронт показывает белый экран без какой-либо информации."
    ""
    "Раз два три."
    "Это последняя фраза в нашем тесте, спасибо что записали все двадцать пять."
)

# Duration in seconds for each phrase (index 0 = phrase 01).
DURATIONS=(6 6 6 6 6 6 6 6 6 6 6 6 6 6 6 7 7 7 12 7 7 12 5 3 6)

# Block labels for display (1-indexed phrase number -> block name).
block_label() {
    local n=$1
    if   [ "$n" -le 5  ]; then printf 'Block 1 — Russian conversational'
    elif [ "$n" -le 10 ]; then printf 'Block 2 — Tech anglicisms'
    elif [ "$n" -le 15 ]; then printf 'Block 3 — Code-switch'
    elif [ "$n" -le 18 ]; then printf 'Block 4 — Numbers and versions'
    elif [ "$n" -le 22 ]; then printf 'Block 5 — Long / fast speech'
    else                       printf 'Block 6 — Edge cases'
    fi
}

# ---------------------------------------------------------------------------
# Trap for summary on exit
# ---------------------------------------------------------------------------
print_summary() {
    printf '\n'
    printf '%b\n' "${C_BOLD}=== Recording session complete ===${C_RESET}"
    wav_count=$(find "${BENCH_DIR}" -name '*.wav' 2>/dev/null | wc -l | tr -d ' ')
    txt_count=$(find "${BENCH_DIR}" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
    printf '%b\n' "WAV files : ${C_GREEN}${wav_count}${C_RESET}"
    printf '%b\n' "TXT files : ${C_GREEN}${txt_count}${C_RESET}"
    printf 'Directory : %s\n' "${BENCH_DIR}"
    if [ "${wav_count}" -gt 0 ]; then
        printf '\nFile sizes:\n'
        find "${BENCH_DIR}" -name '*.wav' -exec stat -f '  %z  %N' {} \; 2>/dev/null \
            | sort || true
    fi
}
trap print_summary EXIT

# ---------------------------------------------------------------------------
# Main recording loop
# ---------------------------------------------------------------------------
printf '%b\n' "${C_BOLD}VoiceType Benchmark Recorder${C_RESET}"
printf 'Recording 25 phrases to %s\n' "${BENCH_DIR}"
printf '%b\n\n' "Press ${C_YELLOW}Ctrl-C${C_RESET} at any time to stop."

for i in "${!PHRASES[@]}"; do
    phrase_num=$(( i + 1 ))
    num_pad=$(printf '%02d' "${phrase_num}")
    wav_file="${BENCH_DIR}/${num_pad}.wav"
    txt_file="${BENCH_DIR}/${num_pad}.txt"
    duration="${DURATIONS[$i]}"
    phrase="${PHRASES[$i]}"
    ref="${REFS[$i]}"
    label="$(block_label "${phrase_num}")"

    while true; do
        clear
        printf '%b\n' "${C_BOLD}Phrase ${phrase_num} / 25${C_RESET}  |  ${label}"
        printf '%b\n\n' "Duration: ${C_YELLOW}${duration} seconds${C_RESET}"

        if [ "${phrase_num}" -eq 23 ]; then
            printf '%b\n\n' "${C_CYAN}[SILENCE TEST]${C_RESET} — do NOT speak. Record ${duration} s of room tone."
        else
            printf '%b\n\n' "${C_CYAN}${phrase}${C_RESET}"
        fi

        if [ -f "${wav_file}" ]; then
            printf '%b\n' "(existing recording found — press ${C_YELLOW}r${C_RESET} to re-record or ${C_YELLOW}Enter${C_RESET} to keep)"
        fi

        printf '%b' "Press ${C_GREEN}Enter${C_RESET} to start recording... "
        read -r response

        if [ "${response}" = "s" ] || [ "${response}" = "S" ]; then
            printf 'Skipping phrase %s.\n' "${phrase_num}"
            break
        fi

        printf '\n'
        printf '%b\n' "${C_RED}* RECORDING${C_RESET} (${duration}s) — speak now!"
        ffmpeg \
            -f avfoundation \
            -i ":0" \
            -t "${duration}" \
            -ar 16000 \
            -ac 1 \
            -y \
            -loglevel error \
            "${wav_file}"

        # Write reference text (empty for silence phrase 23).
        printf '%s' "${ref}" > "${txt_file}"

        printf '%b\n\n' "${C_GREEN}Saved:${C_RESET} ${wav_file}"
        printf '%b' "Press ${C_GREEN}Enter${C_RESET} for next phrase, or ${C_YELLOW}r${C_RESET} to re-record: "
        read -r choice

        if [ "${choice}" != "r" ] && [ "${choice}" != "R" ]; then
            break
        fi
        printf 'Re-recording phrase %s...\n' "${phrase_num}"
    done
done

printf '\n'
printf '%b\n' "${C_GREEN}All 25 phrases processed.${C_RESET}"
