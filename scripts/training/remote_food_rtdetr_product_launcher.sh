#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_v1}"
TRAIN_SCRIPT="${TRAIN_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_v1_train.sh}"
PREPARE_SESSION="${PREPARE_SESSION:-food_rtdetr_prepare}"
SMOKE_SESSION="${SMOKE_SESSION:-food_rtdetr_r101_uec100_smoke}"
CHECKPOINT_SESSION="${CHECKPOINT_SESSION:-food_rtdetr_r101_ckpt}"
LOG_ROOT="${WORK_ROOT}/logs"
LOG_PATH="${LOG_ROOT}/product_launcher.log"
EPOCHES="${EPOCHES:-220}"
SMOKE_EPOCHES="${SMOKE_EPOCHES:-2}"
BATCH_SIZE="${BATCH_SIZE:-4}"
INPUT_SIZE="${INPUT_SIZE:-800}"
PRETRAINED_CKPT="${PRETRAINED_CKPT:-${WORK_ROOT}/checkpoints/rtdetrv2_r101vd_6x_coco_from_paddle.pth}"
PRETRAINED_URL="${PRETRAINED_URL:-https://hf-mirror.com/yours-mykola/rt-detr-v2-r101vd/resolve/main/rtdetrv2_r101vd_6x_coco_from_paddle.pth}"
MIN_CHECKPOINT_BYTES="${MIN_CHECKPOINT_BYTES:-300000000}"

mkdir -p "${LOG_ROOT}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${LOG_PATH}"
}

screen_exists() {
  local session_name="$1"
  screen -list | grep -q "[.]${session_name}[[:space:]]"
}

wait_for_screen_exit() {
  local session_name="$1"
  local label="$2"
  if screen_exists "${session_name}"; then
    log "waiting for ${label}: ${session_name}"
  fi
  while screen_exists "${session_name}"; do
    sleep 60
  done
  log "${label} is not running: ${session_name}"
}

fail_if_log_has_marker() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]] && grep -Eq "Traceback|CUDA out of memory|RuntimeError|No space|没有可训练|download_failed" "${path}"; then
    log "${label} log contains a failure marker: ${path}"
    exit 1
  fi
}

checkpoint_ready() {
  [[ -f "${PRETRAINED_CKPT}" ]] || return 1
  local bytes
  bytes="$(stat -c '%s' "${PRETRAINED_CKPT}" 2>/dev/null || echo 0)"
  (( bytes >= MIN_CHECKPOINT_BYTES ))
}

main() {
  log "product launcher started"
  wait_for_screen_exit "${PREPARE_SESSION}" "full data preparation"
  fail_if_log_has_marker "${WORK_ROOT}/prepare.log" "preparation"

  wait_for_screen_exit "${SMOKE_SESSION}" "R101 UEC100 smoke"
  fail_if_log_has_marker "${LOG_ROOT}/r101_uec100_smoke_train.log" "R101 UEC100 smoke"

  wait_for_screen_exit "${CHECKPOINT_SESSION}" "R101 checkpoint download"
  local use_tuning=0
  if checkpoint_ready; then
    use_tuning=1
    log "using R101 tuning checkpoint: ${PRETRAINED_CKPT}"
  else
    log "R101 tuning checkpoint is not ready; launching without -t"
  fi

  log "launching full-data R101 pipeline"
  PYTHON_BIN="${PYTHON_BIN}" \
  WORK_ROOT="${WORK_ROOT}" \
  EPOCHES="${EPOCHES}" \
  SMOKE_EPOCHES="${SMOKE_EPOCHES}" \
  BATCH_SIZE="${BATCH_SIZE}" \
  INPUT_SIZE="${INPUT_SIZE}" \
  MODEL_CONFIG_NAME=rtdetrv2_r101vd_6x_coco \
  USE_MODEL_TUNING_CKPT="${use_tuning}" \
  PRETRAINED_CKPT="${PRETRAINED_CKPT}" \
  PRETRAINED_URL="${PRETRAINED_URL}" \
  USE_BACKBONE_PRETRAINED=false \
  START_TRAIN=1 \
  AUTO_START_FULL_AFTER_SMOKE=1 \
  "${TRAIN_SCRIPT}" >> "${LOG_PATH}" 2>&1
}

main "$@"
