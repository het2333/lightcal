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


VEGETABLE_CASE = {
    "name": "rgb_vegetable_board",
    "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/vegetable_board/rgb.jpg",
    "prompts": [
        "red cabbage",
        "celery",
        "kale",
        "mushroom",
        "tomato",
        "carrot",
        "onion",
        "brussels sprout",
    ],
}


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


def draw_merged(image: Image.Image, merged: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(71)
    for idx, item in enumerate(merged, start=1):
        color = tuple(random.randint(45, 235) for _ in range(3))
        mask_img = Image.fromarray((item["_mask"].astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color + (88,))
        overlay.alpha_composite(
            Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img)
        )
        x1, y1, x2, y2 = item["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=4)
        label = f"{idx}:{item['prompt']} {item['instance_count']}->{item['component_count']}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def run(args: argparse.Namespace) -> dict[str, Any]:
    probe = import_probe_helpers(args.sam3_repo)
    started = time.perf_counter()
    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    image = probe.resize_image(Image.open(VEGETABLE_CASE["image"]).convert("RGB"), args.max_edge)
    image_area = image.width * image.height
    processor = probe.load_model(args)
    state = processor.set_image(image)

    raw_instances: list[dict[str, Any]] = []
    merged: list[dict[str, Any]] = []
    prompt_summaries: list[dict[str, Any]] = []

    for prompt in VEGETABLE_CASE["prompts"]:
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
        prompt_seconds = round(time.perf_counter() - prompt_started, 3)
        raw_instances.extend(instances)
        if instances:
            union = np.zeros((image.height, image.width), dtype=bool)
            for inst in instances:
                union |= inst["_mask"].astype(bool)
            cleaned = clean_union_mask(union, args.min_component_area)
            count, _, stats, _ = cv2.connectedComponentsWithStats(cleaned.astype(np.uint8), 8)
            component_count = max(0, count - 1)
            area = int(cleaned.sum())
            box = bbox_from_mask(cleaned)
            if area > 0 and box:
                merged.append(
                    {
                        "prompt": prompt,
                        "instance_count": len(instances),
                        "component_count": component_count,
                        "score_max": round(max(float(inst["score"]) for inst in instances), 4),
                        "raw_area_pixels": int(union.sum()),
                        "merged_area_pixels": area,
                        "merged_area_ratio": round(area / max(image_area, 1), 5),
                        "bbox_xyxy": [round(v, 2) for v in box],
                        "_mask": cleaned,
                    }
                )
        prompt_summaries.append(
            {
                "prompt": prompt,
                "raw_count": int(output["scores"].numel()),
                "kept_count": len(instances),
                "seconds": prompt_seconds,
                "instances": [{k: v for k, v in inst.items() if k != "_mask"} for inst in instances],
            }
        )

    raw_path = out_dir / "sam3_raw_instances.jpg"
    merged_path = out_dir / "sam3_merged_same_class.jpg"
    probe.draw_instances(image, raw_instances, raw_path)
    draw_merged(image, merged, merged_path)

    clean_merged = [{k: v for k, v in item.items() if k != "_mask"} for item in merged]
    summary = {
        "name": VEGETABLE_CASE["name"],
        "image": VEGETABLE_CASE["image"],
        "image_size": [image.width, image.height],
        "raw_instance_count": len(raw_instances),
        "merged_class_count": len(clean_merged),
        "total_seconds": round(time.perf_counter() - started, 3),
        "prompt_summaries": prompt_summaries,
        "merged": clean_merged,
        "raw_image": str(raw_path),
        "merged_image": str(merged_path),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


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
    parser.add_argument("--max-per-prompt", type=int, default=8)
    parser.add_argument("--min-component-area", type=int, default=120)
    args = parser.parse_args()
    summary = run(args)
    print(json.dumps({k: summary[k] for k in ["raw_instance_count", "merged_class_count", "total_seconds", "merged_image"]}, ensure_ascii=False, indent=2))
    for item in summary["merged"]:
        print(item["prompt"], item["instance_count"], "->", item["component_count"], item["merged_area_ratio"], item["bbox_xyxy"])


if __name__ == "__main__":
    main()
