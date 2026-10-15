#!/usr/bin/env bash
set -euo pipefail

SERVICE_DIR="${SERVICE_DIR:-/root/autodl-tmp/depth-pipeline-service}"
VENV="${VENV:-/root/autodl-tmp/glm-venv}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8003}"

cd "$SERVICE_DIR"
export GLM_MODEL_PATH="${GLM_MODEL_PATH:-/root/autodl-tmp/modelscope-cache/ZhipuAI/GLM-4___6V-Flash}"
export GLM_MODEL_NAME="${GLM_MODEL_NAME:-GLM-4.6V-Flash}"
export MAX_IMAGE_EDGE="${MAX_IMAGE_EDGE:-1536}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-1536}"
export MIN_MAX_TOKENS="${MIN_MAX_TOKENS:-768}"
export MASK_DIR="${MASK_DIR:-$SERVICE_DIR/masks}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export SAM2_CHECKPOINT="${SAM2_CHECKPOINT:-/root/autodl-tmp/sam2-checkpoints/sam2.1_hiera_tiny.pt}"
export SAM2_MODEL_CFG="${SAM2_MODEL_CFG:-configs/sam2.1/sam2.1_hiera_t.yaml}"

mkdir -p "$MASK_DIR"
exec "$VENV/bin/python" -m uvicorn server:app --host "$HOST" --port "$PORT"
