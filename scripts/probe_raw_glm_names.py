#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gc
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import torch
from PIL import Image
from transformers import AutoProcessor, Glm4vForConditionalGeneration


@dataclass
class Case:
    name: str
    image: Path


CASES = [
    Case("depth_cola_can", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_cab838efdd31/rgb.jpg")),
    Case("depth_pot_bowl", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_04f23a03f8bb/rgb.jpg")),
    Case("rgb_fried_platter", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg")),
    Case("rgb_cafeteria_meal", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg")),
    Case("rgb_vegetable_board", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/vegetable_board/rgb.jpg")),
    Case("rgb_img6388", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg")),
]


PROMPT = """你是“食物 mask 自动标注”的视觉命名助手。目标是给 SAM3 生成可分割的食物/饮料/食材候选词。

只输出图片中真实可见、可食用或可饮用、适合画 mask 的内容。
禁止输出：餐具、锅碗瓢盆、杯子、罐子、瓶子、吸管、纸巾、桌面、包装、品牌、logo、图案、文字、颜色块、影子、手、键盘、背景。
饮料/包装食品只输出里面的食物或饮料名字，例如只写“可乐”，不要写“铝罐/瓶子/塑料杯/吸管”。
如果多个食材混在同一个连续菜肴区域里，要合并成一个菜名，例如“香菇鸡肉”“番茄炒蛋”“青椒肉丝”，不要拆成香菇/鸡肉/青椒/肉丝。
只有物理上分开摆放、边界明显的拼盘/蔬菜盘/套餐，才拆成多个可分割项目。
复杂蔬菜盘按可见面积列具体食材；不要写“拼盘/套餐/一餐/其他”。调料粉末、黑胡椒、盐、酱油等如果不是明显单独一堆，不要输出。
不确定就少报；最多 8 项；按面积从大到小。
每项只能有 name_zh、prompt_en、category、confidence 四个字段。prompt_en 必须是短英文视觉词，2-4 个词以内。
只输出一行严格 JSON，不要 markdown，不要解释，不要代码块。

格式：{"items":[{"name_zh":"香菇鸡肉","prompt_en":"chicken mushroom dish","category":"菜肴","confidence":0.9}]}
"""

NON_FOOD_TERMS = (
    "餐具",
    "桌",
    "键盘",
    "纸巾",
    "吸管",
    "筷子",
    "勺",
    "叉",
    "碗",
    "盘",
    "锅",
    "杯",
    "瓶",
    "罐",
    "盖",
    "包装",
    "袋",
    "盒",
    "品牌",
    "logo",
    "图案",
    "文字",
    "标签",
    "背景",
    "手",
    "铝罐",
    "塑料",
    "white item",
    "snowman",
    "pattern",
    "tissue",
    "straw",
    "cup",
    "can",
    "bottle",
    "lid",
    "packaging",
    "keyboard",
)

NON_MASK_FOOD_TERMS = (
    "盐",
    "黑胡椒",
    "白胡椒",
    "酱油",
    "生抽",
    "老抽",
    "料酒",
    "蚝油",
    "味精",
    "鸡精",
)


def resize_image(image: Image.Image, max_edge: int) -> Image.Image:
    out = image.convert("RGB")
    if max_edge > 0 and max(out.size) > max_edge:
        out = out.copy()
        out.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return out


def parse_json_object(text: str) -> dict[str, Any]:
    text = (text or "").strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    if "<answer>" in text and "</answer>" in text:
        text = text.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, flags=re.S | re.I)
    if fenced:
        text = fenced.group(1).strip()
    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object found")
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start : index + 1])
    raise ValueError("unterminated JSON object")


def normalize_items(payload: dict[str, Any], max_items: int) -> list[dict[str, Any]]:
    raw_items = payload.get("items")
    if not isinstance(raw_items, list):
        raw_items = []
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("name_zh") or raw.get("name") or raw.get("food") or "").strip()
        prompt = str(raw.get("prompt_en") or raw.get("detector_phrase") or "").strip().lower()
        category = str(raw.get("category") or raw.get("kind" ) or "").strip()
        if not name:
            continue
        joined = f"{name} {prompt} {category}".lower()
        if any(term.lower() in joined for term in NON_FOOD_TERMS):
            continue
        if name in NON_MASK_FOOD_TERMS or prompt in NON_MASK_FOOD_TERMS:
            continue
        if category in {"其他", "非食物", "餐具", "容器", "背景"}:
            continue
        key = (name, prompt)
        if key in seen:
            continue
        seen.add(key)
        try:
            confidence = float(raw.get("confidence", 0.0))
        except Exception:
            confidence = 0.0
        items.append(
            {
                "name_zh": name,
                "prompt_en": prompt,
                "category": category,
                "confidence": round(confidence, 4),
            }
        )
        if len(items) >= max_items:
            break
    return items


def model_device(model: torch.nn.Module) -> torch.device:
    return getattr(model, "device", None) or next(model.parameters()).device


def load_model(model_path: Path):
    started = time.perf_counter()
    processor = AutoProcessor.from_pretrained(str(model_path), use_fast=True, trust_remote_code=True)
    model = Glm4vForConditionalGeneration.from_pretrained(
        str(model_path),
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    ).eval()
    return processor, model, time.perf_counter() - started


def extract_names(processor: Any, model: torch.nn.Module, image: Image.Image, max_tokens: int, max_items: int) -> dict[str, Any]:
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": PROMPT},
            ],
        }
    ]
    started = time.perf_counter()
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
        return_dict=True,
        return_tensors="pt",
    ).to(model_device(model))
    inputs.pop("token_type_ids", None)
    with torch.inference_mode():
        generated = model.generate(**inputs, max_new_tokens=max_tokens, do_sample=False)
    output_ids = generated[0][inputs["input_ids"].shape[1] :]
    raw_text = processor.decode(output_ids, skip_special_tokens=True).strip()
    parse_error = None
    try:
        items = normalize_items(parse_json_object(raw_text), max_items=max_items)
    except Exception as exc:
        items = []
        parse_error = f"{type(exc).__name__}: {exc}"
    return {
        "seconds": round(time.perf_counter() - started, 3),
        "items": items,
        "raw_text": raw_text,
        "parse_error": parse_error,
    }


def run(args: argparse.Namespace) -> None:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    cases = CASES[args.start :]
    if args.limit is not None:
        cases = cases[: args.limit]

    print(json.dumps({"event": "load_raw_glm_start", "model": str(args.model_path)}, ensure_ascii=False), flush=True)
    processor, model, load_seconds = load_model(args.model_path)
    print(json.dumps({"event": "load_raw_glm_done", "seconds": round(load_seconds, 3)}, ensure_ascii=False), flush=True)

    rows: list[dict[str, Any]] = []
    for case in cases:
        image = resize_image(Image.open(case.image), args.max_edge)
        result = extract_names(processor, model, image, args.max_tokens, args.max_items)
        row = {
            "case": case.name,
            "image": str(case.image),
            "image_size": list(image.size),
            "raw_glm_seconds": result["seconds"],
            "items": result["items"],
            "raw_text": result["raw_text"],
            "parse_error": result["parse_error"],
        }
        rows.append(row)
        print(
            json.dumps(
                {
                    "case": case.name,
                    "raw_glm_seconds": row["raw_glm_seconds"],
                    "items": row["items"],
                    "parse_error": row["parse_error"],
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    (args.out_dir / "raw_glm_name_extraction.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    del processor
    del model
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    print(f"saved={args.out_dir}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", type=Path, default=Path("/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/raw_glm_names_20260705"))
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--max-tokens", type=int, default=420)
    parser.add_argument("--max-items", type=int, default=12)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
