#!/usr/bin/env bash
set -euo pipefail

BASE_MODEL="${BASE_MODEL:-/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash}"
DATASET="${DATASET:-/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_sft.jsonl}"
OUT_DIR="${OUT_DIR:-/root/autodl-tmp/glm_food_r1_experiment/outputs/glm46_food_r1_lora}"
MAX_GPU_USED_MB="${MAX_GPU_USED_MB:-24000}"

if [ ! -f "${BASE_MODEL}/model-00001-of-00004.safetensors" ]; then
  echo "GLM weights are incomplete: ${BASE_MODEL}" >&2
  exit 2
fi

if [ ! -s "${DATASET}" ]; then
  echo "Dataset is missing or empty: ${DATASET}" >&2
  exit 3
fi

gpu_used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')"
if [ "${gpu_used:-0}" -gt "${MAX_GPU_USED_MB}" ]; then
  echo "GPU is busy (${gpu_used} MiB used). Refusing to start training so phone inference stays usable." >&2
  exit 4
fi

mkdir -p "${OUT_DIR}"

extra_args=()
if [ -n "${MAX_STEPS:-}" ]; then
  extra_args+=(--max_steps "${MAX_STEPS}")
fi

exec swift sft \
  --model "${BASE_MODEL}" \
  --dataset "${DATASET}" \
  --quant_method "${QUANT_METHOD:-bnb}" \
  --quant_bits "${QUANT_BITS:-4}" \
  --torch_dtype bfloat16 \
  --num_train_epochs "${NUM_TRAIN_EPOCHS:-1}" \
  "${extra_args[@]}" \
  --per_device_train_batch_size "${BATCH_SIZE:-1}" \
  --gradient_accumulation_steps "${GRAD_ACCUM:-8}" \
  --gradient_checkpointing "${GRADIENT_CHECKPOINTING:-true}" \
  --freeze_vit "${FREEZE_VIT:-true}" \
  --learning_rate "${LR:-1e-4}" \
  --lora_rank "${LORA_RANK:-16}" \
  --lora_alpha "${LORA_ALPHA:-32}" \
  --save_steps "${SAVE_STEPS:-50}" \
  --logging_steps "${LOGGING_STEPS:-5}" \
  --max_length "${MAX_LENGTH:-2048}" \
  --output_dir "${OUT_DIR}"
