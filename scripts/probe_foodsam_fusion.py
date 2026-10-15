#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont
from segment_anything import SamAutomaticMaskGenerator, sam_model_registry
from transformers import AutoImageProcessor, UperNetForSemanticSegmentation


@dataclass
class Case:
    case_id: str
    image_path: Path


CASES = [
    Case("rgb_vegetable_board", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/vegetable_board/rgb.jpg")),
    Case("rgb_fried_platter", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg")),
    Case("rgb_cafeteria_meal", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg")),
    Case("rgb_img6388", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg")),
    Case("depth_cola_can", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_cab838efdd31/rgb.jpg")),
    Case("depth_pot_bowl", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_19d514014ff4/rgb.jpg")),
]


def load_font(size: int = 16) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def resize_for_max_edge(image: Image.Image, max_edge: int) -> Image.Image:
    if max(image.size) <= max_edge:
        return image
    resized = image.copy()
    resized.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return resized


def palette(index: int) -> tuple[int, int, int]:
    rng = np.random.default_rng(index * 1009 + 17)
    return tuple(int(x) for x in rng.integers(50, 235, size=3))


def colorize_labels(label_mask: np.ndarray, alpha: float = 0.58) -> np.ndarray:
    h, w = label_mask.shape
    color = np.zeros((h, w, 3), dtype=np.uint8)
    for label in np.unique(label_mask):
        if int(label) == 0:
            continue
        color[label_mask == label] = palette(int(label))
    return color


def overlay(base: Image.Image, label_mask: np.ndarray, alpha: float = 0.5) -> Image.Image:
    base_arr = np.asarray(base.convert("RGB")).astype(np.float32)
    colors = colorize_labels(label_mask).astype(np.float32)
    active = label_mask != 0
    out = base_arr.copy()
    out[active] = base_arr[active] * (1.0 - alpha) + colors[active] * alpha
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def semantic_predict(
    image: Image.Image,
    processor: AutoImageProcessor,
    model: UperNetForSemanticSegmentation,
    device: torch.device,
) -> tuple[np.ndarray, float]:
    started = time.time()
    inputs = processor(images=image, return_tensors="pt")
    inputs = {k: v.to(device) for k, v in inputs.items()}
    with torch.no_grad():
        outputs = model(**inputs)
    logits = outputs.logits
    logits = torch.nn.functional.interpolate(
        logits,
        size=(image.height, image.width),
        mode="bilinear",
        align_corners=False,
    )
    labels = logits.argmax(dim=1)[0].detach().cpu().numpy().astype(np.uint8)
    return labels, time.time() - started


def sam_generate(
    image: Image.Image,
    generator: SamAutomaticMaskGenerator,
) -> tuple[list[dict[str, Any]], float]:
    started = time.time()
    masks = generator.generate(np.asarray(image.convert("RGB")))
    return masks, time.time() - started


def bbox_from_mask(mask: np.ndarray) -> list[int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def fuse_foodsam_style(
    semantic_mask: np.ndarray,
    sam_masks: list[dict[str, Any]],
    id2label: dict[int, str],
    ratio_thr: float,
    min_area_ratio: float,
    max_area_ratio: float,
    top_k: int,
) -> tuple[np.ndarray, list[dict[str, Any]]]:
    h, w = semantic_mask.shape
    image_area = float(h * w)
    enhanced = semantic_mask.copy()
    accepted: list[dict[str, Any]] = []

    sorted_masks = sorted(sam_masks, key=lambda m: int(m.get("area") or 0), reverse=True)[:top_k]
    for idx, item in enumerate(sorted_masks):
        mask = np.asarray(item["segmentation"]).astype(bool)
        area_ratio = float(mask.sum()) / image_area
        if area_ratio < min_area_ratio or area_ratio > max_area_ratio:
            continue
        labels = semantic_mask[mask]
        labels = labels[labels != 0]
        if labels.size == 0:
            continue
        values, counts = np.unique(labels, return_counts=True)
        best_i = int(np.argmax(counts))
        label = int(values[best_i])
        vote_ratio = float(counts[best_i]) / float(mask.sum())
        if vote_ratio < ratio_thr:
            continue
        enhanced[mask] = label
        accepted.append(
            {
                "sam_index": idx,
                "label_id": label,
                "label": id2label.get(label, str(label)),
                "vote_ratio": round(vote_ratio, 4),
                "area_ratio": round(area_ratio, 5),
                "predicted_iou": round(float(item.get("predicted_iou") or 0.0), 4),
                "stability_score": round(float(item.get("stability_score") or 0.0), 4),
                "bbox_xyxy": bbox_from_mask(mask),
            }
        )
    return enhanced, accepted


def summarize_labels(label_mask: np.ndarray, id2label: dict[int, str], min_area_ratio: float = 0.001) -> list[dict[str, Any]]:
    h, w = label_mask.shape
    image_area = float(h * w)
    rows: list[dict[str, Any]] = []
    for label in sorted(int(v) for v in np.unique(label_mask) if int(v) != 0):
        mask = label_mask == label
        area_ratio = float(mask.sum()) / image_area
        if area_ratio < min_area_ratio:
            continue
        num, comp = cv2.connectedComponents(mask.astype(np.uint8), connectivity=8)
        comp_count = max(0, num - 1)
        rows.append(
            {
                "label_id": label,
                "label": id2label.get(label, str(label)),
                "area_ratio": round(area_ratio, 5),
                "component_count": comp_count,
                "bbox_xyxy": bbox_from_mask(mask),
            }
        )
    rows.sort(key=lambda r: r["area_ratio"], reverse=True)
    return rows


def draw_boxes(image: Image.Image, rows: list[dict[str, Any]]) -> Image.Image:
    out = image.copy().convert("RGB")
    draw = ImageDraw.Draw(out)
    font = load_font(14)
    for row in rows[:16]:
        color = palette(int(row["label_id"]))
        x1, y1, x2, y2 = row["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color, width=3)
        label = f"{row['label']} {row['area_ratio']:.1%}"
        tw = draw.textlength(label, font=font)
        draw.rectangle([x1, max(0, y1 - 18), x1 + tw + 6, y1], fill=color)
        draw.text((x1 + 3, max(0, y1 - 17)), label, fill=(0, 0, 0), font=font)
    return out


def make_contact_sheet(image_paths: list[Path], output_path: Path, tile_w: int = 420) -> None:
    images = []
    font = load_font(16)
    for path in image_paths:
        img = Image.open(path).convert("RGB")
        scale = tile_w / img.width
        tile_h = max(1, int(img.height * scale))
        img = img.resize((tile_w, tile_h), Image.LANCZOS)
        canvas = Image.new("RGB", (tile_w, tile_h + 26), "white")
        canvas.paste(img, (0, 26))
        ImageDraw.Draw(canvas).text((4, 4), path.parent.name + "/" + path.name, fill=(0, 0, 0), font=font)
        images.append(canvas)
    if not images:
        return
    cols = 2
    rows = math.ceil(len(images) / cols)
    gutter = 20
    row_heights = [max(images[i].height for i in range(r * cols, min((r + 1) * cols, len(images)))) for r in range(rows)]
    sheet = Image.new("RGB", (cols * tile_w + (cols - 1) * gutter, sum(row_heights) + (rows - 1) * gutter), "white")
    y = 0
    for r in range(rows):
        x = 0
        for c in range(cols):
            idx = r * cols + c
            if idx < len(images):
                sheet.paste(images[idx], (x, y))
            x += tile_w + gutter
        y += row_heights[r] + gutter
    sheet.save(output_path, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=Path("/root/autodl-tmp/FoodSAM/ckpts/hf_mccaly_test2"))
    parser.add_argument("--sam-checkpoint", type=Path, default=Path("/root/autodl-tmp/FoodSAM/ckpts/sam_vit_h_4b8939.pth"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_fusion_20260704"))
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--points-per-side", type=int, default=24)
    parser.add_argument("--points-per-batch", type=int, default=32)
    parser.add_argument("--ratio-thr", type=float, default=0.45)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.60)
    parser.add_argument("--top-k", type=int, default=80)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    processor = AutoImageProcessor.from_pretrained(args.model_dir, local_files_only=True)
    semantic_model = UperNetForSemanticSegmentation.from_pretrained(args.model_dir, local_files_only=True).to(device).eval()
    id2label = {int(k): v for k, v in semantic_model.config.id2label.items()}

    sam = sam_model_registry["vit_h"](checkpoint=str(args.sam_checkpoint)).to(device=device).eval()
    generator = SamAutomaticMaskGenerator(
        sam,
        points_per_side=args.points_per_side,
        points_per_batch=args.points_per_batch,
        pred_iou_thresh=0.86,
        stability_score_thresh=0.90,
        crop_n_layers=0,
        min_mask_region_area=100,
    )

    summaries = []
    contact_images: list[Path] = []
    for case in CASES:
        case_dir = args.out_dir / case.case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        image = resize_for_max_edge(Image.open(case.image_path).convert("RGB"), args.max_edge)
        image.save(case_dir / "input.jpg", quality=95)

        semantic_mask, semantic_seconds = semantic_predict(image, processor, semantic_model, device)
        sam_masks, sam_seconds = sam_generate(image, generator)
        enhanced_mask, accepted = fuse_foodsam_style(
            semantic_mask,
            sam_masks,
            id2label,
            ratio_thr=args.ratio_thr,
            min_area_ratio=args.min_area_ratio,
            max_area_ratio=args.max_area_ratio,
            top_k=args.top_k,
        )
        semantic_rows = summarize_labels(semantic_mask, id2label)
        enhanced_rows = summarize_labels(enhanced_mask, id2label)

        np.save(case_dir / "semantic_mask.npy", semantic_mask)
        np.save(case_dir / "foodsam_fused_mask.npy", enhanced_mask)
        overlay(image, semantic_mask).save(case_dir / "semantic_overlay.jpg", quality=92)
        overlay(image, enhanced_mask).save(case_dir / "foodsam_fused_overlay.jpg", quality=92)
        draw_boxes(overlay(image, enhanced_mask), enhanced_rows).save(case_dir / "foodsam_fused_boxes.jpg", quality=92)
        contact_images.extend([case_dir / "semantic_overlay.jpg", case_dir / "foodsam_fused_boxes.jpg"])

        row = {
            "case_id": case.case_id,
            "image_path": str(case.image_path),
            "image_size": list(image.size),
            "semantic_seconds": round(semantic_seconds, 3),
            "sam_seconds": round(sam_seconds, 3),
            "sam_raw_count": len(sam_masks),
            "sam_accepted_count": len(accepted),
            "semantic_labels": semantic_rows,
            "foodsam_fused_labels": enhanced_rows,
            "accepted_sam_masks": accepted[:40],
        }
        (case_dir / "summary.json").write_text(json.dumps(row, ensure_ascii=False, indent=2), encoding="utf-8")
        summaries.append(row)
        print(json.dumps({
            "case_id": case.case_id,
            "semantic_seconds": row["semantic_seconds"],
            "sam_seconds": row["sam_seconds"],
            "sam_raw_count": row["sam_raw_count"],
            "sam_accepted_count": row["sam_accepted_count"],
            "labels": [x["label"] for x in enhanced_rows[:12]],
        }, ensure_ascii=False), flush=True)

    (args.out_dir / "batch_summary.json").write_text(json.dumps(summaries, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(contact_images, args.out_dir / "foodsam_fusion_contact_sheet.jpg")
    print(f"saved={args.out_dir}", flush=True)


if __name__ == "__main__":
    main()
