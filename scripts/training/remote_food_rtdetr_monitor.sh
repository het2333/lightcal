#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"
SCREEN_NAME="${SCREEN_NAME:-stage3_full_train}"
TRAIN_LOG="${TRAIN_LOG:-${WORK_ROOT}/logs/stage3_full_train.log}"
STATUS_JSONL="${STATUS_JSONL:-${WORK_ROOT}/logs/stage3_full_monitor.jsonl}"
TRAIN_MATCH="${TRAIN_MATCH:-tools/train.py}"
MONITOR_INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-300}"
FAILURE_PATTERN="${FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert}"
MODE="${1:-once}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

write_status_once() {
  mkdir -p "$(dirname "${STATUS_JSONL}")"
  SCREEN_NAME="${SCREEN_NAME}" \
  WORK_ROOT="${WORK_ROOT}" \
  TRAIN_LOG="${TRAIN_LOG}" \
  STATUS_JSONL="${STATUS_JSONL}" \
  TRAIN_MATCH="${TRAIN_MATCH}" \
  FAILURE_PATTERN="${FAILURE_PATTERN}" \
  PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}" \
  "${PYTHON_BIN}" -m scripts.training.food_rtdetr_stage3_monitor
}

if [[ "${MODE}" == "once" ]]; then
  write_status_once
elif [[ "${MODE}" == "loop" ]]; then
  while true; do
    write_status_once
    sleep "${MONITOR_INTERVAL_SECONDS}"
  done
else
  echo "usage: $0 [once|loop]" >&2
  exit 2
fi
