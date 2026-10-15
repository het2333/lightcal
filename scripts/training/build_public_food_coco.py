#!/usr/bin/env python3
"""Build a dynamic COCO dataset from public food sources.

This builder is intentionally stricter than the broad v1 scaffold: concrete
Chinese dish names are kept as categories, while coarse fallback labels are
filtered out unless explicitly useful for localization pretraining.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from PIL import Image

from scripts.training.build_food_rtdetr_v1_dataset import (
    deterministic_split,
    display_label,
    get_source_policy,
    load_normalized_rows,
    map_label,
    normalize_bbox,
    score_bbox_quality,
    should_include_license,
    xywh_to_xyxy,
)


COARSE_LABELS = {
    "未知西餐",
    "未知饮品",
    "未知中餐",
    "主食",
    "肉类菜",
    "鱼类菜",
    "蔬菜菜",
    "汤类",
    "饮料",
    "套餐",
    "便当",
    "甜品",
}
FOOD_REGION_LABEL = "食物区域"
FOODSEG_SOURCE_PREFIXES = ("foodseg",)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")


def _stable_image_key(image_path: Path) -> str:
    try:
        return str(image_path.resolve())
    except OSError:
        return str(image_path)


def _image_record_id(path: Path, split: str) -> int:
    digest = hashlib.sha1(f"{split}:{_stable_image_key(path)}".encode("utf-8")).hexdigest()[:8]
    return int(digest, 16)


def _unique_image_name(image_path: Path) -> str:
    digest = hashlib.sha1(_stable_image_key(image_path).encode("utf-8")).hexdigest()[:12]
    suffix = image_path.suffix or ".jpg"
    return f"{image_path.stem}-{digest}{suffix}"


def _copy_image_if_needed(image_path: Path, output_root: Path, split: str) -> str:
    target_dir = output_root / "images" / split
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / _unique_image_name(image_path)
    if image_path.exists() and not target.exists():
        try:
            shutil.copy2(image_path, target)
        except shutil.SameFileError:
            pass
    return str(Path("images") / split / target.name)


def _clean_label(value: Any) -> str:
    label = str(value or "").strip()
    label = re.sub(r"\s+", " ", label.replace("_", " ").replace("-", " ")).strip()
    return label


def _is_foodseg_source(source_dataset: str) -> bool:
    lowered = source_dataset.casefold()
    return any(lowered.startswith(prefix) for prefix in FOODSEG_SOURCE_PREFIXES)


def specific_label(original_label: str, allow_english: bool = True) -> str | None:
    raw = _clean_label(original_label)
    if not raw:
        return None

    mapped = map_label(raw)
    if not mapped.canonical_label.startswith("未知") and mapped.canonical_label not in COARSE_LABELS:
        return mapped.canonical_label

    if CJK_RE.search(raw):
        raw = raw.replace("（", "(").replace("）", ")")
        raw = re.sub(r"\([^)]{0,30}\)", "", raw).strip()
        if raw and not raw.startswith("未知") and raw not in COARSE_LABELS:
            return raw

    if allow_english:
        label = display_label(raw)
        lowered = label.casefold()
        if label and lowered not in {"background", "other ingredients", "others", "other", "unknown"}:
            return label
    return None


def _normalized_rows(paths: Iterable[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in paths:
        if path.exists():
            rows.extend(load_normalized_rows(path))
    return rows


def _row_split(row: dict[str, Any], image_path: Path) -> str:
    split = str(row.get("split") or deterministic_split(str(image_path))).lower()
    return split if split in {"train", "val", "test"} else deterministic_split(str(image_path))


def _row_dimensions(row: dict[str, Any], image_path: Path) -> tuple[int, int] | None:
    width = int(row.get("width") or 0)
    height = int(row.get("height") or 0)
    if (width <= 0 or height <= 0) and image_path.exists():
        with Image.open(image_path) as image:
            width, height = image.size
    if width <= 0 or height <= 0:
        return None
    return width, height


def _foodseg_union_rows(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in rows:
        source_dataset = str(row.get("source_dataset") or "")
        if not _is_foodseg_source(source_dataset):
            continue
        image_path = Path(str(row.get("image_path") or ""))
        dimensions = _row_dimensions(row, image_path)
        if dimensions is None:
            continue
        width, height = dimensions
        split = _row_split(row, image_path)
        bbox_xywh = normalize_bbox(row["bbox"], str(row.get("bbox_format") or "xyxy"))
        x1, y1, x2, y2 = xywh_to_xyxy(bbox_xywh)
        key = (str(image_path), split, source_dataset)
        if key not in grouped:
            grouped[key] = {
                "image_path": str(image_path),
                "width": width,
                "height": height,
                "source_dataset": source_dataset,
                "original_label": FOOD_REGION_LABEL,
                "bbox": [x1, y1, x2, y2],
                "bbox_format": "xyxy",
                "bbox_type": "mask_union_bbox",
                "split": split,
                "quality_signals": {"mask_area": 0},
            }
        else:
            target = grouped[key]
            bx1, by1, bx2, by2 = [float(v) for v in target["bbox"]]
            target["bbox"] = [min(bx1, x1), min(by1, y1), max(bx2, x2), max(by2, y2)]
        grouped[key]["quality_signals"]["mask_area"] = int(
            grouped[key]["quality_signals"].get("mask_area", 0)
            + (row.get("quality_signals") or {}).get("mask_area", 0)
        )
    return list(grouped.values())


def _prepared_rows(rows: list[dict[str, Any]], foodseg_mode: str) -> list[dict[str, Any]]:
    if foodseg_mode == "ingredient":
        return rows
    non_foodseg = [row for row in rows if not _is_foodseg_source(str(row.get("source_dataset") or ""))]
    if foodseg_mode == "skip":
        return non_foodseg
    if foodseg_mode == "union":
        return non_foodseg + _foodseg_union_rows(rows)
    raise ValueError(f"unsupported foodseg_mode: {foodseg_mode}")


def _mapped_label_for_row(row: dict[str, Any], allow_english: bool) -> str | None:
    if str(row.get("original_label") or "") == FOOD_REGION_LABEL:
        return FOOD_REGION_LABEL
    return specific_label(str(row.get("original_label") or row.get("label") or ""), allow_english=allow_english)


def _is_too_large(width: int, height: int, max_image_pixels: int) -> bool:
    return max_image_pixels > 0 and width * height > max_image_pixels


def _eligible_labels(
    rows: Iterable[dict[str, Any]],
    min_train_annotations: int,
    allow_english: bool,
    max_image_pixels: int,
) -> list[str]:
    counts: Counter[str] = Counter()
    for row in rows:
        image_path = Path(str(row.get("image_path") or ""))
        dimensions = _row_dimensions(row, image_path)
        if dimensions is None:
            continue
        if _is_too_large(*dimensions, max_image_pixels=max_image_pixels):
            continue
        if _row_split(row, image_path) != "train":
            continue
        label = _mapped_label_for_row(row, allow_english=allow_english)
        if label:
            counts[label] += 1
    return sorted(label for label, count in counts.items() if count >= min_train_annotations)


def _write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def build_public_food_coco(
    output_root: Path,
    normalized_jsonl_paths: list[Path],
    min_train_annotations: int = 1,
    foodseg_mode: str = "skip",
    license_policy: str = "research_full",
    copy_images: bool = False,
    allow_english_labels: bool = True,
    max_image_pixels: int = 178_956_970,
) -> dict[str, Any]:
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "annotations").mkdir(parents=True, exist_ok=True)
    (output_root / "images").mkdir(parents=True, exist_ok=True)

    rows = _prepared_rows(_normalized_rows(normalized_jsonl_paths), foodseg_mode=foodseg_mode)
    eligible = _eligible_labels(
        rows,
        min_train_annotations=min_train_annotations,
        allow_english=allow_english_labels,
        max_image_pixels=max_image_pixels,
    )
    categories = [{"id": index, "name": label} for index, label in enumerate(eligible, start=1)]
    category_id_by_label = {category["name"]: int(category["id"]) for category in categories}
    coco_by_split: dict[str, dict[str, Any]] = {
        split: {"images": [], "annotations": [], "categories": categories}
        for split in ("train", "val", "test")
    }
    image_records: dict[tuple[str, str], int] = {}
    source_counts: Counter[str] = Counter()
    label_counts: Counter[str] = Counter()
    dropped_counts: Counter[str] = Counter()
    annotation_id = 1

    for row in rows:
        image_path = Path(str(row.get("image_path") or ""))
        if not image_path.exists():
            dropped_counts["missing_image"] += 1
            continue
        dimensions = _row_dimensions(row, image_path)
        if dimensions is None:
            dropped_counts["bad_dimensions"] += 1
            continue
        width, height = dimensions
        if _is_too_large(width, height, max_image_pixels=max_image_pixels):
            dropped_counts["image_too_large"] += 1
            continue
        source_dataset = str(row.get("source_dataset") or "Unknown")
        bbox_type = str(row.get("bbox_type") or get_source_policy(source_dataset).bbox_type)
        source_policy = get_source_policy(source_dataset, bbox_type=bbox_type)
        if not should_include_license(source_policy, license_policy):
            dropped_counts["license_policy"] += 1
            continue
        mapped_label = _mapped_label_for_row(row, allow_english=allow_english_labels)
        if not mapped_label or mapped_label not in category_id_by_label:
            dropped_counts["label_not_eligible"] += 1
            continue
        split = _row_split(row, image_path)
        bbox_xywh = normalize_bbox(row["bbox"], str(row.get("bbox_format") or "xyxy"))
        bbox_xyxy = xywh_to_xyxy(bbox_xywh)
        quality_signals = row.get("quality_signals") or {}
        quality = score_bbox_quality(
            image_width=width,
            image_height=height,
            bbox_xyxy=bbox_xyxy,
            bbox_type=bbox_type,
            mask_area=quality_signals.get("mask_area"),
            predicted_iou=quality_signals.get("predicted_iou"),
            stability_score=quality_signals.get("stability_score"),
        )
        if not quality.keep:
            dropped_counts["bbox_quality"] += 1
            continue

        image_key = (split, _stable_image_key(image_path))
        if image_key in image_records:
            image_id = image_records[image_key]
        else:
            image_id = _image_record_id(image_path, split)
            image_records[image_key] = image_id
            file_name = _copy_image_if_needed(image_path, output_root, split) if copy_images else str(image_path)
            coco_by_split[split]["images"].append(
                {
                    "id": image_id,
                    "file_name": file_name,
                    "width": width,
                    "height": height,
                    "source_dataset": source_dataset,
                    "original_label": str(row.get("original_label") or ""),
                    "mapped_label": mapped_label,
                    "bbox_type": bbox_type,
                    "license_risk": source_policy.license_risk,
                }
            )
        coco_by_split[split]["annotations"].append(
            {
                "id": annotation_id,
                "image_id": image_id,
                "category_id": category_id_by_label[mapped_label],
                "bbox": [round(v, 2) for v in bbox_xywh],
                "area": round(bbox_xywh[2] * bbox_xywh[3], 2),
                "iscrowd": 0,
                "source_dataset": source_dataset,
                "original_label": str(row.get("original_label") or ""),
                "mapped_label": mapped_label,
                "bbox_type": bbox_type,
                "license_risk": source_policy.license_risk,
                "quality_score": quality.score,
            }
        )
        annotation_id += 1
        source_counts[source_dataset] += 1
        label_counts[mapped_label] += 1

    for split, coco in coco_by_split.items():
        (output_root / "annotations" / f"{split}.json").write_text(
            json.dumps(coco, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    _write_csv(
        output_root / "meta" / "class_map_public.csv",
        [{"category_id": category["id"], "label": category["name"]} for category in categories],
        ["category_id", "label"],
    )
    _write_csv(
        output_root / "meta" / "source_counts.csv",
        [{"source_dataset": key, "annotations": value} for key, value in sorted(source_counts.items())],
        ["source_dataset", "annotations"],
    )
    _write_csv(
        output_root / "meta" / "label_counts.csv",
        [{"label": key, "annotations": value} for key, value in label_counts.most_common()],
        ["label", "annotations"],
    )
    summary: dict[str, Any] = {
        split: {
            "images": len(coco["images"]),
            "annotations": len(coco["annotations"]),
            "categories": len(coco["categories"]),
        }
        for split, coco in coco_by_split.items()
    }
    summary.update(
        {
            "suggested_num_classes": len(categories) + 1,
            "foodseg_mode": foodseg_mode,
            "license_policy": license_policy,
            "max_image_pixels": max_image_pixels,
            "dropped": dict(sorted(dropped_counts.items())),
        }
    )
    (output_root / "meta" / "public_dataset_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--normalized-jsonl", type=Path, nargs="+", required=True)
    parser.add_argument("--min-train-annotations", type=int, default=1)
    parser.add_argument("--foodseg-mode", choices=["skip", "union", "ingredient"], default="skip")
    parser.add_argument("--license-policy", choices=["research_full", "commercial_candidate"], default="research_full")
    parser.add_argument("--copy-images", action="store_true")
    parser.add_argument("--no-english-labels", action="store_true")
    parser.add_argument("--max-image-pixels", type=int, default=178_956_970)
    args = parser.parse_args()

    summary = build_public_food_coco(
        output_root=args.output_root,
        normalized_jsonl_paths=args.normalized_jsonl,
        min_train_annotations=args.min_train_annotations,
        foodseg_mode=args.foodseg_mode,
        license_policy=args.license_policy,
        copy_images=args.copy_images,
        allow_english_labels=not args.no_english_labels,
        max_image_pixels=args.max_image_pixels,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
