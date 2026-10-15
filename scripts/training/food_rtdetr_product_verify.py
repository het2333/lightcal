import argparse
import json
from pathlib import Path
from typing import Any

from scripts.training.food_rtdetr_product_manifest import sha256_file


def check_result(ok: bool, detail: str) -> dict[str, Any]:
    return {"ok": ok, "detail": detail}


def check_file(path_text: str, *, expected_sha256: str = "") -> dict[str, Any]:
    path = Path(path_text)
    if not path.is_file():
        return check_result(False, f"missing: {path}")
    size = path.stat().st_size
    if size <= 0:
        return check_result(False, f"empty: {path}")
    actual_sha256 = sha256_file(path)
    if expected_sha256 and actual_sha256 != expected_sha256:
        return check_result(False, f"sha256 mismatch: {path}")
    return check_result(True, f"bytes={size} sha256={actual_sha256}")


def add_metric_check(checks: dict[str, dict[str, Any]], manifest: dict[str, Any], key: str) -> None:
    value = manifest.get("metrics", {}).get("coco_eval_bbox", {}).get(key)
    checks[f"metrics.coco_eval_bbox.{key}"] = check_result(
        isinstance(value, (int, float)),
        f"value={value}",
    )


def add_labels_checks(checks: dict[str, dict[str, Any]], manifest: dict[str, Any]) -> None:
    labels_entry = manifest.get("labels", {})
    labels_path = labels_entry.get("path", "")
    checks["labels.file"] = check_file(labels_path, expected_sha256=labels_entry.get("sha256", ""))
    if not checks["labels.file"]["ok"]:
        checks["labels.num_classes"] = check_result(False, "labels file unavailable")
        checks["labels.category_id_to_label"] = check_result(False, "labels file unavailable")
        checks["labels.model_index_to_label"] = check_result(False, "labels file unavailable")
        return

    labels = json.loads(Path(labels_path).read_text(encoding="utf-8"))
    num_classes = labels.get("num_classes")
    checks["labels.num_classes"] = check_result(
        isinstance(num_classes, int) and num_classes > 0,
        f"value={num_classes}",
    )
    category_id_to_label = labels.get("category_id_to_label")
    model_index_to_label = labels.get("model_index_to_label")
    checks["labels.category_id_to_label"] = check_result(
        isinstance(category_id_to_label, dict) and len(category_id_to_label) == num_classes,
        f"count={len(category_id_to_label) if isinstance(category_id_to_label, dict) else None}",
    )
    checks["labels.model_index_to_label"] = check_result(
        isinstance(model_index_to_label, dict) and len(model_index_to_label) == num_classes,
        f"count={len(model_index_to_label) if isinstance(model_index_to_label, dict) else None}",
    )


def verify_product_bundle(*, manifest_path: Path, output_path: Path | None = None) -> dict[str, Any]:
    checks: dict[str, dict[str, Any]] = {}

    if not manifest_path.is_file():
        checks["manifest.exists"] = check_result(False, f"missing: {manifest_path}")
        report = {"ok": False, "manifest": str(manifest_path), "checks": checks, "summary": {"checked_count": 1, "failed_count": 1}}
        if output_path is not None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        return report

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    checks["manifest.exists"] = check_result(True, str(manifest_path))
    checks["checkpoint.file"] = check_file(manifest.get("checkpoint", ""), expected_sha256=manifest.get("checkpoint_sha256", ""))
    checks["onnx.file"] = check_file(manifest.get("onnx", ""), expected_sha256=manifest.get("onnx_sha256", ""))
    checks["clean_test_config.file"] = check_file(manifest.get("clean_test_config", ""))
    checks["clean_test_eval_log.file"] = check_file(manifest.get("clean_test_eval_log", ""))
    checks["onnx_export_log.file"] = check_file(manifest.get("onnx_export_log", ""))
    checks["eval_pth.file"] = check_file(manifest.get("eval_pth", ""))
    model_card_entry = manifest.get("model_card", {})
    checks["model_card.file"] = check_file(
        model_card_entry.get("path", ""),
        expected_sha256=model_card_entry.get("sha256", ""),
    )

    clean_test = manifest.get("dataset", {}).get("clean_test", {})
    for key in ["images", "annotations", "categories"]:
        value = clean_test.get(key)
        checks[f"dataset.clean_test.{key}"] = check_result(
            isinstance(value, int) and value > 0,
            f"value={value}",
        )

    for key in ["ap", "ap50", "ap75", "ar100"]:
        add_metric_check(checks, manifest, key)

    policy = manifest.get("inference_policy", {})
    checks["inference_policy.accept_confidence"] = check_result(
        isinstance(policy.get("accept_confidence"), (int, float)),
        f"value={policy.get('accept_confidence')}",
    )
    checks["inference_policy.review_confidence_range"] = check_result(
        isinstance(policy.get("review_confidence_range"), list) and len(policy.get("review_confidence_range")) == 2,
        f"value={policy.get('review_confidence_range')}",
    )
    add_labels_checks(checks, manifest)

    for name, entry in manifest.get("metadata_files", {}).items():
        source_path = entry.get("source_path", "")
        bundle_path = entry.get("bundle_path", source_path)
        checks[f"metadata_files.{name}.source_sha256"] = check_file(
            source_path,
            expected_sha256=entry.get("sha256", ""),
        )
        checks[f"metadata_files.{name}.bundle_sha256"] = check_file(
            bundle_path,
            expected_sha256=entry.get("bundle_sha256") or entry.get("sha256", ""),
        )

    failed_count = sum(1 for result in checks.values() if not result["ok"])
    report = {
        "ok": failed_count == 0,
        "manifest": str(manifest_path),
        "checks": checks,
        "summary": {
            "checked_count": len(checks),
            "failed_count": failed_count,
        },
    }

    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    report = verify_product_bundle(manifest_path=args.manifest, output_path=args.output)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not report["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
