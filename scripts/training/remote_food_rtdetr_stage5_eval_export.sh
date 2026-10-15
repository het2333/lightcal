#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
CAL_REPRO_ROOT="${CAL_REPRO_ROOT:-/root/autodl-tmp/cal-repro}"
RTDETR_ROOT="${RTDETR_ROOT:-/root/autodl-tmp/RT-DETR-main/rtdetrv2_pytorch}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"
MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R101}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage5_product}"
STAGE4_OUTPUT_DIR="${STAGE4_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"
STAGE4_CKPT="${STAGE4_CKPT:-}"
STAGE4_CONFIG="${STAGE4_CONFIG:-/root/autodl-tmp/food_rtdetr_stage4_clean/configs/food_rtdetrv1_stage4_clean_finetune.yml}"
CLEAN_DATASET_ROOT="${CLEAN_DATASET_ROOT:-/root/autodl-tmp/food_rtdetr_v2_mask/research_full}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${WORK_ROOT}/product_r101_800px}"
CONFIG_PATH="${CONFIG_PATH:-${WORK_ROOT}/configs/food_rtdetrv1_stage5_clean_test.yml}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-${OUTPUT_ROOT}/eval_clean_test}"
ONNX_OUTPUT="${ONNX_OUTPUT:-${OUTPUT_ROOT}/food_rtdetrv2_r101_800px_clean.onnx}"
ONNX_EXPORT_LOG="${ONNX_EXPORT_LOG:-${OUTPUT_ROOT}/onnx_export.log}"
MANIFEST_PATH="${MANIFEST_PATH:-${OUTPUT_ROOT}/product_manifest.json}"
VERIFICATION_PATH="${VERIFICATION_PATH:-${OUTPUT_ROOT}/product_verification.json}"
LABELS_JSON="${LABELS_JSON:-${OUTPUT_ROOT}/labels.json}"
MODEL_CARD="${MODEL_CARD:-${OUTPUT_ROOT}/MODEL_CARD.md}"
CLASS_MAP="${CLASS_MAP:-${CLEAN_DATASET_ROOT}/meta/class_map_v1.csv}"
SOURCE_COUNTS="${SOURCE_COUNTS:-/root/autodl-tmp/food_rtdetr_stage3/source_counts.csv}"
SOURCE_MAP="${SOURCE_MAP:-${CLEAN_DATASET_ROOT}/meta/source_map.csv}"
LICENSE_RISK="${LICENSE_RISK:-${CLEAN_DATASET_ROOT}/meta/license_risk.csv}"
PSEUDO_LABEL_SCORE="${PSEUDO_LABEL_SCORE:-${CLEAN_DATASET_ROOT}/meta/pseudo_label_score.csv}"
TEST_ANNOTATION="${TEST_ANNOTATION:-${CLEAN_DATASET_ROOT}/annotations/test.json}"
BUNDLE_META_DIR="${BUNDLE_META_DIR:-${OUTPUT_ROOT}/meta}"
INPUT_SIZE="${INPUT_SIZE:-800}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
RUN_EVAL="${RUN_EVAL:-1}"
RUN_EXPORT="${RUN_EXPORT:-1}"
INSTALL_ONNX="${INSTALL_ONNX:-1}"

mkdir -p "$(dirname "${CONFIG_PATH}")" "${EVAL_OUTPUT_DIR}" "$(dirname "${ONNX_OUTPUT}")"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

find_stage4_checkpoint() {
  if [[ -n "${STAGE4_CKPT}" && -s "${STAGE4_CKPT}" ]]; then
    printf '%s\n' "${STAGE4_CKPT}"
    return 0
  fi
  for candidate in "${STAGE4_OUTPUT_DIR}/best.pth" "${STAGE4_OUTPUT_DIR}/last.pth"; do
    if [[ -s "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  find "${STAGE4_OUTPUT_DIR}" -maxdepth 1 -type f -name 'checkpoint*.pth' -print0 2>/dev/null \
    | xargs -r -0 ls -t 2>/dev/null \
    | head -n 1
}

write_test_config() {
  cat > "${CONFIG_PATH}" <<YAML
__include__: [
  ${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml,
]

num_classes: 163
remap_mscoco_category: False
eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]
output_dir: ${EVAL_OUTPUT_DIR}

val_dataloader:
  dataset:
    img_folder: ${CLEAN_DATASET_ROOT}
    ann_file: ${CLEAN_DATASET_ROOT}/annotations/test.json
    return_masks: False
    transforms:
      ops:
        - {type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}
        - {type: ConvertPILImage, dtype: float32, scale: True}
  total_batch_size: 8
  num_workers: 4
  collate_fn:
    type: BatchImageCollateFunction

PResNet:
  pretrained: false
YAML
}

CKPT="$(find_stage4_checkpoint || true)"
if [[ -z "${CKPT}" || ! -s "${CKPT}" ]]; then
  log "未找到 stage4 checkpoint: ${STAGE4_OUTPUT_DIR}"
  exit 1
fi

write_test_config
log "stage5 checkpoint: ${CKPT}"
log "clean test config: ${CONFIG_PATH}"

if [[ "${RUN_EVAL}" == "1" ]]; then
  log "运行 clean test 评估"
  cd "${RTDETR_ROOT}"
  CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}" "${PYTHON_BIN}" tools/train.py \
    -c "${CONFIG_PATH}" \
    -r "${CKPT}" \
    --test-only \
    --output-dir "${EVAL_OUTPUT_DIR}" \
    > "${OUTPUT_ROOT}/clean_test_eval.log" 2>&1
fi

if [[ "${RUN_EXPORT}" == "1" ]]; then
  if [[ "${INSTALL_ONNX}" == "1" ]]; then
    "${PYTHON_BIN}" -m pip install -q onnx
  fi
  log "导出 ONNX: ${ONNX_OUTPUT}"
  cd "${RTDETR_ROOT}"
  CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}" "${PYTHON_BIN}" tools/export_onnx.py \
    -c "${STAGE4_CONFIG}" \
    -r "${CKPT}" \
    -o "${ONNX_OUTPUT}" \
    -s "${INPUT_SIZE}" \
    --check \
    > "${ONNX_EXPORT_LOG}" 2>&1
fi

log "生成 product manifest: metrics/dataset/sha256"
PYTHONPATH="${CAL_REPRO_ROOT}:${PYTHONPATH:-}" "${PYTHON_BIN}" -m scripts.training.food_rtdetr_product_manifest \
  --model "${MODEL_DISPLAY_NAME}" \
  --input-size "${INPUT_SIZE}" \
  --checkpoint "${CKPT}" \
  --onnx "${ONNX_OUTPUT}" \
  --clean-test-config "${CONFIG_PATH}" \
  --clean-test-eval-log "${OUTPUT_ROOT}/clean_test_eval.log" \
  --onnx-export-log "${ONNX_EXPORT_LOG}" \
  --eval-pth "${EVAL_OUTPUT_DIR}/eval.pth" \
  --class-map "${CLASS_MAP}" \
  --source-counts "${SOURCE_COUNTS}" \
  --source-map "${SOURCE_MAP}" \
  --license-risk "${LICENSE_RISK}" \
  --pseudo-label-score "${PSEUDO_LABEL_SCORE}" \
  --test-annotation "${TEST_ANNOTATION}" \
  --bundle-meta-dir "${BUNDLE_META_DIR}" \
  --labels-json "${LABELS_JSON}" \
  --model-card "${MODEL_CARD}" \
  --output "${MANIFEST_PATH}"

log "验证 product bundle: ${VERIFICATION_PATH}"
PYTHONPATH="${CAL_REPRO_ROOT}:${PYTHONPATH:-}" "${PYTHON_BIN}" -m scripts.training.food_rtdetr_product_verify \
  --manifest "${MANIFEST_PATH}" \
  --output "${VERIFICATION_PATH}"

log "stage5 完成: ${MANIFEST_PATH}"
