#!/usr/bin/env bash
set -euo pipefail

SERVICE_DIR="${SERVICE_DIR:-/root/autodl-tmp/depth-pipeline-service}"
VENV="${VENV:-/root/miniconda3}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8003}"

cd "$SERVICE_DIR"
mkdir -p "$SERVICE_DIR/logs" "$SERVICE_DIR/masks"

export GLM_MODEL_PATH="${GLM_MODEL_PATH:-/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash}"
export GLM_ADAPTER_PATH="${GLM_ADAPTER_PATH:-/root/autodl-tmp/glm_food_r1_experiment/outputs/glm46_raw_v3_hardcase_step40_to80/v0-20260701-010815/checkpoint-40}"
export GLM_MODEL_NAME="${GLM_MODEL_NAME:-GLM-4.6V-Flash+Food-GR1-step80}"
export SCENE_MODEL_PROVIDER="${SCENE_MODEL_PROVIDER:-glm}"
export SCENE_MODEL_FALLBACK_TO_GLM="${SCENE_MODEL_FALLBACK_TO_GLM:-1}"
export FOOD_R1_MODEL_PATH="${FOOD_R1_MODEL_PATH:-/root/autodl-tmp/modelscope-cache-ms/zy12123/Food-R1}"
export FOOD_R1_MODEL_NAME="${FOOD_R1_MODEL_NAME:-Food-R1}"
export MAX_IMAGE_EDGE="${MAX_IMAGE_EDGE:-1536}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"
export PRELOAD_GLM_ON_STARTUP="${PRELOAD_GLM_ON_STARTUP:-1}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-1536}"
export MIN_MAX_TOKENS="${MIN_MAX_TOKENS:-768}"
export MASK_DIR="${MASK_DIR:-$SERVICE_DIR/masks}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export GROUNDING_DINO_MODEL_PATH="${GROUNDING_DINO_MODEL_PATH:-/root/autodl-tmp/hf_grounding_dino_base_slim}"
export GROUNDING_DINO_LOCAL_FILES_ONLY="${GROUNDING_DINO_LOCAL_FILES_ONLY:-1}"
export SAM2_CHECKPOINT="${SAM2_CHECKPOINT:-/root/autodl-tmp/sam2-checkpoints/sam2.1_hiera_tiny.pt}"
export SAM2_MODEL_CFG="${SAM2_MODEL_CFG:-configs/sam2.1/sam2.1_hiera_t.yaml}"

exec "$VENV/bin/python" -m uvicorn server:app --host "$HOST" --port "$PORT" --log-level info
