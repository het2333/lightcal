#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw


CASES = [
    {
        "name": "depth_cola_can",
        "image": "/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_cab838efdd31/rgb.jpg",
        "groups": [
            {"label": "drink can", "prompts": ["soda can", "drink can", "soft drink can", "cola can", "cola"]},
        ],
    },
    {
        "name": "depth_pot_bowl",
        "image": "/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_04f23a03f8bb/rgb.jpg",
        "groups": [
            {"label": "fried rice", "prompts": ["fried rice", "food in bowl", "rice dish"]},
            {"label": "noodles", "prompts": ["noodles"]},
        ],
    },
    {
        "name": "rgb_fried_platter",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg",
        "groups": [
            {"label": "fried chicken", "prompts": ["fried chicken", "chicken nugget", "chicken"]},
            {"label": "french fries", "prompts": ["french fries", "fries"]},
            {"label": "curry puff", "prompts": ["curry puff", "samosa", "fried pastry", "turnover"]},
            {"label": "egg tart", "prompts": ["egg tart", "custard tart"]},
        ],
    },
    {
        "name": "rgb_cafeteria_meal",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg",
        "groups": [
            {"label": "fried noodles", "prompts": ["fried noodles", "noodles"]},
            {"label": "purple rice", "prompts": ["purple rice", "rice"]},
            {"label": "tea", "prompts": ["tea", "drink"]},
            {"label": "chicken", "prompts": ["chicken"]},
        ],
    },
    {
        "name": "rgb_img6388",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg",
        "groups": [
            {"label": "noodles", "prompts": ["noodles"]},
            {"label": "shrimp", "prompts": ["shrimp"]},
            {"label": "cucumber", "prompts": ["cucumber"]},
            {"label": "french fries", "prompts": ["french fries", "fries"]},
            {"label": "congee", "prompts": ["purple sweet potato congee", "congee", "porridge"]},
        ],
    },
]


def import_probe_helpers(sam3_repo: str):
    repo = Path(sam3_repo)
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))
    import probe_sam3_food_masks as probe

    return probe


def clean_union_mask(mask: np.ndarray, min_component_area: int) -> np.ndarray:
    mask_u8 = mask.astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask_u8, 8)
    out = np.zeros_like(mask_u8)
    for idx in range(1, count):
        if stats[idx, cv2.CC_STAT_AREA] >= min_component_area:
            out[labels == idx] = 1
    kernel = np.ones((3, 3), np.uint8)
    out = cv2.morphologyEx(out, cv2.MORPH_CLOSE, kernel)
    return out.astype(bool)


def bbox_from_mask(mask: np.ndarray) -> list[float]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return []
    return [float(xs.min()), float(ys.min()), float(xs.max() + 1), float(ys.max() + 1)]


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.logical_and(a, b).sum())
    union = int(np.logical_or(a, b).sum())
    return inter / union if union else 0.0


def dedupe_instances(instances: list[dict[str, Any]], iou_threshold: float) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    for item in sorted(instances, key=lambda inst: float(inst.get("score") or 0), reverse=True):
        mask = item["_mask"].astype(bool)
        if any(mask_iou(mask, used["_mask"].astype(bool)) > iou_threshold for used in selected):
            continue
        selected.append(item)
    return selected


def draw_merged(image: Image.Image, merged: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(89)
    for idx, item in enumerate(merged, start=1):
        color = tuple(random.randint(45, 235) for _ in range(3))
        mask_img = Image.fromarray((item["_mask"].astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color + (88,))
        overlay.alpha_composite(
            Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img)
        )
        x1, y1, x2, y2 = item["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=4)
        label = f"{idx}:{item['label']} {item['instance_count']}->{item['component_count']}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def run_case(case: dict[str, Any], processor: Any, probe: Any, out_root: Path, args: argparse.Namespace) -> dict[str, Any]:
    started = time.perf_counter()
    case_dir = out_root / case["name"]
    case_dir.mkdir(parents=True, exist_ok=True)
    image = probe.resize_image(Image.open(case["image"]).convert("RGB"), args.max_edge)
    image_area = image.width * image.height
    state = processor.set_image(image)

    raw_instances: list[dict[str, Any]] = []
    merged: list[dict[str, Any]] = []
    group_summaries: list[dict[str, Any]] = []

    for group in case["groups"]:
        group_instances: list[dict[str, Any]] = []
        prompt_summaries: list[dict[str, Any]] = []
        for prompt in group["prompts"]:
            processor.reset_all_prompts(state)
            prompt_started = time.perf_counter()
            output = processor.set_text_prompt(state=state, prompt=prompt)
            instances = probe.pick_instances(
                prompt,
                output,
                image_area,
                args.max_per_prompt,
                args.min_area_ratio,
                args.max_area_ratio,
            )
            prompt_summaries.append(
                {
                    "prompt": prompt,
                    "raw_count": int(output["scores"].numel()),
                    "kept_count": len(instances),
                    "seconds": round(time.perf_counter() - prompt_started, 3),
                    "instances": [{k: v for k, v in inst.items() if k != "_mask"} for inst in instances],
                }
            )
            group_instances.extend(instances)
        deduped = dedupe_instances(group_instances, args.dedupe_iou)
        raw_instances.extend(deduped)
        if deduped:
            union = np.zeros((image.height, image.width), dtype=bool)
            for inst in deduped:
                union |= inst["_mask"].astype(bool)
            cleaned = clean_union_mask(union, args.min_component_area)
            count, _, _, _ = cv2.connectedComponentsWithStats(cleaned.astype(np.uint8), 8)
            component_count = max(0, count - 1)
            area = int(cleaned.sum())
            box = bbox_from_mask(cleaned)
            if area > 0 and box:
                merged.append(
                    {
                        "label": group["label"],
                        "prompts": group["prompts"],
                        "instance_count": len(deduped),
                        "component_count": component_count,
                        "score_max": round(max(float(inst["score"]) for inst in deduped), 4),
                        "raw_area_pixels": int(union.sum()),
                        "merged_area_pixels": area,
                        "merged_area_ratio": round(area / max(image_area, 1), 5),
                        "bbox_xyxy": [round(v, 2) for v in box],
                        "_mask": cleaned,
                    }
                )
        group_summaries.append(
            {
                "label": group["label"],
                "prompts": group["prompts"],
                "deduped_instance_count": len(deduped),
                "prompt_summaries": prompt_summaries,
            }
        )

    raw_path = case_dir / "sam3_raw_instances.jpg"
    merged_path = case_dir / "sam3_merged_same_class.jpg"
    probe.draw_instances(image, raw_instances, raw_path)
    draw_merged(image, merged, merged_path)
    clean_merged = [{k: v for k, v in item.items() if k != "_mask"} for item in merged]
    summary = {
        "name": case["name"],
        "image": case["image"],
        "image_size": [image.width, image.height],
        "raw_instance_count": len(raw_instances),
        "merged_class_count": len(clean_merged),
        "total_seconds": round(time.perf_counter() - started, 3),
        "group_summaries": group_summaries,
        "merged": clean_merged,
        "raw_image": str(raw_path),
        "merged_image": str(merged_path),
    }
    (case_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def make_contact_sheet(summaries: list[dict[str, Any]], out_dir: Path) -> Path:
    tiles: list[Image.Image] = []
    for summary in summaries:
        img = Image.open(summary["merged_image"]).convert("RGB")
        img.thumbnail((420, 420))
        tile = Image.new("RGB", (440, 470), "white")
        tile.paste(img, ((440 - img.width) // 2, 38))
        draw = ImageDraw.Draw(tile)
        label = "{} raw {} -> {} classes  {}s".format(
            summary["name"],
            summary["raw_instance_count"],
            summary["merged_class_count"],
            summary["total_seconds"],
        )
        draw.text((10, 10), label, fill=(0, 0, 0))
        tiles.append(tile)
    cols = 2
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * 440, rows * 470), "white")
    for idx, tile in enumerate(tiles):
        sheet.paste(tile, ((idx % cols) * 440, (idx // cols) * 470))
    path = out_dir / "sam3_merged_contact_sheet.jpg"
    sheet.save(path, quality=92)
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--sam3-repo", default="/root/autodl-tmp/sam3")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--confidence-threshold", type=float, default=0.30)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.55)
    parser.add_argument("--max-per-prompt", type=int, default=6)
    parser.add_argument("--dedupe-iou", type=float, default=0.62)
    parser.add_argument("--min-component-area", type=int, default=120)
    parser.add_argument("--case", action="append", help="Optional case name filter; can be passed multiple times.")
    args = parser.parse_args()

    probe = import_probe_helpers(args.sam3_repo)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    processor = probe.load_model(args)
    selected = [case for case in CASES if not args.case or case["name"] in set(args.case)]
    summaries = [run_case(case, processor, probe, args.out_dir, args) for case in selected]
    contact_sheet = make_contact_sheet(summaries, args.out_dir)
    table = [
        {
            "name": item["name"],
            "raw_instance_count": item["raw_instance_count"],
            "merged_class_count": item["merged_class_count"],
            "total_seconds": item["total_seconds"],
            "merged": item["merged"],
            "merged_image": item["merged_image"],
        }
        for item in summaries
    ]
    (args.out_dir / "batch_summary.json").write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"contact_sheet": str(contact_sheet), "cases": table}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
