#!/usr/bin/env bash
set -euo pipefail

cd /root/autodl-tmp/minicpm-v-service
export MODEL_PATH="${MODEL_PATH:-/root/autodl-tmp/models/MiniCPM-V-4_5}"
export MODEL_NAME="${MODEL_NAME:-MiniCPM-V-4_5}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-2048}"
export MAX_IMAGE_EDGE="${MAX_IMAGE_EDGE:-1024}"
export IMAGE_JPEG_QUALITY="${IMAGE_JPEG_QUALITY:-85}"
export MAX_SLICE_NUMS="${MAX_SLICE_NUMS:-6}"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

exec /root/miniconda3/bin/python3 -m uvicorn server:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}" --workers 1
