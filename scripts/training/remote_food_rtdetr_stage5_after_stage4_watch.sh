#!/usr/bin/env bash
set -euo pipefail

STAGE4_WORK_ROOT="${STAGE4_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage4_clean}"
STAGE4_SCREEN="${STAGE4_SCREEN:-stage4_clean_finetune}"
STAGE4_LOG="${STAGE4_LOG:-${STAGE4_WORK_ROOT}/logs/stage4_clean_finetune.log}"
STAGE5_SCRIPT="${STAGE5_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage5_eval_export.sh}"
WATCH_LOG="${WATCH_LOG:-${STAGE4_WORK_ROOT}/logs/stage5_after_stage4_watch.log}"
STAGE5_SESSION="${STAGE5_SESSION:-stage5_eval_export}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-600}"
START_STAGE5="${START_STAGE5:-1}"
MODE="${1:-loop}"
FAILURE_PATTERN="${FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert}"

MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"
MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R101}"
INPUT_SIZE="${INPUT_SIZE:-800}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage5_product}"
STAGE4_OUTPUT_DIR="${STAGE4_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"
STAGE4_CONFIG="${STAGE4_CONFIG:-/root/autodl-tmp/food_rtdetr_stage4_clean/configs/food_rtdetrv1_stage4_clean_finetune.yml}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${WORK_ROOT}/product_r101_800px}"
ONNX_OUTPUT="${ONNX_OUTPUT:-${OUTPUT_ROOT}/food_rtdetrv2_r101_800px_clean.onnx}"
STAGE5_SCREEN_LOG="${STAGE5_SCREEN_LOG:-${WORK_ROOT}/stage5_eval_export.screen.log}"

mkdir -p "$(dirname "${WATCH_LOG}")"

log() {
  local message="$*"
  printf '[%s] %s\n' "$(date '+%F %T')" "${message}" | tee -a "${WATCH_LOG}"
}

screen_exists() {
  screen -ls | grep -q "[.]${1}[[:space:]]"
}

stage4_status_once() {
  local completed="no"
  local failed="no"
  local running="no"
  if [[ -f "${STAGE4_LOG}" ]] && grep -q "Training time" "${STAGE4_LOG}"; then
    completed="yes"
  fi
  if [[ -f "${STAGE4_LOG}" ]] && grep -Eiq "${FAILURE_PATTERN}" "${STAGE4_LOG}"; then
    failed="yes"
  fi
  if screen_exists "${STAGE4_SCREEN}"; then
    running="yes"
  fi
  printf 'completed=%s failed=%s running=%s log_exists=%s\n' \
    "${completed}" "${failed}" "${running}" "$([[ -f "${STAGE4_LOG}" ]] && echo yes || echo no)"
}

start_stage5() {
  if screen_exists "${STAGE5_SESSION}"; then
    log "stage5 screen already exists: ${STAGE5_SESSION}"
    return 0
  fi
  if [[ "${START_STAGE5}" != "1" ]]; then
    log "START_STAGE5=${START_STAGE5}; would start stage5 eval/export"
    return 0
  fi
  log "starting stage5 eval/export"
  mkdir -p "${WORK_ROOT}"
  screen -dmS "${STAGE5_SESSION}" bash -lc "MODEL_CONFIG_NAME='${MODEL_CONFIG_NAME}' MODEL_DISPLAY_NAME='${MODEL_DISPLAY_NAME}' INPUT_SIZE='${INPUT_SIZE}' WORK_ROOT='${WORK_ROOT}' STAGE4_OUTPUT_DIR='${STAGE4_OUTPUT_DIR}' STAGE4_CONFIG='${STAGE4_CONFIG}' OUTPUT_ROOT='${OUTPUT_ROOT}' ONNX_OUTPUT='${ONNX_OUTPUT}' '${STAGE5_SCRIPT}' >\"${STAGE5_SCREEN_LOG}\" 2>&1"
}

check_once() {
  local status completed failed running log_exists
  status="$(stage4_status_once)"
  log "status ${status}"
  completed="$(printf '%s\n' "${status}" | sed -n 's/.*completed=\([^ ]*\).*/\1/p')"
  failed="$(printf '%s\n' "${status}" | sed -n 's/.*failed=\([^ ]*\).*/\1/p')"
  running="$(printf '%s\n' "${status}" | sed -n 's/.*running=\([^ ]*\).*/\1/p')"
  log_exists="$(printf '%s\n' "${status}" | sed -n 's/.*log_exists=\([^ ]*\).*/\1/p')"

  if [[ "${failed}" == "yes" && "${completed}" != "yes" ]]; then
    log "stage4 failure pattern seen before completion; not starting stage5"
    return 2
  fi
  if [[ "${completed}" == "yes" ]]; then
    start_stage5
    return 0
  fi
  if [[ "${running}" != "yes" && "${log_exists}" == "yes" ]]; then
    log "stage4 log exists but completion marker is missing and screen is absent; not starting stage5"
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
