import base64
import binascii
import io
import json
import os
import time
import uuid
from typing import Any

import torch
from fastapi import FastAPI, Header, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel
from transformers import AutoModel, AutoModelForImageTextToText, AutoProcessor, AutoTokenizer


MODEL_PATH = os.getenv("MODEL_PATH", "/root/autodl-tmp/models/MiniCPM-V-4_5")
MODEL_NAME = os.getenv("MODEL_NAME", "MiniCPM-V-4_5")
API_KEY = os.getenv("VISION_API_KEY", os.getenv("QWEN_VL_API_KEY", ""))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "2048"))
MAX_IMAGE_EDGE = int(os.getenv("MAX_IMAGE_EDGE", "1024"))
IMAGE_JPEG_QUALITY = int(os.getenv("IMAGE_JPEG_QUALITY", "85"))
ATTN_IMPLEMENTATION = os.getenv("ATTN_IMPLEMENTATION", "sdpa")
MAX_SLICE_NUMS = int(os.getenv("MAX_SLICE_NUMS", "6"))
DOWNSAMPLE_MODE = os.getenv("DOWNSAMPLE_MODE", "16x")

app = FastAPI(title="MiniCPM-V OpenAI Compatible Service")
tokenizer = None
processor = None
model = None
model_kind = "legacy_chat"
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


def normalize_data_image(image: str) -> Image.Image:
    if not isinstance(image, str):
        raise ValueError("Invalid image payload")
    image = image.strip()
    if not image.lower().startswith("data:image") or "," not in image:
        raise ValueError("Only data:image base64 payloads are supported")

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
    return img


def extract_content_parts(content: Any) -> tuple[str, list[Image.Image]]:
    if isinstance(content, str):
        return content, []
    if not isinstance(content, list):
        return str(content or ""), []

    texts: list[str] = []
    images: list[Image.Image] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "text":
            text = str(item.get("text") or "").strip()
            if text:
                texts.append(text)
        elif item_type in {"image_url", "image"}:
            image_url = item.get("image_url")
            image = image_url.get("url") if isinstance(image_url, dict) else item.get("image") or image_url
            if image:
                images.append(normalize_data_image(str(image)))
    return "\n".join(texts), images


def normalize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    system_texts: list[str] = []
    output: list[dict[str, Any]] = []

    for message in messages:
        role = message.get("role") or "user"
        text, images = extract_content_parts(message.get("content", ""))
        if role == "system":
            if text:
                system_texts.append(text)
            continue
        if role not in {"user", "assistant"}:
            role = "user"
        if role == "assistant":
            if text:
                output.append({"role": "assistant", "content": text})
            continue

        if system_texts:
            text = "\n\n".join(system_texts + ([text] if text else []))
            system_texts = []
        content: list[Any] = [*images]
        if text:
            content.append(text)
        output.append({"role": "user", "content": content or text or "请描述图片。"})

    if not output:
        output = [{"role": "user", "content": "\n\n".join(system_texts) or "请描述图片。"}]
    return output


def normalize_processor_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    system_texts: list[str] = []
    output: list[dict[str, Any]] = []

    for message in messages:
        role = message.get("role") or "user"
        text, images = extract_content_parts(message.get("content", ""))
        if role == "system":
            if text:
                system_texts.append(text)
            continue
        if role not in {"user", "assistant"}:
            role = "user"

        if role == "assistant":
            if text:
                output.append({"role": "assistant", "content": [{"type": "text", "text": text}]})
            continue

        if system_texts:
            text = "\n\n".join(system_texts + ([text] if text else []))
            system_texts = []

        content: list[dict[str, Any]] = []
        for image in images:
            content.append({"type": "image", "image": image})
        if text:
            content.append({"type": "text", "text": text})
        output.append({"role": "user", "content": content or [{"type": "text", "text": "请描述图片。"}]})

    if not output:
        output = [{"role": "user", "content": [{"type": "text", "text": "\n\n".join(system_texts) or "请描述图片。"}]}]
    return output


def detect_model_type() -> str:
    try:
        with open(os.path.join(MODEL_PATH, "config.json"), "r", encoding="utf-8") as fh:
            config = json.load(fh)
        return str(config.get("model_type") or "").lower()
    except Exception:
        return ""


def load_model():
    global tokenizer, processor, model, model_kind, loaded_at
    if model is not None and (tokenizer is not None or processor is not None):
        return
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"MODEL_PATH not found: {MODEL_PATH}")

    model_type = detect_model_type()
    if model_type == "minicpmv4_6":
        model_kind = "image_text_to_text"
        processor = AutoProcessor.from_pretrained(MODEL_PATH)
        model = AutoModelForImageTextToText.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.bfloat16,
            device_map="auto",
        ).eval()
        loaded_at = time.time()
        return

    tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH, trust_remote_code=True)
    model_kwargs = {
        "trust_remote_code": True,
        "torch_dtype": torch.bfloat16,
    }
    if ATTN_IMPLEMENTATION:
        model_kwargs["attn_implementation"] = ATTN_IMPLEMENTATION
    model = AutoModel.from_pretrained(MODEL_PATH, **model_kwargs)
    model = model.eval()
    if torch.cuda.is_available():
        model = model.cuda()
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


def chat_with_model(messages: list[dict[str, Any]], request: ChatCompletionRequest) -> str:
    max_new_tokens = int(request.max_completion_tokens or request.max_tokens or DEFAULT_MAX_TOKENS)
    temperature = max(0.0, float(request.temperature or 0.0))
    if model_kind == "image_text_to_text":
        inputs = processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_dict=True,
            return_tensors="pt",
            downsample_mode=DOWNSAMPLE_MODE,
            max_slice_nums=MAX_SLICE_NUMS,
        ).to(model.device)
        generate_kwargs: dict[str, Any] = {
            "downsample_mode": DOWNSAMPLE_MODE,
            "max_new_tokens": max_new_tokens,
        }
        if temperature > 0.001:
            generate_kwargs.update({"do_sample": True, "temperature": temperature, "top_p": request.top_p})
        else:
            generate_kwargs["do_sample"] = False
        with torch.inference_mode():
            generated_ids = model.generate(**inputs, **generate_kwargs)
        generated_ids_trimmed = [
            out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs.input_ids, generated_ids)
        ]
        output_text = processor.batch_decode(
            generated_ids_trimmed,
            skip_special_tokens=True,
            clean_up_tokenization_spaces=False,
        )
        return str(output_text[0]).strip() if output_text else ""

    chat_kwargs = {
        "msgs": messages,
        "tokenizer": tokenizer,
        "max_new_tokens": max_new_tokens,
        "max_slice_nums": MAX_SLICE_NUMS,
        "enable_thinking": False,
        "stream": False,
    }
    if temperature > 0.001:
        chat_kwargs["sampling"] = True
        chat_kwargs["temperature"] = temperature
        chat_kwargs["top_p"] = request.top_p
    else:
        chat_kwargs["sampling"] = False

    try:
        result = model.chat(**chat_kwargs)
    except TypeError:
        for key in ["max_slice_nums", "sampling", "temperature", "top_p", "enable_thinking", "stream"]:
            chat_kwargs.pop(key, None)
        result = model.chat(**chat_kwargs)
    if isinstance(result, tuple):
        result = result[0]
    return str(result).strip()


@app.post("/v1/chat/completions")
def chat_completions(request: ChatCompletionRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    if request.stream:
        raise HTTPException(status_code=400, detail="stream=true is not supported")

    load_model()
    try:
        messages = normalize_processor_messages(request.messages) if model_kind == "image_text_to_text" else normalize_messages(request.messages)
        started = time.time()
        text = chat_with_model(messages, request)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image payload: {type(exc).__name__}") from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"MiniCPM inference failed: {type(exc).__name__}: {str(exc)[:200]}") from exc

    prompt_chars = sum(len(str(m.get("content", ""))) for m in messages)
    completion_tokens = max(1, len(text) // 3)
    prompt_tokens = max(1, prompt_chars // 3)
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
