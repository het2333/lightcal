#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import re
import time
from pathlib import Path
from typing import Any

import requests
from PIL import Image


DEFAULT_SERVICE_URL = "http://127.0.0.1:8003/v1/depth-meal/analyze"
DEFAULT_ASSET_ROOT = Path("/root/autodl-tmp/cal_food_compare_assets")


SAMPLES = [
    {"name": "有深度-cap_5c68", "route": "ios_depth", "capture": "depth_captures/cap_5c68ecc9547a"},
    {"name": "有深度-cap_cab", "route": "ios_depth", "capture": "depth_captures/cap_cab838efdd31"},
    {"name": "有深度-cap_04f23", "route": "ios_depth", "capture": "depth_captures/cap_04f23a03f8bb"},
    {"name": "有深度-cap_19d", "route": "ios_depth", "capture": "depth_captures/cap_19d514014ff4"},
    {"name": "无深度-蔬菜拼盘", "route": "metric3d", "rgb": "rgb/vegetable_board/rgb.jpg", "metadata": "rgb/vegetable_board/metadata.json"},
    {"name": "无深度-炸物拼盘", "route": "metric3d", "rgb": "rgb/fried_platter/rgb.jpg", "metadata": "rgb/fried_platter/metadata.json"},
    {"name": "无深度-米饭炒面套餐", "route": "metric3d", "rgb": "rgb/cafeteria_meal/rgb.jpg", "metadata": "rgb/cafeteria_meal/metadata.json"},
    {"name": "无深度-锅/剩余图", "route": "metric3d", "rgb": "rgb/img_4623_2/rgb.jpg", "metadata": "rgb/img_4623_2/metadata.json"},
    {"name": "无深度-IMG_6388", "route": "metric3d", "rgb": "rgb/img_6388.jpg"},
]


def safe_id(value: str) -> str:
    return re.sub(r"[^0-9A-Za-z_.-]+", "_", value).strip("_") or "sample"


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def read_json(path: Path | None) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def image_metadata(path: Path, metadata_path: Path | None) -> dict[str, Any]:
    metadata = read_json(metadata_path)
    if "rgb" not in metadata:
        with Image.open(path) as image:
            metadata["rgb"] = {"width": image.width, "height": image.height}
    return metadata


def payload_for(sample: dict[str, str], asset_root: Path) -> dict[str, Any]:
    if capture := sample.get("capture"):
        capture_dir = asset_root / capture
        payload: dict[str, Any] = {
            "rgb_base64": b64(capture_dir / "rgb.jpg"),
            "metadata": read_json(capture_dir / "metadata.json"),
            "capture_id": f"compare_{safe_id(sample['name'])}",
        }
        for source_name, payload_name in (
            ("depth.bin", "depth_base64"),
            ("confidence.bin", "confidence_base64"),
        ):
            source = capture_dir / source_name
            if source.exists():
                payload[payload_name] = b64(source)
        return payload

    rgb = asset_root / sample["rgb"]
    metadata = image_metadata(rgb, asset_root / sample["metadata"] if sample.get("metadata") else None)
    return {
        "rgb_base64": b64(rgb),
        "metadata": metadata,
        "capture_id": f"compare_{safe_id(sample['name'])}",
    }


def trim_large(value: Any) -> Any:
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key.endswith("_base64") and isinstance(item, str):
                result[key] = f"<base64:{len(item)} chars>"
            else:
                result[key] = trim_large(item)
        return result
    if isinstance(value, list):
        return [trim_large(item) for item in value]
    return value


def as_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def nested_float(item: dict[str, Any], path: tuple[str, ...], default: float = 0.0) -> float:
    value: Any = item
    for key in path:
        if not isinstance(value, dict):
            return default
        value = value.get(key)
    return as_float(value, default)


def density_for(item: dict[str, Any]) -> float:
    for path in (
        ("weight", "density_g_per_ml"),
        ("density_hint", "density_g_per_ml"),
        ("density_g_per_ml",),
    ):
        value = nested_float(item, path)
        if value > 0:
            return value
    return 1.0


def kcal100_for(item: dict[str, Any]) -> float:
    for path in (
        ("nutrition_per_100g", "kcal"),
        ("nutrition_per_100g", "calories"),
        ("nutrition", "kcal"),
        ("direct_nutrition", "kcal"),
        ("direct_nutrition", "calories"),
        ("kcal_per_100g",),
        ("kcal100",),
    ):
        value = nested_float(item, path)
        if value > 0:
            return value
    return 0.0


def item_summary(item: dict[str, Any]) -> dict[str, Any]:
    volume_ml = as_float(item.get("estimated_volume_ml"))
    grams = as_float(item.get("visual_estimated_grams"))
    if grams <= 0:
        grams = nested_float(item, ("weight", "estimated_grams"))
    if grams <= 0 and volume_ml > 0:
        grams = volume_ml * density_for(item)
    kcal100 = kcal100_for(item)
    kcal = grams * kcal100 / 100.0 if grams > 0 and kcal100 > 0 else as_float(item.get("calories"))
    seg = item.get("segmentation") if isinstance(item.get("segmentation"), dict) else {}
    vol = item.get("volume") if isinstance(item.get("volume"), dict) else {}
    return {
        "name": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or item.get("name") or "",
        "detector_phrase": item.get("detector_phrase") or "",
        "volume_ml": round(volume_ml, 1),
        "grams": round(grams, 1),
        "density": round(density_for(item), 3),
        "kcal100": round(kcal100, 1),
        "kcal": round(kcal, 1),
        "mask_area": int(seg.get("area_pixels") or 0),
        "mask_conf": round(as_float(seg.get("mask_confidence")), 3),
        "volume_method": vol.get("volume_method") or "",
        "volume_fallback": bool(vol.get("fallback")),
    }


def run_batch(service_url: str, asset_root: Path, output_path: Path, timeout: int, start: int, limit: int | None) -> None:
    rows = []
    samples = SAMPLES[start:]
    samples = samples[:limit] if limit and limit > 0 else samples
    for sample in samples:
        started = time.time()
        row: dict[str, Any] = {"name": sample["name"], "route": sample["route"]}
        try:
            response = requests.post(service_url, json=payload_for(sample, asset_root), timeout=timeout)
            row["http_status"] = response.status_code
            row["wall_seconds"] = round(time.time() - started, 3)
            if response.status_code >= 400:
                row["error"] = response.text[:1200]
            else:
                data = response.json()
                items = data.get("items") if isinstance(data.get("items"), list) else []
                skipped = data.get("skipped_items") if isinstance(data.get("skipped_items"), list) else []
                summary_items = [item_summary(item) for item in items if isinstance(item, dict)]
                timings = data.get("stage_timings") if isinstance(data.get("stage_timings"), dict) else {}
                row["summary"] = {
                    "status": data.get("status"),
                    "mode": data.get("estimation_mode"),
                    "latency_seconds": data.get("latency_seconds"),
                    "depth_source": timings.get("depth_source"),
                    "scene_seconds": timings.get("scene_model_seconds"),
                    "metric3d_seconds": timings.get("metric3d_depth_seconds"),
                    "dino_seconds": timings.get("grounding_dino_seconds"),
                    "sam2_seconds": timings.get("sam2_segmentation_seconds"),
                    "items_count": len(items),
                    "skipped_count": len(skipped),
                    "mask_count": sum(1 for item in summary_items if item["mask_area"] > 0),
                    "total_kcal_calc": round(sum(item["kcal"] for item in summary_items), 1),
                    "items": summary_items,
                    "skipped": skipped,
                }
                row["response"] = trim_large(data)
        except Exception as exc:
            row["wall_seconds"] = round(time.time() - started, 3)
            row["error"] = f"{type(exc).__name__}: {exc}"
        rows.append(row)
        printable = {"name": row["name"], "route": row["route"], **row.get("summary", {}), "error": row.get("error")}
        print(json.dumps(printable, ensure_ascii=False), flush=True)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved={output_path}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service-url", default=DEFAULT_SERVICE_URL)
    parser.add_argument("--asset-root", type=Path, default=DEFAULT_ASSET_ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    run_batch(args.service_url, args.asset_root, args.output, args.timeout, args.start, args.limit)


if __name__ == "__main__":
    main()
