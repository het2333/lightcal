#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
RTDETR_ROOT="${RTDETR_ROOT:-/root/autodl-tmp/RT-DETR-main/rtdetrv2_pytorch}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage4_clean}"
CLEAN_DATASET_ROOT="${CLEAN_DATASET_ROOT:-/root/autodl-tmp/food_rtdetr_v2_mask/research_full}"
STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3/output/stage3_r101_800px_40e}"
STAGE3_CKPT="${STAGE3_CKPT:-}"
OUTPUT_DIR="${OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"
CONFIG_PATH="${CONFIG_PATH:-${WORK_ROOT}/configs/food_rtdetrv1_stage4_clean_finetune.yml}"
LOG_ROOT="${LOG_ROOT:-${WORK_ROOT}/logs}"
SESSION_NAME="${SESSION_NAME:-stage4_clean_finetune}"
EPOCHES="${EPOCHES:-40}"
BATCH_SIZE="${BATCH_SIZE:-8}"
INPUT_SIZE="${INPUT_SIZE:-800}"
NUM_CLASSES="${NUM_CLASSES:-163}"
NUM_WORKERS="${NUM_WORKERS:-4}"
CHECKPOINT_FREQ="${CHECKPOINT_FREQ:-1}"
LR="${LR:-0.00005}"
BACKBONE_LR="${BACKBONE_LR:-0.0000005}"
LR_DROP_EPOCH="${LR_DROP_EPOCH:-30}"
WARMUP_STEPS="${WARMUP_STEPS:-1000}"
COLLATE_SCALES="${COLLATE_SCALES:-640, 672, 704, 736, 768, ${INPUT_SIZE}, 832, 864, 896, 928, 960, 1024}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
SEED="${SEED:-0}"
WAIT_FOR_CKPT="${WAIT_FOR_CKPT:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-600}"
START_TRAIN="${START_TRAIN:-1}"

if [[ -z "${AUG_STOP_EPOCH:-}" ]]; then
  if (( EPOCHES > 5 )); then
    AUG_STOP_EPOCH="$((EPOCHES - 5))"
  else
    AUG_STOP_EPOCH="${EPOCHES}"
  fi
fi

mkdir -p "${WORK_ROOT}/configs" "${LOG_ROOT}" "${OUTPUT_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

find_stage3_checkpoint() {
  if [[ -n "${STAGE3_CKPT}" && -s "${STAGE3_CKPT}" ]]; then
    printf '%s\n' "${STAGE3_CKPT}"
    return 0
  fi
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

wait_for_checkpoint() {
  local ckpt=""
  while true; do
    ckpt="$(find_stage3_checkpoint || true)"
    if [[ -n "${ckpt}" && -s "${ckpt}" ]]; then
      printf '%s\n' "${ckpt}"
      return 0
    fi
    if [[ "${WAIT_FOR_CKPT}" != "1" ]]; then
      return 1
    fi
    log "尚未发现 stage3 checkpoint，${WAIT_SECONDS}s 后重试: ${STAGE3_OUTPUT_DIR}"
    sleep "${WAIT_SECONDS}"
  done
}

write_train_config() {
  cat > "${CONFIG_PATH}" <<YAML
__include__: [
  ${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml,
]

num_classes: ${NUM_CLASSES}
remap_mscoco_category: False
eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]
epoches: ${EPOCHES}
output_dir: ${OUTPUT_DIR}
print_freq: 20
checkpoint_freq: ${CHECKPOINT_FREQ}

optimizer:
  type: AdamW
  params:
    - params: '^(?=.*backbone)(?!.*norm|bn).*$'
      lr: ${BACKBONE_LR}
    - params: '^(?=.*(?:encoder|decoder))(?=.*(?:norm|bn)).*$'
      weight_decay: 0.
  lr: ${LR}
  betas: [0.9, 0.999]
  weight_decay: 0.0001

lr_scheduler:
  type: MultiStepLR
  milestones: [${LR_DROP_EPOCH}]
  gamma: 0.1

lr_warmup_scheduler:
  type: LinearWarmup
  warmup_duration: ${WARMUP_STEPS}

train_dataloader:
  dataset:
    img_folder: ${CLEAN_DATASET_ROOT}
    ann_file: ${CLEAN_DATASET_ROOT}/annotations/train.json
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
        epoch: ${AUG_STOP_EPOCH}
        ops: [RandomPhotometricDistort, RandomZoomOut, RandomIoUCrop]
  total_batch_size: ${BATCH_SIZE}
  num_workers: ${NUM_WORKERS}
  collate_fn:
    type: BatchImageCollateFunction
    scales: [${COLLATE_SCALES}]
    stop_epoch: ${AUG_STOP_EPOCH}

val_dataloader:
  dataset:
    img_folder: ${CLEAN_DATASET_ROOT}
    ann_file: ${CLEAN_DATASET_ROOT}/annotations/val.json
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
}

write_train_config
log "已写入 stage4 clean fine-tune 配置: ${CONFIG_PATH}"

if [[ "${START_TRAIN}" != "1" ]]; then
  log "START_TRAIN=${START_TRAIN}，只生成配置，不启动训练。"
  exit 0
fi

CKPT="$(wait_for_checkpoint || true)"
if [[ -z "${CKPT}" || ! -s "${CKPT}" ]]; then
  log "未找到可用 stage3 checkpoint。可设置 WAIT_FOR_CKPT=1 等待，或显式设置 STAGE3_CKPT。"
  exit 1
fi

if screen -ls | grep -q "[.]${SESSION_NAME}[[:space:]]"; then
  log "screen 已存在: ${SESSION_NAME}"
  exit 1
fi

TRAIN_LOG="${LOG_ROOT}/stage4_clean_finetune.log"
log "启动 stage4 clean fine-tune: checkpoint=${CKPT}"
screen -dmS "${SESSION_NAME}" bash -lc "cd ${RTDETR_ROOT} && CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES} ${PYTHON_BIN} tools/train.py -c ${CONFIG_PATH} -t ${CKPT} --use-amp --seed=${SEED} > ${TRAIN_LOG} 2>&1"
log "日志: ${TRAIN_LOG}"
