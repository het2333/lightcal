#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-loop}"

TARGET_EPOCH="${TARGET_EPOCH:-2}"
POLL_SECONDS="${POLL_SECONDS:-60}"
STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_full_train}"
SWITCH_SCREEN="${SWITCH_SCREEN:-stage3_switch_to_r50m_after_eval}"
SMALL_SCREEN="${SMALL_SCREEN:-stage3_small_r50m_probe}"
STAGE3_WORK_ROOT="${STAGE3_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"
R101_OUTPUT_DIR="${R101_OUTPUT_DIR:-${STAGE3_WORK_ROOT}/output/stage3_r101_800px_40e}"
R101_LOG_JSON="${R101_LOG_JSON:-${R101_OUTPUT_DIR}/log.txt}"
R101_BEST="${R101_OUTPUT_DIR}/best.pth"
R101_LAST="${R101_OUTPUT_DIR}/last.pth"
SMALL_SCRIPT="${SMALL_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage3_small_probe.sh}"
SWITCH_ROOT="${SWITCH_ROOT:-/root/autodl-tmp/food_rtdetr_stage3_small/switch}"
SWITCH_LOG="${SWITCH_LOG:-${SWITCH_ROOT}/switch_to_r50m_after_eval.log}"
STATE_FILE="${STATE_FILE:-${SWITCH_ROOT}/switch_state.json}"

log() {
  mkdir -p "${SWITCH_ROOT}"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${SWITCH_LOG}"
}

write_state() {
  local event="$1"
  local extra="${2:-}"
  if [[ -z "${extra}" ]]; then
    extra="{}"
  fi
  mkdir -p "${SWITCH_ROOT}"
  /root/miniconda3/bin/python - "$event" "$extra" "${STATE_FILE}" <<'PY'
import json
import sys
import time
event, extra_text, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    extra = json.loads(extra_text)
except json.JSONDecodeError:
    extra = {"message": extra_text}
record = {"timestamp": time.strftime("%F %T"), "event": event, **extra}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

has_eval_epoch() {
  local epoch="$1"
  [[ -s "${R101_LOG_JSON}" ]] || return 1
  /root/miniconda3/bin/python - "${R101_LOG_JSON}" "${epoch}" <<'PY'
import json
import sys
path, target = sys.argv[1], int(sys.argv[2])
for line in open(path, encoding="utf-8"):
    if not line.strip():
        continue
    row = json.loads(line)
    if row.get("epoch") == target and row.get("test_coco_eval_bbox"):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

eval_summary_json() {
  /root/miniconda3/bin/python - "${R101_LOG_JSON}" "${TARGET_EPOCH}" <<'PY'
import json
import sys
path, target = sys.argv[1], int(sys.argv[2])
latest = None
for line in open(path, encoding="utf-8"):
    if not line.strip():
        continue
    row = json.loads(line)
    if row.get("epoch") == target and row.get("test_coco_eval_bbox"):
        latest = row
if latest is None:
    print("{}")
else:
    m = latest["test_coco_eval_bbox"]
    print(json.dumps({"epoch": target, "ap": m[0], "ap50": m[1], "ap75": m[2], "ar100": m[8]}, ensure_ascii=False))
PY
}

small_already_running() {
  screen -ls | grep -q "${SMALL_SCREEN}"
}

r101_running() {
  screen -ls | grep -q "${STAGE3_SCREEN}"
}

switch_once() {
  if [[ -s "${STATE_FILE}" ]] && grep -q "switch_to_small_started" "${STATE_FILE}"; then
    log "switch already recorded in ${STATE_FILE}; no-op"
    return 0
  fi

  if ! has_eval_epoch "${TARGET_EPOCH}"; then
    log "waiting_for_eval_epoch_${TARGET_EPOCH}"
    write_state "waiting_for_eval" "$(printf '{"target_epoch": %s}' "${TARGET_EPOCH}")"
    return 1
  fi

  local metrics
  metrics="$(eval_summary_json)"
  log "epoch ${TARGET_EPOCH} eval detected: ${metrics}"

  [[ -s "${R101_BEST}" ]] || { log "missing R101 best checkpoint: ${R101_BEST}"; return 2; }
  [[ -s "${R101_LAST}" ]] || { log "missing R101 last checkpoint: ${R101_LAST}"; return 2; }
  [[ -x "${SMALL_SCRIPT}" ]] || { log "missing executable small script: ${SMALL_SCRIPT}"; return 2; }

  if small_already_running; then
    log "small model session already running: ${SMALL_SCREEN}"
    write_state "switch_to_small_started" "${metrics}"
    return 0
  fi

  if r101_running; then
    log "stopping ${STAGE3_SCREEN} after epoch ${TARGET_EPOCH} eval"
    screen -S "${STAGE3_SCREEN}" -X quit
    sleep 10
  else
    log "${STAGE3_SCREEN} is not running"
  fi

  log "starting stage3_small_r50m_probe"
  ALLOW_CONCURRENT=1 "${SMALL_SCRIPT}" start
  write_state "switch_to_small_started" "${metrics}"
  log "switch_to_small_started"
}

loop() {
  while true; do
    if switch_once; then
      break
    fi
    sleep "${POLL_SECONDS}"
  done
}

case "${MODE}" in
  once)
    switch_once
    ;;
  loop)
    loop
    ;;
  status)
    log "mode=status target_epoch=${TARGET_EPOCH}"
    has_eval_epoch "${TARGET_EPOCH}" && eval_summary_json || true
    screen -ls || true
    ;;
  *)
    echo "Usage: $0 [loop|once|status]" >&2
    exit 64
    ;;
esac
