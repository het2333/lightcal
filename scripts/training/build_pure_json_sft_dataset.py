#!/usr/bin/env python3
"""Build a strict Chinese JSON SFT dataset for app-facing food recognition.

The source `official_foodr1_sft_20k.jsonl` already contains Chinese JSON
targets. This script tightens the user prompt and filters targets so the
assistant response is a bare JSON object, with no `<think>` prefix or markdown.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any


ALLOWED_CATEGORIES = {
    "staple",
    "protein",
    "vegetable",
    "mixed_dish",
    "soup",
    "drink",
    "sauce",
    "dessert",
    "snack",
}

STRICT_IMAGE_PROMPT = """<image>
只识别图片中明显可见食物，返回一个紧凑合法 JSON 对象，无解释。
第一个字符必须是 {，最后一个字符必须是 }。
禁止输出 <think>、</think>、markdown 代码块、自然语言说明或额外文本。
字段只要：name_zh, detector_phrase, category, liquid, mixed_dish, confidence, density_g_per_ml, kcal100, p100, c100, f100, fi100, na100。
name_zh 必须使用中文食物名，不要输出英文；可以保留具体做法、风味、品牌或品类信息。
detector_phrase 必须是英文短语，用于开放词汇检测；detector_prompt_en 用这些英文短语以英文句点分隔。
density_g_per_ml 是可食部分物理密度，用于把体积ml换算成克重；必须大于0，不确定就按类别估计并降低confidence。
kcal100/p100/c100/f100/fi100/na100 是每100克可食部分营养密度，不是本次总营养；分别是千卡、蛋白克、碳水克、脂肪克、纤维克、钠毫克。
密度参考：水/清汤/茶1.0；米饭/炒饭0.75；熟面0.7；炒菜0.65；肉块0.95；炸物0.55；面包/蛋糕0.35；酱料1.05。
不要输出克重、体积、风险项、建议或不可见食物。
拼盘/套餐按明显不同食物拆分；同类重复物可合并。
JSON_SCHEMA: {"items":[{"name_zh":"","detector_phrase":"","category":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","liquid":false,"mixed_dish":false,"confidence":0.0,"density_g_per_ml":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}],"detector_prompt_en":""}"""

STRICT_TEXT_PROMPT = """根据以下官方食物记录，返回一个紧凑合法中文 JSON 对象，无解释。
第一个字符必须是 {，最后一个字符必须是 }。
禁止输出 <think>、</think>、markdown 代码块、自然语言说明或额外文本。
营养字段必须换算为每100克可食部分。
字段只要：name_zh, detector_phrase, category, liquid, mixed_dish, confidence, density_g_per_ml, kcal100, p100, c100, f100, fi100, na100。
density_g_per_ml 是可食部分物理密度，用于把体积ml换算成克重；必须大于0。
JSON_SCHEMA: {"items":[{"name_zh":"","detector_phrase":"","category":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","liquid":false,"mixed_dish":false,"confidence":0.0,"density_g_per_ml":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}],"detector_prompt_en":""}

官方食物记录：
"""


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


def compact_json_object(text: str) -> str | None:
    text = text.strip()
    if not (text.startswith("{") and text.endswith("}")):
        return None
    if "<think" in text.lower() or "```" in text:
        return None
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    ensure_density_fields(obj)
    if not valid_target(obj):
        return None
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def valid_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def ensure_density_fields(obj: Any) -> None:
    if not isinstance(obj, dict):
        return
    items = obj.get("items")
    if not isinstance(items, list):
        return
    for item in items:
        if not isinstance(item, dict):
            continue
        density = item.get("density_g_per_ml") or item.get("rho") or item.get("density")
        if valid_number(density) and float(density) > 0:
            item["density_g_per_ml"] = round(float(density), 3)
            continue
        category = str(item.get("category") or "").lower()
        item["density_g_per_ml"] = DEFAULT_DENSITY_BY_CATEGORY.get(category, 0.75)


def valid_target(obj: Any) -> bool:
    if not isinstance(obj, dict):
        return False
    items = obj.get("items")
    if not isinstance(items, list) or not items:
        return False
    if not isinstance(obj.get("detector_prompt_en"), str):
        return False
    for item in items:
        if not isinstance(item, dict):
            return False
        if item.get("category") not in ALLOWED_CATEGORIES:
            return False
        if not isinstance(item.get("name_zh"), str) or not item["name_zh"].strip():
            return False
        if not isinstance(item.get("detector_phrase"), str) or not item["detector_phrase"].strip():
            return False
        if not isinstance(item.get("liquid"), bool):
            return False
        if not isinstance(item.get("mixed_dish"), bool):
            return False
        for key in ("confidence", "density_g_per_ml", "kcal100", "p100", "c100", "f100", "fi100", "na100"):
            if not valid_number(item.get(key)):
                return False
        if item["density_g_per_ml"] <= 0:
            return False
    return True


def rewrite_prompt(content: str, has_image: bool) -> str:
    if has_image:
        return STRICT_IMAGE_PROMPT
    prefix = "根据以下官方食物记录，输出同样结构的中文 JSON，营养字段必须换算为每100克："
    record = content
    if content.startswith(prefix):
        record = content[len(prefix) :].strip()
    if record.endswith("JSON:"):
        record = record[:-5].strip()
    return STRICT_TEXT_PROMPT + record


def convert_row(row: dict[str, Any], require_images: bool) -> dict[str, Any] | None:
    has_image = bool(row.get("images"))
    if require_images and not has_image:
        return None
    messages = row.get("messages") or []
    if len(messages) < 2:
        return None
    assistant = compact_json_object(messages[-1].get("content", ""))
    if assistant is None:
        return None
    sample: dict[str, Any] = {
        "messages": [
            {"role": "user", "content": rewrite_prompt(messages[0].get("content", ""), has_image)},
            {"role": "assistant", "content": assistant},
        ],
        "metadata": {
            **(row.get("metadata") or {}),
            "stage": "pure_json_sft",
            "format": "bare_json_object",
        },
    }
    if has_image:
        sample["images"] = row["images"]
    return sample


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--limit", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--require-images", action="store_true")
    args = parser.parse_args()

    rows: list[dict[str, Any]] = []
    with Path(args.input).open("r", encoding="utf-8") as src:
        for line in src:
            sample = convert_row(json.loads(line), require_images=args.require_images)
            if sample is not None:
                rows.append(sample)

    random.Random(args.seed).shuffle(rows)
    if args.limit:
        rows = rows[: args.limit]

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as dst:
        for row in rows:
            dst.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    image_count = sum(1 for row in rows if row.get("images"))
    print(f"wrote {len(rows)} pure JSON SFT samples to {out_path} ({image_count} with images)")


if __name__ == "__main__":
    main()
