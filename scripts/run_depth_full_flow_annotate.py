#!/usr/bin/env python3
"""Run the RGB+Depth cloud meal pipeline and draw item labels on the image."""

from __future__ import annotations

import argparse
import base64
import json
import os
import time
import urllib.error
import urllib.request
import importlib.util
import sys
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

PROJECT_ROOT = Path(__file__).resolve().parent.parent

_nutrition_spec = importlib.util.spec_from_file_location(
    "depth_nutrition_standalone",
    PROJECT_ROOT / "services" / "depth_nutrition.py",
)
if _nutrition_spec is None or _nutrition_spec.loader is None:
    raise RuntimeError("cannot load services/depth_nutrition.py")
_nutrition_module = importlib.util.module_from_spec(_nutrition_spec)
sys.modules[_nutrition_spec.name] = _nutrition_module
_nutrition_spec.loader.exec_module(_nutrition_module)
calculate_item_nutrition = _nutrition_module.calculate_item_nutrition
estimate_weight_from_volume = _nutrition_module.estimate_weight_from_volume


FONT_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]


COLORS = [
    (0, 122, 255),
    (52, 199, 89),
    (255, 149, 0),
    (255, 45, 85),
    (175, 82, 222),
    (90, 200, 250),
    (255, 204, 0),
]


FOOD_KEY_RULES = [
    (("炒饭", "fried rice", "egg fried rice"), "rice_fried"),
    (("米饭", "白饭", "rice"), "rice_cooked"),
    (("炒面", "面条", "noodle"), "noodles_fried"),
    (("薯条", "french fries", "fries"), "french_fries"),
    (("薯角", "土豆块", "potato wedge", "potato wedges"), "potato_wedges"),
    (("蛋挞", "egg tart", "custard tart"), "egg_tart"),
    (("香肠", "烤肠", "sausage"), "sausage_cooked"),
    (("芝士条", "长条裹粉", "cheese stick", "mozzarella stick"), "fried_cheese_stick"),
    (("炸丸", "土豆球", "potato ball", "fried ball"), "fried_potato_ball"),
    (("无糖茶", "茶", "tea"), "tea_unsweetened"),
    (("清汤", "汤水", "汤", "broth", "soup"), "soup_clear"),
    (("炸鸡", "鸡米花", "鸡块", "fried chicken", "nugget"), "fried_chicken"),
    (("蔬菜", "青菜", "vegetable"), "stir_fried_vegetables"),
]


KNOWN_KEYS = {
    "rice_fried",
    "rice_cooked",
    "noodles_fried",
    "tea_unsweetened",
    "soup_clear",
    "fried_chicken",
    "french_fries",
    "potato_wedges",
    "egg_tart",
    "sausage_cooked",
    "fried_cheese_stick",
    "fried_potato_ball",
    "stir_fried_vegetables",
    "green_pepper_pork_stir_fry",
}


def read_b64(path: Path | None) -> str | None:
    if not path or not path.exists():
        return None
    return base64.b64encode(path.read_bytes()).decode("ascii")


def load_json(path: Path | None) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def load_font(size: int) -> ImageFont.ImageFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            try:
                return ImageFont.truetype(candidate, size)
            except Exception:
                continue
    return ImageFont.load_default()


def post_json(url: str, payload: dict[str, Any], api_key: str = "", timeout: int = 300) -> dict[str, Any]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {body[:1000]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"connection failed: {exc}") from exc
    result = json.loads(body.decode("utf-8"))
    result.setdefault("_client_latency_seconds", round(time.time() - started, 3))
    return result


def item_bbox(item: dict[str, Any]) -> list[float]:
    detection = item.get("detection") if isinstance(item.get("detection"), dict) else {}
    bbox = detection.get("bbox_xyxy") or item.get("bbox_xyxy") or item.get("bbox") or []
    if isinstance(bbox, list) and len(bbox) == 4:
        try:
            return [float(v) for v in bbox]
        except Exception:
            return []
    return []


def cloud_processed_size(image_size: tuple[int, int], max_edge: int = 1536) -> tuple[int, int]:
    width, height = image_size
    longest = max(width, height)
    if longest <= max_edge:
        return width, height
    scale = max_edge / float(longest)
    return int(round(width * scale)), int(round(height * scale))


def scaled_item_bbox(item: dict[str, Any], image_size: tuple[int, int]) -> list[float]:
    bbox = item_bbox(item)
    if not bbox:
        return []
    processed_w, processed_h = cloud_processed_size(image_size)
    image_w, image_h = image_size
    sx = image_w / max(processed_w, 1)
    sy = image_h / max(processed_h, 1)
    x1, y1, x2, y2 = bbox
    return [x1 * sx, y1 * sy, x2 * sx, y2 * sy]


def mask_bbox(item: dict[str, Any], image_size: tuple[int, int]) -> list[float]:
    segmentation = item.get("segmentation") if isinstance(item.get("segmentation"), dict) else {}
    raw = segmentation.get("mask_preview_base64")
    if not raw:
        return []
    try:
        mask = Image.open(io.BytesIO(base64.b64decode(raw))).convert("L")
        bbox = mask.getbbox()
    except Exception:
        return []
    if not bbox:
        return []
    width, height = image_size
    sx = width / max(mask.width, 1)
    sy = height / max(mask.height, 1)
    x1, y1, x2, y2 = bbox
    return [x1 * sx, y1 * sy, x2 * sx, y2 * sy]


def label_for_item(item: dict[str, Any], index: int) -> str:
    name = str(item.get("name_zh") or item.get("final_name_zh") or item.get("name") or f"Item {index}")
    grams = item.get("estimated_grams")
    calories = item.get("calories")
    if isinstance(item.get("weight"), dict):
        grams = item["weight"].get("estimated_grams", grams)
    if isinstance(item.get("nutrition"), dict):
        calories = item["nutrition"].get("calories", calories)
    parts = [name]
    try:
        if grams is not None:
            parts.append(f"{float(grams):.0f}g")
    except Exception:
        pass
    try:
        if calories is not None:
            parts.append(f"{float(calories):.0f}kcal")
    except Exception:
        pass
    return " ".join(parts)


def name_label_for_item(item: dict[str, Any], index: int) -> str:
    return str(item.get("name_zh") or item.get("final_name_zh") or item.get("name") or f"食物{index}").strip()


def canonical_food_key(item: dict[str, Any]) -> str:
    explicit = str(
        item.get("food_key")
        or item.get("canonical_food_key")
        or item.get("nutrition_key")
        or item.get("density_key")
        or ""
    ).strip()
    if explicit in KNOWN_KEYS:
        return explicit
    text = " ".join(
        str(item.get(key) or "").lower()
        for key in (
            "name_zh",
            "name_en",
            "detector_phrase",
            "category",
            "canonical_food_key",
            "nutrition_key",
            "density_key",
        )
    )
    detection = item.get("detection") if isinstance(item.get("detection"), dict) else {}
    text += " " + str(detection.get("phrase") or "").lower()
    for needles, food_key in FOOD_KEY_RULES:
        if any(needle.lower() in text for needle in needles):
            return food_key
    if "mixed" in text or "混合" in text:
        return "rice_fried"
    return "rice_cooked"


def enrich_with_weight_and_nutrition(result: dict[str, Any]) -> None:
    items = result.get("items") if isinstance(result.get("items"), list) else []
    total = {"calories": 0.0, "protein_g": 0.0, "carbs_g": 0.0, "fat_g": 0.0, "fiber_g": 0.0, "sodium_mg": 0.0}
    for item in items:
        if not isinstance(item, dict):
            continue
        volume_ml = item.get("estimated_volume_ml")
        if volume_ml is None and isinstance(item.get("volume"), dict):
            volume_ml = item["volume"].get("estimated_volume_ml")
        try:
            volume_ml = float(volume_ml)
        except Exception:
            volume_ml = 0.0
        food_key = canonical_food_key(item)
        mixed = bool(item.get("mixed_dish")) or "mixed" in str(item.get("category") or "").lower() or "混合" in str(item.get("category") or "")
        weight = estimate_weight_from_volume(
            food_key,
            volume_ml,
            item.get("density_hint") if isinstance(item.get("density_hint"), dict) else None,
            str(item.get("category") or ""),
            str(item.get("name_zh") or item.get("name_en") or ""),
        )
        nutrition_pack = calculate_item_nutrition(food_key, weight["estimated_grams"], mixed)
        nutrition = nutrition_pack["total"]
        item["food_key"] = food_key
        item["weight"] = weight
        item["nutrition"] = nutrition
        item["ingredients"] = nutrition_pack["ingredients"]
        for key in total:
            total[key] += float(nutrition.get(key) or 0.0)
    result["total"] = {key: round(value, 1) for key, value in total.items()}
    result["pipeline_steps"] = [
        "VLM scene understanding",
        "Grounding DINO open-vocabulary bbox detection",
        "SAM2 bbox-prompt segmentation",
        "Depth mask local-baseline volume estimation",
        "Density table volume-to-grams conversion",
        "Nutrition table grams-to-macros calculation",
    ]


def draw_annotations(image_path: Path, result: dict[str, Any], output_path: Path) -> None:
    image = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(image, "RGBA")
    label_font = load_font(max(30, image.width // 34))
    items = result.get("items") if isinstance(result.get("items"), list) else []
    anchors: list[tuple[float, float, str]] = []

    for index, item in enumerate(items, start=1):
        bbox = mask_bbox(item, image.size) or scaled_item_bbox(item, image.size)
        if not bbox:
            continue
        x1, y1, x2, y2 = bbox
        x1 = max(0, min(image.width - 1, x1))
        x2 = max(0, min(image.width - 1, x2))
        y1 = max(0, min(image.height - 1, y1))
        y2 = max(0, min(image.height - 1, y2))
        if x2 <= x1 or y2 <= y1:
            continue
        anchors.append(((x1 + x2) / 2, (y1 + y2) / 2, name_label_for_item(item, index)))

    draw_callouts(image, draw, anchors, label_font)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path, quality=94)


def draw_callouts(
    image: Image.Image,
    draw: ImageDraw.ImageDraw,
    anchors: list[tuple[float, float, str]],
    font: ImageFont.ImageFont,
) -> None:
    if not anchors:
        return

    cx0, cy0 = image.width / 2, image.height / 2
    margin = max(18, image.width // 46)
    pad_x = max(22, image.width // 42)
    pad_y = max(12, image.width // 80)
    dot_r = max(9, image.width // 78)
    line_w = max(4, image.width // 190)
    radius = max(24, image.width // 28)
    placed: list[tuple[float, float, float, float]] = []

    ordered = sorted(
        anchors,
        key=lambda a: (0 if a[0] < cx0 else 1, a[1]),
    )
    for index, (ax, ay, label) in enumerate(ordered):
        tb = draw.textbbox((0, 0), label, font=font)
        tw = tb[2] - tb[0]
        th = tb[3] - tb[1]
        bw = tw + pad_x * 2
        bh = th + pad_y * 2

        left_side = ax < cx0
        if left_side:
            lx = max(margin, ax - bw - image.width * 0.15)
        else:
            lx = min(image.width - bw - margin, ax + image.width * 0.10)

        dy = -image.height * 0.14 if ay < cy0 else image.height * 0.12
        ly = ay + dy - bh / 2
        ly = max(margin, min(image.height - bh - margin, ly))

        # Push labels apart vertically while keeping the callout feel.
        for _ in range(16):
            rect = (lx, ly, lx + bw, ly + bh)
            if not any(overlap(rect, other, padding=8) for other in placed):
                break
            ly += bh * 0.72
            if ly + bh > image.height - margin:
                ly = max(margin, ly - bh * 1.7)
                break

        rect = (lx, ly, lx + bw, ly + bh)
        placed.append(rect)

        target_x = lx + (bw * 0.78 if left_side else bw * 0.22)
        target_y = ly + bh * 0.58

        # Soft shadow.
        shadow_offset = max(3, image.width // 170)
        draw.rounded_rectangle(
            [lx + shadow_offset, ly + shadow_offset, lx + bw + shadow_offset, ly + bh + shadow_offset],
            radius=radius,
            fill=(0, 0, 0, 38),
        )
        draw.line([ax, ay, target_x, target_y], fill=(255, 255, 255, 245), width=line_w)
        draw.ellipse([ax - dot_r, ay - dot_r, ax + dot_r, ay + dot_r], fill=(255, 255, 255, 255))
        draw.rounded_rectangle([lx, ly, lx + bw, ly + bh], radius=radius, fill=(255, 255, 255, 250))
        draw.text((lx + pad_x, ly + pad_y - 2), label, font=font, fill=(15, 17, 24, 255))


def overlap(a: tuple[float, float, float, float], b: tuple[float, float, float, float], padding: float = 0) -> bool:
    return not (
        a[2] + padding < b[0]
        or b[2] + padding < a[0]
        or a[3] + padding < b[1]
        or b[3] + padding < a[1]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-dir", required=True, type=Path)
    parser.add_argument("--base-url", default=os.getenv("DEPTH_PIPELINE_BASE_URL", "http://127.0.0.1:18003"))
    parser.add_argument("--api-key", default=os.getenv("DEPTH_PIPELINE_API_KEY", ""))
    parser.add_argument("--user-hint", default="")
    parser.add_argument("--container-hint", default="")
    parser.add_argument("--meal-type", default="lunch")
    parser.add_argument("--output-dir", default=Path("tmp/depth_full_flow"), type=Path)
    parser.add_argument("--no-depth", action="store_true")
    args = parser.parse_args()

    capture_dir = args.capture_dir
    rgb_path = capture_dir / "rgb.jpg"
    depth_path = None if args.no_depth else capture_dir / "depth.bin"
    confidence_path = None if args.no_depth else capture_dir / "confidence.bin"
    metadata_path = capture_dir / "metadata.json"

    if not rgb_path.exists():
        raise SystemExit(f"missing rgb: {rgb_path}")

    metadata = load_json(metadata_path)
    payload = {
        "capture_id": capture_dir.name + ("_no_depth" if args.no_depth else ""),
        "rgb_base64": read_b64(rgb_path),
        "depth_base64": read_b64(depth_path),
        "confidence_base64": read_b64(confidence_path),
        "metadata": metadata,
        "user_hint": args.user_hint,
        "container_hint": args.container_hint,
        "meal_type": args.meal_type,
    }
    url = args.base_url.rstrip("/") + "/v1/depth-meal/analyze"
    result = post_json(url, payload, api_key=args.api_key)
    enrich_with_weight_and_nutrition(result)

    suffix = "no_depth" if args.no_depth else "with_depth"
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / f"{capture_dir.name}_{suffix}_result.json"
    annotated_path = output_dir / f"{capture_dir.name}_{suffix}_annotated.jpg"
    json_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    draw_annotations(rgb_path, result, annotated_path)

    print(json.dumps({
        "capture_dir": str(capture_dir),
        "mode": suffix,
        "status": result.get("status"),
        "items": [
            {
                "name": item.get("name_zh"),
                "bbox": item_bbox(item),
                "volume_ml": item.get("estimated_volume_ml") or (item.get("volume") or {}).get("estimated_volume_ml"),
                "detector": (item.get("detection") or {}).get("detector"),
                "detector_score": (item.get("detection") or {}).get("score"),
                "mask_area": (item.get("segmentation") or {}).get("area_pixels"),
            }
            for item in result.get("items", [])
            if isinstance(item, dict)
        ],
        "latency_seconds": result.get("latency_seconds"),
        "client_latency_seconds": result.get("_client_latency_seconds"),
        "json_path": str(json_path),
        "annotated_path": str(annotated_path),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
