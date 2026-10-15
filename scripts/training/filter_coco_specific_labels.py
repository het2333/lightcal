#!/usr/bin/env python3
"""Filter a COCO food detector dataset to concrete dish-name labels only."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


DEFAULT_EXCLUDED_LABELS = {
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
    "甜品",
}


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _is_specific_label(label: str, excluded_labels: set[str]) -> bool:
    return label not in excluded_labels and not label.startswith("未知")


def _absolute_file_name(source_root: Path, file_name: str) -> str:
    path = Path(file_name)
    if path.is_absolute():
        return str(path)
    return str((source_root / path).resolve())


def _eligible_category_ids(
    train: dict[str, Any],
    *,
    excluded_labels: set[str],
    min_train_annotations: int,
) -> tuple[list[dict[str, Any]], dict[int, int]]:
    categories = sorted(train.get("categories", []), key=lambda row: int(row["id"]))
    id_to_name = {int(category["id"]): str(category.get("name", category["id"])) for category in categories}
    counts = Counter(int(annotation["category_id"]) for annotation in train.get("annotations", []))
    eligible_old_ids = [
        old_id
        for old_id, name in id_to_name.items()
        if _is_specific_label(name, excluded_labels) and counts[old_id] >= min_train_annotations
    ]
    old_to_new = {old_id: index for index, old_id in enumerate(eligible_old_ids, start=1)}
    remapped_categories = [{"id": old_to_new[old_id], "name": id_to_name[old_id]} for old_id in eligible_old_ids]
    return remapped_categories, old_to_new


def _filter_split(
    split_data: dict[str, Any],
    *,
    source_root: Path,
    remapped_categories: list[dict[str, Any]],
    old_to_new_category_id: dict[int, int],
) -> dict[str, Any]:
    annotations: list[dict[str, Any]] = []
    used_image_ids: set[int] = set()
    next_annotation_id = 1
    for annotation in split_data.get("annotations", []):
        old_category_id = int(annotation["category_id"])
        if old_category_id not in old_to_new_category_id:
            continue
        remapped = dict(annotation)
        remapped["id"] = next_annotation_id
        remapped["category_id"] = old_to_new_category_id[old_category_id]
        annotations.append(remapped)
        used_image_ids.add(int(annotation["image_id"]))
        next_annotation_id += 1

    images: list[dict[str, Any]] = []
    for image in split_data.get("images", []):
        if int(image["id"]) not in used_image_ids:
            continue
        remapped_image = dict(image)
        remapped_image["file_name"] = _absolute_file_name(source_root, str(image["file_name"]))
        images.append(remapped_image)

    return {
        "images": images,
        "annotations": annotations,
        "categories": remapped_categories,
    }


def _write_class_map(output_root: Path, categories: Iterable[dict[str, Any]]) -> None:
    meta_dir = output_root / "meta"
    meta_dir.mkdir(parents=True, exist_ok=True)
    with (meta_dir / "class_map_specific.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["category_id", "canonical_label"])
        writer.writeheader()
        for category in categories:
            writer.writerow({"category_id": category["id"], "canonical_label": category["name"]})


def filter_coco_specific_labels(
    *,
    source_root: Path,
    output_root: Path,
    excluded_labels: Iterable[str] = DEFAULT_EXCLUDED_LABELS,
    min_train_annotations: int = 1,
    splits: Iterable[str] = ("train", "val", "test"),
) -> dict[str, Any]:
    source_root = source_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    train = _load_json(source_root / "annotations" / "train.json")
    excluded_set = set(excluded_labels)
    remapped_categories, old_to_new_category_id = _eligible_category_ids(
        train,
        excluded_labels=excluded_set,
        min_train_annotations=min_train_annotations,
    )

    summary: dict[str, Any] = {
        "source_root": str(source_root),
        "output_root": str(output_root),
        "excluded_labels": sorted(excluded_set),
        "min_train_annotations": min_train_annotations,
        "suggested_num_classes": len(remapped_categories) + 1,
    }
    for split in splits:
        source_path = source_root / "annotations" / f"{split}.json"
        if source_path.exists():
            split_data = _load_json(source_path)
        else:
            split_data = {"images": [], "annotations": [], "categories": train.get("categories", [])}
        filtered = _filter_split(
            split_data,
            source_root=source_root,
            remapped_categories=remapped_categories,
            old_to_new_category_id=old_to_new_category_id,
        )
        _write_json(output_root / "annotations" / f"{split}.json", filtered)
        summary[split] = {
            "images": len(filtered["images"]),
            "annotations": len(filtered["annotations"]),
            "categories": len(filtered["categories"]),
        }

    _write_class_map(output_root, remapped_categories)
    _write_json(output_root / "meta" / "specific_dataset_summary.json", summary)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--min-train-annotations", type=int, default=1)
    args = parser.parse_args()
    summary = filter_coco_specific_labels(
        source_root=args.source_root,
        output_root=args.output_root,
        min_train_annotations=args.min_train_annotations,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
