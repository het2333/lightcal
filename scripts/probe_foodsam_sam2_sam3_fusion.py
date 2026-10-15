#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFont


CASES = [
    "depth_cola_can",
    "depth_pot_bowl",
    "rgb_cafeteria_meal",
    "rgb_fried_platter",
    "rgb_img6388",
    "rgb_vegetable_board",
]


def add_runtime_paths() -> None:
    for path in ("/root/autodl-tmp/sam2-src", "/root/autodl-tmp/sam3"):
        if path not in sys.path:
            sys.path.insert(0, path)


def load_categories(path: Path) -> dict[int, str]:
    labels: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[0].strip().isdigit():
            labels[int(parts[0])] = parts[1].strip()
    return labels


def load_font(size: int = 15) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def palette(index: int) -> tuple[int, int, int]:
    rng = np.random.default_rng(index * 997 + 23)
    return tuple(int(x) for x in rng.integers(50, 235, size=3))


def bbox_from_mask(mask: np.ndarray) -> list[int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


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


def draw_boxes(image: Image.Image, rows: list[dict[str, Any]]) -> Image.Image:
    out = image.copy().convert("RGB")
    draw = ImageDraw.Draw(out)
    font = load_font(13)
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


def fuse_foodsam_style(
    semantic_mask: np.ndarray,
    masks: list[dict[str, Any]],
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
    sorted_masks = sorted(masks, key=lambda m: int(m.get("area") or 0), reverse=True)[:top_k]
    for idx, item in enumerate(sorted_masks):
        mask = np.asarray(item["segmentation"]).astype(bool)
        if mask.shape != semantic_mask.shape:
            mask = np.asarray(Image.fromarray(mask.astype(np.uint8) * 255).resize((w, h), Image.NEAREST)).astype(bool)
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
                "mask_index": idx,
                "source": item.get("source", ""),
                "source_prompt": item.get("prompt", ""),
                "label_id": label,
                "label": id2label.get(label, str(label)),
                "vote_ratio": round(vote_ratio, 4),
                "area_ratio": round(area_ratio, 5),
                "bbox_xyxy": bbox_from_mask(mask),
                "score": round(float(item.get("score") or item.get("predicted_iou") or 0), 4),
                "stability_score": round(float(item.get("stability_score") or 0), 4),
            }
        )
    return enhanced, accepted


def load_label_mask(path: Path) -> np.ndarray:
    arr = np.asarray(Image.open(path))
    if arr.ndim == 3:
        arr = arr[..., 0]
    return arr.astype(np.uint8)


def load_sam2_generator(args: argparse.Namespace):
    add_runtime_paths()
    from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
    from sam2.build_sam import build_sam2

    model = build_sam2(args.sam2_config, args.sam2_checkpoint, device=args.device)
    return SAM2AutomaticMaskGenerator(
        model,
        points_per_side=args.points_per_side,
        points_per_batch=args.points_per_batch,
        pred_iou_thresh=0.72,
        stability_score_thresh=0.82,
        box_nms_thresh=0.65,
        crop_n_layers=args.crop_n_layers,
        crop_n_points_downscale_factor=2,
        min_mask_region_area=400,
        output_mode="binary_mask",
    )


def generate_sam2_masks(generator: Any, image: Image.Image) -> tuple[list[dict[str, Any]], float]:
    started = time.perf_counter()
    with torch.inference_mode():
        raw = generator.generate(np.asarray(image.convert("RGB")))
    rows: list[dict[str, Any]] = []
    for item in raw:
        seg = np.asarray(item.get("segmentation")).astype(bool)
        rows.append(
            {
                "source": "sam2_auto",
                "segmentation": seg,
                "area": int(item.get("area") or seg.sum()),
                "predicted_iou": float(item.get("predicted_iou") or 0),
                "stability_score": float(item.get("stability_score") or 0),
            }
        )
    return rows, time.perf_counter() - started


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


def load_sam3_processor(args: argparse.Namespace):
    add_runtime_paths()
    patch_sam3_fused_mlp_for_turing()
    from sam3.model.sam3_image_processor import Sam3Processor
    from sam3.model_builder import build_sam3_image_model

    model = build_sam3_image_model(
        checkpoint_path=args.sam3_checkpoint,
        load_from_HF=False,
        device=args.device,
        enable_segmentation=True,
        enable_inst_interactivity=False,
        compile=False,
    )
    return Sam3Processor(model, device=args.device, confidence_threshold=args.sam3_confidence)


def tensor_to_numpy_masks(masks: torch.Tensor) -> np.ndarray:
    masks = masks.detach().cpu()
    if masks.ndim == 4 and masks.shape[1] == 1:
        masks = masks[:, 0]
    return masks.numpy().astype(bool)


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.logical_and(a, b).sum())
    union = int(np.logical_or(a, b).sum())
    return inter / union if union else 0.0


def generate_sam3_masks(
    processor: Any,
    image: Image.Image,
    prompts: list[str],
    min_area_ratio: float,
    max_area_ratio: float,
    max_per_prompt: int,
) -> tuple[list[dict[str, Any]], float, list[dict[str, Any]]]:
    started = time.perf_counter()
    state = processor.set_image(image)
    image_area = image.width * image.height
    rows: list[dict[str, Any]] = []
    prompt_rows: list[dict[str, Any]] = []
    for prompt in prompts:
        processor.reset_all_prompts(state)
        p0 = time.perf_counter()
        try:
            output = processor.set_text_prompt(state=state, prompt=prompt)
            raw_count = int(output["scores"].numel())
            masks = tensor_to_numpy_masks(output["masks"])
            boxes = output["boxes"].detach().cpu().numpy().tolist()
            scores = [float(x) for x in output["scores"].detach().cpu().numpy().tolist()]
            used: list[np.ndarray] = []
            kept = 0
            for idx in sorted(range(len(scores)), key=lambda i: scores[i], reverse=True):
                mask = masks[idx]
                area = int(mask.sum())
                area_ratio = area / max(image_area, 1)
                if area_ratio < min_area_ratio or area_ratio > max_area_ratio:
                    continue
                if any(mask_iou(mask, old) > 0.55 for old in used):
                    continue
                rows.append(
                    {
                        "source": "sam3_prompt",
                        "prompt": prompt,
                        "segmentation": mask,
                        "area": area,
                        "score": scores[idx],
                        "bbox_xyxy": [round(float(v), 2) for v in boxes[idx]],
                    }
                )
                used.append(mask)
                kept += 1
                if kept >= max_per_prompt:
                    break
            error = None
        except Exception as exc:
            raw_count = 0
            kept = 0
            error = f"{type(exc).__name__}: {exc}"
        prompt_rows.append(
            {
                "prompt": prompt,
                "raw_count": raw_count,
                "kept_count": kept,
                "seconds": round(time.perf_counter() - p0, 3),
                "error": error,
            }
        )
    return rows, time.perf_counter() - started, prompt_rows


def prompts_from_semantic(rows: list[dict[str, Any]], max_prompts: int, min_area_ratio: float) -> list[str]:
    prompts: list[str] = []
    for row in rows:
        if float(row["area_ratio"]) < min_area_ratio:
            continue
        label = str(row["label"]).strip()
        if label and label.lower() != "background" and label not in prompts:
            prompts.append(label)
        if len(prompts) >= max_prompts:
            break
    return prompts


def make_case_panel(case_id: str, images: list[tuple[str, Image.Image]], output_path: Path) -> None:
    font = load_font(16)
    tile_w = 310
    header_h = 44
    gutter = 12
    tiles = []
    for title, image in images:
        img = image.convert("RGB")
        scale = tile_w / img.width
        tile_h = max(1, int(img.height * scale))
        img = img.resize((tile_w, tile_h), Image.LANCZOS)
        tile = Image.new("RGB", (tile_w, tile_h + header_h), "white")
        d = ImageDraw.Draw(tile)
        d.text((6, 5), title[:36], fill=(0, 0, 0), font=font)
        tile.paste(img, (0, header_h))
        tiles.append(tile)
    width = len(tiles) * tile_w + (len(tiles) - 1) * gutter
    height = max(tile.height for tile in tiles) + 28
    panel = Image.new("RGB", (width, height), (246, 246, 246))
    d = ImageDraw.Draw(panel)
    d.text((6, 4), case_id, fill=(0, 0, 0), font=font)
    x = 0
    for tile in tiles:
        panel.paste(tile, (x, 28))
        x += tile_w + gutter
    panel.save(output_path, quality=92)


def make_contact_sheet(paths: list[Path], output_path: Path) -> None:
    images = [Image.open(path).convert("RGB") for path in paths]
    if not images:
        return
    width = max(img.width for img in images)
    gutter = 20
    sheet = Image.new("RGB", (width, sum(img.height for img in images) + gutter * (len(images) - 1)), "white")
    y = 0
    for img in images:
        sheet.paste(img, ((width - img.width) // 2, y))
        y += img.height + gutter
    sheet.save(output_path, quality=92)


def run(args: argparse.Namespace) -> None:
    id2label = load_categories(args.category_txt)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    sam2_generator = None
    sam3_processor = None
    if args.run_sam2:
        t0 = time.perf_counter()
        sam2_generator = load_sam2_generator(args)
        sam2_load_seconds = round(time.perf_counter() - t0, 3)
    else:
        sam2_load_seconds = None
    if args.run_sam3:
        t0 = time.perf_counter()
        sam3_processor = load_sam3_processor(args)
        sam3_load_seconds = round(time.perf_counter() - t0, 3)
    else:
        sam3_load_seconds = None

    summaries: list[dict[str, Any]] = []
    panels: list[Path] = []
    for case_id in CASES:
        src_dir = args.official_root / case_id
        if not src_dir.exists():
            continue
        case_dir = args.out_dir / case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        image = Image.open(src_dir / "input.jpg").convert("RGB")
        semantic_mask = load_label_mask(src_dir / "pred_mask.png")
        sam1_mask = load_label_mask(src_dir / "enhance_mask.png")

        semantic_rows = summarize_labels(semantic_mask, id2label)
        sam1_rows = summarize_labels(sam1_mask, id2label)
        case_summary: dict[str, Any] = {
            "case_id": case_id,
            "image_size": list(image.size),
            "sam2_load_seconds": sam2_load_seconds,
            "sam3_load_seconds": sam3_load_seconds,
            "semantic_labels": semantic_rows,
            "foodsam1_labels": sam1_rows,
        }

        panel_images: list[tuple[str, Image.Image]] = [
            ("input", image),
            ("FoodSAM1 official", draw_boxes(overlay(image, sam1_mask), sam1_rows)),
        ]

        if sam2_generator is not None:
            sam2_masks, sam2_seconds = generate_sam2_masks(sam2_generator, image)
            sam2_fused, sam2_accepted = fuse_foodsam_style(
                semantic_mask,
                sam2_masks,
                id2label,
                ratio_thr=args.ratio_thr,
                min_area_ratio=args.min_area_ratio,
                max_area_ratio=args.max_area_ratio,
                top_k=args.top_k,
            )
            sam2_rows = summarize_labels(sam2_fused, id2label)
            np.save(case_dir / "foodsam2_sam2_fused_mask.npy", sam2_fused)
            draw_boxes(overlay(image, sam2_fused), sam2_rows).save(case_dir / "foodsam2_sam2_fused_boxes.jpg", quality=92)
            case_summary["foodsam2"] = {
                "sam_seconds": round(sam2_seconds, 3),
                "sam_raw_count": len(sam2_masks),
                "accepted_count": len(sam2_accepted),
                "labels": sam2_rows,
                "accepted_masks": sam2_accepted[:40],
            }
            panel_images.append(("FoodSAM2 = SETR+SAM2", Image.open(case_dir / "foodsam2_sam2_fused_boxes.jpg")))

        if sam3_processor is not None:
            prompts = prompts_from_semantic(semantic_rows, args.sam3_max_prompts, args.sam3_min_prompt_area)
            sam3_masks, sam3_seconds, prompt_rows = generate_sam3_masks(
                sam3_processor,
                image,
                prompts,
                min_area_ratio=args.min_area_ratio,
                max_area_ratio=args.max_area_ratio,
                max_per_prompt=args.sam3_max_per_prompt,
            )
            sam3_fused, sam3_accepted = fuse_foodsam_style(
                semantic_mask,
                sam3_masks,
                id2label,
                ratio_thr=args.ratio_thr,
                min_area_ratio=args.min_area_ratio,
                max_area_ratio=args.max_area_ratio,
                top_k=args.top_k,
            )
            sam3_rows = summarize_labels(sam3_fused, id2label)
            np.save(case_dir / "foodsam3_sam3_fused_mask.npy", sam3_fused)
            draw_boxes(overlay(image, sam3_fused), sam3_rows).save(case_dir / "foodsam3_sam3_fused_boxes.jpg", quality=92)
            case_summary["foodsam3"] = {
                "sam_seconds": round(sam3_seconds, 3),
                "prompts": prompts,
                "prompt_summaries": prompt_rows,
                "sam_raw_count": len(sam3_masks),
                "accepted_count": len(sam3_accepted),
                "labels": sam3_rows,
                "accepted_masks": sam3_accepted[:40],
            }
            panel_images.append(("FoodSAM3 = SETR+SAM3", Image.open(case_dir / "foodsam3_sam3_fused_boxes.jpg")))

        panel_path = case_dir / "comparison_panel.jpg"
        make_case_panel(case_id, panel_images, panel_path)
        panels.append(panel_path)
        summaries.append(case_summary)
        (case_dir / "summary.json").write_text(json.dumps(case_summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(
            json.dumps(
                {
                    "case_id": case_id,
                    "sam1_labels": [x["label"] for x in sam1_rows[:8]],
                    "sam2": None if "foodsam2" not in case_summary else {
                        "seconds": case_summary["foodsam2"]["sam_seconds"],
                        "raw": case_summary["foodsam2"]["sam_raw_count"],
                        "accepted": case_summary["foodsam2"]["accepted_count"],
                        "labels": [x["label"] for x in case_summary["foodsam2"]["labels"][:8]],
                    },
                    "sam3": None if "foodsam3" not in case_summary else {
                        "seconds": case_summary["foodsam3"]["sam_seconds"],
                        "raw": case_summary["foodsam3"]["sam_raw_count"],
                        "accepted": case_summary["foodsam3"]["accepted_count"],
                        "prompts": case_summary["foodsam3"]["prompts"],
                        "labels": [x["label"] for x in case_summary["foodsam3"]["labels"][:8]],
                    },
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    (args.out_dir / "batch_summary.json").write_text(json.dumps(summaries, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(panels, args.out_dir / "foodsam_sam1_sam2_sam3_contact_sheet.jpg")
    print(f"saved={args.out_dir}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official-root", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_official_script_768_typed_20260704_224953"))
    parser.add_argument("--category-txt", type=Path, default=Path("/root/autodl-tmp/FoodSAM/FoodSAM/FoodSAM_tools/category_id_files/foodseg103_category_id.txt"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/foodsam_sam2_sam3_fusion_20260705"))
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--run-sam2", action="store_true")
    parser.add_argument("--run-sam3", action="store_true")
    parser.add_argument("--sam2-config", default="configs/sam2.1/sam2.1_hiera_t.yaml")
    parser.add_argument("--sam2-checkpoint", default="/root/autodl-tmp/sam2-checkpoints/sam2.1_hiera_tiny.pt")
    parser.add_argument("--sam3-checkpoint", default="/root/autodl-tmp/modelscope-cache-ms/facebook/sam3/sam3.pt")
    parser.add_argument("--points-per-side", type=int, default=24)
    parser.add_argument("--points-per-batch", type=int, default=64)
    parser.add_argument("--crop-n-layers", type=int, default=0)
    parser.add_argument("--ratio-thr", type=float, default=0.50)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.60)
    parser.add_argument("--top-k", type=int, default=100)
    parser.add_argument("--sam3-confidence", type=float, default=0.35)
    parser.add_argument("--sam3-max-prompts", type=int, default=8)
    parser.add_argument("--sam3-min-prompt-area", type=float, default=0.003)
    parser.add_argument("--sam3-max-per-prompt", type=int, default=4)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
