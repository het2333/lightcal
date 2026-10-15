#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="${SCRIPT_ROOT:-/root/autodl-tmp/cal-repro/scripts/training}"
STAGE3_WORK_ROOT="${STAGE3_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3_small}"
STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_small_r50m_probe}"
STAGE3_LOG="${STAGE3_LOG:-${STAGE3_WORK_ROOT}/logs/stage3_small_r50m_probe.log}"
STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-${STAGE3_WORK_ROOT}/output/rtdetrv2_r50vd_m_7x_coco_640px_12e}"
STAGE4_SCRIPT="${STAGE4_SCRIPT:-${SCRIPT_ROOT}/remote_food_rtdetr_stage4_clean_finetune.sh}"
STAGE5_WATCH_SCRIPT="${STAGE5_WATCH_SCRIPT:-${SCRIPT_ROOT}/remote_food_rtdetr_stage5_after_stage4_watch.sh}"
WATCH_ROOT="${WATCH_ROOT:-/root/autodl-tmp/food_rtdetr_stage4_clean_r50m}"
WATCH_LOG="${WATCH_LOG:-${WATCH_ROOT}/logs/stage4_after_stage3_small_watch.log}"
STAGE4_SESSION="${STAGE4_SESSION:-stage4_clean_finetune_r50m}"
STAGE5_WATCH_SESSION="${STAGE5_WATCH_SESSION:-stage5_after_stage4_r50m_watch}"
STAGE5_SESSION="${STAGE5_SESSION:-stage5_eval_export_r50m}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-300}"
START_STAGE4="${START_STAGE4:-1}"
START_STAGE5_WATCH="${START_STAGE5_WATCH:-1}"
MODE="${1:-loop}"
FAILURE_PATTERN="${FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert}"

MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r50vd_m_7x_coco}"
MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R50-M}"
INPUT_SIZE="${INPUT_SIZE:-640}"
BATCH_SIZE="${BATCH_SIZE:-16}"
NUM_WORKERS="${NUM_WORKERS:-2}"
EPOCHES="${EPOCHES:-24}"
LR_DROP_EPOCH="${LR_DROP_EPOCH:-18}"

STAGE4_WORK_ROOT="${STAGE4_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage4_clean_r50m}"
STAGE4_OUTPUT_DIR="${STAGE4_OUTPUT_DIR:-${STAGE4_WORK_ROOT}/output/r50m_640px_clean_finetune}"
STAGE4_CONFIG="${STAGE4_CONFIG:-${STAGE4_WORK_ROOT}/configs/food_rtdetrv2_r50m_stage4_clean_finetune.yml}"
STAGE4_LOG_ROOT="${STAGE4_LOG_ROOT:-${STAGE4_WORK_ROOT}/logs}"
STAGE5_WORK_ROOT="${STAGE5_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage5_product_r50m}"
STAGE5_OUTPUT_ROOT="${STAGE5_OUTPUT_ROOT:-${STAGE5_WORK_ROOT}/product_r50m_640px}"

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

start_stage5_watch() {
  if [[ "${START_STAGE5_WATCH}" != "1" ]]; then
    log "START_STAGE5_WATCH=${START_STAGE5_WATCH}; not starting stage5 watcher"
    return 0
  fi
  if screen_exists "${STAGE5_WATCH_SESSION}"; then
    log "stage5 watcher already exists: ${STAGE5_WATCH_SESSION}"
    return 0
  fi
  log "starting R50-M stage5 watcher: ${STAGE5_WATCH_SESSION}"
  screen -dmS "${STAGE5_WATCH_SESSION}" bash -lc "STAGE4_WORK_ROOT='${STAGE4_WORK_ROOT}' STAGE4_SCREEN='${STAGE4_SESSION}' STAGE4_LOG='${STAGE4_LOG_ROOT}/stage4_clean_finetune.log' STAGE5_SESSION='${STAGE5_SESSION}' STAGE5_SCRIPT='/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage5_eval_export.sh' CHECK_INTERVAL_SECONDS=300 START_STAGE5=1 MODEL_CONFIG_NAME='${MODEL_CONFIG_NAME}' MODEL_DISPLAY_NAME='${MODEL_DISPLAY_NAME}' INPUT_SIZE='${INPUT_SIZE}' WORK_ROOT='${STAGE5_WORK_ROOT}' STAGE4_OUTPUT_DIR='${STAGE4_OUTPUT_DIR}' STAGE4_CONFIG='${STAGE4_CONFIG}' OUTPUT_ROOT='${STAGE5_OUTPUT_ROOT}' ONNX_OUTPUT='${STAGE5_OUTPUT_ROOT}/food_rtdetrv2_r50m_640px_clean.onnx' /root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage5_after_stage4_watch.sh loop"
}

start_stage4() {
  local ckpt="$1"
  if screen_exists "${STAGE4_SESSION}"; then
    log "stage4 screen already exists: ${STAGE4_SESSION}"
    start_stage5_watch
    return 0
  fi
  if [[ "${START_STAGE4}" != "1" ]]; then
    log "START_STAGE4=${START_STAGE4}; would start R50-M stage4 with ${ckpt}"
    return 0
  fi
  log "starting R50-M clean fine-tune from checkpoint: ${ckpt}"
  MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME}" \
  STAGE3_CKPT="${ckpt}" \
  SESSION_NAME="${STAGE4_SESSION}" \
  WORK_ROOT="${STAGE4_WORK_ROOT}" \
  STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR}" \
  OUTPUT_DIR="${STAGE4_OUTPUT_DIR}" \
  CONFIG_PATH="${STAGE4_CONFIG}" \
  LOG_ROOT="${STAGE4_LOG_ROOT}" \
  INPUT_SIZE="${INPUT_SIZE}" \
  BATCH_SIZE="${BATCH_SIZE}" \
  NUM_WORKERS="${NUM_WORKERS}" \
  EPOCHES="${EPOCHES}" \
  LR_DROP_EPOCH="${LR_DROP_EPOCH}" \
  "${STAGE4_SCRIPT}"
  start_stage5_watch
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
    log "R50-M stage3 failure pattern seen before completion; not starting stage4"
    return 2
  fi
  if [[ "${completed}" == "yes" && -n "${ckpt}" && -s "${ckpt}" ]]; then
    start_stage4 "${ckpt}"
    return 0
  fi
  if [[ "${running}" != "yes" && "${completed}" != "yes" && ! -f "${STAGE3_LOG}" ]]; then
    log "R50-M stage3 has not started yet; waiting"
    return 1
  fi
  if [[ "${running}" != "yes" && "${completed}" != "yes" ]]; then
    log "R50-M stage3 screen is absent and completion marker is missing; not starting stage4"
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
