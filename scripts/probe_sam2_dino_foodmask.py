#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw

import probe_sam2_first_dino_filter as shared


FOOD_PROMPT = (
    "rice . noodles . pasta . meat . chicken . fish . shrimp . seafood . vegetable . fruit . "
    "soup . drink . beverage . dessert . bread . pastry . snack . fried food . cooked food . dish . meal"
)


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.logical_and(a, b).sum())
    union = int(np.logical_or(a, b).sum())
    if union <= 0:
        return 0.0
    return inter / union


def bbox_area(box: list[float]) -> float:
    x1, y1, x2, y2 = box
    return max(0.0, x2 - x1) * max(0.0, y2 - y1)


def dino_food_detections(image: Image.Image, prompt: str) -> list[dict[str, Any]]:
    import server

    detections = server.detect_objects(image, prompt, box_threshold=0.16, text_threshold=0.12)
    output: list[dict[str, Any]] = []
    for det in detections:
        box = det.get("bbox_xyxy")
        if not box:
            continue
        output.append(
            {
                "detection_id": det.get("detection_id") or f"det_{len(output)+1}",
                "phrase": det.get("phrase") or "",
                "score": float(det.get("score") or 0.0),
                "bbox_xyxy": [float(v) for v in box],
            }
        )
    return output


def candidate_food_masks(
    masks: list[dict[str, Any]],
    detections: list[dict[str, Any]],
    image_area: int,
    max_candidates: int,
) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for mask in masks:
        mask_arr = mask["_mask"]
        mask_area = int(mask["area"])
        mask_box = mask["bbox_xyxy"]
        mask_area_ratio = mask_area / max(image_area, 1)
        if mask_area_ratio < 0.0015 or mask_area_ratio > 0.22:
            continue
        best: dict[str, Any] | None = None
        for det in detections:
            det_box = det["bbox_xyxy"]
            iou = shared.bbox_iou(mask_box, det_box)
            inside = shared.mask_inside_bbox_ratio(mask_arr, det_box)
            fill = mask_area / max(bbox_area(det_box), 1.0)
            if iou < 0.035 and inside < 0.45:
                continue
            if inside > 0.92 and fill < 0.015:
                continue
            score = (
                0.34 * iou
                + 0.22 * inside
                + 0.22 * float(det.get("score") or 0.0)
                + 0.12 * float(mask.get("pred_iou") or 0.0)
                + 0.10 * min(fill, 1.0)
            )
            if mask_area_ratio < 0.004:
                score -= 0.04
            item = {
                "mask_id": mask["mask_id"],
                "raw_index": mask.get("raw_index"),
                "mask_area": mask_area,
                "mask_area_ratio": round(mask_area_ratio, 5),
                "mask_bbox_xyxy": [round(v, 1) for v in mask_box],
                "mask_pred_iou": mask.get("pred_iou"),
                "mask_stability": mask.get("stability"),
                "dino_detection_id": det.get("detection_id"),
                "dino_phrase": det.get("phrase") or "",
                "dino_score": round(float(det.get("score") or 0.0), 4),
                "dino_bbox_xyxy": [round(v, 1) for v in det_box],
                "bbox_iou": round(iou, 4),
                "mask_inside_dino_bbox": round(inside, 4),
                "mask_bbox_fill_ratio": round(fill, 4),
                "food_mask_score": round(score, 4),
                "_mask": mask_arr,
            }
            if best is None or item["food_mask_score"] > best["food_mask_score"]:
                best = item
        if best is not None:
            candidates.append(best)

    selected: list[dict[str, Any]] = []
    used_masks: list[np.ndarray] = []
    for candidate in sorted(candidates, key=lambda item: item["food_mask_score"], reverse=True):
        mask = candidate["_mask"]
        if any(mask_iou(mask, used) > 0.42 for used in used_masks):
            continue
        selected.append(candidate)
        used_masks.append(mask)
        if len(selected) >= max_candidates:
            break
    return selected


def crop_candidate(image: Image.Image, candidate: dict[str, Any], output_path: Path, pad_ratio: float = 0.18) -> None:
    x1, y1, x2, y2 = [float(v) for v in candidate["mask_bbox_xyxy"]]
    w, h = x2 - x1, y2 - y1
    pad = max(w, h) * pad_ratio
    left = max(0, int(x1 - pad))
    top = max(0, int(y1 - pad))
    right = min(image.width, int(x2 + pad))
    bottom = min(image.height, int(y2 + pad))
    crop = image.crop((left, top, right, bottom)).convert("RGB")
    draw = ImageDraw.Draw(crop)
    draw.rectangle([int(x1 - left), int(y1 - top), int(x2 - left), int(y2 - top)], outline=(35, 132, 255), width=3)
    crop.save(output_path, quality=92)


def draw_candidates(image: Image.Image, candidates: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(23)
    for idx, candidate in enumerate(candidates, start=1):
        mask = candidate["_mask"]
        color = tuple(random.randint(40, 235) for _ in range(3)) + (86,)
        mask_img = Image.fromarray((mask.astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color)
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = candidate["mask_bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color[:3] + (255,), width=3)
        label = f"#{idx} {candidate['dino_phrase']} {candidate['food_mask_score']:.2f}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def run_case(case: dict[str, Any], out_root: Path, args: argparse.Namespace) -> dict[str, Any]:
    name = case["name"]
    out_dir = out_root / name
    crop_dir = out_dir / "crops"
    crop_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    timings: dict[str, float] = {}

    original = Image.open(case["image"]).convert("RGB")
    image = original.copy()
    if args.max_edge > 0:
        image.thumbnail((args.max_edge, args.max_edge))
    image_area = image.width * image.height

    t0 = time.perf_counter()
    masks = shared.generate_masks(image, args.device, args.points_per_side, args.crop_n_layers)
    timings["sam2_seconds"] = round(time.perf_counter() - t0, 3)

    t0 = time.perf_counter()
    detections = dino_food_detections(image, args.food_prompt)
    timings["dino_seconds"] = round(time.perf_counter() - t0, 3)

    t0 = time.perf_counter()
    selected = candidate_food_masks(masks, detections, image_area, args.max_candidates)
    timings["match_seconds"] = round(time.perf_counter() - t0, 3)

    annotated = out_dir / "food_mask_candidates.jpg"
    draw_candidates(image, selected, annotated)

    clean_candidates = []
    for idx, candidate in enumerate(selected, start=1):
        crop_path = crop_dir / f"candidate_{idx:02d}_mask{candidate['mask_id']}.jpg"
        crop_candidate(image, candidate, crop_path)
        public = {key: value for key, value in candidate.items() if key != "_mask"}
        public.update({"candidate_index": idx, "crop_path": str(crop_path)})
        clean_candidates.append(public)

    timings["total_seconds"] = round(time.perf_counter() - started, 3)
    summary = {
        "name": name,
        "image": case["image"],
        "scaled_image_size": [image.width, image.height],
        "food_prompt": args.food_prompt,
        "mask_count": len(masks),
        "dino_detection_count": len(detections),
        "candidate_count": len(clean_candidates),
        "timings": timings,
        "detections": detections,
        "candidates": clean_candidates,
        "annotated_image": str(annotated),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases-json", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--points-per-side", type=int, default=12)
    parser.add_argument("--crop-n-layers", type=int, default=0)
    parser.add_argument("--max-candidates", type=int, default=8)
    parser.add_argument("--food-prompt", default=FOOD_PROMPT)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    cases = json.loads(args.cases_json.read_text(encoding="utf-8"))
    summaries = []
    for case in cases:
        print(f"=== {case['name']} ===", flush=True)
        summary = run_case(case, args.out_dir, args)
        summaries.append(summary)
        print(
            json.dumps(
                {
                    "name": summary["name"],
                    "mask_count": summary["mask_count"],
                    "dino_detection_count": summary["dino_detection_count"],
                    "candidate_count": summary["candidate_count"],
                    "timings": summary["timings"],
                    "top_candidates": summary["candidates"][:5],
                    "annotated_image": summary["annotated_image"],
                },
                ensure_ascii=False,
                indent=2,
            ),
            flush=True,
        )

    table = [
        {
            "name": item["name"],
            "mask_count": item["mask_count"],
            "dino_detection_count": item["dino_detection_count"],
            "candidate_count": item["candidate_count"],
            "sam2_seconds": item["timings"]["sam2_seconds"],
            "dino_seconds": item["timings"]["dino_seconds"],
            "total_seconds": item["timings"]["total_seconds"],
            "annotated_image": item["annotated_image"],
        }
        for item in summaries
    ]
    (args.out_dir / "batch_summary.json").write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    print("=== batch_summary ===")
    print(json.dumps(table, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
