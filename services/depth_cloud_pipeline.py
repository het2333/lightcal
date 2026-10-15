"""Client and normalization helpers for the cloud RGB+Depth meal pipeline."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
from typing import Any

import httpx


FOOD_KEY_HINTS: list[tuple[tuple[str, ...], str]] = [
    (("炒饭", "辣炒饭", "蛋炒饭", "fried rice"), "rice_fried"),
    (("米饭", "饭", "rice"), "rice_cooked"),
    (("炒面", "面条", "noodle", "noodles"), "noodles_fried"),
    (("奶茶", "milk tea"), "milk_tea_base"),
    (("冻柠茶", "柠檬茶", "冰红茶", "lemon tea", "iced lemon tea"), "lemon_tea_sweet"),
    (("白水", "清水", "矿泉水", "水", "water"), "water"),
    (("雪碧", "sprite", "可乐", "可口可乐", "百事", "pepsi", "cola", "健力宝", "jianlibao", "汽水", "soda"), "soda_regular"),
    (("无糖茶", "茶汤", "茶水", "茶", "tea", "unsweetened tea"), "tea_unsweetened"),
    (("清汤", "汤水", "汤", "soup", "broth"), "soup_clear"),
    (("青椒炒肉", "炒肉", "肉片", "pork"), "green_pepper_pork_stir_fry"),
    (("炸鸡", "鸡块", "鸡米花", "fried chicken", "chicken nugget"), "fried_chicken"),
    (("薯条", "french fries", "fries"), "french_fries"),
    (("薯角", "土豆角", "potato wedges", "potato wedge"), "potato_wedges"),
    (("蛋挞", "egg tart", "custard tart"), "egg_tart"),
    (("香肠", "烤肠", "sausage"), "sausage_cooked"),
    (("炸土豆球", "土豆球", "炸薯球", "薯球", "fried potato ball", "potato ball"), "fried_potato_ball"),
    (("洋葱圈", "炸洋葱圈", "onion ring", "onion rings"), "onion_rings"),
    (("卤鸡", "鸡腿", "鸡肉", "marinated chicken", "chicken leg", "chicken"), "chicken_cooked"),
    (("鸡蛋", "蛋", "egg"), "egg_boiled"),
    (("青菜", "蔬菜", "菜", "vegetable"), "stir_fried_vegetables"),
    (("苹果", "apple"), "apple_red"),
    (("水果", "fruit"), "fruit_fresh"),
]


KNOWN_FOOD_KEYS = {
    "rice_cooked",
    "rice_fried",
    "noodles_fried",
    "soup_clear",
    "tea_unsweetened",
    "water",
    "milk_tea_base",
    "soda_regular",
    "lemon_tea_sweet",
    "green_pepper_pork_stir_fry",
    "fried_chicken",
    "french_fries",
    "potato_wedges",
    "egg_tart",
    "sausage_cooked",
    "fried_potato_ball",
    "onion_rings",
    "chicken_cooked",
    "egg_boiled",
    "stir_fried_vegetables",
    "apple_red",
    "fruit_fresh",
}


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off", "disabled"}


def _read_base64(path: str | Path | None, max_bytes: int | None = None) -> str | None:
    if not path:
        return None
    file_path = Path(path)
    if not file_path.exists() or not file_path.is_file():
        return None
    data = file_path.read_bytes()
    if max_bytes and len(data) > max_bytes:
        raise ValueError(f"{file_path.name} is too large for cloud upload: {len(data)} bytes")
    return base64.b64encode(data).decode("ascii")


def _read_json(path: str | Path | None) -> dict:
    if not path:
        return {}
    file_path = Path(path)
    if not file_path.exists() or not file_path.is_file():
        return {}
    try:
        return json.loads(file_path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _read_auxiliary_images(rgb_path: str | Path | None) -> list[str]:
    if not rgb_path:
        return []
    directory = Path(rgb_path).parent
    images = []
    for path in sorted(directory.glob("auxiliary_[0-3].jpg"))[:4]:
        encoded = _read_base64(path, max_bytes=12 * 1024 * 1024)
        if encoded:
            images.append(encoded)
    return images


def _first_number(value: Any, default: float) -> float:
    try:
        if isinstance(value, list) and value:
            return float(value[0])
        return float(value)
    except Exception:
        return default


def _nutrition_pack(raw: dict, key: str) -> dict:
    source = raw.get(key) if isinstance(raw.get(key), dict) else {}
    aliases = {
        "calories": ("calories", "kcal", "calories_kcal", "energy_kcal", "kcal_per_100g", "calories_per_100g", "kcal100"),
        "protein_g": ("protein_g", "protein", "protein100", "protein_per_100g", "p100"),
        "carbs_g": ("carbs_g", "carbs", "carbohydrate_g", "carbohydrates_g", "carbs100", "carbs_per_100g", "c100"),
        "fat_g": ("fat_g", "fat", "fat100", "fat_per_100g", "f100"),
        "fiber_g": ("fiber_g", "fiber", "fiber100", "fiber_per_100g", "fi100"),
        "sodium_mg": ("sodium_mg", "sodium", "sodium100", "sodium_mg_per_100g", "na100"),
    }
    output: dict[str, float] = {}
    for target, keys in aliases.items():
        value = 0.0
        for candidate in keys:
            try:
                if candidate in source:
                    value = float(source.get(candidate) or 0)
                    break
                if candidate in raw:
                    value = float(raw.get(candidate) or 0)
                    break
            except Exception:
                value = 0.0
        if value > 0:
            output[target] = round(value, 1)
    return output


def _category_tokens(category: str) -> set[str]:
    text = (category or "").lower()
    for sep in ("|", "/", ",", "，", "、", " "):
        text = text.replace(sep, " ")
    return {token.strip() for token in text.split() if token.strip()}


def _category_for_matching(category: str) -> str:
    tokens = _category_tokens(category)
    # A model sometimes copies the whole enum string
    # "staple|protein|...|drink"; do not let that match soup/drink hints.
    if len(tokens) >= 4:
        return ""
    return category


def _item_match_text(item: dict) -> str:
    return " ".join(
        str(item.get(key) or "").lower()
        for key in (
            "name_zh",
            "name_en",
            "detector_phrase",
            "visible_desc",
            "canonical_food_key",
            "food_key",
            "nutrition_key",
            "category",
        )
    )


def canonical_food_key(item: dict) -> str:
    lookup = item.get("nutrition_lookup") if isinstance(item.get("nutrition_lookup"), dict) else {}
    if lookup.get("matched") is True:
        for key in ("nutrition_key", "density_key"):
            trusted = str(item.get(key) or "").strip()
            if trusted:
                return trusted
    explicit = str(item.get("canonical_food_key") or item.get("food_key") or item.get("nutrition_key") or "").strip()
    if explicit in KNOWN_FOOD_KEYS:
        return explicit
    category_for_matching = _category_for_matching(str(item.get("category") or ""))
    text = _item_match_text(item)
    if category_for_matching:
        text = f"{text} {category_for_matching.lower()}"
    for needles, food_key in FOOD_KEY_HINTS:
        if any(needle.lower() in text for needle in needles):
            return food_key
    category = category_for_matching.lower()
    if category in {"soup", "drink"}:
        return "soup_clear"
    if category in {"vegetable", "蔬菜"}:
        return "stir_fried_vegetables"
    if category in {"fruit", "水果"}:
        return "fruit_fresh"
    return "rice_cooked"


def _display_name_for_packaged_drink(raw: dict, current_name: str, food_key: str) -> str:
    text = _item_match_text(raw)
    generic_names = {"", "饮品", "饮料", "汽水", "茶", "drink", "beverage", "soda", "tea"}
    current = (current_name or "").strip()
    if "pepsi" in text or "百事" in text:
        return "百事可乐"
    if "jianlibao" in text or "健力宝" in text:
        return "健力宝"
    if "coca" in text or "可口可乐" in text:
        return "可口可乐"
    if "cola" in text or "可乐" in text:
        return "可乐"
    if "sprite" in text or "雪碧" in text:
        return "雪碧"
    if "冻柠茶" in text or "柠檬茶" in text or "lemon tea" in text:
        return "冻柠茶" if "冻" in text else "柠檬茶"
    if food_key == "soda_regular" and current.lower() in generic_names:
        return "含糖汽水"
    if food_key == "lemon_tea_sweet" and current.lower() in generic_names:
        return "柠檬茶"
    return current


def normalize_cloud_items(payload: dict, metadata: dict | None = None) -> list[dict]:
    raw_items = payload.get("items") or payload.get("foods") or []
    if not isinstance(raw_items, list):
        return []

    normalized: list[dict] = []
    for index, raw in enumerate(raw_items, start=1):
        if not isinstance(raw, dict):
            continue
        name_zh = str(raw.get("name_zh") or raw.get("final_name_zh") or raw.get("name") or f"食物{index}").strip()
        name_en = str(raw.get("name_en") or raw.get("detector_phrase") or raw.get("name") or "").strip()
        category = str(raw.get("category") or "mixed_dish").strip()
        category_l = category.lower()
        liquid = bool(raw.get("liquid")) or category_l in {"soup", "drink", "汤", "饮品"}
        mixed_dish = bool(raw.get("mixed_dish")) or category_l in {"mixed_dish", "混合菜"}
        food_key = canonical_food_key(raw)
        name_zh = _display_name_for_packaged_drink(raw, name_zh, food_key)
        volume = raw.get("estimated_volume_ml")
        if volume is None:
            volume = raw.get("volume_ml")
        if volume is None and isinstance(raw.get("volume"), dict):
            volume = raw["volume"].get("estimated_volume_ml")
        volume_ml = round(max(0.0, _first_number(volume, 0.0)), 1)
        detection = raw.get("detection") if isinstance(raw.get("detection"), dict) else {}
        segmentation = raw.get("segmentation") if isinstance(raw.get("segmentation"), dict) else {}
        semantic_validation = raw.get("semantic_validation") if isinstance(raw.get("semantic_validation"), dict) else {}
        volume_pack = raw.get("volume") if isinstance(raw.get("volume"), dict) else {}
        depth_quality = (
            raw.get("depth_quality")
            or volume_pack.get("depth_quality")
            or {"volume_confidence": float(raw.get("confidence") or 0.55)}
        )
        depth_quality = depth_quality if isinstance(depth_quality, dict) else {}
        bbox = detection.get("bbox_xyxy") or raw.get("bbox_xyxy") or raw.get("bbox") or []
        mask_area_pixels = int(segmentation.get("area_pixels") or raw.get("mask_area_pixels") or 0)
        volume_method = str(
            volume_pack.get("volume_method")
            or raw.get("volume_method")
            or ("container_capacity_fill_ratio" if liquid else "cloud_rgb_depth_pipeline")
        )
        normalized.append(
            {
                "name_zh": name_zh,
                "name_en": name_en,
                "food_key": food_key,
                "category": category,
                "cooking_method": str(raw.get("cooking_method") or raw.get("method") or "unknown"),
                "mixed_dish": mixed_dish,
                "liquid": liquid,
                "volume_ml": volume_ml,
                "volume_method": volume_method,
                "depth_quality": depth_quality,
                "density_hint": raw.get("density_hint") if isinstance(raw.get("density_hint"), dict) else {},
                "direct_nutrition": _nutrition_pack(raw, "direct_nutrition"),
                "nutrition_per_100g": _nutrition_pack(raw, "nutrition_per_100g"),
                "fallback": bool(volume_pack.get("fallback", raw.get("fallback", False))),
                "fallback_reason": volume_pack.get("fallback_reason") or raw.get("fallback_reason") or "",
                "detector": str(detection.get("detector") or raw.get("detector") or "grounding_dino_1_5"),
                "detector_phrase": str(
                    detection.get("phrase")
                    or raw.get("detector_phrase")
                    or raw.get("name_en")
                    or raw.get("name_zh")
                    or name_zh
                ),
                "detector_score": float(detection.get("score") or raw.get("detector_score") or raw.get("confidence") or 0.0),
                "bbox": bbox,
                "segmentation_model": str(segmentation.get("model") or raw.get("segmentation_model") or "sam2"),
                "mask_url": str(segmentation.get("mask_url") or raw.get("mask_url") or ""),
                "mask_preview_base64": str(segmentation.get("mask_preview_base64") or raw.get("mask_preview_base64") or ""),
                "mask_area_pixels": mask_area_pixels,
                "mask_confidence": float(segmentation.get("mask_confidence") or raw.get("mask_confidence") or 0.0),
                "semantic_validation": semantic_validation,
                "needs_user_check": sorted(
                    set((raw.get("needs_user_check") or []) + (["estimated_grams"] if volume_ml <= 0 else []))
                ),
            }
        )
    return normalized


class DepthCloudPipelineClient:
    """HTTP client for the cloud VLM + GroundingDINO + SAM2 + depth service."""

    def __init__(self):
        self.base_url = (os.getenv("DEPTH_PIPELINE_BASE_URL") or "").rstrip("/")
        self.api_key = os.getenv("DEPTH_PIPELINE_API_KEY") or os.getenv("VISION_API_KEY") or ""
        self.timeout = httpx.Timeout(
            connect=float(os.getenv("DEPTH_PIPELINE_CONNECT_TIMEOUT", "8")),
            read=float(os.getenv("DEPTH_PIPELINE_READ_TIMEOUT", "240")),
            write=float(os.getenv("DEPTH_PIPELINE_WRITE_TIMEOUT", "240")),
            pool=30.0,
        )
        self.enabled = _env_bool("DEPTH_PIPELINE_ENABLED", False) and bool(self.base_url)

    def status(self) -> dict:
        status = {
            "enabled": self.enabled,
            "configured": bool(self.base_url),
            "base_url": self.base_url,
            "api_key_configured": bool(self.api_key),
            "reachable": False,
            "detail": "未配置云端 Depth pipeline",
        }
        if not self.base_url:
            return status
        headers = {}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        try:
            with httpx.Client(timeout=httpx.Timeout(connect=3.0, read=5.0, write=5.0, pool=3.0), trust_env=False) as client:
                response = client.get(f"{self.base_url}/health", headers=headers)
            status["http_status"] = response.status_code
            status["reachable"] = 200 <= response.status_code < 300
            status["detail"] = response.json() if response.headers.get("content-type", "").lower().startswith("application/json") else response.text[:500]
        except Exception as exc:
            status["detail"] = f"{type(exc).__name__}: {str(exc)[:300]}"
        return status

    def analyze_image_base64(
        self,
        image_base64: str,
        *,
        metadata: dict | None = None,
        depth_base64: str | None = None,
        confidence_base64: str | None = None,
        user_hint: str = "",
        container_hint: str = "",
        meal_type: str = "",
    ) -> dict:
        if not self.enabled:
            raise RuntimeError("未配置 DEPTH_PIPELINE_ENABLED，真实云端 Depth 链路未启用。")
        if not image_base64:
            raise RuntimeError("缺少 RGB 图片。")

        request_payload = {
            "rgb_base64": image_base64,
            "depth_base64": depth_base64 or None,
            "confidence_base64": confidence_base64 or None,
            "metadata": metadata or {},
            "user_hint": user_hint,
            "container_hint": container_hint,
            "meal_type": meal_type,
        }
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        with httpx.Client(timeout=self.timeout, trust_env=False) as client:
            response = client.post(f"{self.base_url}/v1/depth-meal/analyze", json=request_payload, headers=headers)
        response.raise_for_status()
        data = response.json()
        data["normalized_items"] = normalize_cloud_items(data, metadata=request_payload["metadata"])
        return data

    def analyze_capture(self, capture: dict, payload: dict) -> dict:
        if not self.enabled:
            raise RuntimeError("未配置 DEPTH_PIPELINE_ENABLED，真实云端 Depth 链路未启用。")
        rgb_b64 = _read_base64(capture.get("rgb_url"), max_bytes=12 * 1024 * 1024)
        if not rgb_b64:
            raise RuntimeError("缺少 RGB 拍摄文件，请重新拍摄。")
        request_payload = {
            "capture_id": capture.get("id"),
            "rgb_base64": rgb_b64,
            "depth_base64": _read_base64(capture.get("depth_url"), max_bytes=48 * 1024 * 1024),
            "confidence_base64": _read_base64(capture.get("confidence_url"), max_bytes=16 * 1024 * 1024),
            "auxiliary_images_base64": _read_auxiliary_images(capture.get("rgb_url")),
            "metadata": _read_json(capture.get("metadata_url")),
            "user_hint": payload.get("user_hint") or capture.get("user_hint") or "",
            "container_hint": payload.get("container_hint") or capture.get("container_hint") or "",
            "meal_type": payload.get("meal_type") or capture.get("user_hint") or "",
        }
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        with httpx.Client(timeout=self.timeout, trust_env=False) as client:
            response = client.post(f"{self.base_url}/v1/depth-meal/analyze", json=request_payload, headers=headers)
        response.raise_for_status()
        data = response.json()
        items = normalize_cloud_items(data, metadata=request_payload["metadata"])
        return {
            "items": items,
            "source": "cloud_depth_pipeline",
            "raw": data,
        }
