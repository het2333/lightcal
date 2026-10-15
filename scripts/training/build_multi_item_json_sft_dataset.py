#!/usr/bin/env python3
"""Build synthetic multi-item Chinese JSON SFT samples from single-food samples."""

from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw


PROMPT = """<image>
只识别图片中明显可见食物，返回一个紧凑合法 JSON 对象，无解释。
第一个字符必须是 {，最后一个字符必须是 }。
禁止输出 <think>、</think>、markdown 代码块、自然语言说明或额外文本。
每张图可以有一个或多个食物；只列真实可见食物，通常 1-8 项，最多 10 项。
字段只要：name_zh, detector_phrase, category, liquid, mixed_dish, confidence, density_g_per_ml, kcal100, p100, c100, f100, fi100, na100。
name_zh 必须使用中文食物名，不要输出英文；detector_phrase 必须是英文短语，用于开放词汇检测。
density_g_per_ml 是可食部分物理密度，用于把体积ml换算成克重；必须大于0。
kcal100/p100/c100/f100/fi100/na100 是每100克可食部分营养密度，不是本次总营养。
拼盘/套餐/多碗多盘按明显不同食物拆分；同类重复物可合并。
同一个食物只能输出一次，name_zh 或 detector_phrase 已出现过就不要再输出；不要为了凑数量输出重复项或猜测项。
不要输出克重、体积、风险项、建议或不可见食物。
JSON_SCHEMA: {"items":[{"name_zh":"","detector_phrase":"","category":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","liquid":false,"mixed_dish":false,"confidence":0.0,"density_g_per_ml":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}],"detector_prompt_en":""}"""


DEFAULT_DENSITY_BY_CATEGORY = {
    "staple": 0.75,
    "protein": 0.95,
    "vegetable": 0.65,
    "mixed_dish": 0.75,
    "soup": 1.0,
    "drink": 1.0,
    "sauce": 1.05,
    "dessert": 0.45,
    "snack": 0.55,
}

ALLOWED_CATEGORIES = set(DEFAULT_DENSITY_BY_CATEGORY)

NUTRITION_KEYS = ("kcal100", "p100", "c100", "f100", "fi100", "na100")
GENERIC_ZH_NAMES = {"食物", "食品", "菜品", "餐食", "料理", "美食", "未知食物"}


def valid_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def as_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def normalize_item(item: dict[str, Any]) -> dict[str, Any] | None:
    category = str(item.get("category") or "mixed_dish").strip()
    if category not in ALLOWED_CATEGORIES:
        category = "mixed_dish"
    name = str(item.get("name_zh") or item.get("name") or "").strip()
    phrase = str(item.get("detector_phrase") or item.get("name_en") or name or "food").strip()
    if not name or not phrase:
        return None
    if name in GENERIC_ZH_NAMES:
        return None
    density = item.get("density_g_per_ml") or item.get("rho") or item.get("density")
    density_value = as_float(density, 0.0)
    if density_value <= 0:
        density_value = DEFAULT_DENSITY_BY_CATEGORY.get(category, 0.75)
    output = {
        "name_zh": name,
        "detector_phrase": phrase,
        "category": category,
        "liquid": bool(item.get("liquid")) or category in {"soup", "drink"},
        "mixed_dish": bool(item.get("mixed_dish")) or category == "mixed_dish",
        "confidence": round(max(0.1, min(as_float(item.get("confidence"), 0.75), 1.0)), 2),
        "density_g_per_ml": round(density_value, 3),
    }
    for key in NUTRITION_KEYS:
        output[key] = round(as_float(item.get(key), 0.0), 1)
    return output


def parse_source_row(row: dict[str, Any]) -> dict[str, Any] | None:
    images = row.get("images")
    if not isinstance(images, list) or not images:
        return None
    image_path = Path(str(images[0]))
    if not image_path.exists():
        return None
    messages = row.get("messages")
    if not isinstance(messages, list) or not messages:
        return None
    content = str(messages[-1].get("content") or "").strip()
    if not (content.startswith("{") and content.endswith("}")):
        return None
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return None
    items = payload.get("items")
    if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
        return None
    item = normalize_item(items[0])
    if item is None:
        return None
    return {"image": image_path, "item": item, "source": row.get("metadata", {}).get("source", "")}


def load_source_records(input_path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with input_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            record = parse_source_row(row)
            if record is not None:
                records.append(record)
    return records


def make_collage(records: list[dict[str, Any]], output_path: Path, canvas_size: int) -> None:
    count = len(records)
    cols = math.ceil(math.sqrt(count))
    rows = math.ceil(count / cols)
    margin = max(12, canvas_size // 40)
    gap = max(8, canvas_size // 64)
    cell_w = (canvas_size - margin * 2 - gap * (cols - 1)) // cols
    cell_h = (canvas_size - margin * 2 - gap * (rows - 1)) // rows
    canvas = Image.new("RGB", (canvas_size, canvas_size), (246, 246, 241))
    draw = ImageDraw.Draw(canvas)
    for idx, record in enumerate(records):
        row = idx // cols
        col = idx % cols
        x0 = margin + col * (cell_w + gap)
        y0 = margin + row * (cell_h + gap)
        x1 = x0 + cell_w
        y1 = y0 + cell_h
        draw.rounded_rectangle([x0 - 3, y0 - 3, x1 + 3, y1 + 3], radius=10, fill=(255, 255, 255))
        with Image.open(record["image"]) as image:
            image = image.convert("RGB")
            image.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
            px = x0 + (cell_w - image.width) // 2
            py = y0 + (cell_h - image.height) // 2
            canvas.paste(image, (px, py))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path, quality=92)


def target_payload(records: list[dict[str, Any]]) -> dict[str, Any]:
    items = [record["item"] for record in records]
    prompt = " . ".join(item["detector_phrase"] for item in items)
    return {"items": items, "detector_prompt_en": prompt}


def choose_records(
    records: list[dict[str, Any]],
    rng: random.Random,
    count: int,
) -> list[dict[str, Any]]:
    if count <= len(records):
        selected = rng.sample(records, count)
    else:
        selected = [rng.choice(records) for _ in range(count)]
    seen_names: set[str] = set()
    seen_phrases: set[str] = set()
    deduped: list[dict[str, Any]] = []
    for record in selected:
        name = record["item"]["name_zh"].strip()
        phrase = record["item"]["detector_phrase"].strip().lower()
        if name in seen_names or phrase in seen_phrases:
            continue
        seen_names.add(name)
        seen_phrases.add(phrase)
        deduped.append(record)
    while len(deduped) < count and len(deduped) < len(records):
        record = rng.choice(records)
        name = record["item"]["name_zh"].strip()
        phrase = record["item"]["detector_phrase"].strip().lower()
        if name not in seen_names and phrase not in seen_phrases:
            seen_names.add(name)
            seen_phrases.add(phrase)
            deduped.append(record)
    return deduped


def build_dataset(
    input_path: Path,
    output_path: Path,
    image_dir: Path,
    count: int,
    min_items: int = 3,
    max_items: int = 8,
    seed: int = 42,
    canvas_size: int = 1024,
) -> int:
    if min_items < 1:
        raise ValueError("min_items must be at least 1")
    if max_items < min_items:
        raise ValueError("max_items must be >= min_items")
    records = load_source_records(input_path)
    if len(records) < min_items:
        raise ValueError(f"need at least {min_items} valid source records, got {len(records)}")
    rng = random.Random(seed)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    image_dir.mkdir(parents=True, exist_ok=True)
    span = max_items - min_items + 1
    written = 0
    with output_path.open("w", encoding="utf-8") as handle:
        for idx in range(count):
            item_count = min_items + (idx % span)
            item_count = min(item_count, len(records))
            selected = choose_records(records, rng, item_count)
            if len(selected) < min_items:
                continue
            collage_path = image_dir / f"multi_{idx:06d}_{len(selected)}items.jpg"
            make_collage(selected, collage_path, canvas_size)
            assistant = json.dumps(target_payload(selected), ensure_ascii=False, separators=(",", ":"))
            row = {
                "messages": [
                    {"role": "user", "content": PROMPT},
                    {"role": "assistant", "content": assistant},
                ],
                "images": [str(collage_path.resolve())],
                "metadata": {
                    "source": "synthetic_multi_item_collage",
                    "item_count": len(selected),
                    "stage": "multi_item_json_sft",
                },
            }
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
            written += 1
    return written


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--image-dir", required=True)
    parser.add_argument("--count", type=int, default=5000)
    parser.add_argument("--min-items", type=int, default=3)
    parser.add_argument("--max-items", type=int, default=8)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--canvas-size", type=int, default=1024)
    args = parser.parse_args()
    written = build_dataset(
        input_path=Path(args.input),
        output_path=Path(args.output),
        image_dir=Path(args.image_dir),
        count=args.count,
        min_items=args.min_items,
        max_items=args.max_items,
        seed=args.seed,
        canvas_size=args.canvas_size,
    )
    print(f"wrote {written} multi-item JSON SFT samples to {args.output}")


if __name__ == "__main__":
    main()
