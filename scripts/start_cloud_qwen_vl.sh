#!/usr/bin/env bash
set -euo pipefail

cd /root/autodl-tmp/qwen-vl-service
export MODEL_PATH="${MODEL_PATH:-/root/autodl-tmp/models/Qwen2.5-VL-7B-Instruct}"
export MODEL_NAME="${MODEL_NAME:-Qwen2.5-VL-7B-Instruct}"
export MAX_PIXELS="${MAX_PIXELS:-1003520}"
export DEFAULT_MAX_TOKENS="${DEFAULT_MAX_TOKENS:-2048}"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

exec /root/miniconda3/bin/python3 -m uvicorn server:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}" --workers 1
