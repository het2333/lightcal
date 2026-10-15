#!/usr/bin/env bash
set -euo pipefail

cd /root/autodl-tmp/glm41v-service

export MODEL_PATH="${MODEL_PATH:-/root/autodl-tmp/models/GLM-4.1V-9B-Thinking}"
export MODEL_NAME="${MODEL_NAME:-GLM-4.1V-9B-Thinking}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-1536}"
export MIN_MAX_TOKENS="${MIN_MAX_TOKENS:-2048}"
export MAX_IMAGE_EDGE="${MAX_IMAGE_EDGE:-1024}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"

exec /root/autodl-tmp/glm-venv/bin/python -m uvicorn server:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8002}" --workers 1
