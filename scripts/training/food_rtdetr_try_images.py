"""Run RT-DETR food checkpoints on a fixed image set and save QA artifacts."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

from PIL import Image, ImageDraw, ImageFont


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
Predictor = Callable[[Image.Image], tuple[Sequence[object], Sequence[Sequence[object]], Sequence[object]]]


def load_model_index_labels(class_map: Path) -> dict[int, str]:
    """Load 1-based COCO category IDs as 0-based model label indexes."""
    labels: dict[int, str] = {}
    with class_map.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            category_id = int(row["category_id"])
            label = row.get("canonical_label") or row.get("name") or str(category_id)
            labels[category_id - 1] = label
    return labels


def _to_float_list(values: Iterable[object]) -> list[float]:
    return [float(value) for value in values]


def _bbox_iou_xyxy(first: Sequence[float], second: Sequence[float]) -> float:
    x0 = max(first[0], second[0])
    y0 = max(first[1], second[1])
    x1 = min(first[2], second[2])
    y1 = min(first[3], second[3])
    intersection = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    if intersection <= 0:
        return 0.0
    first_area = max(0.0, first[2] - first[0]) * max(0.0, first[3] - first[1])
    second_area = max(0.0, second[2] - second[0]) * max(0.0, second[3] - second[1])
    union = first_area + second_area - intersection
    if union <= 0:
        return 0.0
    return intersection / union


def _apply_nms(rows: Sequence[dict[str, object]], iou_threshold: float) -> list[dict[str, object]]:
    kept: list[dict[str, object]] = []
    for row in rows:
        box = [float(value) for value in row["bbox_xyxy"]]  # type: ignore[index]
        if all(_bbox_iou_xyxy(box, [float(value) for value in kept_row["bbox_xyxy"]]) <= iou_threshold for kept_row in kept):  # type: ignore[index]
            kept.append(dict(row))
    return kept


def format_predictions(
    *,
    labels: Sequence[object],
    boxes: Sequence[Sequence[object]],
    scores: Sequence[object],
    label_map: Mapping[int, str],
    threshold: float,
    limit: int,
    nms_iou_threshold: float | None = 0.65,
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for raw_label, raw_box, raw_score in zip(labels, boxes, scores):
        label_index = int(raw_label)
        score = float(raw_score)
        if score < threshold:
            continue
        box = _to_float_list(raw_box)
        rows.append(
            {
                "label_index": label_index,
                "label": label_map.get(label_index, f"class_{label_index}"),
                "score": round(score, 4),
                "bbox_xyxy": [round(value, 2) for value in box],
            }
        )

    rows.sort(key=lambda item: float(item["score"]), reverse=True)
    if nms_iou_threshold is not None:
        rows = _apply_nms(rows, nms_iou_threshold)
    rows = rows[:limit]
    for rank, row in enumerate(rows, start=1):
        row["rank"] = rank
    return [
        {
            "rank": row["rank"],
            "label_index": row["label_index"],
            "label": row["label"],
            "score": row["score"],
            "bbox_xyxy": row["bbox_xyxy"],
        }
        for row in rows
    ]


def load_rgb_image(path: Path, background: tuple[int, int, int] = (255, 255, 255)) -> Image.Image:
    image = Image.open(path)
    if image.mode in {"RGBA", "LA"} or ("transparency" in image.info):
        rgba = image.convert("RGBA")
        canvas = Image.new("RGBA", rgba.size, background + (255,))
        canvas.alpha_composite(rgba)
        return canvas.convert("RGB")
    return image.convert("RGB")


def _load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for candidate in candidates:
        try:
            if Path(candidate).exists():
                return ImageFont.truetype(candidate, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_predictions(
    image: Image.Image,
    predictions: Sequence[Mapping[str, object]],
    output_path: Path,
    *,
    max_draw: int = 12,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rendered = image.convert("RGB").copy()
    draw = ImageDraw.Draw(rendered)
    font = _load_font(max(12, min(rendered.size) // 28))
    palette = [(255, 56, 56), (0, 180, 128), (40, 128, 255), (255, 160, 0), (160, 80, 255)]

    for idx, prediction in enumerate(predictions[:max_draw]):
        box = [float(value) for value in prediction["bbox_xyxy"]]  # type: ignore[index]
        color = palette[idx % len(palette)]
        label = str(prediction.get("label", "unknown"))
        score = float(prediction.get("score", 0.0))
        text = f"{label} {score:.2f}"
        width = max(2, round(min(rendered.size) / 180))
        draw.rectangle(box, outline=color, width=width)
        text_box = draw.textbbox((0, 0), text, font=font)
        text_width = text_box[2] - text_box[0]
        text_height = text_box[3] - text_box[1]
        x0, y0 = box[0], max(0, box[1] - text_height - 6)
        draw.rectangle([x0, y0, x0 + text_width + 8, y0 + text_height + 6], fill=color)
        draw.text((x0 + 4, y0 + 3), text, fill=(255, 255, 255), font=font)

    rendered.save(output_path, quality=92)


def format_montage_caption(
    *,
    name: str,
    top_prediction: Mapping[str, object] | None,
    max_chars: int = 48,
    max_name_chars: int = 15,
) -> str:
    suffix = ""
    if top_prediction:
        suffix = f" | {top_prediction.get('label', 'unknown')} {float(top_prediction.get('score', 0.0)):.2f}"

    if len(name) + len(suffix) <= max_chars:
        return name + suffix

    available = min(max_name_chars, max(0, max_chars - len(suffix) - 3))
    if available <= 0:
        return suffix[-max_chars:]
    return f"{name[:available]}...{suffix}"


def write_montage(
    items: Sequence[Mapping[str, object]],
    output_path: Path,
    *,
    tile_width: int = 480,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not items:
        Image.new("RGB", (tile_width, tile_width), (255, 255, 255)).save(output_path, quality=92)
        return

    columns = min(3, len(items))
    rows = math.ceil(len(items) / columns)
    tile_height = round(tile_width * 0.78)
    caption_height = 44
    montage = Image.new("RGB", (columns * tile_width, rows * (tile_height + caption_height)), (245, 245, 245))
    draw = ImageDraw.Draw(montage)
    font = _load_font(18)

    for idx, item in enumerate(items):
        image_path = Path(str(item["image"]))
        image = load_rgb_image(image_path)
        image.thumbnail((tile_width, tile_height), Image.Resampling.LANCZOS)
        col = idx % columns
        row = idx // columns
        x = col * tile_width + (tile_width - image.width) // 2
        y = row * (tile_height + caption_height) + (tile_height - image.height) // 2
        montage.paste(image, (x, y))
        predictions = list(item.get("predictions", []))  # type: ignore[arg-type]
        top = predictions[0] if predictions else {}
        caption = format_montage_caption(name=str(item.get("name", image_path.name)), top_prediction=top)
        draw.text((col * tile_width + 12, row * (tile_height + caption_height) + tile_height + 10), caption, fill=(20, 20, 20), font=font)

    montage.save(output_path, quality=92)


def write_prediction_summary(
    *,
    output_path: Path,
    checkpoint: Path,
    config: Path,
    class_map: Path,
    input_size: int,
    threshold: float,
    device: str,
    items: Sequence[Mapping[str, object]],
    montage: Path,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "checkpoint": str(checkpoint),
        "config": str(config),
        "class_map": str(class_map),
        "input_size": input_size,
        "threshold": threshold,
        "device": device,
        "montage": str(montage),
        "items": [],
    }
    for item in items:
        predictions = list(item.get("predictions", []))  # type: ignore[arg-type]
        payload["items"].append(
            {
                "image": str(item["image"]),
                "rendered": str(item["rendered"]),
                "top_prediction": predictions[0] if predictions else None,
                "predictions": predictions,
            }
        )
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def collect_input_paths(inputs: Sequence[Path] | None, input_dirs: Sequence[Path] | None) -> list[Path]:
    seen: set[Path] = set()
    paths: list[Path] = []

    def add(path: Path) -> None:
        resolved = path.expanduser()
        if resolved.suffix.lower() not in IMAGE_SUFFIXES:
            return
        if resolved in seen:
            return
        seen.add(resolved)
        paths.append(resolved)

    for path in inputs or []:
        add(Path(path))
    for directory in input_dirs or []:
        for path in sorted(Path(directory).expanduser().iterdir()):
            if path.is_file():
                add(path)
    return paths


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run a food RT-DETR checkpoint on QA images.")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--class-map", type=Path, required=True)
    parser.add_argument("--input", type=Path, action="append", default=[])
    parser.add_argument("--input-dir", type=Path, action="append", default=[])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--threshold", type=float, default=0.25)
    parser.add_argument("--input-size", type=int, default=800)
    parser.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    parser.add_argument("--max-predictions", type=int, default=20)
    parser.add_argument("--montage-name", default="try_images_montage.jpg")
    parser.add_argument("--summary-name", default="try_images_predictions.json")
    return parser


def _safe_stem(path: Path) -> str:
    stem = path.stem.strip() or "image"
    return "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in stem)


def run_try_images(
    *,
    config: Path,
    checkpoint: Path,
    class_map: Path,
    input_paths: Sequence[Path],
    output_dir: Path,
    threshold: float,
    input_size: int,
    device: str,
    max_predictions: int,
    montage_name: str,
    summary_name: str,
    predictor: Callable[..., tuple[Sequence[object], Sequence[Sequence[object]], Sequence[object]]],
) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    label_map = load_model_index_labels(class_map)
    items: list[dict[str, object]] = []

    for image_path in input_paths:
        image = load_rgb_image(Path(image_path))
        labels, boxes, scores = predictor(image, input_size=input_size, device=device)
        predictions = format_predictions(
            labels=labels,
            boxes=boxes,
            scores=scores,
            label_map=label_map,
            threshold=threshold,
            limit=max_predictions,
        )
        rendered = output_dir / f"{_safe_stem(Path(image_path))}_pred.jpg"
        draw_predictions(image, predictions, rendered)
        items.append(
            {
                "image": Path(image_path),
                "rendered": rendered,
                "name": Path(image_path).name,
                "predictions": predictions,
            }
        )

    montage_path = output_dir / montage_name
    write_montage(items, montage_path)
    summary_path = output_dir / summary_name
    write_prediction_summary(
        output_path=summary_path,
        checkpoint=checkpoint,
        config=config,
        class_map=class_map,
        input_size=input_size,
        threshold=threshold,
        device=device,
        items=items,
        montage=montage_path,
    )
    return summary_path


def build_rtdetr_predictor(
    *,
    config: Path,
    checkpoint: Path,
) -> Callable[..., tuple[Sequence[object], Sequence[Sequence[object]], Sequence[object]]]:
    try:
        import numpy as np
        import torch
        from src.core import YAMLConfig
    except ImportError as exc:  # pragma: no cover - exercised on the remote training host.
        raise RuntimeError(
            "RT-DETR dependencies are unavailable. Run with PYTHONPATH including rtdetrv2_pytorch."
        ) from exc

    cfg = YAMLConfig(str(config))
    try:
        payload = torch.load(str(checkpoint), map_location="cpu", weights_only=False)
    except TypeError:
        payload = torch.load(str(checkpoint), map_location="cpu")
    if isinstance(payload, Mapping) and "ema" in payload:
        state = payload["ema"]["module"]
    elif isinstance(payload, Mapping) and "model" in payload:
        state = payload["model"]
    else:
        state = payload

    cfg.model.load_state_dict(state)
    model = cfg.model.deploy().eval()
    postprocessor = cfg.postprocessor.deploy().eval()
    current_device: str | None = None

    def predict(image: Image.Image, *, input_size: int, device: str):
        nonlocal current_device, model, postprocessor
        target_device = torch.device(device)
        if target_device.type == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("CUDA was requested but torch.cuda.is_available() is false.")
        if current_device != str(target_device):
            model = model.to(target_device)
            postprocessor = postprocessor.to(target_device)
            current_device = str(target_device)

        resized = image.resize((input_size, input_size), Image.Resampling.BILINEAR)
        array = np.asarray(resized, dtype=np.float32) / 255.0
        tensor = torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0).to(target_device)
        orig_size = torch.tensor([[image.width, image.height]], dtype=torch.float32, device=target_device)
        with torch.no_grad():
            outputs = model(tensor)
            labels, boxes, scores = postprocessor(outputs, orig_size)
        return (
            labels[0].detach().cpu().tolist(),
            boxes[0].detach().cpu().tolist(),
            scores[0].detach().cpu().tolist(),
        )

    return predict


def main(
    argv: Sequence[str] | None = None,
    *,
    predictor_factory: Callable[..., Callable[..., tuple[Sequence[object], Sequence[Sequence[object]], Sequence[object]]]] | None = None,
) -> Path:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    input_paths = collect_input_paths(args.input, args.input_dir)
    if not input_paths:
        parser.error("Provide at least one image with --input or --input-dir.")

    factory = predictor_factory or build_rtdetr_predictor
    predictor = factory(config=args.config, checkpoint=args.checkpoint)
    return run_try_images(
        config=args.config,
        checkpoint=args.checkpoint,
        class_map=args.class_map,
        input_paths=input_paths,
        output_dir=args.output_dir,
        threshold=args.threshold,
        input_size=args.input_size,
        device=args.device,
        max_predictions=args.max_predictions,
        montage_name=args.montage_name,
        summary_name=args.summary_name,
        predictor=predictor,
    )


if __name__ == "__main__":
    print(main(sys.argv[1:]))
