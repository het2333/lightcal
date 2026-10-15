#!/usr/bin/env bash
set -euo pipefail

STAGE3_WORK_ROOT="${STAGE3_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"
STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_full_train}"
STAGE3_LOG="${STAGE3_LOG:-${STAGE3_WORK_ROOT}/logs/stage3_full_train.log}"
STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-${STAGE3_WORK_ROOT}/output/stage3_r101_800px_40e}"
STAGE4_SCRIPT="${STAGE4_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage4_clean_finetune.sh}"
WATCH_LOG="${WATCH_LOG:-${STAGE3_WORK_ROOT}/logs/stage4_after_stage3_watch.log}"
STAGE4_SESSION="${STAGE4_SESSION:-stage4_clean_finetune}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-600}"
START_STAGE4="${START_STAGE4:-1}"
MODE="${1:-loop}"
FAILURE_PATTERN="${FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert}"

mkdir -p "$(dirname "${WATCH_LOG}")"

log() {
  local message="$*"
  printf '[%s] %s\n' "$(date '+%F %T')" "${message}" | tee -a "${WATCH_LOG}"
}

screen_exists() {
  screen -ls | grep -q "[.]${1}[[:space:]]"
}

find_stage3_checkpoint() {
  for candidate in "${STAGE3_OUTPUT_DIR}/best.pth" "${STAGE3_OUTPUT_DIR}/last.pth"; do
    if [[ -s "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  find "${STAGE3_OUTPUT_DIR}" -maxdepth 1 -type f -name 'checkpoint*.pth' -print0 2>/dev/null \
    | xargs -r -0 ls -t 2>/dev/null \
    | head -n 1
}

stage3_status_once() {
  local completed="no"
  local failed="no"
  local running="no"
  local ckpt=""
  if [[ -f "${STAGE3_LOG}" ]] && grep -q "Training time" "${STAGE3_LOG}"; then
    completed="yes"
  fi
  if [[ -f "${STAGE3_LOG}" ]] && grep -Eiq "${FAILURE_PATTERN}" "${STAGE3_LOG}"; then
    failed="yes"
  fi
  if screen_exists "${STAGE3_SCREEN}"; then
    running="yes"
  fi
  ckpt="$(find_stage3_checkpoint || true)"
  printf 'completed=%s failed=%s running=%s checkpoint=%s\n' "${completed}" "${failed}" "${running}" "${ckpt}"
}

start_stage4() {
  local ckpt="$1"
  if screen_exists "${STAGE4_SESSION}"; then
    log "stage4 screen already exists: ${STAGE4_SESSION}"
    return 0
  fi
  if [[ "${START_STAGE4}" != "1" ]]; then
    log "START_STAGE4=${START_STAGE4}; would start stage4 with ${ckpt}"
    return 0
  fi
  log "starting stage4 clean fine-tune from checkpoint: ${ckpt}"
  STAGE3_CKPT="${ckpt}" SESSION_NAME="${STAGE4_SESSION}" "${STAGE4_SCRIPT}"
}

check_once() {
  local status completed failed running ckpt
  status="$(stage3_status_once)"
  log "status ${status}"
  completed="$(printf '%s\n' "${status}" | sed -n 's/.*completed=\([^ ]*\).*/\1/p')"
  failed="$(printf '%s\n' "${status}" | sed -n 's/.*failed=\([^ ]*\).*/\1/p')"
  running="$(printf '%s\n' "${status}" | sed -n 's/.*running=\([^ ]*\).*/\1/p')"
  ckpt="$(printf '%s\n' "${status}" | sed -n 's/.*checkpoint=\(.*\)$/\1/p')"

  if [[ "${failed}" == "yes" && "${completed}" != "yes" ]]; then
    log "stage3 failure pattern seen before completion; not starting stage4"
    return 2
  fi
  if [[ "${completed}" == "yes" && -n "${ckpt}" && -s "${ckpt}" ]]; then
    start_stage4 "${ckpt}"
    return 0
  fi
  if [[ "${running}" != "yes" && "${completed}" != "yes" ]]; then
    log "stage3 screen is absent and completion marker is missing; not starting stage4"
    return 3
  fi
  return 1
}

if [[ "${MODE}" == "once" ]]; then
  check_once
elif [[ "${MODE}" == "loop" ]]; then
  while true; do
    if check_once; then
      exit 0
    fi
    code=$?
    if [[ "${code}" == "2" || "${code}" == "3" ]]; then
      exit "${code}"
    fi
    sleep "${CHECK_INTERVAL_SECONDS}"
  done
else
  echo "usage: $0 [once|loop]" >&2
  exit 2
fi
