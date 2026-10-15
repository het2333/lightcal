#!/usr/bin/env bash
set -euo pipefail

RUN_MODE="${1:-prepare}"

MODEL_NAME="${MODEL_NAME:-rtdetrv2_r50vd_m_7x_coco}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r50vd_m_7x_coco}"
MODEL_CKPT_URL="${MODEL_CKPT_URL:-https://github.com/lyuwenyu/storage/releases/download/v0.1/rtdetrv2_r50vd_m_7x_coco_ema.pth}"
MODEL_CKPT_URLS="${MODEL_CKPT_URLS:-${MODEL_CKPT_URL} https://huggingface.co/ekky24/rtdetrv2_r50vd_m_7x_coco_ema/resolve/main/rtdetrv2_r50vd_m_7x_coco_ema.pth https://hf-mirror.com/ekky24/rtdetrv2_r50vd_m_7x_coco_ema/resolve/main/rtdetrv2_r50vd_m_7x_coco_ema.pth}"
MODEL_CKPT="${MODEL_CKPT:-/root/autodl-tmp/food_rtdetr_v1/checkpoints/rtdetrv2_r50vd_m_7x_coco_ema.pth}"

RTDETR_ROOT="${RTDETR_ROOT:-/root/autodl-tmp/RT-DETR-main/rtdetrv2_pytorch}"
DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/food_rtdetr_stage3/research_stage3_no_copy}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3_small}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

INPUT_SIZE="${INPUT_SIZE:-640}"
BATCH_SIZE="${BATCH_SIZE:-16}"
NUM_WORKERS="${NUM_WORKERS:-4}"
EPOCHES="${EPOCHES:-12}"
LR_DROP_EPOCH="${LR_DROP_EPOCH:-9}"
CHECKPOINT_FREQ="${CHECKPOINT_FREQ:-1}"
SEED="${SEED:-0}"
SESSION_NAME="${SESSION_NAME:-stage3_small_r50m_probe}"
ALLOW_CONCURRENT="${ALLOW_CONCURRENT:-0}"
DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-20}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-600}"
MODEL_CKPT_MIN_BYTES="${MODEL_CKPT_MIN_BYTES:-100000000}"

CONFIG_DIR="${WORK_ROOT}/configs"
LOG_DIR="${WORK_ROOT}/logs"
OUTPUT_DIR="${WORK_ROOT}/output/${MODEL_NAME}_${INPUT_SIZE}px_${EPOCHES}e"
CONFIG_PATH="${CONFIG_DIR}/food_${MODEL_NAME}_${INPUT_SIZE}px_${EPOCHES}e.yml"
TRAIN_LOG="${LOG_DIR}/${SESSION_NAME}.log"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

download_one_checkpoint() {
  local url="$1"
  mkdir -p "$(dirname "${MODEL_CKPT}")"
  rm -f "${MODEL_CKPT}.tmp"
  log "downloading ${url}"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x 8 -s 8 -c -o "$(basename "${MODEL_CKPT}.tmp")" -d "$(dirname "${MODEL_CKPT}")" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    timeout "${DOWNLOAD_MAX_TIME}" wget -c --timeout="${DOWNLOAD_CONNECT_TIMEOUT}" --tries=5 -O "${MODEL_CKPT}.tmp" "${url}"
  else
    curl -L \
      --connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT}" \
      --max-time "${DOWNLOAD_MAX_TIME}" \
      --retry 5 \
      --retry-delay 3 \
      -C - \
      -o "${MODEL_CKPT}.tmp" \
      "${url}"
  fi
  [[ -s "${MODEL_CKPT}.tmp" ]] || return 1
  mv "${MODEL_CKPT}.tmp" "${MODEL_CKPT}"
}

download_checkpoint() {
  mkdir -p "$(dirname "${MODEL_CKPT}")"
  if [[ -s "${MODEL_CKPT}" ]]; then
    local existing_size
    existing_size="$(stat -c%s "${MODEL_CKPT}")"
    if (( existing_size >= MODEL_CKPT_MIN_BYTES )); then
      log "checkpoint exists: ${MODEL_CKPT}"
      return
    fi
    log "checkpoint too small (${existing_size} bytes), removing: ${MODEL_CKPT}"
    rm -f "${MODEL_CKPT}"
  fi
  local url
  for url in ${MODEL_CKPT_URLS}; do
    if download_one_checkpoint "${url}"; then
      local downloaded_size
      downloaded_size="$(stat -c%s "${MODEL_CKPT}")"
      if (( downloaded_size < MODEL_CKPT_MIN_BYTES )); then
        log "checkpoint too small after download (${downloaded_size} bytes): ${url}"
        rm -f "${MODEL_CKPT}"
        continue
      fi
      log "checkpoint ready: ${MODEL_CKPT}"
      return
    fi
    log "download failed: ${url}"
    rm -f "${MODEL_CKPT}.tmp"
  done
  log "all checkpoint downloads failed"
  exit 5
}

write_config() {
  mkdir -p "${CONFIG_DIR}" "${LOG_DIR}" "${OUTPUT_DIR}"
  cat > "${CONFIG_PATH}" <<YAML
__include__: [
  ${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml,
]

num_classes: 163
remap_mscoco_category: False
eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]
epoches: ${EPOCHES}
output_dir: ${OUTPUT_DIR}
print_freq: 20
checkpoint_freq: ${CHECKPOINT_FREQ}

optimizer:
  type: AdamW
  params:
    -
      params: '^(?=.*backbone)(?!.*norm|bn).*$'
      lr: 0.000001
    -
      params: '^(?=.*(?:encoder|decoder))(?=.*(?:norm|bn)).*$'
      weight_decay: 0.
  lr: 0.00001
  betas: [0.9, 0.999]
  weight_decay: 0.0001

lr_scheduler:
  type: MultiStepLR
  milestones: [${LR_DROP_EPOCH}]
  gamma: 0.1

train_dataloader:
  dataset:
    img_folder: ${DATA_ROOT}
    ann_file: ${DATA_ROOT}/annotations/train.json
    return_masks: False
    transforms:
      ops:
        - {type: RandomPhotometricDistort, p: 0.5}
        - {type: RandomZoomOut, fill: 0}
        - {type: RandomIoUCrop, p: 0.8}
        - {type: SanitizeBoundingBoxes, min_size: 1}
        - {type: RandomHorizontalFlip}
        - {type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}
        - {type: SanitizeBoundingBoxes, min_size: 1}
        - {type: ConvertPILImage, dtype: float32, scale: True}
        - {type: ConvertBoxes, fmt: cxcywh, normalize: True}
      policy:
        name: stop_epoch
        epoch: ${EPOCHES}
        ops: [RandomPhotometricDistort, RandomZoomOut, RandomIoUCrop]
  total_batch_size: ${BATCH_SIZE}
  num_workers: ${NUM_WORKERS}
  collate_fn:
    type: BatchImageCollateFunction

val_dataloader:
  dataset:
    img_folder: ${DATA_ROOT}
    ann_file: ${DATA_ROOT}/annotations/val.json
    return_masks: False
    transforms:
      ops:
        - {type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}
        - {type: ConvertPILImage, dtype: float32, scale: True}
  total_batch_size: ${BATCH_SIZE}
  num_workers: ${NUM_WORKERS}
  collate_fn:
    type: BatchImageCollateFunction

PResNet:
  pretrained: false
YAML
  log "wrote config: ${CONFIG_PATH}"
}

ensure_ready() {
  [[ -d "${RTDETR_ROOT}" ]] || { log "missing RTDETR_ROOT=${RTDETR_ROOT}"; exit 2; }
  [[ -f "${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml" ]] || { log "missing model config ${MODEL_CONFIG_NAME}"; exit 2; }
  [[ -f "${DATA_ROOT}/annotations/train.json" ]] || { log "missing train annotation"; exit 2; }
  [[ -f "${DATA_ROOT}/annotations/val.json" ]] || { log "missing val annotation"; exit 2; }
  write_config
  download_checkpoint
}

assert_can_start() {
  if screen -ls | grep -q "stage3_full_train" && [[ "${ALLOW_CONCURRENT}" != "1" ]]; then
    log "Refusing to start small probe while stage3_full_train is running. Set ALLOW_CONCURRENT=1 or stop/pause R101 first."
    exit 3
  fi
  if screen -ls | grep -q "${SESSION_NAME}"; then
    log "session already exists: ${SESSION_NAME}"
    exit 4
  fi
}

start_training() {
  ensure_ready
  assert_can_start
  log "starting ${SESSION_NAME}"
  screen -dmS "${SESSION_NAME}" bash -lc "cd ${RTDETR_ROOT} && CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES} ${PYTHON_BIN} tools/train.py -c ${CONFIG_PATH} -t ${MODEL_CKPT} --use-amp --seed=${SEED} > ${TRAIN_LOG} 2>&1"
  log "log: ${TRAIN_LOG}"
}

case "${RUN_MODE}" in
  prepare)
    ensure_ready
    ;;
  start)
    start_training
    ;;
  status)
    screen -ls || true
    ls -lh "${MODEL_CKPT}" "${CONFIG_PATH}" "${TRAIN_LOG}" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 [prepare|start|status]" >&2
    exit 64
    ;;
esac
