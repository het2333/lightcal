#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-loop}"
POLL_SECONDS="${POLL_SECONDS:-300}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
RTDETR_ROOT="${RTDETR_ROOT:-/root/autodl-tmp/RT-DETR-main/rtdetrv2_pytorch}"
TRY_SCRIPT="${TRY_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/food_rtdetr_try_images.py}"

STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3_small/output/rtdetrv2_r50vd_m_7x_coco_640px_12e}"
CONFIG_PATH="${CONFIG_PATH:-/root/autodl-tmp/food_rtdetr_stage3_small/configs/food_rtdetrv2_r50vd_m_7x_coco_640px_12e.yml}"
CLASS_MAP="${CLASS_MAP:-/root/autodl-tmp/food_rtdetr_stage3/research_stage3_no_copy/meta/class_map_v1.csv}"
INPUT_DIR="${INPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3_small/user_try_images}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/root/autodl-tmp/food_rtdetr_stage3_small/try_images_after_checkpoint}"
WATCH_LOG="${WATCH_LOG:-/root/autodl-tmp/food_rtdetr_stage3_small/logs/try_after_checkpoint_watch.log}"
STATE_FILE="${STATE_FILE:-/root/autodl-tmp/food_rtdetr_stage3_small/logs/try_after_checkpoint_state.json}"

INPUT_SIZE="${INPUT_SIZE:-640}"
THRESHOLD="${THRESHOLD:-0.15}"
MAX_PREDICTIONS="${MAX_PREDICTIONS:-20}"
CHECKPOINT_STABLE_SECONDS="${CHECKPOINT_STABLE_SECONDS:-30}"

mkdir -p "$(dirname "${WATCH_LOG}")" "$(dirname "${STATE_FILE}")" "${OUTPUT_ROOT}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${WATCH_LOG}"
}

write_state() {
  local event="$1"
  local checkpoint_path="${2:-}"
  local output_dir="${3:-}"
  "${PYTHON_BIN}" - "${event}" "${checkpoint_path}" "${output_dir}" "${STATE_FILE}" <<'PY'
import json
import sys
import time

event, checkpoint_path, output_dir, state_file = sys.argv[1:5]
record = {
    "timestamp": time.strftime("%F %T"),
    "event": event,
}
if checkpoint_path:
    record["checkpoint_path"] = checkpoint_path
if output_dir:
    record["output_dir"] = output_dir
with open(state_file, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

find_checkpoint() {
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

checkpoint_is_stable() {
  local checkpoint_path="$1"
  [[ -s "${checkpoint_path}" ]] || return 1
  local checkpoint_size checkpoint_mtime now checkpoint_age_seconds
  checkpoint_size="$(stat -c%s "${checkpoint_path}")"
  checkpoint_mtime="$(stat -c%Y "${checkpoint_path}")"
  now="$(date +%s)"
  checkpoint_age_seconds=$((now - checkpoint_mtime))
  if (( checkpoint_age_seconds < CHECKPOINT_STABLE_SECONDS )); then
    log "checkpoint_not_stable_yet checkpoint=${checkpoint_path} checkpoint_size=${checkpoint_size} checkpoint_age_seconds=${checkpoint_age_seconds}"
    write_state "checkpoint_not_stable_yet" "${checkpoint_path}"
    return 1
  fi
  log "checkpoint_stable checkpoint=${checkpoint_path} checkpoint_size=${checkpoint_size} checkpoint_age_seconds=${checkpoint_age_seconds}"
  return 0
}

already_ran_for_checkpoint() {
  local checkpoint_path="$1"
  [[ -s "${STATE_FILE}" ]] || return 1
  grep -q '"event": "try_after_checkpoint_finished"' "${STATE_FILE}" \
    && grep -q "\"checkpoint_path\": \"${checkpoint_path}\"" "${STATE_FILE}"
}

validate_inputs() {
  [[ -d "${RTDETR_ROOT}" ]] || { log "missing RTDETR_ROOT=${RTDETR_ROOT}"; return 2; }
  [[ -f "${TRY_SCRIPT}" ]] || { log "missing TRY_SCRIPT=${TRY_SCRIPT}"; return 2; }
  [[ -f "${CONFIG_PATH}" ]] || { log "missing CONFIG_PATH=${CONFIG_PATH}"; return 2; }
  [[ -f "${CLASS_MAP}" ]] || { log "missing CLASS_MAP=${CLASS_MAP}"; return 2; }
  [[ -d "${INPUT_DIR}" ]] || { log "missing INPUT_DIR=${INPUT_DIR}"; return 2; }
  find "${INPUT_DIR}" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \) | grep -q . \
    || { log "no user images found in ${INPUT_DIR}"; return 2; }
}

run_try_once() {
  validate_inputs
  local checkpoint_path
  checkpoint_path="$(find_checkpoint || true)"
  if [[ -z "${checkpoint_path}" || ! -s "${checkpoint_path}" ]]; then
    log "waiting_for_checkpoint in ${STAGE3_OUTPUT_DIR}"
    write_state "waiting_for_checkpoint"
    return 1
  fi
  if ! checkpoint_is_stable "${checkpoint_path}"; then
    return 1
  fi
  if already_ran_for_checkpoint "${checkpoint_path}"; then
    log "try images already finished for checkpoint: ${checkpoint_path}"
    return 0
  fi

  local checkpoint_name output_dir
  checkpoint_name="$(basename "${checkpoint_path}" .pth)"
  output_dir="${OUTPUT_ROOT}/${checkpoint_name}_$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "${output_dir}"
  log "try_after_checkpoint_started checkpoint=${checkpoint_path} output=${output_dir}"
  write_state "try_after_checkpoint_started" "${checkpoint_path}" "${output_dir}"
  (
    cd "${RTDETR_ROOT}"
    CUDA_VISIBLE_DEVICES="" PYTHONPATH="${RTDETR_ROOT}:${PYTHONPATH:-}" "${PYTHON_BIN}" "${TRY_SCRIPT}" \
      --config "${CONFIG_PATH}" \
      --checkpoint "${checkpoint_path}" \
      --class-map "${CLASS_MAP}" \
      --input-dir "${INPUT_DIR}" \
      --output-dir "${output_dir}" \
      --threshold "${THRESHOLD}" \
      --input-size "${INPUT_SIZE}" \
      --device cpu \
      --max-predictions "${MAX_PREDICTIONS}"
  ) >> "${WATCH_LOG}" 2>&1
  write_state "try_after_checkpoint_finished" "${checkpoint_path}" "${output_dir}"
  log "try_after_checkpoint_finished output=${output_dir}"
  return 0
}

case "${MODE}" in
  once)
    run_try_once
    ;;
  loop)
    while true; do
      if run_try_once; then
        exit 0
      fi
      code=$?
      if [[ "${code}" == "2" ]]; then
        exit "${code}"
      fi
      sleep "${POLL_SECONDS}"
    done
    ;;
  *)
    echo "usage: $0 [once|loop]" >&2
    exit 64
    ;;
esac
