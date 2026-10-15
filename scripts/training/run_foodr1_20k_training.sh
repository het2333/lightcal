#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/autodl-tmp/glm_food_r1_experiment}"
TARGET_ROWS="${TARGET_ROWS:-20000}"
SEED="${SEED:-42}"

cd "${ROOT}"

mkdir -p data outputs

RAW_SFT="data/official_foodr1_sft_20k_raw.jsonl"
SFT="data/official_foodr1_sft_20k.jsonl"
GRPO="data/official_foodr1_grpo_20k.jsonl"
COT_SFT="data/official_foodr1_cot_sft_20k.jsonl"

echo "[$(date)] building >${TARGET_ROWS} official SFT rows"
.venv-train/bin/python scripts/build_official_foodr1_sft_dataset.py \
  --out "${RAW_SFT}" \
  --food101-per-class "${FOOD101_PER_CLASS:-100}" \
  --fooddialogues-limit "${FOODDIALOGUES_LIMIT:-4000}" \
  --mm-limit "${MM_LIMIT:-8000}"

raw_count="$(wc -l < "${RAW_SFT}")"
if [ "${raw_count}" -lt "${TARGET_ROWS}" ]; then
  echo "Only generated ${raw_count} rows, need ${TARGET_ROWS}" >&2
  exit 10
fi

echo "[$(date)] shuffling and cutting exactly ${TARGET_ROWS} rows"
shuf --random-source=<(yes "${SEED}") -n "${TARGET_ROWS}" "${RAW_SFT}" > "${SFT}"

echo "[$(date)] converting to Food-R1 GRPO and CoT SFT formats"
.venv-train/bin/python scripts/build_foodr1_grpo_dataset.py --input "${SFT}" --output "${GRPO}"
.venv-train/bin/python scripts/build_foodr1_cot_sft_dataset.py --input "${GRPO}" --output "${COT_SFT}"

echo "[$(date)] row counts"
wc -l "${SFT}" "${GRPO}" "${COT_SFT}"

SFT_OUT="${SFT_OUT:-${ROOT}/outputs/glm46_food_r1_cot_sft_20k_official_style}"
GRPO_OUT="${GRPO_OUT:-${ROOT}/outputs/glm46_food_r1_grpo_20k_official_style}"

echo "[$(date)] starting 20k CoT SFT"
source .venv-train/bin/activate
MAX_GPU_USED_MB="${MAX_GPU_USED_MB:-35000}" \
DATASET="${ROOT}/${COT_SFT}" \
OUT_DIR="${SFT_OUT}" \
SAVE_STEPS="${SFT_SAVE_STEPS:-250}" \
LOGGING_STEPS="${SFT_LOGGING_STEPS:-25}" \
GRAD_ACCUM="${SFT_GRAD_ACCUM:-2}" \
BATCH_SIZE="${SFT_BATCH_SIZE:-4}" \
LORA_RANK="${LORA_RANK:-16}" \
LORA_ALPHA="${LORA_ALPHA:-32}" \
NUM_TRAIN_EPOCHS="${SFT_NUM_TRAIN_EPOCHS:-1}" \
scripts/start_glm_food_r1_lora.sh

SFT_ADAPTER="$(find "${SFT_OUT}" -mindepth 2 -maxdepth 2 -type d -name 'checkpoint-*' | sort -V | tail -1)"
if [ -z "${SFT_ADAPTER}" ] || [ ! -f "${SFT_ADAPTER}/adapter_model.safetensors" ]; then
  echo "Cannot find SFT adapter under ${SFT_OUT}" >&2
  exit 11
fi

echo "[$(date)] starting 20k GRPO from ${SFT_ADAPTER}"
MAX_GPU_USED_MB="${MAX_GPU_USED_MB:-35000}" \
SFT_ADAPTER="${SFT_ADAPTER}" \
DATASET="${ROOT}/${GRPO}" \
OUT_DIR="${GRPO_OUT}" \
SAVE_STEPS="${GRPO_SAVE_STEPS:-500}" \
LOGGING_STEPS="${GRPO_LOGGING_STEPS:-25}" \
GRAD_ACCUM="${GRPO_GRAD_ACCUM:-1}" \
BATCH_SIZE="${GRPO_BATCH_SIZE:-16}" \
NUM_GENERATIONS="${GRPO_NUM_GENERATIONS:-2}" \
MAX_COMPLETION_LENGTH="${GRPO_MAX_COMPLETION_LENGTH:-160}" \
USE_VLLM="${GRPO_USE_VLLM:-false}" \
NUM_TRAIN_EPOCHS="${GRPO_NUM_TRAIN_EPOCHS:-1}" \
scripts/start_glm_food_r1_grpo.sh

echo "[$(date)] 20k Food-R1-style training finished"
