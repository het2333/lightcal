#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gc
import json
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFont
from transformers import AutoModelForImageTextToText, AutoProcessor


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


PROMPT = """你是食物图片识别助手。只提取图片中真实可见、可被分割的食物/饮料/食材名字，用于后续分割。

要求：
1. 不要估算热量、重量、体积、密度、营养。
2. 不要输出解释，不要 markdown。
3. 对拼盘、沙拉、套餐、锅/碗里的食物，要优先拆成图片里可见的具体食材或菜品；不要只写“色拉”“拼盘”“套餐”“一餐”这类总称。
4. 不确定就少报，不要编不存在的食物；不要把餐具、桌子、包装、纸巾输出为食物。
5. 每个项目给中文名 name_zh 和适合视觉分割的英文短语 prompt_en。prompt_en 要短，最好是具体视觉类别，例如 carrot、fried chicken、noodles。
6. 最多输出 12 项，按可见面积从大到小。
7. 输出严格 JSON，格式如下：
{"items":[{"name_zh":"炸鸡","prompt_en":"fried chicken","kind":"food","confidence":0.90}]}
"""


def add_sam3_path() -> None:
    path = "/root/autodl-tmp/sam3"
    if path not in sys.path:
        sys.path.insert(0, path)


def resize_image(image: Image.Image, max_edge: int) -> Image.Image:
    out = image.convert("RGB")
    if max_edge > 0 and max(out.size) > max_edge:
        out = out.copy()
        out.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return out


def load_font(size: int = 15) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


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
    prompt_aliases = {
        "brussels sprout": "broccoli",
        "fries sticks": "french fries",
        "tart": "egg tart",
        "chicken mushroom dish": "chicken mushroom dish",
    }
    name_aliases = {
        "鸡米花": "鸡块",
        "炸鸡排": "炸鸡",
        "炸薯角": "薯条",
        "西蓝花": "西兰花",
    }
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("name_zh") or raw.get("name") or "").strip()
        prompt = str(raw.get("prompt_en") or raw.get("detector_phrase") or "").strip().lower()
        if not name or not prompt:
            continue
        name = name_aliases.get(name, name)
        prompt = prompt_aliases.get(prompt, prompt)
        key = prompt
        if key in seen:
            continue
        seen.add(key)
        conf = raw.get("confidence", 0.0)
        try:
            conf_f = float(conf)
        except Exception:
            conf_f = 0.0
        items.append(
            {
                "name_zh": name,
                "prompt_en": prompt,
                "kind": str(raw.get("kind") or "food"),
                "confidence": round(conf_f, 4),
            }
        )
        if len(items) >= max_items:
            break
    return items


def load_food_r1(model_path: Path):
    started = time.perf_counter()
    processor = AutoProcessor.from_pretrained(str(model_path), use_fast=True, trust_remote_code=True)
    model = AutoModelForImageTextToText.from_pretrained(
        str(model_path),
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    ).eval()
    return processor, model, time.perf_counter() - started


def model_device(model: torch.nn.Module) -> torch.device:
    return getattr(model, "device", None) or next(model.parameters()).device


def extract_names(
    processor: Any,
    model: torch.nn.Module,
    image: Image.Image,
    max_tokens: int,
    max_items: int,
) -> tuple[list[dict[str, Any]], str, float, str | None]:
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
        return_dict=True,
        return_tensors="pt",
    ).to(model_device(model))
    inputs.pop("token_type_ids", None)
    with torch.inference_mode():
        generated = model.generate(**inputs, max_new_tokens=max_tokens, do_sample=False)
    output_ids = generated[0][inputs["input_ids"].shape[1] :]
    text = processor.decode(output_ids, skip_special_tokens=True).strip()
    error = None
    items: list[dict[str, Any]] = []
    try:
        items = normalize_items(parse_json_object(text), max_items=max_items)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    return items, text, time.perf_counter() - started, error


def unload_food_r1(processor: Any, model: Any) -> None:
    del processor
    del model
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()


def load_extraction_rows(path: Path, max_items: int) -> list[dict[str, Any]]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    repaired: list[dict[str, Any]] = []
    for row in rows:
        raw_text = str(row.get("raw_text") or "")
        try:
            items = normalize_items(parse_json_object(raw_text), max_items=max_items)
            error = None
        except Exception as exc:
            items = []
            error = f"{type(exc).__name__}: {exc}"
        repaired.append(
            {
                **row,
                "items": items,
                "parse_error": error,
            }
        )
        print(
            json.dumps(
                {
                    "case": row.get("case"),
                    "repaired_items": items,
                    "parse_error": error,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
    return repaired


def patch_sam3_fused_mlp_for_turing() -> None:
    import sam3.model.vitdet as sam3_vitdet

    def safe_addmm_act(activation: Any, linear: torch.nn.Module, mat1: torch.Tensor) -> torch.Tensor:
        y = linear(mat1)
        name = getattr(activation, "__name__", str(activation)).lower()
        if activation in (torch.nn.functional.relu, torch.nn.ReLU) or "relu" in name:
            return F.relu(y)
        if activation in (torch.nn.functional.gelu, torch.nn.GELU) or "gelu" in name:
            return F.gelu(y)
        raise ValueError(f"Unexpected activation {activation}")

    sam3_vitdet.addmm_act = safe_addmm_act


def load_sam3(args: argparse.Namespace):
    add_sam3_path()
    patch_sam3_fused_mlp_for_turing()
    from sam3.model.sam3_image_processor import Sam3Processor
    from sam3.model_builder import build_sam3_image_model

    started = time.perf_counter()
    model = build_sam3_image_model(
        checkpoint_path=args.sam3_checkpoint,
        load_from_HF=False,
        device=args.device,
        enable_segmentation=True,
        enable_inst_interactivity=False,
        compile=False,
    )
    processor = Sam3Processor(model, device=args.device, confidence_threshold=args.confidence_threshold)
    return processor, time.perf_counter() - started


def tensor_to_numpy_masks(masks: torch.Tensor) -> np.ndarray:
    masks = masks.detach().cpu()
    if masks.ndim == 4 and masks.shape[1] == 1:
        masks = masks[:, 0]
    return masks.numpy().astype(bool)


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.logical_and(a, b).sum())
    union = int(np.logical_or(a, b).sum())
    return inter / union if union else 0.0


def pick_instances(
    prompt: str,
    output: dict[str, Any],
    image_area: int,
    max_per_prompt: int,
    min_area_ratio: float,
    max_area_ratio: float,
) -> list[dict[str, Any]]:
    masks = tensor_to_numpy_masks(output["masks"])
    boxes = output["boxes"].detach().cpu().numpy().tolist()
    scores = [float(v) for v in output["scores"].detach().cpu().numpy().tolist()]
    rows: list[dict[str, Any]] = []
    used_masks: list[np.ndarray] = []
    for index in sorted(range(len(scores)), key=lambda idx: scores[idx], reverse=True):
        mask = masks[index]
        area = int(mask.sum())
        area_ratio = area / max(image_area, 1)
        if area_ratio < min_area_ratio or area_ratio > max_area_ratio:
            continue
        if any(mask_iou(mask, old) > 0.55 for old in used_masks):
            continue
        rows.append(
            {
                "prompt": prompt,
                "score": round(scores[index], 4),
                "bbox_xyxy": [round(float(v), 2) for v in boxes[index]],
                "mask_area": area,
                "mask_area_ratio": round(area_ratio, 5),
                "_mask": mask,
            }
        )
        used_masks.append(mask)
        if len(rows) >= max_per_prompt:
            break
    return rows


def run_sam3_case(
    processor: Any,
    image: Image.Image,
    items: list[dict[str, Any]],
    args: argparse.Namespace,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], float]:
    started = time.perf_counter()
    state = processor.set_image(image)
    image_area = image.width * image.height
    all_instances: list[dict[str, Any]] = []
    prompt_summaries: list[dict[str, Any]] = []
    for item in items:
        prompt = item["prompt_en"]
        processor.reset_all_prompts(state)
        p0 = time.perf_counter()
        try:
            output = processor.set_text_prompt(state=state, prompt=prompt)
            raw_count = int(output["scores"].numel())
            instances = pick_instances(
                prompt,
                output,
                image_area,
                args.max_per_prompt,
                args.min_area_ratio,
                args.max_area_ratio,
            )
            error = None
        except Exception as exc:
            raw_count = 0
            instances = []
            error = f"{type(exc).__name__}: {exc}"
        for inst in instances:
            inst["name_zh"] = item["name_zh"]
            inst["food_r1_confidence"] = item.get("confidence", 0.0)
        all_instances.extend(instances)
        prompt_summaries.append(
            {
                "name_zh": item["name_zh"],
                "prompt": prompt,
                "raw_count": raw_count,
                "kept_count": len(instances),
                "seconds": round(time.perf_counter() - p0, 3),
                "error": error,
                "instances": [{k: v for k, v in inst.items() if k != "_mask"} for inst in instances],
            }
        )
    return all_instances, prompt_summaries, time.perf_counter() - started


def draw_instances(image: Image.Image, items: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    font = load_font(13)
    rng = np.random.default_rng(53)
    for index, item in enumerate(items, start=1):
        color = tuple(int(x) for x in rng.integers(45, 235, size=3))
        mask_img = Image.fromarray((item["_mask"].astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color + (86,))
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = item["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=3)
        label = f"{index}:{item['name_zh']} {item['score']:.2f}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255), font=font)
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def export_auto_label_manifest(
    image: Image.Image,
    case_name: str,
    items: list[dict[str, Any]],
    case_dir: Path,
    source_model: str,
) -> list[dict[str, Any]]:
    masks_dir = case_dir / "masks"
    masks_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    image_area = max(1, image.width * image.height)
    for index, item in enumerate(items, start=1):
        mask = np.asarray(item["_mask"]).astype(bool)
        mask_path = masks_dir / f"{case_name}_{index:03d}_{item['name_zh']}.png"
        Image.fromarray((mask.astype(np.uint8) * 255), mode="L").save(mask_path)
        x1, y1, x2, y2 = item["bbox_xyxy"]
        confidence = float(item.get("score") or 0.0) * float(item.get("food_r1_confidence") or item.get("glm_confidence") or 1.0)
        area_ratio = float(mask.sum()) / image_area
        rows.append(
            {
                "annotation_id": f"{case_name}_{index:03d}",
                "name_zh": item["name_zh"],
                "prompt_en": item["prompt"],
                "bbox_xyxy": [round(float(x1), 2), round(float(y1), 2), round(float(x2), 2), round(float(y2), 2)],
                "bbox_xywh": [round(float(x1), 2), round(float(y1), 2), round(float(x2 - x1), 2), round(float(y2 - y1), 2)],
                "mask_area": int(mask.sum()),
                "mask_area_ratio": round(area_ratio, 5),
                "sam3_score": round(float(item.get("score") or 0.0), 4),
                "label_confidence": round(float(item.get("food_r1_confidence") or item.get("glm_confidence") or 0.0), 4),
                "combined_confidence": round(confidence, 4),
                "mask_path": str(mask_path),
                "source": f"{source_model}+sam3",
                "need_review": confidence < 0.55 or area_ratio < 0.002 or area_ratio > 0.45,
            }
        )
    return rows


def make_contact_sheet(rows: list[dict[str, Any]], output_path: Path) -> None:
    font = load_font(20)
    small = load_font(15)
    tiles: list[Image.Image] = []
    for row in rows:
        image = Image.open(row["annotated_image"]).convert("RGB")
        image.thumbnail((520, 390), Image.LANCZOS)
        names = ", ".join(f"{x['name_zh']}({x['prompt_en']})" for x in row["items"][:8]) or "no parsed items"
        label_seconds = row.get("food_r1_seconds", row.get("raw_glm_seconds", row.get("glm_seconds", 0)))
        label_model = row.get("label_model", "Food-R1")
        meta = f"{row['case']} | {label_model} {label_seconds}s | SAM3 {row['sam3_seconds']}s | {row['instance_count']} masks"
        tile = Image.new("RGB", (560, 470), "white")
        d = ImageDraw.Draw(tile)
        d.text((10, 8), meta, fill=(0, 0, 0), font=font)
        d.text((10, 36), names[:95], fill=(65, 65, 65), font=small)
        tile.paste(image, ((560 - image.width) // 2, 76))
        tiles.append(tile)
    if not tiles:
        return
    cols = 2
    rows_n = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * 560, rows_n * 470), (245, 245, 245))
    for idx, tile in enumerate(tiles):
        sheet.paste(tile, ((idx % cols) * 560, (idx // cols) * 470))
    sheet.save(output_path, quality=92)


def run(args: argparse.Namespace) -> None:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    cases = CASES[args.start :]
    if args.limit is not None:
        cases = cases[: args.limit]

    if args.extraction_json:
        extraction_rows = load_extraction_rows(Path(args.extraction_json), args.max_items)
        (args.out_dir / "foodr1_name_extraction_repaired.json").write_text(json.dumps(extraction_rows, ensure_ascii=False, indent=2), encoding="utf-8")
        source_model = args.source_model
    else:
        print(json.dumps({"event": "load_food_r1_start"}, ensure_ascii=False), flush=True)
        food_processor, food_model, food_load_seconds = load_food_r1(Path(args.food_r1_model))
        print(json.dumps({"event": "load_food_r1_done", "seconds": round(food_load_seconds, 3)}, ensure_ascii=False), flush=True)

        extraction_rows: list[dict[str, Any]] = []
        for case in cases:
            image = resize_image(Image.open(case.image), args.max_edge)
            items, raw_text, seconds, error = extract_names(food_processor, food_model, image, args.max_tokens, args.max_items)
            row = {
                "case": case.name,
                "image": str(case.image),
                "image_size": list(image.size),
                "food_r1_seconds": round(seconds, 3),
                "items": items,
                "raw_text": raw_text,
                "parse_error": error,
            }
            extraction_rows.append(row)
            print(json.dumps({"case": case.name, "food_r1_seconds": row["food_r1_seconds"], "items": items, "parse_error": error}, ensure_ascii=False), flush=True)

        (args.out_dir / "foodr1_name_extraction.json").write_text(json.dumps(extraction_rows, ensure_ascii=False, indent=2), encoding="utf-8")
        unload_food_r1(food_processor, food_model)
        source_model = "Food-R1"

    print(json.dumps({"event": "load_sam3_start"}, ensure_ascii=False), flush=True)
    sam3_processor, sam3_load_seconds = load_sam3(args)
    print(json.dumps({"event": "load_sam3_done", "seconds": round(sam3_load_seconds, 3)}, ensure_ascii=False), flush=True)

    final_rows: list[dict[str, Any]] = []
    for row in extraction_rows:
        image = resize_image(Image.open(row["image"]), args.max_edge)
        case_dir = args.out_dir / row["case"]
        case_dir.mkdir(parents=True, exist_ok=True)
        instances, prompt_summaries, seconds = run_sam3_case(sam3_processor, image, row["items"], args)
        annotated = case_dir / "foodr1_sam3_annotated.jpg"
        draw_instances(image, instances, annotated)
        auto_labels = export_auto_label_manifest(image, row["case"], instances, case_dir, source_model)
        final = {
            **row,
            "label_model": source_model,
            "sam3_seconds": round(seconds, 3),
            "sam3_load_seconds": round(sam3_load_seconds, 3),
            "instance_count": len(instances),
            "prompt_summaries": prompt_summaries,
            "auto_labels": auto_labels,
            "annotated_image": str(annotated),
        }
        (case_dir / "summary.json").write_text(json.dumps(final, ensure_ascii=False, indent=2), encoding="utf-8")
        final_rows.append(final)
        print(json.dumps({"case": row["case"], "sam3_seconds": final["sam3_seconds"], "instance_count": len(instances), "prompts": [x["prompt"] for x in prompt_summaries], "kept": [x["kept_count"] for x in prompt_summaries]}, ensure_ascii=False), flush=True)

    (args.out_dir / "batch_summary.json").write_text(json.dumps(final_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    auto_manifest = {
        "source_model": source_model,
        "label_format": "mask_png_manifest_v1",
        "images": [
            {
                "case": row["case"],
                "image": row["image"],
                "image_size": row["image_size"],
                "annotated_image": row["annotated_image"],
                "labels": row["auto_labels"],
            }
            for row in final_rows
        ],
    }
    (args.out_dir / "auto_label_manifest.json").write_text(json.dumps(auto_manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(final_rows, args.out_dir / "foodr1_sam3_contact_sheet.jpg")
    print(f"saved={args.out_dir}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--food-r1-model", default="/root/autodl-tmp/modelscope-cache-ms/zy12123/Food-R1")
    parser.add_argument("--extraction-json", default="")
    parser.add_argument("--source-model", default="Food-R1")
    parser.add_argument("--sam3-checkpoint", default="/root/autodl-tmp/modelscope-cache-ms/facebook/sam3/sam3.pt")
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodr1_sam3_names_20260705"))
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--max-items", type=int, default=10)
    parser.add_argument("--confidence-threshold", type=float, default=0.35)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.60)
    parser.add_argument("--max-per-prompt", type=int, default=4)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
