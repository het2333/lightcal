import argparse
import csv
import hashlib
import json
import re
from pathlib import Path
from typing import Any


COCO_METRIC_PATTERNS = {
    "ap": re.compile(
        r"Average Precision\s+\(AP\)\s+@\[ IoU=0\.50:0\.95 \| area=\s+all \| maxDets=100 \]\s+=\s+([0-9.]+)"
    ),
    "ap50": re.compile(
        r"Average Precision\s+\(AP\)\s+@\[ IoU=0\.50\s+\| area=\s+all \| maxDets=100 \]\s+=\s+([0-9.]+)"
    ),
    "ap75": re.compile(
        r"Average Precision\s+\(AP\)\s+@\[ IoU=0\.75\s+\| area=\s+all \| maxDets=100 \]\s+=\s+([0-9.]+)"
    ),
    "ar100": re.compile(
        r"Average Recall\s+\(AR\)\s+@\[ IoU=0\.50:0\.95 \| area=\s+all \| maxDets=100 \]\s+=\s+([0-9.]+)"
    ),
}


def sha256_file(path: Path) -> str:
    if not path.is_file() or path.stat().st_size == 0:
        return ""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_coco_eval_metrics(eval_log: Path) -> dict[str, float]:
    if not eval_log.is_file():
        return {}
    text = eval_log.read_text(encoding="utf-8", errors="ignore")
    metrics: dict[str, float] = {}
    for key, pattern in COCO_METRIC_PATTERNS.items():
        match = pattern.search(text)
        if match:
            metrics[key] = float(match.group(1))
    return metrics


def count_coco_annotation(annotation_path: Path) -> dict[str, int]:
    if not annotation_path.is_file():
        return {"images": 0, "annotations": 0, "categories": 0}
    data = json.loads(annotation_path.read_text(encoding="utf-8"))
    return {
        "images": len(data.get("images", [])),
        "annotations": len(data.get("annotations", [])),
        "categories": len(data.get("categories", [])),
    }


def metadata_file_entry(source: Path, bundle_meta_dir: Path | None = None) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "source_path": str(source),
        "sha256": sha256_file(source),
        "bytes": source.stat().st_size if source.is_file() else 0,
    }
    if bundle_meta_dir is None:
        return entry

    destination = bundle_meta_dir / source.name
    entry["bundle_path"] = str(destination)
    if source.is_file():
        bundle_meta_dir.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
        entry["bundle_sha256"] = sha256_file(destination)
        entry["bundle_bytes"] = destination.stat().st_size
    else:
        entry["bundle_sha256"] = ""
        entry["bundle_bytes"] = 0
    return entry


def build_labels_payload(class_map: Path) -> dict[str, Any]:
    rows: list[dict[str, str]] = []
    if class_map.is_file():
        with class_map.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))

    categories: list[dict[str, Any]] = []
    category_id_to_label: dict[str, str] = {}
    model_index_to_label: dict[str, str] = {}
    for row in rows:
        category_id = int(row["category_id"])
        model_index = category_id - 1
        label = row["canonical_label"]
        category = {
            "category_id": category_id,
            "model_index": model_index,
            "label": label,
            "fallback_label": row.get("fallback_label", ""),
            "tier": row.get("tier", ""),
            "group": row.get("group", ""),
            "aliases": [alias for alias in row.get("aliases", "").split("|") if alias],
        }
        categories.append(category)
        category_id_to_label[str(category_id)] = label
        model_index_to_label[str(model_index)] = label

    return {
        "num_classes": len(categories),
        "category_id_to_label": category_id_to_label,
        "model_index_to_label": model_index_to_label,
        "categories": categories,
    }


def write_labels_json(class_map: Path, labels_json: Path) -> dict[str, Any]:
    labels = build_labels_payload(class_map)
    labels_json.parent.mkdir(parents=True, exist_ok=True)
    labels_json.write_text(json.dumps(labels, ensure_ascii=False, indent=2), encoding="utf-8")
    return labels


def artifact_file_entry(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {"path": "", "sha256": "", "bytes": 0}
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size if path.is_file() else 0,
    }


def metric_text(metrics: dict[str, float], key: str) -> str:
    value = metrics.get(key)
    if value is None:
        return "n/a"
    return f"{value:.3f}"


def write_model_card(manifest: dict[str, Any], model_card: Path) -> None:
    metrics = manifest.get("metrics", {}).get("coco_eval_bbox", {})
    clean_test = manifest.get("dataset", {}).get("clean_test", {})
    policy = manifest.get("inference_policy", {})
    labels_path = manifest.get("labels", {}).get("path", "")
    metadata_files = manifest.get("metadata_files", {})
    metadata_names = ", ".join(sorted(metadata_files)) or "n/a"
    review_range = policy.get("review_confidence_range", ["n/a", "n/a"])
    if isinstance(review_range, list) and len(review_range) == 2:
        review_range_text = f"{review_range[0]}-{review_range[1]}"
    else:
        review_range_text = "n/a"

    lines = [
        "# RT-DETRv2 R101 Food Dish Detector",
        "",
        "## Model",
        f"- Name: {manifest.get('model', 'RT-DETRv2 R101')}",
        f"- Input size: {manifest.get('input_size', 'n/a')}",
        f"- Checkpoint: {manifest.get('checkpoint', '')}",
        f"- ONNX: {manifest.get('onnx', '')}",
        "",
        "## Intended Use",
        "- Detect dish-level bounding boxes in food photos.",
        "- Return a dish label, confidence score, and bbox for product inference.",
        "- Use top-3 confirmation for uncertain predictions before user-facing automation.",
        "",
        "## Key Artifacts",
        "- product_manifest.json",
        "- product_verification.json",
        f"- {Path(labels_path).name if labels_path else 'labels.json'}",
        f"- Metadata files: {metadata_names}",
        "",
        "## Clean Test Metrics",
        f"- AP: {metric_text(metrics, 'ap')}",
        f"- AP50: {metric_text(metrics, 'ap50')}",
        f"- AP75: {metric_text(metrics, 'ap75')}",
        f"- AR100: {metric_text(metrics, 'ar100')}",
        "",
        "## Clean Test Dataset",
        f"- Images: {clean_test.get('images', 0)}",
        f"- Annotations: {clean_test.get('annotations', 0)}",
        f"- Categories: {clean_test.get('categories', 0)}",
        "",
        "## Inference Policy",
        f"- Accept predictions at confidence >= {policy.get('accept_confidence', 'n/a')}.",
        f"- Send predictions in confidence range {review_range_text} to review.",
        f"- Reject predictions below confidence {policy.get('reject_below_confidence', 'n/a')}.",
        "",
        "## Data And License Notes",
        "- The training bundle combines public food datasets, mask-derived boxes, and pseudo single-label boxes.",
        "- Review meta/license_risk.csv before commercial release and keep source attribution with the bundle.",
        "",
    ]
    model_card.parent.mkdir(parents=True, exist_ok=True)
    model_card.write_text("\n".join(lines), encoding="utf-8")


def build_product_manifest(
    *,
    model: str,
    input_size: int,
    checkpoint: Path,
    onnx: Path,
    clean_test_config: Path,
    clean_test_eval_log: Path,
    onnx_export_log: Path,
    eval_pth: Path,
    class_map: Path,
    source_counts: Path,
    source_map: Path | None = None,
    license_risk: Path | None = None,
    pseudo_label_score: Path | None = None,
    test_annotation: Path,
    bundle_meta_dir: Path | None = None,
    labels_json: Path | None = None,
    model_card: Path | None = None,
    output_path: Path | None = None,
) -> dict[str, Any]:
    metadata_sources = {
        "class_map": class_map,
        "source_counts": source_counts,
    }
    if source_map is not None:
        metadata_sources["source_map"] = source_map
    if license_risk is not None:
        metadata_sources["license_risk"] = license_risk
    if pseudo_label_score is not None:
        metadata_sources["pseudo_label_score"] = pseudo_label_score
    labels_count = 0
    if labels_json is not None:
        labels_count = write_labels_json(class_map, labels_json)["num_classes"]

    manifest: dict[str, Any] = {
        "model": model,
        "input_size": input_size,
        "checkpoint": str(checkpoint),
        "checkpoint_sha256": sha256_file(checkpoint),
        "onnx": str(onnx),
        "onnx_sha256": sha256_file(onnx),
        "clean_test_config": str(clean_test_config),
        "clean_test_eval_log": str(clean_test_eval_log),
        "onnx_export_log": str(onnx_export_log),
        "eval_pth": str(eval_pth),
        "class_map": str(class_map),
        "source_counts": str(source_counts),
        "metadata_files": {
            key: metadata_file_entry(path, bundle_meta_dir) for key, path in metadata_sources.items()
        },
        "labels": artifact_file_entry(labels_json) | {"num_classes": labels_count},
        "dataset": {
            "clean_test": count_coco_annotation(test_annotation),
            "test_annotation": str(test_annotation),
        },
        "metrics": {
            "coco_eval_bbox": parse_coco_eval_metrics(clean_test_eval_log),
        },
        "inference_policy": {
            "accept_confidence": 0.75,
            "review_confidence_range": [0.45, 0.75],
            "reject_below_confidence": 0.45,
            "review_action": "Food-R1/top-3 user confirmation",
        },
        "product_gates": {
            "p1_bbox_recall_at_0_5_target": 0.85,
            "p2_bbox_recall_at_0_5_target": 0.90,
            "p1_common_dish_top1_target": 0.75,
            "p2_common_dish_top1_target": 0.85,
        },
    }
    if model_card is not None:
        write_model_card(manifest, model_card)
        manifest["model_card"] = artifact_file_entry(model_card)
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="RT-DETRv2 R101")
    parser.add_argument("--input-size", type=int, default=800)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--onnx", required=True, type=Path)
    parser.add_argument("--clean-test-config", required=True, type=Path)
    parser.add_argument("--clean-test-eval-log", required=True, type=Path)
    parser.add_argument("--onnx-export-log", required=True, type=Path)
    parser.add_argument("--eval-pth", required=True, type=Path)
    parser.add_argument("--class-map", required=True, type=Path)
    parser.add_argument("--source-counts", required=True, type=Path)
    parser.add_argument("--source-map", type=Path)
    parser.add_argument("--license-risk", type=Path)
    parser.add_argument("--pseudo-label-score", type=Path)
    parser.add_argument("--test-annotation", required=True, type=Path)
    parser.add_argument("--bundle-meta-dir", type=Path)
    parser.add_argument("--labels-json", type=Path)
    parser.add_argument("--model-card", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest = build_product_manifest(
        model=args.model,
        input_size=args.input_size,
        checkpoint=args.checkpoint,
        onnx=args.onnx,
        clean_test_config=args.clean_test_config,
        clean_test_eval_log=args.clean_test_eval_log,
        onnx_export_log=args.onnx_export_log,
        eval_pth=args.eval_pth,
        class_map=args.class_map,
        source_counts=args.source_counts,
        source_map=args.source_map,
        license_risk=args.license_risk,
        pseudo_label_score=args.pseudo_label_score,
        test_annotation=args.test_annotation,
        bundle_meta_dir=args.bundle_meta_dir,
        labels_json=args.labels_json,
        model_card=args.model_card,
        output_path=args.output,
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
