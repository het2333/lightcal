import os
import base64
import binascii
import io
import time
import uuid
from typing import Any

import torch
from fastapi import FastAPI, Header, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel
from qwen_vl_utils import process_vision_info
from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

MODEL_PATH = os.getenv("MODEL_PATH", "/root/autodl-tmp/models/Qwen2.5-VL-7B-Instruct")
MODEL_NAME = os.getenv("MODEL_NAME", "Qwen2.5-VL-7B-Instruct")
API_KEY = os.getenv("QWEN_VL_API_KEY", "")
MAX_PIXELS = int(os.getenv("MAX_PIXELS", str(1280 * 28 * 28)))
MIN_PIXELS = int(os.getenv("MIN_PIXELS", str(256 * 28 * 28)))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "2048"))
MAX_IMAGE_EDGE = int(os.getenv("MAX_IMAGE_EDGE", "1024"))
IMAGE_JPEG_QUALITY = int(os.getenv("IMAGE_JPEG_QUALITY", "85"))

app = FastAPI(title="Qwen2.5-VL OpenAI Compatible Service")
processor = None
model = None
loaded_at = None


class ChatCompletionRequest(BaseModel):
    model: str | None = None
    messages: list[dict[str, Any]]
    temperature: float = 0.1
    top_p: float = 0.9
    max_tokens: int | None = None
    max_completion_tokens: int | None = None
    stream: bool = False


def check_auth(authorization: str | None):
    if not API_KEY:
        return
    if authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="Unauthorized")


def normalize_data_image(image: str) -> str:
    """Validate data-url images and re-encode them as standard JPEG payloads."""
    if not isinstance(image, str):
        raise ValueError("Invalid image payload")
    image = image.strip()
    if not image.lower().startswith("data:image"):
        return image
    if "," not in image:
        raise ValueError("Invalid image data URL")

    _, encoded = image.split(",", 1)
    encoded = "".join(encoded.split())
    encoded += "=" * (-len(encoded) % 4)
    try:
        raw = base64.b64decode(encoded, validate=True)
        img = Image.open(io.BytesIO(raw))
        img.load()
    except (binascii.Error, UnidentifiedImageError, OSError) as exc:
        raise ValueError("Invalid image payload") from exc

    img = img.convert("RGB")
    max_edge = max(320, min(2048, MAX_IMAGE_EDGE))
    if img.width > max_edge or img.height > max_edge:
        img.thumbnail((max_edge, max_edge), Image.LANCZOS)

    buf = io.BytesIO()
    quality = max(45, min(92, IMAGE_JPEG_QUALITY))
    img.save(buf, "JPEG", quality=quality, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def normalize_content(content: Any) -> Any:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return str(content or "")

    normalized = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "text":
            normalized.append({"type": "text", "text": str(item.get("text") or "")})
        elif item_type in {"image_url", "image"}:
            image_url = item.get("image_url")
            image = image_url.get("url") if isinstance(image_url, dict) else item.get("image") or image_url
            if image:
                image = normalize_data_image(image)
                normalized.append({
                    "type": "image",
                    "image": image,
                    "min_pixels": MIN_PIXELS,
                    "max_pixels": MAX_PIXELS,
                })
        elif item_type == "video_url":
            video_url = item.get("video_url")
            video = video_url.get("url") if isinstance(video_url, dict) else video_url
            if video:
                normalized.append({"type": "video", "video": video})
    return normalized


def normalize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for message in messages:
        role = message.get("role") or "user"
        if role == "assistant":
            continue
        if role not in {"system", "user"}:
            role = "user"
        try:
            normalized_content = normalize_content(message.get("content", ""))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        output.append({"role": role, "content": normalized_content})
    return output or [{"role": "user", "content": "请描述图片。"}]


def load_model():
    global processor, model, loaded_at
    if model is not None and processor is not None:
        return
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"MODEL_PATH not found: {MODEL_PATH}")
    processor = AutoProcessor.from_pretrained(
        MODEL_PATH,
        trust_remote_code=True,
        min_pixels=MIN_PIXELS,
        max_pixels=MAX_PIXELS,
    )
    model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        MODEL_PATH,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
        low_cpu_mem_usage=True,
        attn_implementation="sdpa",
    )
    model.eval()
    loaded_at = time.time()


@app.on_event("startup")
def startup():
    load_model()


@app.get("/health")
def health():
    gpu = {}
    if torch.cuda.is_available():
        gpu = {
            "name": torch.cuda.get_device_name(0),
            "memory_allocated_mb": round(torch.cuda.memory_allocated(0) / 1024 / 1024),
            "memory_reserved_mb": round(torch.cuda.memory_reserved(0) / 1024 / 1024),
        }
    return {"status": "ok", "model": MODEL_NAME, "loaded": model is not None, "loaded_at": loaded_at, "gpu": gpu}


@app.get("/v1/models")
def models(authorization: str | None = Header(default=None)):
    check_auth(authorization)
    return {"object": "list", "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "local"}]}


@app.post("/v1/chat/completions")
def chat_completions(request: ChatCompletionRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    if request.stream:
        raise HTTPException(status_code=400, detail="stream=true is not supported")

    load_model()
    messages = normalize_messages(request.messages)
    try:
        prompt_text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        image_inputs, video_inputs = process_vision_info(messages)
        inputs = processor(
            text=[prompt_text],
            images=image_inputs,
            videos=video_inputs,
            padding=True,
            return_tensors="pt",
        )
        inputs = inputs.to(model.device)

        max_new_tokens = request.max_completion_tokens or request.max_tokens or DEFAULT_MAX_TOKENS
        temperature = max(0.0, float(request.temperature or 0.0))
        generation_kwargs = {
            "max_new_tokens": int(max_new_tokens),
            "do_sample": temperature > 0.001,
            "temperature": temperature if temperature > 0.001 else None,
            "top_p": request.top_p,
        }
        generation_kwargs = {key: value for key, value in generation_kwargs.items() if value is not None}

        started = time.time()
        with torch.inference_mode():
            generated = model.generate(**inputs, **generation_kwargs)
        trimmed = [out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs.input_ids, generated)]
        text = processor.batch_decode(trimmed, skip_special_tokens=True, clean_up_tokenization_spaces=False)[0].strip()
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image payload: {type(exc).__name__}") from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Qwen inference failed: {type(exc).__name__}: {str(exc)[:200]}") from exc

    prompt_tokens = int(inputs.input_ids.shape[-1])
    completion_tokens = int(trimmed[0].shape[-1]) if trimmed else 0
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:16]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model or MODEL_NAME,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
        "latency_seconds": round(time.time() - started, 3),
    }
