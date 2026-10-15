#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/build_food_rtdetr_v1_dataset.py}"
BASE_URL="${BASE_URL:-https://hf-mirror.com/datasets/EduardoPacheco/FoodSeg103/resolve/main/data}"
PARQUET_ROOT="${PARQUET_ROOT:-${WORK_ROOT}/raw_datasets/FoodSeg103HF/parquet}"
IMAGE_ROOT="${IMAGE_ROOT:-${WORK_ROOT}/raw_datasets/FoodSeg103HF/images}"
OUTPUT_JSONL="${OUTPUT_JSONL:-${WORK_ROOT}/normalized/FoodSeg103_hf_mask_to_bbox.jsonl}"

mkdir -p "${PARQUET_ROOT}" "${IMAGE_ROOT}" "$(dirname "${OUTPUT_JSONL}")"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

download_one() {
  local name="$1"
  local out="${PARQUET_ROOT}/${name}"
  if [[ -s "${out}" ]]; then
    log "已存在: ${out}"
    return 0
  fi
  log "下载 FoodSeg103 parquet: ${name}"
  wget -c --tries=20 --timeout=60 -O "${out}" "${BASE_URL}/${name}"
}

download_one train-00000-of-00003.parquet
download_one train-00001-of-00003.parquet
download_one train-00002-of-00003.parquet
download_one validation-00000-of-00001.parquet

"${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-foodseg-hf-parquet \
  --train-parquet \
    "${PARQUET_ROOT}/train-00000-of-00003.parquet" \
    "${PARQUET_ROOT}/train-00001-of-00003.parquet" \
    "${PARQUET_ROOT}/train-00002-of-00003.parquet" \
  --val-parquet "${PARQUET_ROOT}/validation-00000-of-00001.parquet" \
  --output-jsonl "${OUTPUT_JSONL}" \
  --image-output-root "${IMAGE_ROOT}" \
  --source-dataset FoodSeg103

log "转换完成: ${OUTPUT_JSONL}"
wc -l "${OUTPUT_JSONL}"
find "${IMAGE_ROOT}" -type f | wc -l
df -h "${WORK_ROOT}"
