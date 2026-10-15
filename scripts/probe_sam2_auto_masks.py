#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
from sam2.build_sam import build_sam2


def run(
    image_path: Path,
    out_dir: Path,
    max_masks: int,
    points_per_side: int,
    device: str,
    max_edge: int,
    crop_n_layers: int,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    image = Image.open(image_path).convert("RGB")
    original_size = image.size
    if max_edge > 0:
        image.thumbnail((max_edge, max_edge))
    image_np = np.array(image)
    h, w = image_np.shape[:2]

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
    with torch.inference_mode():
        masks = generator.generate(image_np)

    rows = []
    for idx, mask_info in enumerate(masks):
        seg = mask_info.get("segmentation")
        if seg is None:
            continue
        seg_bool = np.asarray(seg).astype(bool)
        area = int(mask_info.get("area") or seg_bool.sum())
        if area < 500 or area > w * h * 0.65:
            continue
        rows.append(
            {
                "raw_index": idx,
                "area": area,
                "bbox_xywh": [int(x) for x in mask_info.get("bbox", [0, 0, 0, 0])],
                "pred_iou": round(float(mask_info.get("predicted_iou") or 0), 4),
                "stability": round(float(mask_info.get("stability_score") or 0), 4),
                "segmentation": seg_bool,
            }
        )

    rows.sort(key=lambda row: (-(row["pred_iou"] + row["stability"]), row["area"]))
    selected = rows[:max_masks]

    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    summary = []
    random.seed(7)
    for index, row in enumerate(selected, 1):
        mask = row.pop("segmentation")
        color = tuple(random.randint(40, 240) for _ in range(3)) + (95,)
        colored = Image.new("RGBA", base.size, color)
        mask_img = Image.fromarray((mask.astype(np.uint8) * 255), mode="L")
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x, y, bw, bh = row["bbox_xywh"]
        draw.rectangle([x, y, x + bw, y + bh], outline=color[:3] + (255,), width=3)
        draw.text((x + 3, y + 3), str(index), fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
        row["id"] = index
        row["area_ratio"] = round(row["area"] / max(w * h, 1), 5)
        summary.append(row)
        mask_img.save(out_dir / f"mask_{index:02d}.png")

    annotated = Image.alpha_composite(base, overlay).convert("RGB")
    annotated_path = out_dir / "annotated_top_masks.jpg"
    annotated.save(annotated_path, quality=92)
    summary_path = out_dir / "summary.json"
    summary_path.write_text(
        json.dumps(
            {
                "image": str(image_path),
                "original_size": list(original_size),
                "image_size": [w, h],
                "raw_masks": len(masks),
                "kept_masks": len(rows),
                "selected_masks": len(selected),
                "annotated": str(annotated_path),
                "masks": summary,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(json.dumps({"annotated": str(annotated_path), "summary": str(summary_path), "raw_masks": len(masks), "kept_masks": len(rows), "selected_masks": len(selected)}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--max-masks", type=int, default=30)
    parser.add_argument("--points-per-side", type=int, default=20)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--max-edge", type=int, default=0)
    parser.add_argument("--crop-n-layers", type=int, default=1)
    args = parser.parse_args()
    run(
        args.image,
        args.out_dir,
        args.max_masks,
        args.points_per_side,
        args.device,
        args.max_edge,
        args.crop_n_layers,
    )


if __name__ == "__main__":
    main()
