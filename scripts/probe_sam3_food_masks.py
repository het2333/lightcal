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
import torch.nn.functional as F
from PIL import Image, ImageDraw
from sam3.model.sam3_image_processor import Sam3Processor
from sam3.model_builder import build_sam3_image_model
import sam3.model.vitdet as sam3_vitdet


CASES = [
    {
        "name": "depth_cola_can",
        "image": "/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_cab838efdd31/rgb.jpg",
        "prompts": ["cola", "soda can", "drink can"],
    },
    {
        "name": "depth_pot_bowl",
        "image": "/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_04f23a03f8bb/rgb.jpg",
        "prompts": ["fried rice", "noodles", "food in bowl"],
    },
    {
        "name": "rgb_fried_platter",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg",
        "prompts": ["fried chicken", "french fries", "curry puff", "egg tart"],
    },
    {
        "name": "rgb_cafeteria_meal",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg",
        "prompts": ["fried noodles", "purple rice", "tea", "chicken"],
    },
    {
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
    },
    {
        "name": "rgb_img6388",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg",
        "prompts": ["noodles", "shrimp", "cucumber", "french fries", "purple sweet potato congee"],
    },
]


def patch_sam3_fused_mlp_for_turing() -> None:
    """Avoid SAM3's bf16 fused MLP path on pre-Ampere GPUs."""

    def safe_addmm_act(activation: Any, linear: torch.nn.Module, mat1: torch.Tensor) -> torch.Tensor:
        y = linear(mat1)
        if activation in (torch.nn.functional.relu, torch.nn.ReLU):
            return F.relu(y)
        if activation in (torch.nn.functional.gelu, torch.nn.GELU):
            return F.gelu(y)
        name = getattr(activation, "__name__", str(activation)).lower()
        if "relu" in name:
            return F.relu(y)
        if "gelu" in name:
            return F.gelu(y)
        raise ValueError(f"Unexpected activation {activation}")

    sam3_vitdet.addmm_act = safe_addmm_act


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.logical_and(a, b).sum())
    union = int(np.logical_or(a, b).sum())
    return inter / union if union else 0.0


def resize_image(image: Image.Image, max_edge: int) -> Image.Image:
    if max_edge <= 0:
        return image
    out = image.copy()
    out.thumbnail((max_edge, max_edge))
    return out


def tensor_to_numpy_masks(masks: torch.Tensor) -> np.ndarray:
    masks = masks.detach().cpu()
    if masks.ndim == 4 and masks.shape[1] == 1:
        masks = masks[:, 0]
    return masks.numpy().astype(bool)


def tensor_to_list(tensor: torch.Tensor) -> list[Any]:
    return tensor.detach().cpu().numpy().tolist()


def pick_instances(
    prompt: str,
    output: dict[str, Any],
    image_area: int,
    max_per_prompt: int,
    min_area_ratio: float,
    max_area_ratio: float,
) -> list[dict[str, Any]]:
    masks = tensor_to_numpy_masks(output["masks"])
    boxes = tensor_to_list(output["boxes"])
    scores = [float(v) for v in tensor_to_list(output["scores"])]
    instances: list[dict[str, Any]] = []
    used_masks: list[np.ndarray] = []
    order = sorted(range(len(scores)), key=lambda index: scores[index], reverse=True)
    for index in order:
        mask = masks[index]
        area = int(mask.sum())
        area_ratio = area / max(image_area, 1)
        if area_ratio < min_area_ratio or area_ratio > max_area_ratio:
            continue
        if any(mask_iou(mask, used) > 0.55 for used in used_masks):
            continue
        box = [float(v) for v in boxes[index]]
        instances.append(
            {
                "prompt": prompt,
                "score": round(scores[index], 4),
                "bbox_xyxy": [round(v, 2) for v in box],
                "mask_area": area,
                "mask_area_ratio": round(area_ratio, 5),
                "_mask": mask,
            }
        )
        used_masks.append(mask)
        if len(instances) >= max_per_prompt:
            break
    return instances


def draw_instances(image: Image.Image, instances: list[dict[str, Any]], output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(53)
    for index, item in enumerate(instances, start=1):
        color = tuple(random.randint(45, 235) for _ in range(3))
        mask_img = Image.fromarray((item["_mask"].astype(np.uint8) * 255), mode="L")
        colored = Image.new("RGBA", base.size, color + (86,))
        overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = item["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=3)
        label = f"{index}:{item['prompt']} {item['score']:.2f}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def load_model(args: argparse.Namespace) -> Sam3Processor:
    patch_sam3_fused_mlp_for_turing()
    started = time.perf_counter()
    model = build_sam3_image_model(
        checkpoint_path=args.checkpoint,
        load_from_HF=False,
        device=args.device,
        enable_segmentation=True,
        enable_inst_interactivity=False,
        compile=False,
    )
    processor = Sam3Processor(model, device=args.device, confidence_threshold=args.confidence_threshold)
    print(json.dumps({"event": "model_loaded", "seconds": round(time.perf_counter() - started, 3)}, ensure_ascii=False), flush=True)
    return processor


def run_case(case: dict[str, Any], processor: Sam3Processor, out_root: Path, args: argparse.Namespace) -> dict[str, Any]:
    case_started = time.perf_counter()
    case_dir = out_root / case["name"]
    case_dir.mkdir(parents=True, exist_ok=True)
    image = resize_image(Image.open(case["image"]).convert("RGB"), args.max_edge)
    image_area = image.width * image.height

    t0 = time.perf_counter()
    state = processor.set_image(image)
    image_seconds = round(time.perf_counter() - t0, 3)

    all_instances: list[dict[str, Any]] = []
    prompt_summaries: list[dict[str, Any]] = []
    for prompt in case["prompts"]:
        processor.reset_all_prompts(state)
        t0 = time.perf_counter()
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
        except Exception as exc:  # Keep batch probing alive across individual prompt failures.
            raw_count = 0
            instances = []
            error = f"{type(exc).__name__}: {exc}"
        prompt_seconds = round(time.perf_counter() - t0, 3)
        all_instances.extend(instances)
        prompt_summaries.append(
            {
                "prompt": prompt,
                "raw_count": raw_count,
                "kept_count": len(instances),
                "seconds": prompt_seconds,
                "error": error,
                "instances": [{k: v for k, v in item.items() if k != "_mask"} for item in instances],
            }
        )
        print(
            json.dumps(
                {
                    "case": case["name"],
                    "prompt": prompt,
                    "raw_count": raw_count,
                    "kept_count": len(instances),
                    "seconds": prompt_seconds,
                    "error": error,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    annotated = case_dir / "sam3_masks.jpg"
    draw_instances(image, all_instances, annotated)
    summary = {
        "name": case["name"],
        "image": case["image"],
        "image_size": [image.width, image.height],
        "prompts": case["prompts"],
        "image_embedding_seconds": image_seconds,
        "prompt_count": len(case["prompts"]),
        "instance_count": len(all_instances),
        "total_seconds": round(time.perf_counter() - case_started, 3),
        "prompt_summaries": prompt_summaries,
        "annotated_image": str(annotated),
    }
    (case_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--confidence-threshold", type=float, default=0.35)
    parser.add_argument("--min-area-ratio", type=float, default=0.001)
    parser.add_argument("--max-area-ratio", type=float, default=0.45)
    parser.add_argument("--max-per-prompt", type=int, default=4)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    selected_cases = CASES[args.start :]
    if args.limit is not None:
        selected_cases = selected_cases[: args.limit]

    processor = load_model(args)
    summaries = []
    for case in selected_cases:
        print(f"=== {case['name']} ===", flush=True)
        summaries.append(run_case(case, processor, args.out_dir, args))

    table = [
        {
            "name": item["name"],
            "prompt_count": item["prompt_count"],
            "instance_count": item["instance_count"],
            "image_embedding_seconds": item["image_embedding_seconds"],
            "total_seconds": item["total_seconds"],
            "annotated_image": item["annotated_image"],
        }
        for item in summaries
    ]
    (args.out_dir / "batch_summary.json").write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    print("=== batch_summary ===", flush=True)
    print(json.dumps(table, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
