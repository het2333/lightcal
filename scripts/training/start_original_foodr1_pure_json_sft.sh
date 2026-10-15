#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/autodl-tmp/glm_food_r1_experiment}"
BASE_MODEL="${BASE_MODEL:-/root/autodl-tmp/modelscope-cache-ms/zy12123/Food-R1}"
DATASET="${DATASET:-${ROOT}/data/pure_json_sft_2k_images.jsonl}"
OUT_DIR="${OUT_DIR:-${ROOT}/outputs/original_foodr1_pure_json_sft_2k}"
MAX_GPU_USED_MB="${MAX_GPU_USED_MB:-24000}"

if [ ! -f "${BASE_MODEL}/model-00001-of-00004.safetensors" ]; then
  echo "Original Food-R1 weights are incomplete: ${BASE_MODEL}" >&2
  exit 2
fi

if [ ! -s "${DATASET}" ]; then
  echo "Dataset is missing or empty: ${DATASET}" >&2
  exit 3
fi

gpu_used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')"
if [ "${gpu_used:-0}" -gt "${MAX_GPU_USED_MB}" ]; then
  echo "GPU is busy (${gpu_used} MiB used). Refusing to start training." >&2
  exit 4
fi

mkdir -p "${OUT_DIR}"

extra_args=()
if [ -n "${MAX_STEPS:-}" ]; then
  extra_args+=(--max_steps "${MAX_STEPS}")
fi

exec swift sft \
  --model "${BASE_MODEL}" \
  --load_args false \
  --model_type qwen3_vl \
  --template qwen3_vl \
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
  --learning_rate "${LR:-5e-5}" \
  --lora_rank "${LORA_RANK:-16}" \
  --lora_alpha "${LORA_ALPHA:-32}" \
  --save_steps "${SAVE_STEPS:-50}" \
  --logging_steps "${LOGGING_STEPS:-5}" \
  --max_length "${MAX_LENGTH:-2048}" \
  --no_add_non_thinking_prefix \
  --output_dir "${OUT_DIR}"
