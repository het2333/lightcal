import base64
import binascii
import io
import os
import time
import uuid
from typing import Any

import torch
from fastapi import FastAPI, Header, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel
from transformers import AutoProcessor, Glm4vForConditionalGeneration


MODEL_PATH = os.getenv("MODEL_PATH", "/root/autodl-tmp/models/GLM-4.1V-9B-Thinking")
MODEL_NAME = os.getenv("MODEL_NAME", "GLM-4.1V-9B-Thinking")
API_KEY = os.getenv("VISION_API_KEY", os.getenv("QWEN_VL_API_KEY", ""))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "1536"))
MIN_MAX_TOKENS = int(os.getenv("MIN_MAX_TOKENS", "2048"))
MAX_IMAGE_EDGE = int(os.getenv("MAX_IMAGE_EDGE", "1024"))
FORCE_ANSWER_TAGS = os.getenv("FORCE_ANSWER_TAGS", "1").strip().lower() not in {"0", "false", "no"}
ENABLE_THINKING = os.getenv("ENABLE_THINKING", "0").strip().lower() not in {"0", "false", "no"}

app = FastAPI(title="GLM-4.1V OpenAI Compatible Service")
processor = None
model = None
loaded_at = None


class ChatCompletionRequest(BaseModel):
    model: str | None = None
    messages: list[dict[str, Any]]
    temperature: float = 0.0
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
    if FORCE_ANSWER_TAGS:
        contract = (
            "\n\n重要：不要把最终 JSON 写在思考过程中。最终答案必须放在 <answer> 和 </answer> 之间，"
            "<answer> 内只能包含一个合法 JSON 对象，不要 Markdown，不要解释。"
        )
        for message in reversed(output):
            if message.get("role") != "user":
                continue
            content = message.get("content")
            if isinstance(content, list):
                for part in reversed(content):
                    if isinstance(part, dict) and part.get("type") == "text":
                        part["text"] = str(part.get("text") or "") + contract
                        break
                else:
                    content.append({"type": "text", "text": contract.strip()})
            break
    return output


def load_model():
    global processor, model, loaded_at
    if processor is not None and model is not None:
        return
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"MODEL_PATH not found: {MODEL_PATH}")

    processor = AutoProcessor.from_pretrained(MODEL_PATH, use_fast=True)
    model = Glm4vForConditionalGeneration.from_pretrained(
        pretrained_model_name_or_path=MODEL_PATH,
        torch_dtype=torch.bfloat16,
        device_map="auto",
    ).eval()
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
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "loaded": model is not None,
        "loaded_at": loaded_at,
        "enable_thinking": ENABLE_THINKING,
        "gpu": gpu,
    }


@app.get("/v1/models")
def models(authorization: str | None = Header(default=None)):
    check_auth(authorization)
    return {"object": "list", "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "local"}]}


def clean_thinking_output(text: str) -> str:
    text = str(text or "").strip()
    if "<answer>" in text and "</answer>" in text:
        return text.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    elif text.startswith("<think>"):
        # The model may spend the entire budget thinking. Keep the best JSON-like
        # segment if one exists so callers are not forced to parse reasoning text.
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        return text[start : end + 1].strip()
    return text


def generate_text(messages: list[dict[str, Any]], request: ChatCompletionRequest) -> str:
    max_new_tokens = max(int(request.max_completion_tokens or request.max_tokens or DEFAULT_MAX_TOKENS), MIN_MAX_TOKENS)
    temperature = max(0.0, float(request.temperature or 0.0))
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=ENABLE_THINKING,
        return_dict=True,
        return_tensors="pt",
    ).to(model.device)
    inputs.pop("token_type_ids", None)
    generate_kwargs: dict[str, Any] = {"max_new_tokens": max_new_tokens}
    if temperature > 0.001:
        generate_kwargs.update({"do_sample": True, "temperature": temperature, "top_p": request.top_p})
    else:
        generate_kwargs["do_sample"] = False
    with torch.inference_mode():
        generated_ids = model.generate(**inputs, **generate_kwargs)
    output_ids = generated_ids[0][inputs["input_ids"].shape[1]:]
    return clean_thinking_output(processor.decode(output_ids, skip_special_tokens=True))


@app.post("/v1/chat/completions")
def chat_completions(request: ChatCompletionRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    if request.stream:
        raise HTTPException(status_code=400, detail="stream=true is not supported")

    load_model()
    try:
        messages = normalize_messages(request.messages)
        started = time.time()
        text = generate_text(messages, request)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image payload: {type(exc).__name__}: {str(exc)[:300]}") from exc
    except Exception as exc:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"GLM-4.1V inference failed: {type(exc).__name__}: {str(exc)[:300]}") from exc

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
