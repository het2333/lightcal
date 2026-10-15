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
from mmcv import Config
from mmseg.apis import init_segmentor, inference_segmentor
from PIL import Image, ImageDraw, ImageFont
from segment_anything import SamAutomaticMaskGenerator, sam_model_registry


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


def load_categories(path: Path) -> dict[int, str]:
    labels: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[0].strip().isdigit():
            labels[int(parts[0])] = parts[1].strip()
    return labels


def resize_for_max_edge(image: Image.Image, max_edge: int) -> Image.Image:
    if max(image.size) <= max_edge:
        return image
    resized = image.copy()
    resized.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return resized


def palette(index: int) -> tuple[int, int, int]:
    rng = np.random.default_rng(index * 997 + 23)
    return tuple(int(x) for x in rng.integers(50, 235, size=3))


def overlay(base: Image.Image, label_mask: np.ndarray, alpha: float = 0.52) -> Image.Image:
    base_arr = np.asarray(base.convert("RGB")).astype(np.float32)
    color = np.zeros((*label_mask.shape, 3), dtype=np.float32)
    for label in np.unique(label_mask):
        if int(label) == 0:
            continue
        color[label_mask == label] = palette(int(label))
    active = label_mask != 0
    out = base_arr.copy()
    out[active] = base_arr[active] * (1.0 - alpha) + color[active] * alpha
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def bbox_from_mask(mask: np.ndarray) -> list[int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def semantic_predict_to_mask(model: torch.nn.Module, image: Image.Image, temp_path: Path) -> tuple[np.ndarray, float]:
    temp_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(temp_path, quality=95)
    started = time.time()
    result = inference_segmentor(model, str(temp_path))
    return result[0].astype(np.uint8), time.time() - started


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
        best = int(np.argmax(counts))
        label = int(values[best])
        vote_ratio = float(counts[best]) / float(mask.sum())
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
                "bbox_xyxy": bbox_from_mask(mask),
                "predicted_iou": round(float(item.get("predicted_iou") or 0), 4),
                "stability_score": round(float(item.get("stability_score") or 0), 4),
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
        comp_count = max(0, int(cv2.connectedComponents(mask.astype(np.uint8), connectivity=8)[0]) - 1)
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
    for row in rows[:18]:
        color = palette(int(row["label_id"]))
        x1, y1, x2, y2 = row["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color, width=3)
        text = f"{row['label']} {row['area_ratio']:.1%}"
        width = draw.textlength(text, font=font)
        y0 = max(0, y1 - 18)
        draw.rectangle([x1, y0, x1 + width + 6, y0 + 18], fill=color)
        draw.text((x1 + 3, y0 + 1), text, fill=(0, 0, 0), font=font)
    return out


def make_contact_sheet(paths: list[Path], output_path: Path, tile_w: int = 420) -> None:
    font = load_font(16)
    tiles = []
    for path in paths:
        image = Image.open(path).convert("RGB")
        scale = tile_w / image.width
        tile_h = max(1, int(image.height * scale))
        image = image.resize((tile_w, tile_h), Image.LANCZOS)
        tile = Image.new("RGB", (tile_w, tile_h + 26), "white")
        tile.paste(image, (0, 26))
        ImageDraw.Draw(tile).text((4, 4), path.parent.name + "/" + path.name, fill=(0, 0, 0), font=font)
        tiles.append(tile)
    if not tiles:
        return
    cols = 2
    rows = math.ceil(len(tiles) / cols)
    gutter = 20
    row_heights = [max(tiles[i].height for i in range(r * cols, min((r + 1) * cols, len(tiles)))) for r in range(rows)]
    sheet = Image.new("RGB", (cols * tile_w + gutter, sum(row_heights) + (rows - 1) * gutter), "white")
    y = 0
    for r in range(rows):
        x = 0
        for c in range(cols):
            idx = r * cols + c
            if idx < len(tiles):
                sheet.paste(tiles[idx], (x, y))
            x += tile_w + gutter
        y += row_heights[r] + gutter
    sheet.save(output_path, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("/root/autodl-tmp/FoodSAM/configs/SETR_MLA_768x768_80k_base_official.py"))
    parser.add_argument("--checkpoint", type=Path, default=Path("/root/autodl-tmp/FoodSAM/ckpts/SETR_MLA/iter_80000.pth"))
    parser.add_argument("--sam-checkpoint", type=Path, default=Path("/root/autodl-tmp/FoodSAM/ckpts/sam_vit_h_4b8939.pth"))
    parser.add_argument("--category-txt", type=Path, default=Path("/root/autodl-tmp/FoodSAM/FoodSAM/FoodSAM_tools/category_id_files/foodseg103_category_id.txt"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_official_fusion_20260704"))
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--points-per-side", type=int, default=24)
    parser.add_argument("--points-per-batch", type=int, default=32)
    parser.add_argument("--ratio-thr", type=float, default=0.50)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.60)
    parser.add_argument("--top-k", type=int, default=80)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    id2label = load_categories(args.category_txt)

    cfg = Config.fromfile(str(args.config))
    cfg.model.pretrained = None
    cfg.model.backbone.random_init = True
    started = time.time()
    semantic_model = init_segmentor(cfg, str(args.checkpoint), device=device)
    semantic_init_seconds = time.time() - started

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

    summaries: list[dict[str, Any]] = []
    contact_paths: list[Path] = []
    for case in CASES:
        case_dir = args.out_dir / case.case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        image = resize_for_max_edge(Image.open(case.image_path).convert("RGB"), args.max_edge)
        image_path = case_dir / "input.jpg"
        image.save(image_path, quality=95)

        semantic_mask, semantic_seconds = semantic_predict_to_mask(semantic_model, image, case_dir / "tmp_input.jpg")
        started = time.time()
        sam_masks = generator.generate(np.asarray(image.convert("RGB")))
        sam_seconds = time.time() - started
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

        np.save(case_dir / "official_semantic_mask.npy", semantic_mask)
        np.save(case_dir / "official_foodsam_fused_mask.npy", enhanced_mask)
        overlay(image, semantic_mask).save(case_dir / "official_semantic_overlay.jpg", quality=92)
        overlay(image, enhanced_mask).save(case_dir / "official_foodsam_fused_overlay.jpg", quality=92)
        draw_boxes(overlay(image, enhanced_mask), enhanced_rows).save(case_dir / "official_foodsam_fused_boxes.jpg", quality=92)
        contact_paths.extend([case_dir / "official_semantic_overlay.jpg", case_dir / "official_foodsam_fused_boxes.jpg"])

        row = {
            "case_id": case.case_id,
            "image_size": list(image.size),
            "semantic_init_seconds": round(semantic_init_seconds, 3),
            "semantic_seconds": round(semantic_seconds, 3),
            "sam_seconds": round(sam_seconds, 3),
            "sam_raw_count": len(sam_masks),
            "sam_accepted_count": len(accepted),
            "semantic_labels": semantic_rows,
            "foodsam_fused_labels": enhanced_rows,
            "accepted_sam_masks": accepted[:40],
        }
        summaries.append(row)
        (case_dir / "summary.json").write_text(json.dumps(row, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({
            "case_id": case.case_id,
            "semantic_seconds": row["semantic_seconds"],
            "sam_seconds": row["sam_seconds"],
            "sam_raw_count": row["sam_raw_count"],
            "sam_accepted_count": row["sam_accepted_count"],
            "labels": [x["label"] for x in enhanced_rows[:12]],
        }, ensure_ascii=False), flush=True)

    (args.out_dir / "batch_summary.json").write_text(json.dumps(summaries, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(contact_paths, args.out_dir / "foodsam_official_contact_sheet.jpg")
    print(f"saved={args.out_dir}", flush=True)


if __name__ == "__main__":
    main()
