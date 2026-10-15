#!/usr/bin/env bash
set -euo pipefail

cd /root/autodl-tmp/internvl35-service

export MODEL_PATH="${MODEL_PATH:-/root/autodl-tmp/models/InternVL3_5-8B-Instruct}"
export MODEL_NAME="${MODEL_NAME:-InternVL3_5-8B-Instruct}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-2048}"
export MAX_IMAGE_EDGE="${MAX_IMAGE_EDGE:-1536}"
export IMAGE_SIZE="${IMAGE_SIZE:-448}"
export MAX_NUM_TILES="${MAX_NUM_TILES:-12}"
export USE_FLASH_ATTN="${USE_FLASH_ATTN:-0}"

exec /root/miniconda3/bin/python3 -m uvicorn server:app --host 127.0.0.1 --port 8002 --workers 1
