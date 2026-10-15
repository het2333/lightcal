#!/usr/bin/env bash
set -euo pipefail

STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3/output/stage3_r101_800px_40e}"
STAGE4_OUTPUT_DIR="${STAGE4_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"
OUTPUT_DIRS="${OUTPUT_DIRS:-${STAGE3_OUTPUT_DIR} ${STAGE4_OUTPUT_DIR}}"
LOG_PATH="${LOG_PATH:-/root/autodl-tmp/food_rtdetr_stage3/logs/checkpoint_janitor.log}"
CHECKPOINT_GLOB="${CHECKPOINT_GLOB:-checkpoint*.pth}"
KEEP_RECENT="${KEEP_RECENT:-3}"
MIN_AGE_MINUTES="${MIN_AGE_MINUTES:-20}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1800}"
MODE="${1:-loop}"

mkdir -p "$(dirname "${LOG_PATH}")"

log() {
  printf '[%s] %s\n' "$(date '+%F_%T')" "$*" >> "${LOG_PATH}"
}

clean_output_dir() {
  local output_dir="$1"
  local tmp checkpoint bytes

  [[ -d "${output_dir}" ]] || return 0
  tmp="$(mktemp)"
  find "${output_dir}" -maxdepth 1 -type f -name "${CHECKPOINT_GLOB}" -mmin +"${MIN_AGE_MINUTES}" -printf "%T@ %p\n" 2>/dev/null \
    | sort -nr > "${tmp}" || true

  awk -v keep="${KEEP_RECENT}" 'NR > keep {$1=""; sub(/^ /, ""); print}' "${tmp}" \
    | while IFS= read -r checkpoint; do
        [[ -n "${checkpoint}" ]] || continue
        if [[ -f "${checkpoint}" ]]; then
          bytes="$(stat -c %s "${checkpoint}" 2>/dev/null || echo 0)"
          rm -f -- "${checkpoint}"
          log "removed old checkpoint bytes=${bytes} path=${checkpoint}"
        fi
      done
  rm -f "${tmp}"
}

run_once() {
  local output_dir
  for output_dir in ${OUTPUT_DIRS}; do
    clean_output_dir "${output_dir}"
  done
  df -h /root/autodl-tmp >> "${LOG_PATH}" 2>&1 || true
}

log "checkpoint janitor started mode=${MODE} dirs=${OUTPUT_DIRS}"

if [[ "${MODE}" == "once" ]]; then
  run_once
elif [[ "${MODE}" == "loop" ]]; then
  while true; do
    run_once
    sleep "${SLEEP_SECONDS}"
  done
else
  echo "usage: $0 [once|loop]" >&2
  exit 2
fi
