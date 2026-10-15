#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gc
import json
import re
import time
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont
from transformers import AutoProcessor, Glm4vForConditionalGeneration


DEFAULT_CASES = [
    "rgb_cafeteria_meal",
    "rgb_fried_platter",
    "rgb_vegetable_board",
]

PROMPT_TEMPLATE = """你是食物 mask 识别助手。图片左侧是原图，右侧是食物分割模型已切出的红色 mask crop，每个 crop 有编号。

整图已经识别出的候选食物/菜肴：
{scene_candidates}

分割模型粗标签对照：
{rough_labels}

任务：判断每个编号红色 mask 对应的中文食物/饮料/菜肴名字，用于训练食物分割模型。

规则：
1. 只回答红色 mask 覆盖的食物区域，不要回答餐具、桌面、包装、文字、品牌。
2. 优先从“整图候选食物/菜肴”里选择最合适的中文名。
3. FoodSAM3 粗标签只是参考，不能直接翻译。若粗标签与整图候选冲突，必须以整图候选和视觉内容为准。
4. 如果红色 mask 是一个混合菜中的一部分，但视觉上属于同一个连续菜肴，请输出整道菜名，例如候选里有“香菇鸡肉”时，香菇/鸡肉局部 mask 都写“香菇鸡肉”，不要拆成“香菇”。
5. 如果是蔬菜拼盘、炸物拼盘这种物理分开摆放的区域，就按该 mask 的具体食材/食物输出，例如“胡萝卜”“紫甘蓝”“薯条”“香肠”。
6. 不要输出不在整图候选里的新食物名；如果无法匹配候选，name_zh 写“待确认食物”，usable=false。
7. 如果 mask 明显切错、只切到背景/餐具/非食物，name_zh 写“非食物”，usable=false。
8. 如果同一道菜被多个编号分割成碎块，给它们相同的 merge_group，例如“香菇鸡肉”。物理分开的同类食物也可以同名，但 merge_group 用具体名字。
9. 输出严格 JSON，一行，不要 markdown，不要解释。

格式：
{"items":[{"mask_id":1,"name_zh":"香菇鸡肉","category":"菜肴","usable":true,"confidence":0.86,"merge_group":"香菇鸡肉"}]}
"""

NON_FOOD_TERMS = ("非食物", "餐具", "桌面", "包装", "杯子", "碗", "盘", "锅", "纸巾", "吸管", "文字", "品牌")
UNCERTAIN_FOOD = "待确认食物"
AMBIGUOUS_ROUGH_LABELS = {
    "bread",
    "pork",
    "fried meat",
    "chicken duck",
    "other ingredients",
    "sauce",
    "egg",
}

ROUGH_ZH = {
    "rice": "米饭",
    "noodles": "面条",
    "shiitake": "香菇",
    "soup": "汤",
    "lettuce": "生菜",
    "french fries": "薯条",
    "fried meat": "炸肉",
    "chicken duck": "鸡肉",
    "pork": "猪肉",
    "bread": "面包",
    "sausage": "香肠",
    "egg": "鸡蛋",
    "cabbage": "卷心菜",
    "spring onion": "葱",
    "carrot": "胡萝卜",
    "pepper": "甜椒",
    "celery stick": "芹菜",
    "tomato": "番茄",
}


def load_font(size: int = 18) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def load_categories(path: Path) -> dict[int, str]:
    labels: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[0].strip().isdigit():
            labels[int(parts[0])] = parts[1].strip()
    return labels


def bbox_from_mask(mask: np.ndarray) -> list[int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def crop_with_pad(image: Image.Image, mask: np.ndarray, bbox: list[int], pad: int) -> tuple[Image.Image, np.ndarray, list[int]]:
    w, h = image.size
    x1, y1, x2, y2 = bbox
    x1 = max(0, x1 - pad)
    y1 = max(0, y1 - pad)
    x2 = min(w, x2 + pad)
    y2 = min(h, y2 + pad)
    crop = image.crop((x1, y1, x2, y2)).convert("RGB")
    crop_mask = mask[y1:y2, x1:x2]
    return crop, crop_mask, [x1, y1, x2, y2]


def overlay_mask(image: Image.Image, mask: np.ndarray, alpha: float = 0.50) -> Image.Image:
    arr = np.asarray(image.convert("RGB")).astype(np.float32)
    red = np.zeros_like(arr)
    red[..., 0] = 255
    active = mask.astype(bool)
    arr[active] = arr[active] * (1 - alpha) + red[active] * alpha
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def summarize_label_masks(label_mask: np.ndarray, id2label: dict[int, str], max_masks: int, min_area_ratio: float) -> list[dict[str, Any]]:
    h, w = label_mask.shape
    image_area = float(h * w)
    rows: list[dict[str, Any]] = []
    for label_id in sorted(int(v) for v in np.unique(label_mask) if int(v) != 0):
        mask = label_mask == label_id
        area_ratio = float(mask.sum()) / image_area
        if area_ratio < min_area_ratio:
            continue
        rows.append(
            {
                "label_id": label_id,
                "foodsam3_label": id2label.get(label_id, str(label_id)),
                "area_ratio": round(area_ratio, 5),
                "component_count": max(0, int(cv2.connectedComponents(mask.astype(np.uint8), connectivity=8)[0]) - 1),
                "bbox_xyxy": bbox_from_mask(mask),
                "_mask": mask,
            }
        )
    rows.sort(key=lambda row: row["area_ratio"], reverse=True)
    return rows[:max_masks]


def make_crop_sheet(
    image: Image.Image,
    rows: list[dict[str, Any]],
    output_path: Path,
    crop_size: int,
    pad: int,
) -> list[dict[str, Any]]:
    font = load_font(22)
    small = load_font(15)
    original = image.convert("RGB")
    original.thumbnail((420, 420), Image.LANCZOS)
    tile_w = crop_size
    tile_h = crop_size + 34
    cols = 3
    crop_tiles: list[Image.Image] = []
    meta_rows: list[dict[str, Any]] = []
    for index, row in enumerate(rows, start=1):
        crop, crop_mask, padded_bbox = crop_with_pad(image, row["_mask"], row["bbox_xyxy"], pad)
        masked = overlay_mask(crop, crop_mask)
        masked.thumbnail((crop_size, crop_size), Image.LANCZOS)
        tile = Image.new("RGB", (tile_w, tile_h), "white")
        draw = ImageDraw.Draw(tile)
        draw.text((8, 4), f"#{index}", fill=(220, 0, 0), font=font)
        draw.text((64, 9), f"rough:{row['foodsam3_label']}", fill=(70, 70, 70), font=small)
        tile.paste(masked, ((tile_w - masked.width) // 2, 34))
        crop_tiles.append(tile)
        meta_rows.append(
            {
                "mask_id": index,
                "foodsam3_label": row["foodsam3_label"],
                "label_id": row["label_id"],
                "area_ratio": row["area_ratio"],
                "component_count": row["component_count"],
                "bbox_xyxy": row["bbox_xyxy"],
                "padded_bbox_xyxy": padded_bbox,
            }
        )

    grid_rows = (len(crop_tiles) + cols - 1) // cols
    right_w = cols * tile_w
    right_h = max(tile_h, grid_rows * tile_h)
    width = 430 + right_w
    height = max(455, right_h + 35)
    sheet = Image.new("RGB", (width, height), (246, 246, 246))
    draw = ImageDraw.Draw(sheet)
    draw.text((10, 8), "original context", fill=(0, 0, 0), font=font)
    sheet.paste(original, (10, 42))
    draw.text((430, 8), "Food masks for GLM labeling", fill=(0, 0, 0), font=font)
    for idx, tile in enumerate(crop_tiles):
        x = 430 + (idx % cols) * tile_w
        y = 36 + (idx // cols) * tile_h
        sheet.paste(tile, (x, y))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, quality=92)
    return meta_rows


def parse_json_object(text: str) -> dict[str, Any]:
    text = (text or "").strip()
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
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


def load_scene_items(path: Path) -> dict[str, list[dict[str, Any]]]:
    if not path.exists():
        return {}
    rows = json.loads(path.read_text(encoding="utf-8"))
    out: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        case = str(row.get("case") or row.get("case_id") or "")
        items = row.get("items")
        if case and isinstance(items, list):
            out[case] = [item for item in items if isinstance(item, dict)]
    return out


def scene_candidate_names(items: list[dict[str, Any]]) -> list[str]:
    names: list[str] = []
    for item in items:
        name = str(item.get("name_zh") or item.get("name") or "").strip()
        if name and name not in names and not any(term in name for term in NON_FOOD_TERMS):
            names.append(name)
    return names


def build_prompt(scene_names: list[str], meta_rows: list[dict[str, Any]]) -> str:
    candidates = "、".join(scene_names) if scene_names else "无"
    rough = "；".join(
        f"#{row['mask_id']} {row['foodsam3_label']}≈{ROUGH_ZH.get(str(row['foodsam3_label']), str(row['foodsam3_label']))}"
        for row in meta_rows
    )
    return PROMPT_TEMPLATE.replace("{scene_candidates}", candidates).replace("{rough_labels}", rough)


def normalize_glm_items(payload: dict[str, Any], known_ids: set[int]) -> list[dict[str, Any]]:
    raw_items = payload.get("items")
    if not isinstance(raw_items, list):
        return []
    rows: list[dict[str, Any]] = []
    seen: set[int] = set()
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        try:
            mask_id = int(raw.get("mask_id"))
        except Exception:
            continue
        if mask_id not in known_ids or mask_id in seen:
            continue
        seen.add(mask_id)
        name = str(raw.get("name_zh") or "").strip()
        category = str(raw.get("category") or "").strip()
        merge_group = str(raw.get("merge_group") or name).strip()
        try:
            confidence = float(raw.get("confidence", 0.0))
        except Exception:
            confidence = 0.0
        usable_raw = raw.get("usable", True)
        usable = bool(usable_raw) and name not in NON_FOOD_TERMS and not any(term in name for term in NON_FOOD_TERMS)
        rows.append(
            {
                "mask_id": mask_id,
                "name_zh": name,
                "category": category,
                "usable": usable,
                "confidence": round(confidence, 4),
                "merge_group": merge_group or name,
            }
        )
    return rows


def model_device(model: torch.nn.Module) -> torch.device:
    return getattr(model, "device", None) or next(model.parameters()).device


def load_glm(model_path: Path, adapter_path: Path | None = None):
    started = time.perf_counter()
    processor = AutoProcessor.from_pretrained(str(model_path), use_fast=True, trust_remote_code=True)
    model = Glm4vForConditionalGeneration.from_pretrained(
        str(model_path),
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    ).eval()
    if adapter_path and str(adapter_path):
        from peft import PeftModel

        model = PeftModel.from_pretrained(model, str(adapter_path)).eval()
    return processor, model, time.perf_counter() - started


def ask_glm(processor: Any, model: torch.nn.Module, sheet: Image.Image, prompt: str, max_tokens: int) -> dict[str, Any]:
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": sheet},
                {"type": "text", "text": prompt},
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
    return {"seconds": round(time.perf_counter() - started, 3), "raw_text": raw_text}


def resize_for_glm(image: Image.Image, max_edge: int) -> Image.Image:
    out = image.convert("RGB")
    if max_edge > 0 and max(out.size) > max_edge:
        out = out.copy()
        out.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return out


def draw_labeled_overlay(image: Image.Image, label_mask: np.ndarray, masks: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    font = load_font(17)
    rng = np.random.default_rng(71)
    for row in masks:
        mask = label_mask == int(row["label_id"])
        color = tuple(int(x) for x in rng.integers(50, 235, size=3))
        mask_img = Image.fromarray((mask.astype(np.uint8) * 255), "L")
        colored = Image.new("RGBA", base.size, color + (92,))
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = row["bbox_xyxy"]
        label = f"{row['mask_id']}:{row.get('name_zh') or row['foodsam3_label']}"
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=3)
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255), font=font)
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def choose_scene_relabel(current_name: str, rough_label: str, scene_names: list[str]) -> str:
    if not current_name:
        return current_name
    rough_zh = ROUGH_ZH.get(rough_label, "")
    probes = [current_name, rough_zh]
    for probe in probes:
        if not probe:
            continue
        for candidate in scene_names:
            if probe in candidate and candidate != probe:
                return candidate
    if current_name == "面条":
        for candidate in scene_names:
            if "炒面" in candidate or candidate.endswith("面"):
                return candidate
    if current_name in {"米饭", "饭"}:
        for candidate in scene_names:
            if "饭" in candidate:
                return candidate
    if current_name in {"炸肉", "鸡肉", "鸡肉块"} or rough_label in {"fried meat", "chicken duck"}:
        for candidate in scene_names:
            if candidate in {"炸鸡", "鸡块", "鸡米花"}:
                return candidate
    if rough_label == "pork":
        for candidate in scene_names:
            if candidate in {"香肠", "热狗"}:
                return candidate
    if rough_label == "cabbage":
        for candidate in scene_names:
            if candidate in {"紫甘蓝", "卷心菜"}:
                return candidate
    if rough_label == "pepper":
        for candidate in scene_names:
            if candidate in {"红甜椒", "青椒", "辣椒"}:
                return candidate
    if rough_label == "bread" and current_name == "面包" and "面包" not in scene_names:
        for candidate in scene_names:
            if candidate in {"蛋挞", "炸鸡", "鸡块", "鸡米花", "薯条", "炸薯角"}:
                return UNCERTAIN_FOOD
    return current_name


def needs_scene_review(name: str, raw_name: str, rough_label: str, scene_names: list[str]) -> bool:
    if not scene_names:
        return False
    if name in scene_names:
        return False
    if name == UNCERTAIN_FOOD:
        return True
    if rough_label in AMBIGUOUS_ROUGH_LABELS and raw_name not in scene_names:
        return True
    if raw_name and raw_name not in scene_names and name not in scene_names:
        return True
    return False


def make_contact_sheet(rows: list[dict[str, Any]], output_path: Path) -> None:
    font = load_font(20)
    tiles: list[Image.Image] = []
    for row in rows:
        img = Image.open(row["labeled_overlay"]).convert("RGB")
        img.thumbnail((520, 420), Image.LANCZOS)
        tile = Image.new("RGB", (560, 500), "white")
        draw = ImageDraw.Draw(tile)
        names = ", ".join(f"#{x['mask_id']} {x.get('name_zh','?')}" for x in row["labels"][:8])
        draw.text((10, 8), f"{row['case']} | GLM {row['glm_seconds']}s | masks {len(row['labels'])}", fill=(0, 0, 0), font=font)
        draw.text((10, 36), names[:90], fill=(70, 70, 70), font=load_font(14))
        tile.paste(img, ((560 - img.width) // 2, 74))
        tiles.append(tile)
    if not tiles:
        return
    cols = 2
    sheet = Image.new("RGB", (cols * 560, ((len(tiles) + cols - 1) // cols) * 500), (245, 245, 245))
    for index, tile in enumerate(tiles):
        sheet.paste(tile, ((index % cols) * 560, (index // cols) * 500))
    sheet.save(output_path, quality=92)


def run(args: argparse.Namespace) -> None:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    id2label = load_categories(args.category_txt)
    print(
        json.dumps(
            {"event": "load_glm_start", "model": str(args.model_path), "adapter": str(args.adapter_path or "")},
            ensure_ascii=False,
        ),
        flush=True,
    )
    adapter_text = str(args.adapter_path or "").strip()
    adapter_path = args.adapter_path if adapter_text and adapter_text != "." else None
    processor, model, load_seconds = load_glm(args.model_path, adapter_path)
    print(json.dumps({"event": "load_glm_done", "seconds": round(load_seconds, 3)}, ensure_ascii=False), flush=True)
    scene_by_case = load_scene_items(args.scene_json) if args.scene_json else {}

    cases = [case.strip() for case in args.cases.split(",") if case.strip()]
    final_rows: list[dict[str, Any]] = []
    for case in cases:
        case_dir = args.foodsam3_dir / case
        image_path = args.official_root / case / "input.jpg"
        if args.mask_source == "foodsam2":
            mask_path = case_dir / "foodsam2_sam2_fused_mask.npy"
        else:
            mask_path = case_dir / "foodsam3_sam3_fused_mask.npy"
        if not image_path.exists() or not mask_path.exists():
            print(json.dumps({"case": case, "error": "missing image or mask"}, ensure_ascii=False), flush=True)
            continue
        image = Image.open(image_path).convert("RGB")
        label_mask = np.load(mask_path).astype(np.int32)
        masks = summarize_label_masks(label_mask, id2label, args.max_masks, args.min_area_ratio)
        case_out = args.out_dir / case
        case_out.mkdir(parents=True, exist_ok=True)
        sheet_path = case_out / f"{args.mask_source}_mask_crops_for_glm.jpg"
        meta_rows = make_crop_sheet(image, masks, sheet_path, args.crop_size, args.pad)
        scene_names = scene_candidate_names(scene_by_case.get(case, []))
        prompt = build_prompt(scene_names, meta_rows)
        result = ask_glm(processor, model, resize_for_glm(Image.open(sheet_path), args.sheet_max_edge), prompt, args.max_tokens)
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        parse_error = None
        labels: list[dict[str, Any]] = []
        try:
            labels = normalize_glm_items(parse_json_object(result["raw_text"]), {row["mask_id"] for row in meta_rows})
        except Exception as exc:
            parse_error = f"{type(exc).__name__}: {exc}"
        by_id = {row["mask_id"]: row for row in labels}
        merged_rows: list[dict[str, Any]] = []
        for row in meta_rows:
            merged = {**row, **by_id.get(row["mask_id"], {})}
            raw_name = str(merged.get("name_zh") or "")
            if scene_names and merged.get("name_zh"):
                relabeled = choose_scene_relabel(str(merged.get("name_zh") or ""), str(merged["foodsam3_label"]), scene_names)
                merged["name_zh_raw_glm"] = merged.get("name_zh")
                merged["name_zh"] = relabeled
                merged["merge_group"] = relabeled
                if relabeled == UNCERTAIN_FOOD:
                    merged["usable"] = False
            merged["need_review"] = False if args.no_review else (
                (not merged.get("usable", True))
                or float(merged.get("confidence", 0.0)) < args.review_confidence
                or needs_scene_review(str(merged.get("name_zh") or ""), raw_name, str(merged["foodsam3_label"]), scene_names)
            )
            merged_rows.append(merged)
        overlay_path = case_out / f"{args.mask_source}_glm_labeled_overlay.jpg"
        draw_labeled_overlay(image, label_mask, merged_rows, overlay_path)
        row = {
            "case": case,
            "image": str(image_path),
            "mask_path": str(mask_path),
            "mask_source": args.mask_source,
            "recognizer": "Food-GR1" if adapter_path else "raw GLM-4.6V-Flash",
            "sheet": str(sheet_path),
            "labeled_overlay": str(overlay_path),
            "glm_seconds": result["seconds"],
            "raw_text": result["raw_text"],
            "parse_error": parse_error,
            "scene_candidates": scene_names,
            "labels": merged_rows,
        }
        (case_out / "summary.json").write_text(json.dumps(row, ensure_ascii=False, indent=2), encoding="utf-8")
        final_rows.append(row)
        print(
            json.dumps(
                {
                    "case": case,
                    "glm_seconds": result["seconds"],
                    "parse_error": parse_error,
                    "labels": [
                        {
                            "id": x["mask_id"],
                            "rough": x["foodsam3_label"],
                            "name": x.get("name_zh"),
                            "usable": x.get("usable"),
                            "conf": x.get("confidence"),
                            "review": x.get("need_review"),
                        }
                        for x in merged_rows
                    ],
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    (args.out_dir / "batch_summary.json").write_text(json.dumps(final_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(final_rows, args.out_dir / "foodsam3_glm_label_contact_sheet.jpg")
    del processor
    del model
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    print(f"saved={args.out_dir}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", type=Path, default=Path("/root/autodl-tmp/modelscope-cache-ms/ZhipuAI/GLM-4___6V-Flash"))
    parser.add_argument("--adapter-path", type=Path, default=Path(""))
    parser.add_argument("--foodsam3-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_sam2_sam3_fusion_20260705_015707"))
    parser.add_argument("--official-root", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_official_script_768_typed_20260704_224953"))
    parser.add_argument("--category-txt", type=Path, default=Path("/root/autodl-tmp/FoodSAM/FoodSAM/FoodSAM_tools/category_id_files/foodseg103_category_id.txt"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam3_glm_label_20260705"))
    parser.add_argument("--scene-json", type=Path, default=Path(""))
    parser.add_argument("--mask-source", choices=("foodsam2", "foodsam3"), default="foodsam3")
    parser.add_argument("--cases", default="rgb_cafeteria_meal,rgb_fried_platter,rgb_vegetable_board")
    parser.add_argument("--max-masks", type=int, default=8)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--crop-size", type=int, default=260)
    parser.add_argument("--sheet-max-edge", type=int, default=768)
    parser.add_argument("--pad", type=int, default=22)
    parser.add_argument("--max-tokens", type=int, default=700)
    parser.add_argument("--review-confidence", type=float, default=0.65)
    parser.add_argument("--no-review", action="store_true")
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
