from __future__ import annotations

import base64
import binascii
import io
import json
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any

import numpy as np
import cv2
from fastapi import FastAPI, Header, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel

try:
    import torch
except ModuleNotFoundError:
    torch = None

try:
    from transformers import (
        AutoModelForImageTextToText,
        AutoModelForZeroShotObjectDetection,
        AutoProcessor,
        Glm4vForConditionalGeneration,
    )
except ModuleNotFoundError:
    AutoModelForImageTextToText = None
    AutoModelForZeroShotObjectDetection = None
    AutoProcessor = None
    Glm4vForConditionalGeneration = None


MODEL_PATH = os.getenv("GLM_MODEL_PATH", "/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash")
MODEL_NAME = os.getenv("GLM_MODEL_NAME", "GLM-4.6V-Flash")
GLM_ADAPTER_PATH = os.getenv("GLM_ADAPTER_PATH", "").strip()
SCENE_MODEL_PROVIDER = os.getenv("SCENE_MODEL_PROVIDER", "glm").strip().lower()
SCENE_MODEL_FALLBACK_TO_GLM = os.getenv("SCENE_MODEL_FALLBACK_TO_GLM", "1").strip().lower() not in {"0", "false", "no"}
FOOD_R1_MODEL_PATH = os.getenv("FOOD_R1_MODEL_PATH", "/root/autodl-tmp/modelscope-cache-ms/zy12123/Food-R1")
FOOD_R1_MODEL_NAME = os.getenv("FOOD_R1_MODEL_NAME", "Food-R1")
API_KEY = os.getenv("VISION_API_KEY", os.getenv("DEPTH_PIPELINE_API_KEY", ""))
MAX_IMAGE_EDGE = int(os.getenv("MAX_IMAGE_EDGE", "1536"))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "1536"))
MIN_MAX_TOKENS = int(os.getenv("MIN_MAX_TOKENS", "768"))
ENABLE_THINKING = os.getenv("ENABLE_THINKING", "0").strip().lower() not in {"0", "false", "no"}

DETECTOR_MODEL_PATH = os.getenv("GROUNDING_DINO_MODEL_PATH", "IDEA-Research/grounding-dino-base")
DETECTOR_ENABLED = os.getenv("GROUNDING_DINO_ENABLED", "1").strip().lower() not in {"0", "false", "no"}
DETECTOR_LOCAL_FILES_ONLY = os.getenv("GROUNDING_DINO_LOCAL_FILES_ONLY", "1").strip().lower() not in {"0", "false", "no"}
GROUNDING_DINO_15_DDS_TOKEN = os.getenv("GROUNDING_DINO_15_DDS_TOKEN", "")
GROUNDING_DINO_15_API_PATH = os.getenv("GROUNDING_DINO_15_API_PATH", "/v2/task/grounding_dino/detection")
GROUNDING_DINO_15_MODEL = os.getenv("GROUNDING_DINO_15_MODEL", "GroundingDino-1.5-Pro")
SAM2_ENABLED = os.getenv("SAM2_ENABLED", "1").strip().lower() not in {"0", "false", "no"}
SAM2_CHECKPOINT = os.getenv("SAM2_CHECKPOINT", "")
SAM2_MODEL_CFG = os.getenv("SAM2_MODEL_CFG", "")
MASK_DIR = Path(os.getenv("MASK_DIR", "/root/autodl-tmp/depth-pipeline-service/masks"))
MASK_PREVIEW_MAX_EDGE = int(os.getenv("MASK_PREVIEW_MAX_EDGE", "256"))
METRIC3D_ENABLED = os.getenv("METRIC3D_ENABLED", "1").strip().lower() not in {"0", "false", "no"}
METRIC3D_REPO = os.getenv("METRIC3D_REPO", "/root/autodl-tmp/Metric3D")
METRIC3D_MODEL = os.getenv("METRIC3D_MODEL", "metric3d_vit_small")
METRIC3D_TORCH_HOME = os.getenv("METRIC3D_TORCH_HOME", "/root/autodl-tmp/torch-cache")
METRIC3D_INPUT_HEIGHT = int(os.getenv("METRIC3D_INPUT_HEIGHT", "616"))
METRIC3D_INPUT_WIDTH = int(os.getenv("METRIC3D_INPUT_WIDTH", "1064"))
METRIC3D_CANONICAL_FOCAL = float(os.getenv("METRIC3D_CANONICAL_FOCAL", "1000.0"))

app = FastAPI(title="Depth Meal Pipeline Service")
glm_processor = None
glm_model = None
food_r1_processor = None
food_r1_model = None
detector_processor = None
detector_model = None
sam2_predictor = None
metric3d_model = None
loaded_at = None
last_scene_model_provider = ""


def require_torch():
    if torch is None:
        raise RuntimeError("PyTorch is required for GPU model inference")


def require_transformers():
    require_torch()
    if AutoProcessor is None:
        raise RuntimeError("Transformers is required for vision model inference")


def model_device(model: torch.nn.Module) -> torch.device:
    return getattr(model, "device", None) or next(model.parameters()).device


class ChatCompletionRequest(BaseModel):
    model: str | None = None
    messages: list[dict[str, Any]]
    temperature: float = 0.0
    top_p: float = 0.9
    max_tokens: int | None = None
    max_completion_tokens: int | None = None
    stream: bool = False


class DepthMealAnalyzeRequest(BaseModel):
    capture_id: str | None = None
    rgb_base64: str
    depth_base64: str | None = None
    confidence_base64: str | None = None
    auxiliary_images_base64: list[str] = []
    metadata: dict[str, Any] = {}
    user_hint: str = ""
    container_hint: str = ""
    meal_type: str = ""


class DetectRequest(BaseModel):
    image_base64: str
    text_prompt: str
    box_threshold: float = 0.25
    text_threshold: float = 0.20


class SegmentRequest(BaseModel):
    image_base64: str
    detections: list[dict[str, Any]]
    capture_id: str | None = None


class DebugDepthVolumeRequest(BaseModel):
    image_base64: str
    depth_base64: str | None = None
    confidence_base64: str | None = None
    metadata: dict[str, Any] = {}
    bbox_xyxy: list[float] | None = None
    mask_base64: str | None = None
    item: dict[str, Any] = {}


def check_auth(authorization: str | None):
    if API_KEY and authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="Unauthorized")


def decode_base64(raw: str | None) -> bytes | None:
    if not raw:
        return None
    value = raw.strip()
    if "," in value and value.lower().startswith("data:"):
        value = value.split(",", 1)[1]
    value = "".join(value.split())
    value += "=" * (-len(value) % 4)
    try:
        return base64.b64decode(value, validate=True)
    except binascii.Error as exc:
        raise ValueError("invalid base64") from exc


def decode_image(raw: str) -> Image.Image:
    data = decode_base64(raw)
    if not data:
        raise ValueError("missing image")
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError("invalid image") from exc
    image = image.convert("RGB")
    if max(image.size) > MAX_IMAGE_EDGE:
        image.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE), Image.LANCZOS)
    return image


def decode_mask(raw: str | None, image_size: tuple[int, int]) -> np.ndarray | None:
    data = decode_base64(raw)
    if not data:
        return None
    try:
        mask = Image.open(io.BytesIO(data))
        mask.load()
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError("invalid mask image") from exc
    mask = mask.convert("L")
    if mask.size != image_size:
        mask = mask.resize(image_size, Image.NEAREST)
    return np.array(mask) > 127


def bbox_mask(image_size: tuple[int, int], bbox_xyxy: list[float] | None) -> np.ndarray | None:
    if not bbox_xyxy or len(bbox_xyxy) != 4:
        return None
    width, height = image_size
    x1, y1, x2, y2 = [int(round(float(v))) for v in bbox_xyxy]
    x1 = max(0, min(width, x1))
    x2 = max(0, min(width, x2))
    y1 = max(0, min(height, y1))
    y2 = max(0, min(height, y2))
    if x2 <= x1 or y2 <= y1:
        return None
    mask = np.zeros((height, width), dtype=bool)
    mask[y1:y2, x1:x2] = True
    return mask


def decode_depth(raw: str | None, metadata: dict[str, Any]) -> np.ndarray | None:
    data = decode_base64(raw)
    if not data:
        return None
    depth_meta = metadata.get("depth") if isinstance(metadata.get("depth"), dict) else {}
    width = int(depth_meta.get("width") or 0)
    height = int(depth_meta.get("height") or 0)
    if width <= 0 or height <= 0:
        return None
    expected = width * height * 4
    if len(data) < expected:
        return None
    return np.frombuffer(data[:expected], dtype=np.float32).reshape((height, width))


def decode_confidence(raw: str | None, metadata: dict[str, Any]) -> np.ndarray | None:
    data = decode_base64(raw)
    if not data:
        return None
    depth_meta = metadata.get("depth") if isinstance(metadata.get("depth"), dict) else {}
    width = int(depth_meta.get("width") or 0)
    height = int(depth_meta.get("height") or 0)
    if width <= 0 or height <= 0:
        return None
    expected = width * height
    if len(data) < expected:
        return None
    return np.frombuffer(data[:expected], dtype=np.uint8).reshape((height, width))


def _camera_fx_fy_from_metadata(metadata: dict[str, Any], image_size: tuple[int, int]) -> tuple[float, float, bool]:
    camera = metadata.get("camera") if isinstance(metadata.get("camera"), dict) else {}
    intrinsics = camera.get("intrinsics")
    try:
        if intrinsics:
            fx = float(intrinsics[0][0])
            fy = float(intrinsics[1][1])
            if fx > 0 and fy > 0:
                return fx, fy, False
    except Exception:
        pass
    width, height = image_size
    focal = max(width, height) * 1.25
    return float(focal), float(focal), True


def _metadata_with_depth_camera(
    metadata: dict[str, Any],
    image_size: tuple[int, int],
    fx: float,
    fy: float,
    estimated_intrinsics: bool,
) -> dict[str, Any]:
    width, height = image_size
    updated = dict(metadata or {})
    updated["depth_source"] = "metric3d_predicted_depth"
    updated["depth"] = {
        **(updated.get("depth") if isinstance(updated.get("depth"), dict) else {}),
        "width": width,
        "height": height,
        "unit": "meter",
        "source": "metric3d_predicted_depth",
    }
    camera = dict(updated.get("camera") if isinstance(updated.get("camera"), dict) else {})
    if not camera.get("intrinsics"):
        camera["intrinsics"] = [
            [fx, 0.0, width / 2.0],
            [0.0, fy, height / 2.0],
            [0.0, 0.0, 1.0],
        ]
        camera["intrinsics_estimated"] = estimated_intrinsics
    camera["intrinsics_reference_dimensions"] = {"width": width, "height": height}
    updated["camera"] = camera
    updated["metric3d"] = {
        "model": METRIC3D_MODEL,
        "repo": METRIC3D_REPO,
        "input_size": [METRIC3D_INPUT_HEIGHT, METRIC3D_INPUT_WIDTH],
        "canonical_focal_px": METRIC3D_CANONICAL_FOCAL,
        "fx_px": round(float(fx), 4),
        "fy_px": round(float(fy), 4),
        "intrinsics_estimated": bool(estimated_intrinsics),
    }
    return updated


def load_metric3d():
    global metric3d_model
    if not METRIC3D_ENABLED or metric3d_model is not None:
        return
    require_torch()
    if not os.path.exists(METRIC3D_REPO):
        raise RuntimeError(f"Metric3D repo not found: {METRIC3D_REPO}")
    if METRIC3D_TORCH_HOME:
        os.environ.setdefault("TORCH_HOME", METRIC3D_TORCH_HOME)
    model = torch.hub.load(METRIC3D_REPO, METRIC3D_MODEL, pretrain=True, source="local")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    metric3d_model = model.to(device).eval()


def predict_metric3d_depth(image: Image.Image, metadata: dict[str, Any]) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    load_metric3d()
    if metric3d_model is None:
        raise RuntimeError("Metric3D is disabled or failed to load")

    rgb_origin = np.array(image.convert("RGB"))
    original_h, original_w = rgb_origin.shape[:2]
    input_size = (METRIC3D_INPUT_HEIGHT, METRIC3D_INPUT_WIDTH)
    scale = min(input_size[0] / original_h, input_size[1] / original_w)
    resized_w = max(1, int(original_w * scale))
    resized_h = max(1, int(original_h * scale))
    rgb = cv2.resize(rgb_origin, (resized_w, resized_h), interpolation=cv2.INTER_LINEAR)

    fx, fy, estimated_intrinsics = _camera_fx_fy_from_metadata(metadata, image.size)
    fx_scaled = fx * scale
    fy_scaled = fy * scale

    padding = [123.675, 116.28, 103.53]
    pad_h = input_size[0] - resized_h
    pad_w = input_size[1] - resized_w
    pad_h_half = max(0, pad_h // 2)
    pad_w_half = max(0, pad_w // 2)
    rgb = cv2.copyMakeBorder(
        rgb,
        pad_h_half,
        max(0, pad_h - pad_h_half),
        pad_w_half,
        max(0, pad_w - pad_w_half),
        cv2.BORDER_CONSTANT,
        value=padding,
    )
    pad_info = [pad_h_half, max(0, pad_h - pad_h_half), pad_w_half, max(0, pad_w - pad_w_half)]

    device = next(metric3d_model.parameters()).device
    mean = torch.tensor([123.675, 116.28, 103.53], dtype=torch.float32, device=device)[:, None, None]
    std = torch.tensor([58.395, 57.12, 57.375], dtype=torch.float32, device=device)[:, None, None]
    rgb_tensor = torch.from_numpy(rgb.transpose((2, 0, 1))).float().to(device)
    rgb_tensor = torch.div((rgb_tensor - mean), std)[None]

    with torch.inference_mode():
        pred_depth, confidence, _ = metric3d_model.inference({"input": rgb_tensor})

    pred_depth = pred_depth.squeeze()
    pred_depth = pred_depth[
        pad_info[0] : pred_depth.shape[0] - pad_info[1],
        pad_info[2] : pred_depth.shape[1] - pad_info[3],
    ]
    pred_depth = torch.nn.functional.interpolate(
        pred_depth[None, None, :, :],
        (original_h, original_w),
        mode="bilinear",
        align_corners=False,
    ).squeeze()
    focal_scale = max(0.05, fx_scaled / max(METRIC3D_CANONICAL_FOCAL, 1.0))
    pred_depth = torch.clamp(pred_depth * focal_scale, 0.05, 5.0)
    depth_m = pred_depth.detach().float().cpu().numpy().astype(np.float32)

    confidence_u8 = np.full((original_h, original_w), 192, dtype=np.uint8)
    try:
        if isinstance(confidence, torch.Tensor):
            conf = confidence.squeeze()
            conf = conf[
                pad_info[0] : conf.shape[-2] - pad_info[1],
                pad_info[2] : conf.shape[-1] - pad_info[3],
            ]
            conf = torch.nn.functional.interpolate(
                conf[None, None, :, :].float(),
                (original_h, original_w),
                mode="bilinear",
                align_corners=False,
            ).squeeze()
            conf_np = conf.detach().cpu().numpy()
            if np.isfinite(conf_np).any():
                lo = float(np.nanpercentile(conf_np, 2))
                hi = float(np.nanpercentile(conf_np, 98))
                if hi > lo:
                    confidence_u8 = np.clip((conf_np - lo) / (hi - lo) * 255.0, 0, 255).astype(np.uint8)
    except Exception:
        confidence_u8 = np.full((original_h, original_w), 192, dtype=np.uint8)

    metric_metadata = _metadata_with_depth_camera(metadata, image.size, fx, fy, estimated_intrinsics)
    return depth_m, confidence_u8, metric_metadata


def depth_or_metric3d(
    image: Image.Image,
    depth: np.ndarray | None,
    confidence: np.ndarray | None,
    metadata: dict[str, Any],
) -> tuple[np.ndarray | None, np.ndarray | None, dict[str, Any], str]:
    if depth is not None:
        source = str((metadata or {}).get("depth_source") or "uploaded_depth")
        return depth, confidence, metadata, source
    if not METRIC3D_ENABLED:
        return None, confidence, metadata, "none"
    try:
        metric_depth, metric_confidence, metric_metadata = predict_metric3d_depth(image, metadata)
        return metric_depth, metric_confidence, metric_metadata, "metric3d_predicted_depth"
    except Exception as exc:
        print(f"[DepthPipeline] Metric3D failed: {type(exc).__name__}: {str(exc)[:240]}")
        return None, confidence, metadata, "none"


def parse_json_object(text: str) -> dict:
    text = str(text or "").strip()
    if "<answer>" in text and "</answer>" in text:
        text = text.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, flags=re.S | re.I)
    if fenced:
        text = fenced.group(1).strip()
    start = text.find("{")
    if start < 0:
        raise json.JSONDecodeError("No JSON object found", text, 0)
    candidate = text[start:].strip()
    candidate = re.sub(r'"\s+"([A-Za-z_][A-Za-z0-9_]*)"\s*:', r'"\1":', candidate)
    try:
        parsed = json.loads(candidate)
    except json.JSONDecodeError:
        decoder = json.JSONDecoder()
        parsed, _ = decoder.raw_decode(candidate)
    if not isinstance(parsed, dict):
        raise json.JSONDecodeError("JSON root is not an object", candidate, 0)
    return parsed


def repair_json_object(text: str, schema_hint: str = "") -> dict:
    """Ask the local VLM to repair malformed JSON into a valid object."""
    repair_prompt = (
        "修复下面的 JSON。只返回合法 JSON 对象，不要 Markdown，不要解释。"
        "保留原有字段和中文内容；如果字段不完整，按最接近含义补齐或删除坏字段。"
        f"\nSchema hint: {schema_hint}\nBroken JSON:\n{text[:12000]}"
    )
    fixed = generate_scene_model(
        [{"role": "user", "content": [{"type": "text", "text": repair_prompt}]}],
        max_tokens=1800,
        temperature=0.0,
    )
    return parse_json_object(fixed)


def parse_scene_or_retry(
    scene_text: str,
    image: Image.Image,
    user_hint: str,
    container_hint: str,
    rgb_only: bool,
) -> tuple[dict, str]:
    try:
        return parse_json_object(scene_text), "initial_parse"
    except Exception as initial_exc:
        try:
            return repair_json_object(scene_text, "meal scene JSON with items and detector_prompt_en"), "json_repair"
        except Exception:
            retry_prompt = (
                "上一次输出不是合法 JSON。请重新看图，只返回一个合法 JSON 对象，不要 Markdown，不要解释。"
                "所有 key/value 必须用双引号；不要输出尾随逗号；不要输出不可见食物。\n"
                + scene_prompt(user_hint, container_hint, rgb_only=rgb_only)
            )
            retry_text = generate_scene_model(
                [
                    {
                        "role": "user",
                        "content": [
                            {"type": "image", "image": image},
                            {"type": "text", "text": retry_prompt},
                        ],
                    }
                ],
                max_tokens=650 if rgb_only else 700,
                temperature=0.0,
            )
            try:
                return parse_json_object(retry_text), "image_retry_parse"
            except Exception:
                return repair_json_object(retry_text, f"meal scene JSON after retry; first error: {type(initial_exc).__name__}"), "image_retry_repair"


def as_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def visual_volume_hint(item: dict[str, Any]) -> tuple[float, dict[str, Any]]:
    hint = item.get("visual_volume_hint") if isinstance(item.get("visual_volume_hint"), dict) else {}
    volume_ml = as_float(
        item.get("v")
        or item.get("volume_ml")
        or item.get("estimated_volume_ml")
        or item.get("visual_volume_ml")
        or item.get("vol_ml")
        or item.get("ml")
        or
        hint.get("volume_ml")
        or hint.get("estimated_volume_ml")
        or hint.get("ml"),
        0.0,
    )
    if volume_ml <= 0:
        volume_range = hint.get("range") or hint.get("volume_ml_range") or []
        if isinstance(volume_range, list) and len(volume_range) >= 2:
            low = as_float(volume_range[0], 0.0)
            high = as_float(volume_range[1], 0.0)
            if low > 0 and high >= low:
                volume_ml = (low + high) / 2.0
    return max(0.0, min(round(volume_ml, 1), 1800.0)), hint


def visual_density_bounds(item: dict[str, Any]) -> tuple[float, float]:
    text = " ".join(
        str(item.get(key) or "").lower()
        for key in ("name_zh", "name_en", "category", "canonical_food_key", "density_key", "nutrition_key", "detector_phrase")
    )
    if any(token in text for token in ("水", "清汤", "汤", "茶", "water", "broth", "soup", "tea")) or item.get("liquid"):
        return 0.99, 1.05
    if any(token in text for token in ("米饭", "炒饭", "rice")):
        return 0.65, 0.85
    if any(token in text for token in ("面条", "意面", "noodle", "pasta")):
        return 0.55, 0.85
    if any(token in text for token in ("炒菜", "青菜", "蔬菜", "vegetable", "leafy")):
        return 0.45, 0.85
    if any(token in text for token in ("肉", "猪", "牛", "鸡", "鱼", "虾", "meat", "pork", "beef", "chicken", "fish", "shrimp")):
        return 0.90, 1.05
    if any(token in text for token in ("炸", "薯条", "fried", "fries", "nugget")):
        return 0.35, 0.80
    if any(token in text for token in ("面包", "蛋糕", "糕点", "bread", "cake", "pastry")):
        return 0.20, 0.60
    return 0.45, 1.05


def visual_weight_from_volume(item: dict[str, Any], volume_ml: float) -> dict[str, Any]:
    density_hint = item.get("density_hint") if isinstance(item.get("density_hint"), dict) else {}
    density = as_float(
        item.get("rho")
        or item.get("density_g_per_ml")
        or item.get("density")
        or density_hint.get("density_g_per_ml")
        or density_hint.get("density_default_g_per_ml")
        or density_hint.get("density"),
        0.0,
    )
    density_range = density_hint.get("range") or []
    if density <= 0 and isinstance(density_range, list) and len(density_range) >= 2:
        low = as_float(density_range[0], 0.0)
        high = as_float(density_range[1], 0.0)
        if low > 0 and high >= low:
            density = (low + high) / 2.0
    if density <= 0:
        category = str(item.get("category") or "").lower()
        if "drink" in category or "soup" in category or item.get("liquid"):
            density = 1.0
        elif "staple" in category or "mixed" in category:
            density = 0.75
        elif "protein" in category or "meat" in category:
            density = 0.85
        elif "vegetable" in category:
            density = 0.55
        elif "snack" in category or "dessert" in category:
            density = 0.65
        else:
            density = 0.75
    lower, upper = visual_density_bounds(item)
    raw_density = density
    density = max(lower, min(density, upper))
    grams = volume_ml * density
    return {
        "density_g_per_ml": round(density, 4),
        "estimated_grams": round(grams, 1),
        "density_source": "glm_density_hint" if density_hint else "category_default_density",
        "raw_density_g_per_ml": round(raw_density, 4),
        "density_clamp_range": [round(lower, 4), round(upper, 4)],
        "density_hint": density_hint,
    }


def estimated_nutrition_from_item(item: dict[str, Any], grams: float) -> dict[str, Any]:
    per_100g = nutrition_pack_from_item(item, "nutrition_per_100g") or nutrition_pack_from_item(item, "direct_nutrition")
    if not per_100g or grams <= 0:
        return {}
    factor = grams / 100.0
    output: dict[str, Any] = {
        "estimated_grams": round(grams, 1),
        "basis": "nutrition_per_100g_x_estimated_grams",
        "per_100g": per_100g,
    }
    for key, value in per_100g.items():
        scaled = as_float(value, 0.0) * factor
        if scaled <= 0:
            continue
        output[key] = round(scaled, 1)
    return output


def simplify_food_name_zh(name: Any) -> str:
    return str(name or "").strip()


def nutrition_pack_from_item(item: dict[str, Any], source_key: str) -> dict[str, Any]:
    source = item.get(source_key) if isinstance(item.get(source_key), dict) else {}
    aliases = {
        "calories": ("calories", "kcal", "calories_kcal", "energy_kcal", "kcal_per_100g", "calories_per_100g", "kcal100"),
        "protein_g": ("protein_g", "protein", "protein100", "protein_per_100g", "p100"),
        "carbs_g": ("carbs_g", "carbs", "carbohydrate_g", "carbohydrates_g", "carbs100", "carbs_per_100g", "c100"),
        "fat_g": ("fat_g", "fat", "fat100", "fat_per_100g", "f100"),
        "fiber_g": ("fiber_g", "fiber", "fiber100", "fiber_per_100g", "fi100"),
        "sodium_mg": ("sodium_mg", "sodium", "sodium100", "sodium_mg_per_100g", "na100"),
    }
    output: dict[str, Any] = {}
    for target, keys in aliases.items():
        value = 0.0
        for key in keys:
            if key in source:
                value = as_float(source.get(key), 0.0)
                break
            if key in item:
                value = as_float(item.get(key), 0.0)
                break
        if value > 0:
            output[target] = round(value, 1)
    return output


def chinese_food_name(name: Any, category: Any = "") -> str:
    value = str(name or "").strip()
    if not value:
        return ""
    if contains_cjk(value):
        return value
    normalized = re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()
    mapping = {
        "fried chicken": "炸鸡",
        "fried chicken wing": "炸鸡翅",
        "fried chicken wings": "炸鸡翅",
        "fried chicken nugget": "炸鸡块",
        "chicken nugget": "鸡块",
        "popcorn chicken": "鸡米花",
        "chicken": "鸡肉",
        "meat": "肉类",
        "sausage": "香肠",
        "fries": "薯条",
        "french fries": "薯条",
        "potato wedges": "薯角",
        "fried food": "炸物",
        "dessert": "甜点",
        "egg tart": "蛋挞",
        "rice": "米饭",
        "purple rice": "紫米饭",
        "fried rice": "炒饭",
        "noodles": "面条",
        "fried noodles": "炒面",
        "vegetable": "蔬菜",
        "vegetables": "蔬菜",
        "celery": "芹菜",
        "leek": "大葱",
        "shimeji mushrooms": "蟹味菇",
        "mushroom": "蘑菇",
        "mushrooms": "蘑菇",
        "cabbage": "甘蓝",
        "red cabbage": "紫甘蓝",
        "kale": "羽衣甘蓝",
        "broccoli": "西蓝花",
        "brussels sprouts": "抱子甘蓝",
        "tomato": "番茄",
        "cherry tomato": "小番茄",
        "carrot": "胡萝卜",
        "onion": "洋葱",
        "red bell pepper": "红甜椒",
        "bell pepper": "甜椒",
        "olive oil": "橄榄油",
        "sauce": "酱料",
        "soup": "汤",
        "tea": "茶",
        "water": "水",
        "drink": "饮品",
    }
    if normalized in mapping:
        return mapping[normalized]
    for key, zh in sorted(mapping.items(), key=lambda pair: len(pair[0]), reverse=True):
        if key in normalized:
            return zh
    category_text = str(category or "").lower()
    if "drink" in category_text:
        return "饮品"
    if "soup" in category_text:
        return "汤"
    if "vegetable" in category_text:
        return "蔬菜"
    if "protein" in category_text or "meat" in category_text:
        return "肉类"
    if "staple" in category_text:
        return "主食"
    return value


def contains_cjk(text: Any) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", str(text or "")))


def english_detector_phrase(item: dict[str, Any]) -> str:
    name = str(item.get("name_zh") or "").strip()
    category = str(item.get("category") or "").lower()
    mapping = [
        ("紫米饭", "purple rice"),
        ("米饭", "cooked rice"),
        ("炒饭", "fried rice"),
        ("面条", "noodles"),
        ("炒面", "fried noodles"),
        ("鸡肉香菇", "chicken and mushroom dish"),
        ("鸡肉", "chicken"),
        ("鸡", "chicken"),
        ("香菇", "mushroom"),
        ("鸡米花", "popcorn chicken"),
        ("炸鸡块", "fried chicken nugget"),
        ("鸡块", "chicken nugget"),
        ("鸡排", "fried chicken cutlet"),
        ("薯条", "french fries"),
        ("炸薯条", "french fries"),
        ("土豆角", "potato wedges"),
        ("薯角", "potato wedges"),
        ("香肠", "sausage"),
        ("蛋挞", "egg tart"),
        ("炸物", "fried food"),
        ("紫甘蓝", "red cabbage"),
        ("羽衣甘蓝", "kale"),
        ("西蓝花", "broccoli"),
        ("西兰花", "broccoli"),
        ("胡萝卜", "carrot"),
        ("红甜椒", "red bell pepper"),
        ("甜椒", "bell pepper"),
        ("小番茄", "cherry tomato"),
        ("番茄", "tomato"),
        ("芹菜", "celery"),
        ("洋葱", "onion"),
        ("蘑菇", "mushroom"),
        ("黄瓜", "cucumber"),
        ("蔬菜", "vegetable"),
        ("汤", "soup"),
        ("奶茶", "milk tea"),
        ("雪碧", "Sprite"),
        ("可乐", "cola"),
        ("饮料", "drink"),
        ("茶", "tea"),
        ("油", "sauce"),
        ("酱", "sauce"),
    ]
    for zh, en in mapping:
        if zh in name:
            return en
    phrase = str(item.get("detector_phrase") or item.get("name_en") or "").strip()
    if phrase and not contains_cjk(phrase):
        cleaned = re.sub(r"[^A-Za-z0-9, /_-]+", " ", phrase).strip(" .,;/")
        banned = {
            "eat",
            "chopsticks",
            "fork",
            "spoon",
            "needed",
            "table",
            "plate",
            "bowl",
            "cup",
            "container",
            "background",
            "person",
            "hand",
        }
        tokens = [token for token in re.split(r"[\s,;/]+", cleaned.lower()) if token]
        generic = cleaned.lower()
        contradicts_category = (
            generic in {"drink", "water", "tea", "beverage"}
            and "drink" not in category
            and "soup" not in category
            and "饮" not in name
            and "茶" not in name
            and "汤" not in name
            and "水" not in name
        )
        if cleaned and len(cleaned) <= 64 and not all(token in banned for token in tokens) and not contradicts_category:
            return cleaned
    if "drink" in category or "饮" in category:
        return "drink"
    if "soup" in category or "汤" in category:
        return "soup"
    if "dessert" in category or "甜" in category:
        return "dessert"
    if "protein" in category or "肉" in category:
        return "meat"
    if "vegetable" in category or "菜" in category:
        return "vegetable"
    if "snack" in category or "炸" in name:
        return "fried food"
    if "staple" in category or "饭" in name or "面" in name:
        return "staple food"
    return "food"


def detector_prompt_from_items(items: list[dict[str, Any]], scene: dict[str, Any] | None = None) -> str:
    phrases: list[str] = []
    for item in items:
        phrase = english_detector_phrase(item)
        if phrase and phrase.lower() not in {"food", "staple food", "vegetable", "drink"}:
            phrases.append(phrase)
        elif phrase:
            phrases.append(phrase)
    if not phrases and isinstance(scene, dict):
        raw_prompt = str(scene.get("detector_prompt_en") or "")
        for chunk in re.split(r"[.;\n]+", raw_prompt):
            chunk = re.sub(r"[^A-Za-z0-9, /_-]+", " ", chunk).strip(" .,;/")
            if 0 < len(chunk) <= 64:
                phrases.append(chunk)
    deduped: list[str] = []
    seen: set[str] = set()
    for phrase in phrases:
        key = phrase.lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(phrase)
    return " . ".join(deduped) or "food"


def normalize_scene_item(item: dict[str, Any]) -> dict[str, Any]:
    """Accept compact RGB-only keys while preserving the existing response shape."""
    if not isinstance(item, dict):
        return {}
    normalized = dict(item)
    if not normalized.get("name_zh"):
        normalized["name_zh"] = normalized.get("n") or normalized.get("name") or normalized.get("food")
    normalized["name_zh"] = simplify_food_name_zh(normalized.get("name_zh"))
    if normalized.get("n"):
        normalized["n"] = normalized["name_zh"]
    if not normalized.get("category"):
        normalized["category"] = normalized.get("c") or normalized.get("cat")
    normalized["name_zh"] = chinese_food_name(normalized.get("name_zh"), normalized.get("category"))
    if normalized.get("n"):
        normalized["n"] = normalized["name_zh"]
    if not normalized.get("confidence"):
        normalized["confidence"] = as_float(normalized.get("conf"), 0.0)
    if "liquid" not in normalized:
        normalized["liquid"] = bool(normalized.get("l"))
    if "mixed_dish" not in normalized:
        normalized["mixed_dish"] = bool(normalized.get("m"))
    if not isinstance(normalized.get("visual_volume_hint"), dict):
        volume_ml = as_float(
            normalized.get("v")
            or normalized.get("volume_ml")
            or normalized.get("estimated_volume_ml")
            or normalized.get("visual_volume_ml")
            or normalized.get("vol_ml")
            or normalized.get("ml"),
            0.0,
        )
        if volume_ml > 0:
            normalized["visual_volume_hint"] = {
                "volume_ml": volume_ml,
                "basis": "glm_compact_visual_volume",
                "confidence": as_float(normalized.get("conf"), as_float(normalized.get("confidence"), 0.0)),
            }
    if not isinstance(normalized.get("density_hint"), dict):
        density = as_float(normalized.get("rho") or normalized.get("density_g_per_ml") or normalized.get("density"), 0.0)
        if density > 0:
            normalized["density_hint"] = {
                "density_g_per_ml": density,
                "basis": "glm_compact_density",
                "confidence": as_float(normalized.get("conf"), as_float(normalized.get("confidence"), 0.0)),
            }
    direct_nutrition = nutrition_pack_from_item(normalized, "direct_nutrition")
    if direct_nutrition:
        normalized["direct_nutrition"] = direct_nutrition
    nutrition_per_100g = nutrition_pack_from_item(normalized, "nutrition_per_100g")
    if nutrition_per_100g:
        normalized["nutrition_per_100g"] = nutrition_per_100g
    normalized["detector_phrase"] = english_detector_phrase(normalized)
    return normalized


def load_glm():
    global glm_processor, glm_model, loaded_at
    if glm_processor is not None and glm_model is not None:
        return
    require_transformers()
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"GLM model path not found: {MODEL_PATH}")
    glm_processor = AutoProcessor.from_pretrained(MODEL_PATH, use_fast=True, trust_remote_code=True)
    glm_model = Glm4vForConditionalGeneration.from_pretrained(
        MODEL_PATH,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    ).eval()
    if GLM_ADAPTER_PATH:
        if not os.path.exists(GLM_ADAPTER_PATH):
            raise RuntimeError(f"GLM adapter path not found: {GLM_ADAPTER_PATH}")
        from peft import PeftModel

        glm_model = PeftModel.from_pretrained(glm_model, GLM_ADAPTER_PATH).eval()
    loaded_at = time.time()


def load_food_r1():
    global food_r1_processor, food_r1_model, loaded_at
    if food_r1_processor is not None and food_r1_model is not None:
        return
    require_transformers()
    if not os.path.exists(FOOD_R1_MODEL_PATH):
        raise RuntimeError(f"Food-R1 model path not found: {FOOD_R1_MODEL_PATH}")
    partial_files = list(Path(FOOD_R1_MODEL_PATH).glob("*.aria2"))
    if partial_files:
        raise RuntimeError(f"Food-R1 model download incomplete: {partial_files[0].name}")
    food_r1_processor = AutoProcessor.from_pretrained(FOOD_R1_MODEL_PATH, use_fast=True, trust_remote_code=True)
    food_r1_model = AutoModelForImageTextToText.from_pretrained(
        FOOD_R1_MODEL_PATH,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    ).eval()
    loaded_at = time.time()


def extract_parts(content: Any) -> tuple[str, list[Image.Image]]:
    if isinstance(content, str):
        return content, []
    texts: list[str] = []
    images: list[Image.Image] = []
    if not isinstance(content, list):
        return str(content or ""), images
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            texts.append(str(item.get("text") or ""))
        elif item.get("type") in {"image_url", "image"}:
            image_url = item.get("image_url")
            url = image_url.get("url") if isinstance(image_url, dict) else item.get("image") or image_url
            if url:
                images.append(decode_image(str(url)))
    return "\n".join(t for t in texts if t.strip()), images


def normalize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    system_texts: list[str] = []
    output: list[dict[str, Any]] = []
    for message in messages:
        role = message.get("role") or "user"
        text, images = extract_parts(message.get("content", ""))
        if role == "system":
            if text:
                system_texts.append(text)
            continue
        content: list[dict[str, Any]] = []
        for image in images:
            content.append({"type": "image", "image": image})
        if system_texts:
            text = "\n\n".join(system_texts + ([text] if text else []))
            system_texts = []
        if text:
            content.append({"type": "text", "text": text})
        output.append({"role": "user" if role not in {"assistant", "user"} else role, "content": content or [{"type": "text", "text": "请描述图片。"}]})
    if not output:
        output.append({"role": "user", "content": [{"type": "text", "text": "\n\n".join(system_texts) or "请描述图片。"}]})
    return output


def generate_glm(messages: list[dict[str, Any]], max_tokens: int, temperature: float = 0.0) -> str:
    load_glm()
    inputs = glm_processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=ENABLE_THINKING,
        return_dict=True,
        return_tensors="pt",
    ).to(model_device(glm_model))
    inputs.pop("token_type_ids", None)
    kwargs = {"max_new_tokens": max(max_tokens, MIN_MAX_TOKENS)}
    if temperature > 0.001:
        kwargs.update({"do_sample": True, "temperature": temperature})
    else:
        kwargs["do_sample"] = False
    with torch.inference_mode():
        generated = glm_model.generate(**inputs, **kwargs)
    output_ids = generated[0][inputs["input_ids"].shape[1]:]
    text = glm_processor.decode(output_ids, skip_special_tokens=True).strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    if "<answer>" in text and "</answer>" in text:
        text = text.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    return text


def generate_food_r1(messages: list[dict[str, Any]], max_tokens: int, temperature: float = 0.0) -> str:
    load_food_r1()
    inputs = food_r1_processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        return_dict=True,
        return_tensors="pt",
    ).to(food_r1_model.device)
    inputs.pop("token_type_ids", None)
    kwargs = {"max_new_tokens": max(max_tokens, MIN_MAX_TOKENS)}
    if temperature > 0.001:
        kwargs.update({"do_sample": True, "temperature": temperature})
    else:
        kwargs["do_sample"] = False
    with torch.inference_mode():
        generated = food_r1_model.generate(**inputs, **kwargs)
    output_ids = generated[0][inputs["input_ids"].shape[1]:]
    text = food_r1_processor.decode(output_ids, skip_special_tokens=True).strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    if "<answer>" in text and "</answer>" in text:
        text = text.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    return text


def generate_scene_model(messages: list[dict[str, Any]], max_tokens: int, temperature: float = 0.0) -> str:
    global last_scene_model_provider
    if SCENE_MODEL_PROVIDER in {"food_r1", "food-r1", "foodr1"}:
        try:
            text = generate_food_r1(messages, max_tokens=max_tokens, temperature=temperature)
            last_scene_model_provider = "food_r1"
            return text
        except Exception:
            if not SCENE_MODEL_FALLBACK_TO_GLM:
                raise
            text = generate_glm(messages, max_tokens=max_tokens, temperature=temperature)
            last_scene_model_provider = "glm_fallback"
            return text
    if SCENE_MODEL_PROVIDER in {"glm_food_r1", "glm-food-r1", "glm_foodr1", "glm-foodr1"}:
        text = generate_glm(messages, max_tokens=max_tokens, temperature=temperature)
        last_scene_model_provider = "glm_food_r1"
        return text
    text = generate_glm(messages, max_tokens=max_tokens, temperature=temperature)
    last_scene_model_provider = "glm"
    return text


def load_detector():
    global detector_processor, detector_model
    if not DETECTOR_ENABLED:
        return
    if detector_processor is not None and detector_model is not None:
        return
    require_transformers()
    try:
        detector_processor = AutoProcessor.from_pretrained(DETECTOR_MODEL_PATH, local_files_only=DETECTOR_LOCAL_FILES_ONLY)
        detector_model = AutoModelForZeroShotObjectDetection.from_pretrained(
            DETECTOR_MODEL_PATH,
            local_files_only=DETECTOR_LOCAL_FILES_ONLY,
        ).to("cuda" if torch.cuda.is_available() else "cpu").eval()
    except Exception:
        detector_processor = None
        detector_model = None
        raise


def detect_objects(image: Image.Image, text_prompt: str, box_threshold: float = 0.25, text_threshold: float = 0.20) -> list[dict]:
    if GROUNDING_DINO_15_DDS_TOKEN:
        dds_result = detect_objects_with_dds_grounding_dino_15(image, text_prompt, box_threshold, text_threshold)
        if dds_result is not None:
            return dds_result
    try:
        load_detector()
    except Exception as exc:
        return [{"error": f"detector_not_ready: {type(exc).__name__}: {str(exc)[:160]}"}]
    if detector_processor is None or detector_model is None:
        return []
    text = text_prompt.strip()
    if text and not text.endswith("."):
        text += " ."
    inputs = detector_processor(images=image, text=text, return_tensors="pt").to(detector_model.device)
    with torch.inference_mode():
        outputs = detector_model(**inputs)
    target_sizes = torch.tensor([image.size[::-1]], device=detector_model.device)
    results = detector_processor.post_process_grounded_object_detection(
        outputs=outputs,
        input_ids=inputs.get("input_ids"),
        threshold=box_threshold,
        text_threshold=text_threshold,
        target_sizes=target_sizes,
    )[0]
    boxes = results.get("boxes", []).detach().cpu().numpy().tolist()
    scores = results.get("scores", []).detach().cpu().numpy().tolist()
    labels = results.get("labels") or results.get("text_labels") or []
    return [
        {
            "detection_id": f"det_{i+1}",
            "phrase": str(labels[i] if i < len(labels) else ""),
            "bbox_xyxy": [round(float(v), 2) for v in box],
            "score": round(float(scores[i]), 4) if i < len(scores) else 0.0,
            "detector": "grounding_dino_open_source",
        }
        for i, box in enumerate(boxes)
    ]


def detect_objects_with_dds_grounding_dino_15(
    image: Image.Image,
    text_prompt: str,
    box_threshold: float,
    text_threshold: float,
) -> list[dict] | None:
    """Use Grounding DINO 1.5 through the official DDS Cloud API when configured.

    The official Grounded-SAM-2 path exposes Grounding DINO 1.5/1.6 through
    dds-cloudapi-sdk. We keep this optional so the service still runs on local
    GroundingDINO when no DDS token is available.
    """
    try:
        from dds_cloudapi_sdk import Client, Config
        from dds_cloudapi_sdk.tasks.v2_task import V2Task
    except Exception:
        return None

    try:
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=92)
        client = Client(Config(GROUNDING_DINO_15_DDS_TOKEN))
        image_b64 = base64.b64encode(buffer.getvalue()).decode("ascii")
        task = V2Task(
            api_path=GROUNDING_DINO_15_API_PATH,
            api_body={
                "image": image_b64,
                "prompt": {"type": "text", "text": text_prompt},
                "prompts": [{"type": "text", "text": text_prompt}],
                "targets": ["bbox"],
                "model": GROUNDING_DINO_15_MODEL,
                "box_threshold": box_threshold,
                "text_threshold": text_threshold,
            },
        )
        client.run_task(task)
        result = getattr(task, "result", None) or {}
        objects = []
        if isinstance(result, dict):
            objects = result.get("objects") or result.get("detections") or result.get("results") or []
        else:
            objects = getattr(result, "objects", None) or getattr(result, "detections", None) or []
        detections = []
        for index, obj in enumerate(objects):
            if isinstance(obj, dict):
                bbox = obj.get("bbox") or obj.get("box") or obj.get("bbox_xyxy") or []
                score = float(obj.get("score") or obj.get("confidence") or 0.0)
                label = str(obj.get("category") or obj.get("label") or obj.get("phrase") or obj.get("text") or "")
            else:
                bbox = getattr(obj, "bbox", None) or getattr(obj, "box", None) or []
                score = float(getattr(obj, "score", 0.0) or 0.0)
                label = str(getattr(obj, "category", "") or getattr(obj, "label", "") or getattr(obj, "phrase", ""))
            if len(bbox) != 4:
                continue
            detections.append(
                {
                    "detection_id": f"det_{index+1}",
                    "phrase": label,
                    "bbox_xyxy": [round(float(v), 2) for v in bbox],
                    "score": round(score, 4),
                    "detector": "grounding_dino_1_5_dds",
                }
            )
        return detections
    except Exception as exc:
        print(f"[DepthPipeline] Grounding DINO 1.5 DDS failed: {type(exc).__name__}: {str(exc)[:240]}")
        return None


def load_sam2():
    global sam2_predictor
    if not SAM2_ENABLED or sam2_predictor is not None:
        return
    require_torch()
    if not SAM2_CHECKPOINT or not SAM2_MODEL_CFG:
        raise RuntimeError("SAM2_CHECKPOINT and SAM2_MODEL_CFG are required")
    from sam2.build_sam import build_sam2
    from sam2.sam2_image_predictor import SAM2ImagePredictor

    config_name = str(SAM2_MODEL_CFG)
    if "/configs/" in config_name:
        config_name = "configs/" + config_name.split("/configs/", 1)[1]
    elif config_name.startswith("sam2.1/") or config_name.startswith("sam2/"):
        config_name = "configs/" + config_name
    model = build_sam2(config_name, SAM2_CHECKPOINT, device="cuda" if torch.cuda.is_available() else "cpu")
    sam2_predictor = SAM2ImagePredictor(model)


def remove_tiny_components(mask: np.ndarray, min_area: int = 64) -> np.ndarray:
    mask_u8 = mask.astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask_u8, 8)
    output = np.zeros_like(mask_u8)
    for idx in range(1, count):
        if stats[idx, cv2.CC_STAT_AREA] >= min_area:
            output[labels == idx] = 1
    return output.astype(bool)


def fill_mask_holes(mask: np.ndarray) -> np.ndarray:
    mask_u8 = mask.astype(np.uint8) * 255
    h, w = mask_u8.shape
    flood = mask_u8.copy()
    fill = np.zeros((h + 2, w + 2), np.uint8)
    cv2.floodFill(flood, fill, (0, 0), 255)
    return ((mask_u8 | cv2.bitwise_not(flood)) > 0)


def postprocess_mask(mask: np.ndarray) -> np.ndarray:
    clean = remove_tiny_components(mask.astype(bool), min_area=80)
    clean = fill_mask_holes(clean)
    kernel = np.ones((3, 3), np.uint8)
    clean = cv2.morphologyEx(clean.astype(np.uint8), cv2.MORPH_OPEN, kernel)
    clean = cv2.morphologyEx(clean, cv2.MORPH_CLOSE, kernel)
    return clean.astype(bool)


def clamped_bbox_xyxy(bbox: list[float] | None, shape: tuple[int, int], margin_ratio: float = 0.0) -> tuple[int, int, int, int] | None:
    if not bbox or len(bbox) != 4:
        return None
    h, w = shape
    x1, y1, x2, y2 = [float(v) for v in bbox]
    if x2 < x1:
        x1, x2 = x2, x1
    if y2 < y1:
        y1, y2 = y2, y1
    margin_x = max(2.0, (x2 - x1) * margin_ratio)
    margin_y = max(2.0, (y2 - y1) * margin_ratio)
    x1 = int(max(0, min(w - 1, np.floor(x1 - margin_x))))
    y1 = int(max(0, min(h - 1, np.floor(y1 - margin_y))))
    x2 = int(max(0, min(w, np.ceil(x2 + margin_x))))
    y2 = int(max(0, min(h, np.ceil(y2 + margin_y))))
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2


def bbox_boolean_mask(shape: tuple[int, int], bbox: list[float] | None, margin_ratio: float = 0.0) -> np.ndarray:
    out = np.zeros(shape, dtype=bool)
    clipped = clamped_bbox_xyxy(bbox, shape, margin_ratio)
    if clipped is None:
        return out
    x1, y1, x2, y2 = clipped
    out[y1:y2, x1:x2] = True
    return out


def bbox_area_pixels(bbox: list[float] | None, shape: tuple[int, int], margin_ratio: float = 0.0) -> int:
    clipped = clamped_bbox_xyxy(bbox, shape, margin_ratio)
    if clipped is None:
        return 0
    x1, y1, x2, y2 = clipped
    return max(0, x2 - x1) * max(0, y2 - y1)


def constrain_mask_to_bbox(mask: np.ndarray, bbox: list[float] | None) -> tuple[np.ndarray, dict[str, Any]]:
    clean = mask.astype(bool)
    shape = clean.shape
    original_area = int(clean.sum())
    exact_area = bbox_area_pixels(bbox, shape, 0.0)
    if exact_area <= 0 or original_area <= 0:
        return clean, {
            "mask_original_area_pixels": original_area,
            "bbox_area_pixels": exact_area,
            "mask_bbox_area_ratio": 0.0,
            "mask_bbox_fit_ratio": 0.0,
            "mask_constrained_to_bbox": False,
        }

    exact_region = bbox_boolean_mask(shape, bbox, 0.0)
    loose_region = bbox_boolean_mask(shape, bbox, 0.12)
    in_bbox_area = int((clean & exact_region).sum())
    loose = clean & loose_region
    loose_area = int(loose.sum())
    constrained = loose
    constrained_to_bbox = loose_area < original_area

    # SAM2 can occasionally flood-fill almost the whole plate from a small box.
    # If the loose crop is still much larger than its DINO box, keep only the
    # pixels inside the exact box so one bad mask cannot erase every neighbor.
    if loose_area > exact_area * 1.45:
        constrained = clean & exact_region
        constrained_to_bbox = True

    constrained = remove_tiny_components(constrained, min_area=64)
    final_area = int(constrained.sum())
    return constrained, {
        "mask_original_area_pixels": original_area,
        "bbox_area_pixels": exact_area,
        "mask_bbox_area_ratio": round(final_area / max(exact_area, 1), 4),
        "mask_bbox_fit_ratio": round(in_bbox_area / max(original_area, 1), 4),
        "mask_constrained_to_bbox": constrained_to_bbox,
    }


def mask_overlap_priority(item: dict) -> float:
    confidence = float(item.get("mask_confidence") or 0.0)
    fit = float(item.get("mask_bbox_fit_ratio") or 0.0)
    area_ratio = float(item.get("mask_bbox_area_ratio") or 0.0)
    image_ratio = float(item.get("mask_image_area_ratio") or 0.0)
    area_penalty = max(0.0, area_ratio - 1.0) * 0.18 + max(0.0, image_ratio - 0.55) * 0.35
    return confidence + fit * 0.22 - area_penalty


def resolve_mask_overlaps(mask_results: list[dict]) -> list[dict]:
    with_arrays = [m for m in mask_results if isinstance(m.get("_mask_array"), np.ndarray)]
    if not with_arrays:
        return mask_results
    ordered = sorted(
        enumerate(mask_results),
        key=lambda pair: mask_overlap_priority(pair[1]),
        reverse=True,
    )
    occupied = np.zeros_like(with_arrays[0]["_mask_array"], dtype=bool)
    resolved = [dict(m) for m in mask_results]
    for original_index, item in ordered:
        mask = item.get("_mask_array")
        if not isinstance(mask, np.ndarray):
            continue
        raw_mask = mask.astype(bool)
        clean = raw_mask & (~occupied)
        removed = int(raw_mask.sum() - clean.sum())
        bbox_region = bbox_boolean_mask(raw_mask.shape, item.get("bbox_xyxy"), 0.0)
        bbox_core = raw_mask & bbox_region
        # Dense food piles have legitimate overlaps. If confidence-only ordering
        # would erase almost all of this item's own boxed region, preserve that
        # boxed core instead of returning an empty mask.
        min_keep = max(64, int(raw_mask.sum() * 0.18))
        preserved_overlap = 0
        if int(clean.sum()) < min_keep and int(bbox_core.sum()) > int(clean.sum()):
            preserved_overlap = int((bbox_core & occupied).sum())
            clean = bbox_core
        occupied |= clean
        resolved[original_index]["_mask_array"] = clean
        resolved[original_index]["area_pixels"] = int(clean.sum())
        resolved[original_index]["overlap_removed_pixels"] = removed
        resolved[original_index]["overlap_preserved_pixels"] = preserved_overlap
    return resolved


def segment_boxes(image: Image.Image, detections: list[dict], capture_id: str, include_arrays: bool = False) -> list[dict]:
    valid = [d for d in detections if d.get("bbox_xyxy")]
    if not valid:
        return []
    try:
        load_sam2()
    except Exception as exc:
        results = []
        for d in valid:
            result = {
                "detection_id": d.get("detection_id"),
                "model": "sam2",
                "mask_url": "",
                "area_pixels": 0,
                "mask_confidence": 0.0,
                "error": f"sam2_not_ready: {type(exc).__name__}: {str(exc)[:160]}",
            }
            if include_arrays:
                result["_mask_array"] = None
            results.append(result)
        return results
    if sam2_predictor is None:
        return []
    image_np = np.array(image)
    boxes = np.array([d["bbox_xyxy"] for d in valid], dtype=np.float32)
    sam2_predictor.set_image(image_np)
    masks, scores, _ = sam2_predictor.predict(box=boxes, multimask_output=False)
    MASK_DIR.mkdir(parents=True, exist_ok=True)
    results = []
    for index, det in enumerate(valid):
        mask = masks[index][0] if masks.ndim == 4 else masks[index]
        mask = postprocess_mask(mask.astype(bool))
        mask, mask_quality = constrain_mask_to_bbox(mask, det.get("bbox_xyxy"))
        area = int(mask.sum())
        score = float(scores[index][0] if getattr(scores, "ndim", 1) > 1 else scores[index])
        item = {
            "detection_id": det.get("detection_id"),
            "bbox_xyxy": det.get("bbox_xyxy") or [],
            "phrase": det.get("phrase") or "",
            "model": "sam2",
            "mask_url": "",
            "mask_preview_base64": "",
            "area_pixels": area,
            "mask_confidence": round(score, 4),
            "mask_image_area_ratio": round(area / max(image.width * image.height, 1), 5),
            **mask_quality,
        }
        item["_mask_array"] = mask
        results.append(item)
    results = resolve_mask_overlaps(results)
    for index, item in enumerate(results):
        mask = item.get("_mask_array")
        if not isinstance(mask, np.ndarray):
            continue
        item["mask_image_area_ratio"] = round(int(mask.sum()) / max(image.width * image.height, 1), 5)
        path = MASK_DIR / f"{capture_id}_{index+1}.png"
        mask_image = Image.fromarray((mask.astype(np.uint8) * 255))
        mask_image.save(path)
        preview = mask_image.copy()
        preview.thumbnail((MASK_PREVIEW_MAX_EDGE, MASK_PREVIEW_MAX_EDGE))
        preview_buffer = io.BytesIO()
        preview.save(preview_buffer, format="PNG", optimize=True)
        item["mask_url"] = str(path)
        item["mask_preview_base64"] = base64.b64encode(preview_buffer.getvalue()).decode("ascii")
        if not include_arrays:
            item.pop("_mask_array", None)
    return results


def scale_intrinsics_to_depth(metadata: dict[str, Any], depth_shape: tuple[int, int]) -> tuple[float, float]:
    camera = metadata.get("camera") if isinstance(metadata.get("camera"), dict) else {}
    intrinsics = camera.get("intrinsics")
    if not intrinsics:
        return 0.0, 0.0
    try:
        fx_rgb = float(intrinsics[0][0])
        fy_rgb = float(intrinsics[1][1])
        ref = camera.get("intrinsics_reference_dimensions") or metadata.get("rgb") or {}
        rgb_w = float(ref.get("width") or metadata.get("rgb", {}).get("width") or 0)
        rgb_h = float(ref.get("height") or metadata.get("rgb", {}).get("height") or 0)
        depth_h, depth_w = depth_shape
        if rgb_w <= 0 or rgb_h <= 0:
            return 0.0, 0.0
        return fx_rgb * depth_w / rgb_w, fy_rgb * depth_h / rgb_h
    except Exception:
        return 0.0, 0.0


def resize_mask_to_depth(mask_rgb: np.ndarray, depth_shape: tuple[int, int]) -> np.ndarray:
    h, w = depth_shape
    resized = cv2.resize(mask_rgb.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST)
    return resized.astype(bool)


def text_tokens(value: str) -> set[str]:
    text = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", " ", str(value or "").lower())
    return {token for token in text.split() if token and token not in {"the", "with", "and", "in", "visible", "foods", "food"}}


def detection_item_score(detection: dict, item: dict) -> float:
    det_tokens = text_tokens(detection.get("phrase") or "")
    item_text = " ".join(
        str(item.get(key) or "")
        for key in ("detector_phrase", "name_en", "name_zh", "canonical_food_key", "category")
    )
    item_tokens = text_tokens(item_text)
    if not det_tokens or not item_tokens:
        return 0.0
    overlap = len(det_tokens & item_tokens)
    jaccard = overlap / max(len(det_tokens | item_tokens), 1)
    containment = overlap / max(min(len(det_tokens), len(item_tokens)), 1)
    score = 0.65 * containment + 0.35 * jaccard
    if str(detection.get("phrase") or "").lower().strip() in str(item.get("detector_phrase") or "").lower():
        score += 0.25
    return min(score, 1.0)


def match_detections_to_items(detections: list[dict], items: list[dict]) -> list[dict]:
    valid = [d for d in detections if d.get("bbox_xyxy")]
    used: set[str] = set()
    matched: list[dict] = []
    for item in items:
        best = {}
        best_score = 0.0
        for detection in valid:
            detection_id = str(detection.get("detection_id") or "")
            if detection_id in used:
                continue
            score = detection_item_score(detection, item)
            if score > best_score:
                best = detection
                best_score = score
        if best and best_score >= 0.18:
            used.add(str(best.get("detection_id") or ""))
            item["detection_match_score"] = round(best_score, 4)
            matched.append(best)
        else:
            item["detection_match_score"] = 0.0
            matched.append({})
    return matched


def estimate_volume_from_depth_mask(
    mask_rgb: np.ndarray | None,
    bbox_xyxy: list[float] | None,
    depth_m: np.ndarray | None,
    confidence: np.ndarray | None,
    metadata: dict[str, Any],
    image: Image.Image,
    item: dict | None = None,
    user_hint: str = "",
    container_hint: str = "",
) -> tuple[float, dict, str, bool, str]:
    item = item or {}
    if depth_m is None:
        volume_ml, quality = rough_volume_for_item(item, bbox_xyxy, image, depth_m, mask_rgb, user_hint, container_hint)
        method = "sam2_mask_area_fallback" if mask_rgb is not None else "bbox_area_fallback"
        reason = "missing_depth" if mask_rgb is not None else "missing_mask_or_depth"
        return volume_ml, quality, method, True, reason
    if mask_rgb is None:
        volume_ml, quality = rough_volume_for_item(item, bbox_xyxy, image, depth_m, None, user_hint, container_hint)
        return volume_ml, quality, "bbox_area_fallback", True, "missing_mask"
    mask_d = resize_mask_to_depth(mask_rgb, depth_m.shape)
    max_valid_depth_m = 5.0 if metadata.get("depth_source") == "metric3d_predicted_depth" else 1.8
    valid = np.isfinite(depth_m) & (depth_m > 0.15) & (depth_m <= max_valid_depth_m)
    if confidence is not None:
        valid &= confidence >= 64
    item_valid = mask_d & valid
    if int(item_valid.sum()) < 20:
        volume_ml, quality = rough_volume_for_item(item, bbox_xyxy, image, depth_m, mask_rgb, user_hint, container_hint)
        return volume_ml, quality, "sam2_mask_area_fallback", True, "not_enough_valid_depth_in_mask"

    kernel = np.ones((9, 9), np.uint8)
    outer = cv2.dilate(mask_d.astype(np.uint8), kernel, iterations=2).astype(bool)
    inner = cv2.dilate(mask_d.astype(np.uint8), kernel, iterations=1).astype(bool)
    ring = outer & (~inner) & valid
    if int(ring.sum()) < 20:
        ring = (~mask_d) & valid
    if int(ring.sum()) < 20:
        volume_ml, quality = rough_volume_for_item(item, bbox_xyxy, image, depth_m, mask_rgb, user_hint, container_hint)
        return volume_ml, quality, "sam2_mask_area_fallback", True, "not_enough_local_baseline_depth"

    base_depth = float(np.percentile(depth_m[ring], 55))
    food_depth = depth_m[item_valid]
    heights = np.clip(base_depth - food_depth, 0.0, 0.16)
    heights = heights[heights > 0.002]
    if heights.size < 20:
        volume_ml, quality = rough_volume_for_item(item, bbox_xyxy, image, depth_m, mask_rgb, user_hint, container_hint)
        return volume_ml, quality, "sam2_mask_area_fallback", True, "height_too_low_or_noisy"

    fx, fy = scale_intrinsics_to_depth(metadata, depth_m.shape)
    if fx <= 0 or fy <= 0:
        # Conservative fallback for missing intrinsics: estimate per-pixel area
        # from a 45-degree-ish phone camera field of view.
        fx = fy = max(depth_m.shape) * 1.25
    ys, xs = np.where(item_valid)
    z = depth_m[ys, xs]
    positive = np.clip(base_depth - z, 0.0, 0.16) > 0.002
    z = z[positive]
    heights = np.clip(base_depth - z, 0.0, 0.16)
    pixel_area_m2 = (z * z) / max(fx * fy, 1.0)
    volume_m3 = float(np.sum(heights * pixel_area_m2))
    volume_ml = max(1.0, min(volume_m3 * 1_000_000.0, 1800.0))
    valid_depth_ratio = float(item_valid.sum() / max(mask_d.sum(), 1))
    mean_conf = float(confidence[item_valid].mean() / 255.0) if confidence is not None and item_valid.any() else 0.0
    quality = {
        "valid_depth_ratio": round(valid_depth_ratio, 4),
        "mean_confidence": round(mean_conf, 4),
        "local_baseline_depth_m": round(base_depth, 4),
        "median_height_m": round(float(np.median(heights)), 4),
        "volume_confidence": round(min(0.95, 0.35 + valid_depth_ratio * 0.35 + mean_conf * 0.20), 4),
    }
    return round(volume_ml, 1), quality, "depth_mask_local_baseline_integration", False, ""


NON_FOOD_CATEGORIES = {"container", "plate", "bowl", "cup", "table", "cutlery", "utensil", "餐具", "容器", "桌面"}
FOOD_CATEGORIES = {"staple", "protein", "meat", "vegetable", "mixed_dish", "soup", "drink", "sauce", "dessert", "snack", "fruit", "主食", "肉禽鱼虾", "蔬菜", "混合菜", "汤", "饮品", "水果"}


def food_semantic_validate(item: dict, detection: dict, segmentation: dict, volume_quality: dict) -> dict:
    category = str(item.get("category") or "").strip()
    category_l = category.lower()
    detector_score = float(detection.get("score") or 0.0)
    mask_confidence = float(segmentation.get("mask_confidence") or 0.0)
    area_pixels = int(segmentation.get("area_pixels") or 0)
    vlm_confidence = float(item.get("confidence") or 0.0)
    volume_confidence = float(volume_quality.get("volume_confidence") or 0.0)
    is_non_food = category_l in NON_FOOD_CATEGORIES or category in NON_FOOD_CATEGORIES
    is_food_category = category_l in FOOD_CATEGORIES or category in FOOD_CATEGORIES
    has_shape = bool(detection.get("bbox_xyxy")) and area_pixels > 32
    score = (
        0.25 * max(vlm_confidence, 0.35 if is_food_category else 0.0)
        + 0.30 * detector_score
        + 0.30 * mask_confidence
        + 0.15 * volume_confidence
    )
    notes = []
    needs_user_check = []
    if is_non_food:
        notes.append("category_is_non_food")
    if not has_shape:
        notes.append("missing_bbox_or_mask")
        needs_user_check.append("food_region")
    if detector_score < 0.25:
        notes.append("low_detector_score")
        needs_user_check.append("food_name")
    if mask_confidence < 0.45:
        notes.append("low_mask_confidence")
        needs_user_check.append("food_region")
    if volume_confidence < 0.45:
        notes.append("low_volume_confidence")
        needs_user_check.append("estimated_grams")
    mixed = bool(item.get("mixed_dish")) or category_l == "mixed_dish"
    if mixed:
        notes.append("mixed_dish_ratio_uncertain")
        needs_user_check.append("ingredient_ratio")
    return {
        "is_food": bool((is_food_category or not is_non_food) and has_shape),
        "semantic_label": category or "food",
        "semantic_confidence": round(max(0.0, min(score, 1.0)), 4),
        "needs_split": bool(mixed and str(item.get("detector_phrase") or "").count(",") >= 2),
        "notes": notes,
        "needs_user_check": sorted(set(needs_user_check)),
    }


def scene_prompt(user_hint: str, container_hint: str, rgb_only: bool = False) -> str:
    if rgb_only:
        return f"""
只看图中明显可见食物，返回紧凑 JSON，无解释。
最多10项；保留主要食物/饮品/酱料，小葱芝麻黑胡椒等微量调味忽略。
每项只用短字段：n中文名,c类别,l液体,m混合菜,v可食体积ml,rho密度g/ml,conf,kcal100,p100,c100,f100,fi100,na100。
n 必须使用中文食物名，不要输出英文；可以保留具体做法、风味、品牌或品类信息。
v和rho必须大于0；不确定就降低conf，不要漏v。
kcal100/p100/c100/f100/fi100/na100 是每100克可食部分营养密度，不是本次总营养；分别是千卡、蛋白克、碳水克、脂肪克、纤维克、钠毫克。
密度参考：水/清汤/茶1.0；米饭/炒饭0.75；熟面0.7；炒菜0.65；肉块0.95；炸物0.55；面包/蛋糕0.35；酱料1.05。
用户提示：{user_hint or "无"}；容器提示：{container_hint or "无"}。
JSON:{{"items":[{{"n":"","c":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","l":false,"m":false,"v":0,"rho":0,"conf":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}}]}}
""".strip()
    return f"""
只识别图片中明显可见食物，返回紧凑 JSON，无解释。
字段只要：name_zh, detector_phrase, category, liquid, mixed_dish, confidence, density_g_per_ml, visual_volume_ml, kcal100, p100, c100, f100, fi100, na100。
name_zh 必须使用中文食物名，不要输出英文；可以保留具体做法、风味、品牌或品类信息。
detector_phrase 必须是英文短语，用于开放词汇检测；detector_prompt_en 用这些英文短语以英文句点分隔。
density_g_per_ml 是可食部分物理密度，用于把体积ml换算成克重；必须大于0，不确定就按类别估计并降低confidence。
visual_volume_ml 是备用视觉体积估计，只在深度/Metric3D体积异常时使用；必须大于0，不确定就降低confidence。
kcal100/p100/c100/f100/fi100/na100 是每100克可食部分营养密度，不是本次总营养；分别是千卡、蛋白克、碳水克、脂肪克、纤维克、钠毫克。
密度参考：水/清汤/茶1.0；米饭/炒饭0.75；熟面0.7；炒菜0.65；肉块0.95；炸物0.55；面包/蛋糕0.35；酱料1.05。
不要输出克重、风险项、建议或不可见食物；除 visual_volume_ml 外不要输出其他体积字段。
拼盘/套餐按明显不同食物拆分；同类重复物可合并。汤面反光、油光、菜汤、清汤、酱汁反光不要误识别为油。
用户提示：{user_hint or "无"}；容器提示：{container_hint or "无"}。
JSON:{{"items":[{{"name_zh":"","detector_phrase":"","category":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","liquid":false,"mixed_dish":false,"confidence":0.0,"density_g_per_ml":0,"visual_volume_ml":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}}],"detector_prompt_en":""}}
""".strip()


def rough_volume_for_item(
    item: dict,
    bbox: list[float] | None,
    image: Image.Image,
    depth: np.ndarray | None,
    mask_rgb: np.ndarray | None = None,
    user_hint: str = "",
    container_hint: str = "",
) -> tuple[float, dict]:
    category = str(item.get("category") or "").lower()
    category_tokens = text_tokens(category)
    base_by_category = {
        "staple": 230.0,
        "protein": 160.0,
        "meat": 170.0,
        "vegetable": 180.0,
        "mixed": 260.0,
        "dish": 260.0,
        "mixed_dish": 260.0,
        "soup": 180.0,
        "drink": 180.0,
        "sauce": 25.0,
        "dessert": 80.0,
        "snack": 80.0,
        "fruit": 140.0,
    }
    base = next((base_by_category[token] for token in category_tokens if token in base_by_category), base_by_category.get(category, 180.0))

    image_area = max(1.0, float(image.width * image.height))
    bbox_area_ratio = 0.0
    if bbox and len(bbox) == 4:
        x1, y1, x2, y2 = [float(v) for v in bbox]
        bbox_area_ratio = max(0.0, (x2 - x1) * (y2 - y1)) / image_area

    mask_area_ratio = 0.0
    if isinstance(mask_rgb, np.ndarray):
        mask_area_ratio = float(mask_rgb.astype(bool).sum()) / image_area

    area_ratio = mask_area_ratio or bbox_area_ratio
    context_text = " ".join(
        str(value or "")
        for value in (
            user_hint,
            container_hint,
            item.get("name_zh"),
            item.get("name_en"),
            item.get("detector_phrase"),
            item.get("category"),
        )
    ).lower()

    liquid = bool(item.get("liquid")) or any(token in category_tokens for token in {"soup", "drink"})
    if area_ratio > 0:
        if mask_area_ratio > 0:
            # Mask area is much less sensitive than bbox area for bowls/trays.
            # The square-root scale approximates portion footprint without
            # letting a large loose bbox become a full serving.
            reference_area = 0.13 if not liquid else 0.20
            area_scale = (area_ratio / reference_area) ** 0.5
            base = base * max(0.22, min(area_scale, 2.4))
        else:
            base = base * (0.55 + min(bbox_area_ratio * 9.0, 2.2))

    leftover_markers = ("剩余", "剩下", "吃剩", "少量", "一点", "碗底", "残余", "leftover", "small amount", "remaining")
    shallow_container_markers = ("碗", "bowl", "透明碗", "餐盒", "container")
    is_leftover = any(marker in context_text for marker in leftover_markers)
    is_shallow_container = any(marker in context_text for marker in shallow_container_markers)
    if is_leftover and not liquid:
        factor = 0.32
        if "碗底" in context_text or "一点" in context_text or "少量" in context_text:
            factor = 0.24
        base *= factor
        if is_shallow_container and area_ratio < 0.12:
            base = min(base, 90.0)

    if "半" in context_text and not is_leftover and not liquid:
        base *= 0.65

    base = max(8.0, min(900.0 if not liquid else 1000.0, base))
    depth_valid = float(np.isfinite(depth).mean()) if depth is not None else 0.0
    return round(base, 1), {
        "volume_confidence": round(0.38 + min(area_ratio * 3.0, 0.22) + min(depth_valid * 0.15, 0.15) - (0.08 if is_leftover else 0.0), 4),
        "valid_depth_ratio": depth_valid,
        "base_plane_inlier_ratio": 0.0,
        "mean_confidence": 0.0,
        "bbox_area_ratio": round(bbox_area_ratio, 5),
        "mask_area_ratio": round(mask_area_ratio, 5),
        "leftover_context": is_leftover,
        "note": "rgb_mask_area_context_fallback_without_depth",
    }


def apply_volume_plausibility_limits(item: dict, volume_ml: float, quality: dict) -> tuple[float, dict, bool]:
    """Clamp obviously impossible depth volumes before density conversion.

    Real LiDAR depth is noisy around glossy bowls, tray edges, and synthetic test
    captures. This guard does not replace user correction; it prevents a single
    mask from becoming a kilogram-scale apple/sauce/snack because the local base
    depth was wrong.
    """
    food_key = str(item.get("canonical_food_key") or item.get("density_key") or item.get("nutrition_key") or "").lower()
    name = f"{item.get('name_zh') or ''} {item.get('name_en') or ''}".lower()
    category = str(item.get("category") or "").lower()
    liquid = bool(item.get("liquid"))

    if "apple" in food_key or "苹果" in name or "apple" in name:
        max_ml = 320.0
    elif "sauce" in category or "酱" in name:
        max_ml = 90.0
    elif liquid or category in {"drink", "soup", "汤", "饮品"}:
        max_ml = 900.0
    elif category in {"fruit", "水果"}:
        max_ml = 500.0
    elif category in {"snack", "dessert", "小吃", "甜品"}:
        max_ml = 650.0
    elif category in {"protein", "meat", "肉禽鱼虾"}:
        max_ml = 800.0
    elif category in {"staple", "主食"}:
        max_ml = 900.0
    elif category in {"mixed_dish", "混合菜"}:
        max_ml = 1200.0
    else:
        max_ml = 900.0

    adjusted = float(volume_ml) > max_ml
    if not adjusted:
        return round(float(volume_ml), 1), quality, False

    quality = dict(quality or {})
    quality["plausibility_adjusted"] = True
    quality["raw_volume_ml"] = round(float(volume_ml), 1)
    quality["volume_cap_ml"] = max_ml
    quality["volume_confidence"] = round(min(float(quality.get("volume_confidence") or 0.0), 0.44), 4)
    return round(max_ml, 1), quality, True


@app.on_event("startup")
def startup():
    if os.getenv("PRELOAD_GLM_ON_STARTUP", "0").strip().lower() in {"1", "true", "yes", "on"}:
        load_glm()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "glm": {
            "model": MODEL_NAME,
            "loaded": glm_model is not None,
            "path": MODEL_PATH,
            "adapter_path": GLM_ADAPTER_PATH or None,
            "adapter_loaded": bool(GLM_ADAPTER_PATH and glm_model is not None),
        },
        "scene_model": {
            "provider": SCENE_MODEL_PROVIDER,
            "fallback_to_glm": SCENE_MODEL_FALLBACK_TO_GLM,
            "food_r1": {
                "model": FOOD_R1_MODEL_NAME,
                "loaded": food_r1_model is not None,
                "path": FOOD_R1_MODEL_PATH,
            },
            "glm": {
                "model": MODEL_NAME,
                "loaded": glm_model is not None,
                "path": MODEL_PATH,
                "adapter_path": GLM_ADAPTER_PATH or None,
                "adapter_loaded": bool(GLM_ADAPTER_PATH and glm_model is not None),
            },
        },
        "detector": {
            "requested": "grounding_dino_open_source",
            "enabled": DETECTOR_ENABLED,
            "implementation": "open_source_grounded_segment_anything_style",
            "dds_1_5_configured": bool(GROUNDING_DINO_15_DDS_TOKEN),
            "official_1_5_ready": bool(GROUNDING_DINO_15_DDS_TOKEN),
            "dds_api_path": GROUNDING_DINO_15_API_PATH,
            "dds_model": GROUNDING_DINO_15_MODEL,
            "loaded": detector_model is not None,
            "local_provider": "grounding_dino_open_source",
            "path": DETECTOR_MODEL_PATH,
        },
        "sam2": {
            "enabled": SAM2_ENABLED,
            "loaded": sam2_predictor is not None,
            "checkpoint": SAM2_CHECKPOINT,
            "config": SAM2_MODEL_CFG,
        },
        "metric3d": {
            "enabled": METRIC3D_ENABLED,
            "loaded": metric3d_model is not None,
            "repo": METRIC3D_REPO,
            "model": METRIC3D_MODEL,
            "torch_home": os.environ.get("TORCH_HOME") or METRIC3D_TORCH_HOME,
            "input_size": [METRIC3D_INPUT_HEIGHT, METRIC3D_INPUT_WIDTH],
        },
        "gpu": torch.cuda.get_device_name(0) if torch is not None and torch.cuda.is_available() else None,
    }


@app.post("/v1/chat/completions")
def chat_completions(request: ChatCompletionRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    if request.stream:
        raise HTTPException(status_code=400, detail="stream=true is not supported")
    started = time.time()
    try:
        text = generate_scene_model(
            normalize_messages(request.messages),
            max_tokens=int(request.max_completion_tokens or request.max_tokens or DEFAULT_MAX_TOKENS),
            temperature=float(request.temperature or 0.0),
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"GLM inference failed: {type(exc).__name__}: {str(exc)[:300]}") from exc
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:16]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model or MODEL_NAME,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "latency_seconds": round(time.time() - started, 3),
    }


@app.post("/v1/depth-meal/analyze")
def analyze_depth_meal(request: DepthMealAnalyzeRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    started = time.time()
    stage_timings: dict[str, float] = {}
    capture_id = request.capture_id or uuid.uuid4().hex[:12]
    try:
        image = decode_image(request.rgb_base64)
        auxiliary_images = [decode_image(value) for value in request.auxiliary_images_base64[:4] if value]
        depth = decode_depth(request.depth_base64, request.metadata)
        confidence = decode_confidence(request.confidence_base64, request.metadata)
        metric3d_started = time.time()
        depth, confidence, metadata, depth_source = depth_or_metric3d(image, depth, confidence, request.metadata)
        if depth_source == "metric3d_predicted_depth":
            stage_timings["metric3d_depth_seconds"] = round(time.time() - metric3d_started, 3)
        stage_timings["depth_source"] = depth_source
        message_content: list[dict[str, Any]] = [
            {"type": "image", "image": image},
        ]
        for index, auxiliary_image in enumerate(auxiliary_images, start=1):
            message_content.extend(
                [
                    {"type": "text", "text": f"辅助图{index}：只用于核对包装名、营养表、秤读数或其他角度。"},
                    {"type": "image", "image": auxiliary_image},
                ]
            )
        auxiliary_rule = (
            "\n第1张是主图，食物项目和分割必须以主图为准。"
            "辅助图不得新增或重复食物项，只能修正主图中已可见项的名称、每100克营养和明确秤读数。"
            if auxiliary_images
            else ""
        )
        message_content.append(
            {
                "type": "text",
                "text": scene_prompt(request.user_hint, request.container_hint, rgb_only=depth is None) + auxiliary_rule,
            }
        )
        messages = [
            {
                "role": "user",
                "content": message_content,
            }
        ]
        stage_started = time.time()
        scene_text = generate_scene_model(messages, max_tokens=650 if depth is None else 700)
        stage_timings["scene_model_seconds"] = round(time.time() - stage_started, 3)
        stage_timings["auxiliary_image_count"] = len(auxiliary_images)
        stage_started = time.time()
        scene, parse_strategy = parse_scene_or_retry(
            scene_text,
            image,
            request.user_hint,
            request.container_hint,
            rgb_only=depth is None,
        )
        stage_timings["scene_parse_strategy"] = parse_strategy
        stage_timings["json_parse_or_repair_seconds"] = round(time.time() - stage_started, 3)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"scene understanding failed: {type(exc).__name__}: {str(exc)[:300]}") from exc

    items = scene.get("items") if isinstance(scene.get("items"), list) else []
    items = [normalize_scene_item(item) for item in items if isinstance(item, dict)]
    scene_model_provider_used = last_scene_model_provider or SCENE_MODEL_PROVIDER
    scene["scene_model_provider"] = scene_model_provider_used
    scene["items"] = items
    prompt = detector_prompt_from_items(items, scene)
    scene["detector_prompt_en"] = prompt
    if depth is None:
        stage_started = time.time()
        detections = detect_objects(image, prompt)
        stage_timings["grounding_dino_seconds"] = round(time.time() - stage_started, 3)
        stage_started = time.time()
        matched_detections = match_detections_to_items(detections, items)
        for index, item in enumerate(items):
            current = matched_detections[index] if index < len(matched_detections) else {}
            if current.get("bbox_xyxy"):
                continue
            if len(detections) == len(items) and index < len(detections) and detections[index].get("bbox_xyxy"):
                matched_detections[index] = detections[index]
                item["detection_match_score"] = item.get("detection_match_score") or 0.12
        stage_timings["detection_match_seconds"] = round(time.time() - stage_started, 3)
        detections_for_segmentation = [d for d in matched_detections if d.get("bbox_xyxy")]
        stage_started = time.time()
        segmentations = segment_boxes(image, detections_for_segmentation, capture_id, include_arrays=True)
        stage_timings["sam2_segmentation_seconds"] = round(time.time() - stage_started, 3)
        seg_by_detection = {s.get("detection_id"): s for s in segmentations}

        output_items = []
        skipped_items = []
        volume_started = time.time()
        for index, item in enumerate(items):
            det = matched_detections[index] if index < len(matched_detections) else {}
            seg = seg_by_detection.get(det.get("detection_id"), {}) if det.get("bbox_xyxy") else {}
            seg_public = {key: value for key, value in seg.items() if key != "_mask_array"} if isinstance(seg, dict) else {}
            mask = seg.get("_mask_array") if isinstance(seg, dict) else None
            volume_ml, volume_hint = visual_volume_hint(item)
            volume_method = "food_r1_visual_volume_estimate" if scene_model_provider_used == "food_r1" else "glm_visual_volume_estimate"
            fallback_reason = "rgb_only_visual_volume_no_depth"
            if volume_ml <= 0:
                volume_ml, volume_hint = rough_volume_for_item(
                    item,
                    det.get("bbox_xyxy") if det else None,
                    image,
                    None,
                    mask,
                    request.user_hint,
                    request.container_hint,
                )
                volume_method = "sam2_mask_area_rgb_fallback" if mask is not None else "bbox_area_rgb_fallback"
                fallback_reason = "missing_scene_visual_volume"
            weight = visual_weight_from_volume(item, volume_ml)
            estimated_nutrition = estimated_nutrition_from_item(item, weight["estimated_grams"])
            volume_confidence = min(
                0.92,
                max(
                    0.25,
                    0.45
                    + as_float(volume_hint.get("confidence"), 0.0) * 0.30
                    + as_float((item.get("density_hint") or {}).get("confidence") if isinstance(item.get("density_hint"), dict) else 0.0, 0.0) * 0.20
                    + as_float(item.get("confidence"), 0.0) * 0.15,
                ),
            )
            semantic_validation = food_semantic_validate(item, det, seg_public, volume_hint) if det.get("bbox_xyxy") else {}
            output_items.append(
                {
                    **item,
                    "estimated_volume_ml": volume_ml,
                    "visual_estimated_grams": weight["estimated_grams"],
                    "estimated_nutrition": estimated_nutrition,
                    "semantic_validation": semantic_validation,
                    "volume": {
                        "estimated_volume_ml": volume_ml,
                        "volume_method": volume_method,
                        "depth_source": "none",
                        "fallback": True,
                        "fallback_reason": fallback_reason,
                        "depth_quality": {
                            "volume_confidence": round(volume_confidence, 4),
                            "visual_volume_hint": volume_hint,
                            "bbox_area_ratio": volume_hint.get("bbox_area_ratio"),
                            "mask_area_ratio": volume_hint.get("mask_area_ratio"),
                            "note": "rgb_only_scene_visual_volume_with_groundingdino_sam2_without_depth",
                        },
                    },
                    "weight": {
                        "estimated_grams": weight["estimated_grams"],
                        "density_g_per_ml": weight["density_g_per_ml"],
                        "density_source": weight["density_source"],
                        "density_hint": weight["density_hint"],
                    },
                    "detection": {
                        "detector": det.get("detector") or "grounding_dino_unavailable",
                        "phrase": item.get("detector_phrase") or item.get("name_en") or item.get("name_zh") or "",
                        "bbox_xyxy": det.get("bbox_xyxy") or [],
                        "score": det.get("score") or 0.0,
                        "match_score": item.get("detection_match_score") or 0.0,
                    },
                    "segmentation": {
                        "model": seg_public.get("model") or ("sam2" if det.get("bbox_xyxy") else "sam2_not_run_without_bbox"),
                        "mask_url": seg_public.get("mask_url") or "",
                        "mask_preview_base64": seg_public.get("mask_preview_base64") or "",
                        "area_pixels": seg_public.get("area_pixels") or 0,
                        "mask_confidence": seg_public.get("mask_confidence") or 0.0,
                        "bbox_area_pixels": seg_public.get("bbox_area_pixels") or 0,
                        "mask_original_area_pixels": seg_public.get("mask_original_area_pixels") or 0,
                        "mask_bbox_area_ratio": seg_public.get("mask_bbox_area_ratio") or 0.0,
                        "mask_bbox_fit_ratio": seg_public.get("mask_bbox_fit_ratio") or 0.0,
                        "mask_constrained_to_bbox": seg_public.get("mask_constrained_to_bbox") or False,
                        "overlap_removed_pixels": seg_public.get("overlap_removed_pixels") or 0,
                        "overlap_preserved_pixels": seg_public.get("overlap_preserved_pixels") or 0,
                    },
                    "needs_user_check": sorted(set((item.get("needs_user_check") or []) + ["estimated_grams"])),
                }
            )
            if not det.get("bbox_xyxy"):
                skipped_items.append(
                    {
                        "name_zh": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or "",
                        "reason": "grounding_dino_not_detected_rgb_only",
                        "detection_match_score": item.get("detection_match_score") or 0.0,
                    }
                )
            elif not seg_public.get("area_pixels"):
                skipped_items.append(
                    {
                        "name_zh": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or "",
                        "reason": "sam2_not_segmented_rgb_only",
                        "detection_id": det.get("detection_id") or "",
                        "bbox_xyxy": det.get("bbox_xyxy") or [],
                    }
                )
        stage_timings["rgb_visual_volume_items_seconds"] = round(time.time() - volume_started, 3)
        return {
            "capture_id": capture_id,
            "status": "completed",
            "estimation_mode": "cloud_food_r1_groundingdino_sam2_rgb_visual_volume" if scene_model_provider_used == "food_r1" else "cloud_glm46v_groundingdino_sam2_rgb_visual_volume",
            "scene": scene,
            "detections": detections,
            "segmentations": [{key: value for key, value in item.items() if key != "_mask_array"} for item in segmentations],
            "skipped_items": skipped_items,
            "items": output_items,
            "stage_timings": stage_timings,
            "latency_seconds": round(time.time() - started, 3),
        }

    stage_started = time.time()
    detections = detect_objects(image, prompt)
    stage_timings["grounding_dino_seconds"] = round(time.time() - stage_started, 3)
    stage_started = time.time()
    matched_detections = match_detections_to_items(detections, items)
    stage_timings["detection_match_seconds"] = round(time.time() - stage_started, 3)
    detections_for_segmentation = [d for d in matched_detections if d.get("bbox_xyxy")]
    stage_started = time.time()
    segmentations = segment_boxes(image, detections_for_segmentation, capture_id, include_arrays=True)
    stage_timings["sam2_segmentation_seconds"] = round(time.time() - stage_started, 3)
    seg_by_detection = {s.get("detection_id"): s for s in segmentations}

    output_items = []
    skipped_items = []
    volume_started = time.time()
    for index, item in enumerate(items):
        det = matched_detections[index] if index < len(matched_detections) else {}
        if not det.get("bbox_xyxy"):
            skipped_items.append(
                {
                    "name_zh": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or "",
                    "reason": "grounding_dino_not_detected",
                    "detection_match_score": item.get("detection_match_score") or 0.0,
                }
            )
            continue
        seg = seg_by_detection.get(det.get("detection_id"), {})
        seg_public = {key: value for key, value in seg.items() if key != "_mask_array"} if isinstance(seg, dict) else {}
        if not isinstance(seg, dict) or seg.get("_mask_array") is None or int(seg_public.get("area_pixels") or 0) <= 0:
            skipped_items.append(
                {
                    "name_zh": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or "",
                    "reason": "sam2_not_segmented",
                    "detection_id": det.get("detection_id") or "",
                    "bbox_xyxy": det.get("bbox_xyxy") or [],
                    "detector_score": det.get("score") or 0.0,
                    "segmentation_error": seg_public.get("error") or "",
                }
            )
            continue
        volume_ml, depth_quality, volume_method, fallback, fallback_reason = estimate_volume_from_depth_mask(
            seg.get("_mask_array"),
            det.get("bbox_xyxy"),
            depth,
            confidence,
            metadata,
            image,
            item,
            request.user_hint,
            request.container_hint,
        )
        volume_ml, depth_quality, plausibility_adjusted = apply_volume_plausibility_limits(item, volume_ml, depth_quality)
        if plausibility_adjusted:
            capped_volume_ml = volume_ml
            visual_volume_ml, visual_volume_hint_data = visual_volume_hint(item)
            visual_volume_method = "scene_visual_volume_hint_after_depth_cap"
            if visual_volume_ml <= 0:
                visual_volume_ml, visual_volume_hint_data = rough_volume_for_item(
                    item,
                    det.get("bbox_xyxy"),
                    image,
                    None,
                    seg.get("_mask_array"),
                    request.user_hint,
                    request.container_hint,
                )
                visual_volume_method = (
                    "sam2_mask_area_rgb_fallback_after_depth_cap"
                    if seg.get("_mask_array") is not None
                    else "bbox_area_rgb_fallback_after_depth_cap"
                )
            if visual_volume_ml > 0:
                depth_quality = dict(depth_quality or {})
                depth_quality["capped_depth_volume_ml"] = capped_volume_ml
                depth_quality["visual_fallback_volume_ml"] = visual_volume_ml
                depth_quality["visual_fallback_hint"] = visual_volume_hint_data
                volume_ml = visual_volume_ml
                volume_method = visual_volume_method
        if plausibility_adjusted and not fallback_reason:
            fallback = True
            fallback_reason = "volume_plausibility_cap"
        validation = food_semantic_validate(item, det, seg_public, depth_quality)
        fallback_check = ["volume_fallback"] if fallback else []
        item_needs_check = sorted(set((item.get("needs_user_check") or []) + validation.get("needs_user_check", []) + fallback_check))
        weight = visual_weight_from_volume(item, volume_ml)
        estimated_nutrition = estimated_nutrition_from_item(item, weight["estimated_grams"])
        output_items.append(
            {
                **item,
                "needs_user_check": item_needs_check,
                "estimated_volume_ml": volume_ml,
                "visual_estimated_grams": weight["estimated_grams"],
                "weight": weight,
                "estimated_nutrition": estimated_nutrition,
                "volume_warning": {
                    "reason": fallback_reason or "volume_fallback",
                    "detection_id": det.get("detection_id") or "",
                    "bbox_xyxy": det.get("bbox_xyxy") or [],
                    "detector_score": det.get("score") or 0.0,
                    "mask_area": seg_public.get("area_pixels") or 0,
                    "volume_method": volume_method,
                } if fallback else {},
                "semantic_validation": validation,
                "volume": {
                    "estimated_volume_ml": volume_ml,
                    "volume_method": volume_method,
                    "depth_source": metadata.get("depth_source") or depth_source or "uploaded_depth",
                    "fallback": fallback,
                    "fallback_reason": fallback_reason,
                    "depth_quality": depth_quality,
                },
                "detection": {
                    "detector": det.get("detector") or "grounding_dino_unavailable",
                    "phrase": det.get("phrase") or item.get("detector_phrase") or item.get("name_en") or item.get("name_zh"),
                    "bbox_xyxy": det.get("bbox_xyxy") or [],
                    "score": det.get("score") or 0.0,
                    "match_score": item.get("detection_match_score") or 0.0,
                },
                "segmentation": {
                    "model": seg_public.get("model") or "sam2",
                    "mask_url": seg_public.get("mask_url") or "",
                    "mask_preview_base64": seg_public.get("mask_preview_base64") or "",
                    "area_pixels": seg_public.get("area_pixels") or 0,
                    "mask_confidence": seg_public.get("mask_confidence") or 0.0,
                    "bbox_area_pixels": seg_public.get("bbox_area_pixels") or 0,
                    "mask_original_area_pixels": seg_public.get("mask_original_area_pixels") or 0,
                    "mask_bbox_area_ratio": seg_public.get("mask_bbox_area_ratio") or 0.0,
                    "mask_bbox_fit_ratio": seg_public.get("mask_bbox_fit_ratio") or 0.0,
                    "mask_constrained_to_bbox": seg_public.get("mask_constrained_to_bbox") or False,
                    "overlap_removed_pixels": seg_public.get("overlap_removed_pixels") or 0,
                    "overlap_preserved_pixels": seg_public.get("overlap_preserved_pixels") or 0,
                },
            }
        )
    stage_timings["depth_volume_items_seconds"] = round(time.time() - volume_started, 3)

    return {
        "capture_id": capture_id,
        "status": "completed",
        "estimation_mode": (
            "cloud_food_r1_groundingdino_sam2_metric3d_depth"
            if scene_model_provider_used == "food_r1" and depth_source == "metric3d_predicted_depth"
            else "cloud_glm46v_groundingdino_sam2_metric3d_depth"
            if depth_source == "metric3d_predicted_depth"
            else "cloud_food_r1_groundingdino_sam2_depth"
            if scene_model_provider_used == "food_r1"
            else "cloud_glm46v_groundingdino_sam2_depth"
        ),
        "scene": scene,
        "detections": detections,
        "segmentations": [{key: value for key, value in item.items() if key != "_mask_array"} for item in segmentations],
        "skipped_items": skipped_items,
        "items": output_items,
        "stage_timings": stage_timings,
        "latency_seconds": round(time.time() - started, 3),
    }


@app.post("/v1/detect")
def detect_endpoint(request: DetectRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    started = time.time()
    try:
        image = decode_image(request.image_base64)
        detections = detect_objects(image, request.text_prompt, request.box_threshold, request.text_threshold)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"detect failed: {type(exc).__name__}: {str(exc)[:300]}") from exc
    return {"detections": detections, "latency_seconds": round(time.time() - started, 3)}


@app.post("/v1/segment")
def segment_endpoint(request: SegmentRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    started = time.time()
    try:
        image = decode_image(request.image_base64)
        masks = segment_boxes(image, request.detections, request.capture_id or uuid.uuid4().hex[:12])
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"segment failed: {type(exc).__name__}: {str(exc)[:300]}") from exc
    return {"segmentations": masks, "latency_seconds": round(time.time() - started, 3)}


@app.post("/debug/depth-volume")
def debug_depth_volume(request: DebugDepthVolumeRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    started = time.time()
    try:
        image = decode_image(request.image_base64)
        depth = decode_depth(request.depth_base64, request.metadata)
        confidence = decode_confidence(request.confidence_base64, request.metadata)
        depth, confidence, metadata, depth_source = depth_or_metric3d(image, depth, confidence, request.metadata)
        mask = decode_mask(request.mask_base64, image.size) or bbox_mask(image.size, request.bbox_xyxy)
        volume_ml, depth_quality, volume_method, fallback, fallback_reason = estimate_volume_from_depth_mask(
            mask,
            request.bbox_xyxy,
            depth,
            confidence,
            metadata,
            image,
            request.item,
        )
        volume_ml, depth_quality, plausibility_adjusted = apply_volume_plausibility_limits(
            request.item,
            volume_ml,
            depth_quality,
        )
        if plausibility_adjusted and not fallback_reason:
            fallback = True
            fallback_reason = "volume_plausibility_cap"
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"debug depth volume failed: {type(exc).__name__}: {str(exc)[:300]}") from exc

    return {
        "volume": {
            "estimated_volume_ml": volume_ml,
            "volume_method": volume_method,
            "depth_source": metadata.get("depth_source") or depth_source or "uploaded_depth",
            "fallback": fallback,
            "fallback_reason": fallback_reason,
            "depth_quality": depth_quality,
        },
        "debug": {
            "has_depth": depth is not None,
            "has_confidence": confidence is not None,
            "has_mask": mask is not None,
            "bbox_xyxy": request.bbox_xyxy or [],
            "image_size": list(image.size),
            "latency_seconds": round(time.time() - started, 3),
        },
    }
