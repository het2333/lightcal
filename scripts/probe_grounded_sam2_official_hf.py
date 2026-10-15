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
from sam2.build_sam import build_sam2
from sam2.sam2_image_predictor import SAM2ImagePredictor
from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor


CASES = [
    {
        "name": "无深度_炸物拼盘",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg",
        "prompt": "french fries . egg tart . fried chicken . curry puff",
    },
    {
        "name": "无深度_蔬菜拼盘",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/vegetable_board/rgb.jpg",
        "prompt": "red cabbage . celery . kale . mushroom . tomato . carrot . onion . brussels sprout",
    },
    {
        "name": "无深度_米饭炒面套餐",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg",
        "prompt": "fried noodles . purple rice . tea . chicken",
    },
    {
        "name": "无深度_IMG6388",
        "image": "/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg",
        "prompt": "noodles . shrimp . cucumber . french fries . purple sweet potato congee",
    },
]


def normalize_prompt(prompt: str) -> str:
    chunks = [chunk.strip().lower().strip(".") for chunk in prompt.replace("\n", ".").split(".")]
    chunks = [chunk for chunk in chunks if chunk]
    return " . ".join(chunks) + " ."


def load_models(args: argparse.Namespace) -> tuple[Any, Any, SAM2ImagePredictor]:
    processor = AutoProcessor.from_pretrained(args.grounding_model, local_files_only=args.local_files_only)
    grounding_model = AutoModelForZeroShotObjectDetection.from_pretrained(
        args.grounding_model,
        local_files_only=args.local_files_only,
    ).to(args.device).eval()
    sam2_model = build_sam2(args.sam2_model_config, args.sam2_checkpoint, device=args.device)
    sam2_predictor = SAM2ImagePredictor(sam2_model)
    return processor, grounding_model, sam2_predictor


def run_dino(
    image: Image.Image,
    prompt: str,
    processor: Any,
    model: Any,
    box_threshold: float,
    text_threshold: float,
    device: str,
) -> list[dict[str, Any]]:
    inputs = processor(images=image, text=normalize_prompt(prompt), return_tensors="pt").to(device)
    with torch.inference_mode():
        outputs = model(**inputs)
    results = processor.post_process_grounded_object_detection(
        outputs=outputs,
        input_ids=inputs.get("input_ids"),
        threshold=box_threshold,
        text_threshold=text_threshold,
        target_sizes=[image.size[::-1]],
    )[0]
    boxes = results.get("boxes", []).detach().cpu().numpy().tolist()
    scores = results.get("scores", []).detach().cpu().numpy().tolist()
    labels = results.get("labels") or results.get("text_labels") or []
    detections = []
    for index, box in enumerate(boxes):
        detections.append(
            {
                "detection_id": f"det_{index + 1}",
                "phrase": str(labels[index] if index < len(labels) else ""),
                "score": round(float(scores[index]), 4) if index < len(scores) else 0.0,
                "bbox_xyxy": [round(float(v), 2) for v in box],
            }
        )
    return detections


def run_sam2(
    image: Image.Image,
    detections: list[dict[str, Any]],
    predictor: SAM2ImagePredictor,
) -> tuple[np.ndarray, list[float]]:
    boxes = np.array([det["bbox_xyxy"] for det in detections], dtype=np.float32)
    if boxes.size == 0:
        return np.zeros((0, image.height, image.width), dtype=bool), []
    predictor.set_image(np.array(image.convert("RGB")))
    with torch.inference_mode():
        masks, scores, _ = predictor.predict(
            point_coords=None,
            point_labels=None,
            box=boxes,
            multimask_output=False,
        )
    if masks.ndim == 4:
        masks = masks.squeeze(1)
    return masks.astype(bool), [round(float(v), 4) for v in np.array(scores).reshape(-1).tolist()]


def draw_result(image: Image.Image, detections: list[dict[str, Any]], masks: np.ndarray, output_path: Path) -> None:
    base = image.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    random.seed(37)
    for index, det in enumerate(detections):
        color = tuple(random.randint(40, 235) for _ in range(3)) + (90,)
        if index < len(masks):
            mask_img = Image.fromarray((masks[index].astype(np.uint8) * 255), mode="L")
            colored = Image.new("RGBA", base.size, color)
            overlay.alpha_composite(Image.composite(colored, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask_img))
        x1, y1, x2, y2 = det["bbox_xyxy"]
        draw.rectangle([x1, y1, x2, y2], outline=color[:3] + (255,), width=3)
        label = f"{index + 1}:{det['phrase']} {det['score']:.2f}"
        draw.text((x1 + 3, y1 + 3), label, fill=(255, 255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(base, overlay).convert("RGB").save(output_path, quality=92)


def run_case(case: dict[str, Any], out_dir: Path, args: argparse.Namespace, processor: Any, model: Any, predictor: SAM2ImagePredictor) -> dict[str, Any]:
    started = time.perf_counter()
    case_dir = out_dir / case["name"]
    case_dir.mkdir(parents=True, exist_ok=True)
    image = Image.open(case["image"]).convert("RGB")
    if args.max_edge > 0:
        image.thumbnail((args.max_edge, args.max_edge))

    t0 = time.perf_counter()
    detections = run_dino(image, case["prompt"], processor, model, args.box_threshold, args.text_threshold, args.device)
    dino_seconds = round(time.perf_counter() - t0, 3)

    t0 = time.perf_counter()
    masks, sam2_scores = run_sam2(image, detections, predictor)
    sam2_seconds = round(time.perf_counter() - t0, 3)

    for index, det in enumerate(detections):
        det["sam2_score"] = sam2_scores[index] if index < len(sam2_scores) else 0.0
        det["mask_area"] = int(masks[index].sum()) if index < len(masks) else 0

    annotated = case_dir / "grounded_sam2_official_hf.jpg"
    draw_result(image, detections, masks, annotated)
    summary = {
        "name": case["name"],
        "image": case["image"],
        "prompt": normalize_prompt(case["prompt"]),
        "image_size": [image.width, image.height],
        "dino_detection_count": len(detections),
        "mask_count": int(sum(1 for det in detections if det.get("mask_area", 0) > 0)),
        "timings": {
            "dino_seconds": dino_seconds,
            "sam2_seconds": sam2_seconds,
            "total_seconds": round(time.perf_counter() - started, 3),
        },
        "detections": detections,
        "annotated_image": str(annotated),
    }
    (case_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--grounding-model", default="/root/autodl-tmp/hf_grounding_dino_base_slim")
    parser.add_argument("--sam2-checkpoint", default="/root/autodl-tmp/sam2-checkpoints/sam2.1_hiera_tiny.pt")
    parser.add_argument("--sam2-model-config", default="configs/sam2.1/sam2.1_hiera_t.yaml")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--box-threshold", type=float, default=0.18)
    parser.add_argument("--text-threshold", type=float, default=0.15)
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--local-files-only", action="store_true", default=True)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    processor, grounding_model, sam2_predictor = load_models(args)
    summaries = []
    for case in CASES:
        print(f"=== {case['name']} ===", flush=True)
        summary = run_case(case, args.out_dir, args, processor, grounding_model, sam2_predictor)
        summaries.append(summary)
        compact = {
            "name": summary["name"],
            "dino_detection_count": summary["dino_detection_count"],
            "mask_count": summary["mask_count"],
            "timings": summary["timings"],
            "labels": [det["phrase"] for det in summary["detections"][:20]],
            "annotated_image": summary["annotated_image"],
        }
        print(json.dumps(compact, ensure_ascii=False, indent=2), flush=True)
    table = [
        {
            "name": item["name"],
            "dino_detection_count": item["dino_detection_count"],
            "mask_count": item["mask_count"],
            "dino_seconds": item["timings"]["dino_seconds"],
            "sam2_seconds": item["timings"]["sam2_seconds"],
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
