import base64
import binascii
import io
import math
import os
import time
import uuid
from typing import Any

import torch
import torchvision.transforms as T
from fastapi import FastAPI, Header, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel
from torchvision.transforms.functional import InterpolationMode
from transformers import AutoModel, AutoTokenizer


MODEL_PATH = os.getenv("MODEL_PATH", "/root/autodl-tmp/models/InternVL3_5-8B-Instruct")
MODEL_NAME = os.getenv("MODEL_NAME", "InternVL3_5-8B-Instruct")
API_KEY = os.getenv("VISION_API_KEY", os.getenv("QWEN_VL_API_KEY", ""))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "2048"))
MAX_IMAGE_EDGE = int(os.getenv("MAX_IMAGE_EDGE", "1536"))
IMAGE_SIZE = int(os.getenv("IMAGE_SIZE", "448"))
MAX_NUM_TILES = int(os.getenv("MAX_NUM_TILES", "12"))
USE_FLASH_ATTN = os.getenv("USE_FLASH_ATTN", "0").strip().lower() in {"1", "true", "yes"}

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

app = FastAPI(title="InternVL3.5 OpenAI Compatible Service")
tokenizer = None
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
    max_edge = max(320, min(4096, MAX_IMAGE_EDGE))
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


def normalize_prompt(messages: list[dict[str, Any]]) -> tuple[str, list[Image.Image]]:
    system_texts: list[str] = []
    user_texts: list[str] = []
    images: list[Image.Image] = []

    for message in messages:
        role = message.get("role") or "user"
        text, message_images = extract_content_parts(message.get("content", ""))
        if role == "system":
            if text:
                system_texts.append(text)
            continue
        if role == "assistant":
            if text:
                user_texts.append(f"上一轮回答：{text}")
            continue
        if text:
            user_texts.append(text)
        images.extend(message_images)

    prompt = "\n\n".join([*system_texts, *user_texts]).strip() or "请描述图片。"
    if images and not prompt.lstrip().startswith("<image>"):
        prompt = "<image>\n" + prompt
    return prompt, images


def build_transform(input_size: int):
    return T.Compose(
        [
            T.Lambda(lambda img: img.convert("RGB") if img.mode != "RGB" else img),
            T.Resize((input_size, input_size), interpolation=InterpolationMode.BICUBIC),
            T.ToTensor(),
            T.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
        ]
    )


def find_closest_aspect_ratio(aspect_ratio: float, target_ratios: list[tuple[int, int]], width: int, height: int, image_size: int) -> tuple[int, int]:
    best_ratio_diff = float("inf")
    best_ratio = (1, 1)
    area = width * height
    for ratio in target_ratios:
        target_aspect_ratio = ratio[0] / ratio[1]
        ratio_diff = abs(aspect_ratio - target_aspect_ratio)
        if ratio_diff < best_ratio_diff:
            best_ratio_diff = ratio_diff
            best_ratio = ratio
        elif ratio_diff == best_ratio_diff and area > 0.5 * image_size * image_size * ratio[0] * ratio[1]:
            best_ratio = ratio
    return best_ratio


def dynamic_preprocess(
    image: Image.Image,
    min_num: int = 1,
    max_num: int = 12,
    image_size: int = 448,
    use_thumbnail: bool = True,
) -> list[Image.Image]:
    orig_width, orig_height = image.size
    aspect_ratio = orig_width / orig_height
    target_ratios = sorted(
        {(i, j) for n in range(min_num, max_num + 1) for i in range(1, n + 1) for j in range(1, n + 1) if min_num <= i * j <= max_num},
        key=lambda x: x[0] * x[1],
    )
    target_aspect_ratio = find_closest_aspect_ratio(aspect_ratio, target_ratios, orig_width, orig_height, image_size)
    target_width = image_size * target_aspect_ratio[0]
    target_height = image_size * target_aspect_ratio[1]
    blocks = target_aspect_ratio[0] * target_aspect_ratio[1]

    resized_img = image.resize((target_width, target_height))
    processed_images = []
    for i in range(blocks):
        box = (
            (i % (target_width // image_size)) * image_size,
            (i // (target_width // image_size)) * image_size,
            ((i % (target_width // image_size)) + 1) * image_size,
            ((i // (target_width // image_size)) + 1) * image_size,
        )
        processed_images.append(resized_img.crop(box))
    if use_thumbnail and len(processed_images) != 1:
        processed_images.append(image.resize((image_size, image_size)))
    return processed_images


def image_to_pixel_values(image: Image.Image) -> torch.Tensor:
    transform = build_transform(IMAGE_SIZE)
    images = dynamic_preprocess(image, image_size=IMAGE_SIZE, max_num=MAX_NUM_TILES, use_thumbnail=True)
    pixel_values = torch.stack([transform(tile) for tile in images])
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    device = "cuda" if torch.cuda.is_available() else "cpu"
    return pixel_values.to(dtype=dtype, device=device)


def load_model():
    global tokenizer, model, loaded_at
    if model is not None and tokenizer is not None:
        return
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"MODEL_PATH not found: {MODEL_PATH}")

    tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH, trust_remote_code=True, use_fast=False)
    model = AutoModel.from_pretrained(
        MODEL_PATH,
        torch_dtype=torch.bfloat16,
        low_cpu_mem_usage=True,
        use_flash_attn=USE_FLASH_ATTN,
        trust_remote_code=True,
    ).eval()
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


def chat_with_model(prompt: str, images: list[Image.Image], request: ChatCompletionRequest) -> str:
    max_new_tokens = int(request.max_completion_tokens or request.max_tokens or DEFAULT_MAX_TOKENS)
    temperature = max(0.0, float(request.temperature or 0.0))
    generation_config = {
        "max_new_tokens": max_new_tokens,
        "do_sample": temperature > 0.001,
    }
    if temperature > 0.001:
        generation_config["temperature"] = temperature
        generation_config["top_p"] = request.top_p

    pixel_values = image_to_pixel_values(images[0]) if images else None
    with torch.inference_mode():
        response = model.chat(tokenizer, pixel_values, prompt, generation_config)
    return str(response).strip()


@app.post("/v1/chat/completions")
def chat_completions(request: ChatCompletionRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    if request.stream:
        raise HTTPException(status_code=400, detail="stream=true is not supported")

    load_model()
    try:
        prompt, images = normalize_prompt(request.messages)
        started = time.time()
        text = chat_with_model(prompt, images, request)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image payload: {type(exc).__name__}") from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"InternVL inference failed: {type(exc).__name__}: {str(exc)[:200]}") from exc

    prompt_tokens = max(1, len(prompt) // 3)
    completion_tokens = max(1, len(text) // 3)
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
