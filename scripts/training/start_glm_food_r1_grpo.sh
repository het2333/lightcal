#!/usr/bin/env bash
set -euo pipefail

BASE_MODEL="${BASE_MODEL:-/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash}"
SFT_ADAPTER="${SFT_ADAPTER:-/root/autodl-tmp/glm_food_r1_experiment/outputs/glm46_food_r1_lora_official/v0-20260628-180834/checkpoint-64}"
DATASET="${DATASET:-/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_grpo.jsonl}"
OUT_DIR="${OUT_DIR:-/root/autodl-tmp/glm_food_r1_experiment/outputs/glm46_food_r1_grpo_official_style}"
REWARD_PLUGIN="${REWARD_PLUGIN:-/root/autodl-tmp/glm_food_r1_experiment/scripts/foodr1_swift43_rewards.py}"
MAX_GPU_USED_MB="${MAX_GPU_USED_MB:-35000}"

if [ ! -f "${BASE_MODEL}/model-00001-of-00004.safetensors" ]; then
  echo "GLM weights are incomplete: ${BASE_MODEL}" >&2
  exit 2
fi

if [ ! -s "${DATASET}" ]; then
  echo "GRPO dataset is missing or empty: ${DATASET}" >&2
  exit 3
fi

if [ ! -f "${SFT_ADAPTER}/adapter_model.safetensors" ]; then
  echo "SFT adapter is missing: ${SFT_ADAPTER}" >&2
  exit 4
fi

if [ ! -f "${REWARD_PLUGIN}" ]; then
  echo "Food-R1 reward plugin is missing: ${REWARD_PLUGIN}" >&2
  exit 5
fi

gpu_used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')"
if [ "${gpu_used:-0}" -gt "${MAX_GPU_USED_MB}" ]; then
  echo "GPU is busy (${gpu_used} MiB used). Refusing to start GRPO so phone inference stays usable." >&2
  exit 6
fi

mkdir -p "${OUT_DIR}"

extra_args=()
if [ -n "${MAX_STEPS:-}" ]; then
  extra_args+=(--max_steps "${MAX_STEPS}")
fi

exec swift rlhf \
  --rlhf_type grpo \
  --model "${BASE_MODEL}" \
  --adapters "${SFT_ADAPTER}" \
  --ref_adapters "${SFT_ADAPTER}" \
  --dataset "${DATASET}" \
  --external_plugins "${REWARD_PLUGIN}" \
  --reward_funcs ingredient_format ingredient_match ingredient_quantity_match total_kcal_exact \
  --reward_weights 1.0 1.0 1.0 1.0 \
  --quant_method "${QUANT_METHOD:-bnb}" \
  --quant_bits "${QUANT_BITS:-4}" \
  --torch_dtype bfloat16 \
  --tuner_type lora \
  --lora_rank "${LORA_RANK:-16}" \
  --lora_alpha "${LORA_ALPHA:-32}" \
  --num_train_epochs "${NUM_TRAIN_EPOCHS:-1}" \
  "${extra_args[@]}" \
  --per_device_train_batch_size "${BATCH_SIZE:-1}" \
  --gradient_accumulation_steps "${GRAD_ACCUM:-8}" \
  --gradient_checkpointing "${GRADIENT_CHECKPOINTING:-true}" \
  --learning_rate "${LR:-1e-6}" \
  --weight_decay "${WEIGHT_DECAY:-0.05}" \
  --num_generations "${NUM_GENERATIONS:-2}" \
  --temperature "${TEMPERATURE:-0.9}" \
  --top_p "${TOP_P:-0.9}" \
  --max_completion_length "${MAX_COMPLETION_LENGTH:-256}" \
  --max_length "${MAX_LENGTH:-2048}" \
  --use_vllm "${USE_VLLM:-false}" \
  --save_steps "${SAVE_STEPS:-16}" \
  --save_total_limit "${SAVE_TOTAL_LIMIT:-2}" \
  --logging_steps "${LOGGING_STEPS:-1}" \
  --log_completions true \
  --save_only_model true \
  --output_dir "${OUT_DIR}"
