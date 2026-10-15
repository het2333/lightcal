#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
from PIL import Image, ImageDraw
from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
from sam2.build_sam import build_sam2


DEFAULT_TARGET_ITEMS = [
    {
        "name_zh": "薯条",
        "phrases": ["french fries", "fries", "potato fries"],
    },
    {
        "name_zh": "蛋挞",
        "phrases": ["egg tart", "custard tart", "tart"],
    },
    {
        "name_zh": "炸鸡",
        "phrases": ["fried chicken", "chicken nugget", "fried chicken pieces", "fried meat", "fried food"],
    },
    {
        "name_zh": "咖喱角",
        "phrases": ["curry puff", "fried pastry", "triangle pastry", "turnover", "fried snack"],
    },
]

SAM2_GENERATOR_CACHE: dict[tuple[str, int, int], SAM2AutomaticMaskGenerator] = {}


def load_targets(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        raw_targets = DEFAULT_TARGET_ITEMS
    else:
        raw_targets = json.loads(path.read_text(encoding="utf-8"))
    targets: list[dict[str, Any]] = []
    for item in raw_targets:
        phrases: list[str] = []
        for key in ("detector_phrase", "phrase"):
            value = str(item.get(key) or "").strip()
            if value:
                phrases.append(value)
        for value in item.get("phrases") or []:
            value = str(value or "").strip()
            if value:
                phrases.append(value)
        for value in item.get("aliases") or []:
            value = str(value or "").strip()
            if value:
                phrases.append(value)
        deduped: list[str] = []
        seen: set[str] = set()
        for phrase in phrases:
            key = phrase.lower()
            if key in seen:
                continue
            seen.add(key)
            deduped.append(phrase)
        name = str(item.get("name_zh") or item.get("name") or item.get("label") or "").strip()
        if name and deduped:
            targets.append({"name_zh": name, "phrases": deduped})
    return targets


def xywh_to_xyxy(bbox: list[int | float]) -> list[float]:
    x, y, w, h = [float(v) for v in bbox]
    return [x, y, x + w, y + h]


def bbox_iou(a: list[float], b: list[float]) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    return inter / max(area_a + area_b - inter, 1.0)


def mask_bbox(mask: np.ndarray) -> list[float]:
    ys, xs = np.where(mask)
    if len(xs) == 0 or len(ys) == 0:
        return [0.0, 0.0, 0.0, 0.0]
    return [float(xs.min()), float(ys.min()), float(xs.max() + 1), float(ys.max() + 1)]


def mask_inside_bbox_ratio(mask: np.ndarray, bbox: list[float]) -> float:
    x1, y1, x2, y2 = [int(round(v)) for v in bbox]
    h, w = mask.shape
    x1, x2 = max(0, min(w, x1)), max(0, min(w, x2))
    y1, y2 = max(0, min(h, y1)), max(0, min(h, y2))
    area = int(mask.sum())
    if area <= 0 or x2 <= x1 or y2 <= y1:
        return 0.0
    return float(mask[y1:y2, x1:x2].sum()) / area


def scale_box(box: list[float], sx: float, sy: float) -> list[float]:
    x1, y1, x2, y2 = box
    return [x1 * sx, y1 * sy, x2 * sx, y2 * sy]


def generate_masks(image: Image.Image, device: str, points_per_side: int, crop_n_layers: int) -> list[dict[str, Any]]:
    cache_key = (device, points_per_side, crop_n_layers)
    generator = SAM2_GENERATOR_CACHE.get(cache_key)
    if generator is None:
        model = build_sam2(
            "configs/sam2.1/sam2.1_hiera_t.yaml",
            "/root/autodl-tmp/sam2-checkpoints/sam2.1_hiera_tiny.pt",
            device=device,
        )
        generator = SAM2AutomaticMaskGenerator(
            model,
            points_per_side=points_per_side,
            points_per_batch=64,
            pred_iou_thresh=0.72,
            stability_score_thresh=0.82,
            box_nms_thresh=0.65,
            crop_n_layers=crop_n_layers,
            crop_n_points_downscale_factor=2,
            min_mask_region_area=400,
            output_mode="binary_mask",
        )
        SAM2_GENERATOR_CACHE[cache_key] = generator
    with torch.inference_mode():
        raw_masks = generator.generate(np.array(image))
    masks: list[dict[str, Any]] = []
    image_area = image.width * image.height
    for raw_index, item in enumerate(raw_masks):
        mask = np.asarray(item.get("segmentation")).astype(bool)
        area = int(item.get("area") or mask.sum())
        if area < 500 or area > image_area * 0.65:
            continue
        bbox = xywh_to_xyxy(item.get("bbox", [0, 0, 0, 0]))
        masks.append(
            {
                "mask_id": len(masks) + 1,
                "raw_index": raw_index,
                "area": area,
                "area_ratio": round(area / max(image_area, 1), 5),
                "bbox_xyxy": bbox,
                "pred_iou": round(float(item.get("predicted_iou") or 0), 4),
                "stability": round(float(item.get("stability_score") or 0), 4),
                "_mask": mask,
            }
        )
    return masks


def phrase_target_score(label: str, target: dict[str, Any]) -> float:
    label_tokens = set(label.lower().replace("-", " ").split())
    if not label_tokens:
        return 0.0
    best = 0.0
    for phrase in target["phrases"]:
        phrase_tokens = set(phrase.lower().replace("-", " ").split())
        if not phrase_tokens:
            continue
        overlap = len(label_tokens & phrase_tokens)
        score = overlap / max(len(phrase_tokens), 1)
        if phrase.lower() in label.lower():
            score += 0.35
        best = max(best, score)
    return best


def best_target_for_label(label: str, targets: list[dict[str, Any]]) -> dict[str, Any] | None:
    aliases = {
        "薯条": ["fries", "french fries"],
        "蛋挞": ["egg tart", "tart"],
        "炸鸡": ["chicken", "nugget", "meat"],
        "咖喱角": ["puff", "pastry", "turnover"],
    }
    lower = label.lower()
    for target in targets:
        if any(alias in lower for alias in aliases.get(target["name_zh"], [])):
            return target
    scored = [(phrase_target_score(label, target), target) for target in targets]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    if scored and scored[0][0] >= 0.45:
        return scored[0][1]
    return None


def combined_detector_prompt(targets: list[dict[str, Any]]) -> str:
    phrases: list[str] = []
    seen: set[str] = set()
    for target in targets:
        for phrase in target["phrases"]:
            key = phrase.lower()
            if key in seen:
                continue
            seen.add(key)
            phrases.append(phrase)
    return " . ".join(phrases)


def dino_detections_combined(image: Image.Image, targets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    import server

    prompt = combined_detector_prompt(targets)
    found = server.detect_objects(image, prompt, box_threshold=0.18, text_threshold=0.15)
    detections = []
    for det in found:
        if not det.get("bbox_xyxy"):
            continue
        label = det.get("phrase") or ""
        target = best_target_for_label(label, targets)
        if target is None:
            continue
        detections.append(
            {
                "target": target["name_zh"],
                "phrase_query": "combined",
                "combined_prompt": prompt,
                "phrase": label,
                "score": float(det.get("score") or 0.0),
                "bbox_xyxy": [float(v) for v in det.get("bbox_xyxy")],
            }
        )
    return detections


def dino_detections_per_phrase(image: Image.Image, targets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    import server

    detections = []
    for target in targets:
        for phrase in target["phrases"]:
            try:
                found = server.detect_objects(image, phrase, box_threshold=0.18, text_threshold=0.15)
            except Exception as exc:
                detections.append({"target": target["name_zh"], "phrase_query": phrase, "error": f"{type(exc).__name__}: {exc}"})
                continue
            for det in found:
                if not det.get("bbox_xyxy"):
                    continue
                detections.append(
                    {
                        "target": target["name_zh"],
                        "phrase_query": phrase,
                        "phrase": det.get("phrase") or "",
                        "score": float(det.get("score") or 0.0),
                        "bbox_xyxy": [float(v) for v in det.get("bbox_xyxy")],
                    }
                )
    return detections


def score_mask_candidates(masks: list[dict[str, Any]], detections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for detection in detections:
        box = detection.get("bbox_xyxy")
        target = detection.get("target")
        if not box or not target:
            continue
        for mask in masks:
            mask_box = mask["bbox_xyxy"]
            iou = bbox_iou(mask_box, box)
            inside = mask_inside_bbox_ratio(mask["_mask"], box)
            score = float(detection.get("score") or 0.0) * 0.5 + iou * 0.35 + inside * 0.15
            if iou < 0.02 and inside < 0.2:
                continue
            candidates.append(
                {
                    "target": target,
                    "mask_id": mask["mask_id"],
                    "mask_area": mask["area"],
                    "mask_area_ratio": mask["area_ratio"],
                    "mask_bbox_xyxy": [round(v, 1) for v in mask_box],
                    "dino_phrase_query": detection.get("phrase_query"),
                    "dino_phrase": detection.get("phrase"),
                    "dino_score": round(float(detection.get("score") or 0.0), 4),
                    "dino_bbox_xyxy": [round(float(v), 1) for v in box],
                    "bbox_iou": round(iou, 4),
                    "mask_inside_dino_bbox": round(inside, 4),
                    "match_score": round(score, 4),
                }
            )
    return candidates


def best_match_per_target(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    matches: dict[str, Any] = {}
    for candidate in candidates:
        target = candidate["target"]
        current = matches.get(target)
        if current is None or candidate["match_score"] > current["match_score"]:
            matches[target] = candidate
    return matches


def unique_match_per_mask(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    matches: dict[str, Any] = {}
    used_masks: set[int] = set()
    used_targets: set[str] = set()
    for candidate in sorted(candidates, key=lambda item: item["match_score"], reverse=True):
        target = candidate["target"]
        mask_id = int(candidate["mask_id"])
        if target in used_targets or mask_id in used_masks:
            continue
        matches[target] = candidate
        used_targets.add(target)
        used_masks.add(mask_id)
    return matches


def draw_result(image: Image.Image, masks: list[dict[str, Any]], matches: dict[str, Any], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(11)
    for target, match in matches.items():
        mask = next((m["_mask"] for m in masks if m["mask_id"] == match["mask_id"]), None)
        if mask is None:
            continue
        color = tuple(random.randint(40, 240) for _ in range(3)) + (100,)
        mask_img = Image.fromarray((mask.astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color)
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = match["mask_bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color[:3] + (255,), width=4)
        draw.text((x1 + 4, y1 + 4), f"{target} #{match['mask_id']}", fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--points-per-side", type=int, default=12)
    parser.add_argument("--crop-n-layers", type=int, default=0)
    parser.add_argument("--dino-mode", choices=["combined", "per_phrase"], default="combined")
    parser.add_argument("--targets-json", type=Path)
    args = parser.parse_args()

    started = time.perf_counter()
    timings: dict[str, float] = {}
    args.out_dir.mkdir(parents=True, exist_ok=True)
    targets = load_targets(args.targets_json)
    if not targets:
        raise SystemExit("No targets were provided.")
    original = Image.open(args.image).convert("RGB")
    image = original.copy()
    if args.max_edge > 0:
        image.thumbnail((args.max_edge, args.max_edge))
    sx = image.width / original.width
    sy = image.height / original.height

    t0 = time.perf_counter()
    masks = generate_masks(image, args.device, args.points_per_side, args.crop_n_layers)
    timings["sam2_seconds"] = round(time.perf_counter() - t0, 3)
    t0 = time.perf_counter()
    if args.dino_mode == "per_phrase":
        detections = dino_detections_per_phrase(image, targets)
    else:
        detections = dino_detections_combined(image, targets)
    timings["dino_seconds"] = round(time.perf_counter() - t0, 3)
    t0 = time.perf_counter()
    candidates = score_mask_candidates(masks, detections)
    raw_matches = best_match_per_target(candidates)
    unique_matches = unique_match_per_mask(candidates)
    timings["match_seconds"] = round(time.perf_counter() - t0, 3)
    timings["total_seconds"] = round(time.perf_counter() - started, 3)
    raw_result_image = args.out_dir / "sam2_first_dino_filter_raw_matches.jpg"
    unique_result_image = args.out_dir / "sam2_first_dino_filter_unique_matches.jpg"
    draw_result(image, masks, raw_matches, raw_result_image)
    draw_result(image, masks, unique_matches, unique_result_image)

    clean_masks = [{k: v for k, v in m.items() if k != "_mask"} for m in masks]
    raw_mask_ids = [match["mask_id"] for match in raw_matches.values()]
    duplicate_mask_ids = sorted({mask_id for mask_id in raw_mask_ids if raw_mask_ids.count(mask_id) > 1})
    output = {
        "image": str(args.image),
        "scaled_image_size": [image.width, image.height],
        "scale": [sx, sy],
        "targets": targets,
        "target_count": len(targets),
        "mask_count": len(masks),
        "dino_mode": args.dino_mode,
        "dino_detection_count": len([d for d in detections if d.get("bbox_xyxy")]),
        "candidate_count": len(candidates),
        "timings": timings,
        "detections": detections,
        "raw_matches": raw_matches,
        "raw_unmatched_targets": [t["name_zh"] for t in targets if t["name_zh"] not in raw_matches],
        "duplicate_mask_ids_in_raw_matches": duplicate_mask_ids,
        "unique_matches": unique_matches,
        "unique_unmatched_targets": [t["name_zh"] for t in targets if t["name_zh"] not in unique_matches],
        "top_candidates": sorted(candidates, key=lambda item: item["match_score"], reverse=True)[:80],
        "masks": clean_masks[:80],
        "raw_result_image": str(raw_result_image),
        "unique_result_image": str(unique_result_image),
    }
    summary_path = args.out_dir / "summary.json"
    summary_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        json.dumps(
            {
                k: output[k]
                for k in (
                    "target_count",
                    "mask_count",
                    "dino_mode",
                    "dino_detection_count",
                    "candidate_count",
                    "timings",
                    "raw_matches",
                    "raw_unmatched_targets",
                    "duplicate_mask_ids_in_raw_matches",
                    "unique_matches",
                    "unique_unmatched_targets",
                    "raw_result_image",
                    "unique_result_image",
                )
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
