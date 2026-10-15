#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import time
from pathlib import Path
from typing import Any

import requests
from PIL import Image


SERVICE_URL = "http://127.0.0.1:8003/v1/depth-meal/analyze"
SERVICE_ROOT = Path("/root/autodl-tmp/depth-pipeline-service")
TEST_ROOT = Path("/root/autodl-tmp/glm_food_r1_experiment/test_images")


DEFAULT_SAMPLES = [
    {
        "name": "有深度-cap_5c68",
        "route": "ios_depth",
        "capture_dir": SERVICE_ROOT / "cap_5c68ecc9547a",
    },
    {
        "name": "有深度-cap_cab",
        "route": "ios_depth",
        "capture_dir": SERVICE_ROOT / "cap_cab838efdd31",
    },
    {
        "name": "无深度-cap_a474",
        "route": "metric3d",
        "rgb": SERVICE_ROOT / "cap_a474cc887d1d" / "rgb.jpg",
        "metadata": SERVICE_ROOT / "cap_a474cc887d1d" / "metadata.json",
    },
    {
        "name": "无深度-IMG_6388",
        "route": "metric3d",
        "rgb": TEST_ROOT / "phone_user_img_6388.jpg",
    },
    {
        "name": "无深度-黄瓜饭",
        "route": "metric3d",
        "rgb": TEST_ROOT / "phone_cucumber_rice.jpg",
    },
    {
        "name": "无深度-剩饭1",
        "route": "metric3d",
        "rgb": TEST_ROOT / "phone_leftover_rice_1.jpg",
    },
    {
        "name": "无深度-剩饭2",
        "route": "metric3d",
        "rgb": TEST_ROOT / "phone_leftover_rice_2.jpg",
    },
]


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


def read_json(path: Path | None) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def image_metadata(path: Path, metadata_path: Path | None = None) -> dict[str, Any]:
    metadata = read_json(metadata_path)
    if "rgb" not in metadata:
        with Image.open(path) as image:
            metadata["rgb"] = {"width": image.width, "height": image.height}
    return metadata


def payload_for(sample: dict[str, Any]) -> dict[str, Any]:
    capture_dir = sample.get("capture_dir")
    if capture_dir:
        capture_dir = Path(capture_dir)
        metadata = read_json(capture_dir / "metadata.json")
        payload = {
            "rgb_base64": b64(capture_dir / "rgb.jpg"),
            "metadata": metadata,
            "capture_id": f"batch_{sample['name']}",
        }
        if (capture_dir / "depth.bin").exists():
            payload["depth_base64"] = b64(capture_dir / "depth.bin")
        if (capture_dir / "confidence.bin").exists():
            payload["confidence_base64"] = b64(capture_dir / "confidence.bin")
        return payload

    rgb = Path(sample["rgb"])
    metadata = image_metadata(rgb, Path(sample["metadata"]) if sample.get("metadata") else None)
    return {
        "rgb_base64": b64(rgb),
        "metadata": metadata,
        "capture_id": f"batch_{sample['name']}",
    }


def without_large_base64(value: Any) -> Any:
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if key == "mask_preview_base64":
                cleaned[key] = f"<base64:{len(item)} chars>" if isinstance(item, str) else item
            else:
                cleaned[key] = without_large_base64(item)
        return cleaned
    if isinstance(value, list):
        return [without_large_base64(item) for item in value]
    return value


def as_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def density_for(item: dict[str, Any]) -> float:
    weight = item.get("weight") if isinstance(item.get("weight"), dict) else {}
    direct = as_float(weight.get("density_g_per_ml"), 0.0)
    if direct > 0:
        return direct
    hint = item.get("density_hint") if isinstance(item.get("density_hint"), dict) else {}
    direct = as_float(hint.get("density_g_per_ml"), 0.0)
    if direct > 0:
        return direct
    direct = as_float(item.get("density_g_per_ml"), 0.0)
    return direct if direct > 0 else 1.0


def kcal100_for(item: dict[str, Any]) -> float:
    for key in ("nutrition_per_100g", "nutrition", "direct_nutrition"):
        pack = item.get(key)
        if isinstance(pack, dict):
            kcal = as_float(pack.get("kcal"), 0.0) or as_float(pack.get("calories"), 0.0)
            if kcal > 0:
                return kcal
    kcal = as_float(item.get("kcal_per_100g"), 0.0)
    if kcal <= 0:
        kcal = as_float(item.get("kcal100"), 0.0)
    return kcal


def item_summary(item: dict[str, Any]) -> dict[str, Any]:
    volume_ml = as_float(item.get("estimated_volume_ml"), 0.0)
    grams = as_float(item.get("visual_estimated_grams"), 0.0)
    if grams <= 0 and isinstance(item.get("weight"), dict):
        grams = as_float(item["weight"].get("estimated_grams"), 0.0)
    if grams <= 0 and volume_ml > 0:
        grams = volume_ml * density_for(item)
    kcal100 = kcal100_for(item)
    kcal = grams * kcal100 / 100.0 if grams > 0 and kcal100 > 0 else 0.0
    seg = item.get("segmentation") if isinstance(item.get("segmentation"), dict) else {}
    vol = item.get("volume") if isinstance(item.get("volume"), dict) else {}
    return {
        "name": item.get("name_zh") or item.get("name_en") or item.get("detector_phrase") or "",
        "volume_ml": round(volume_ml, 1),
        "grams": round(grams, 1),
        "density": round(density_for(item), 3),
        "kcal100": round(kcal100, 1),
        "kcal": round(kcal, 1),
        "mask_area": int(seg.get("area_pixels") or 0),
        "mask_conf": as_float(seg.get("mask_confidence"), 0.0),
        "volume_method": vol.get("volume_method") or "",
        "volume_fallback": bool(vol.get("fallback")),
    }


def run_batch(output_path: Path) -> None:
    results = []
    for sample in DEFAULT_SAMPLES:
        started = time.time()
        row = {"name": sample["name"], "route": sample["route"]}
        try:
            response = requests.post(SERVICE_URL, json=payload_for(sample), timeout=1200)
            row["http_status"] = response.status_code
            row["wall_seconds"] = round(time.time() - started, 3)
            if response.status_code >= 400:
                row["error"] = response.text[:1000]
            else:
                data = response.json()
                row["response"] = without_large_base64(data)
                items = data.get("items") if isinstance(data.get("items"), list) else []
                skipped = data.get("skipped_items") if isinstance(data.get("skipped_items"), list) else []
                summary_items = [item_summary(item) for item in items if isinstance(item, dict)]
                row["summary"] = {
                    "status": data.get("status"),
                    "mode": data.get("estimation_mode"),
                    "latency_seconds": data.get("latency_seconds"),
                    "depth_source": (data.get("stage_timings") or {}).get("depth_source"),
                    "scene_seconds": (data.get("stage_timings") or {}).get("scene_model_seconds"),
                    "metric3d_seconds": (data.get("stage_timings") or {}).get("metric3d_depth_seconds"),
                    "dino_seconds": (data.get("stage_timings") or {}).get("grounding_dino_seconds"),
                    "sam2_seconds": (data.get("stage_timings") or {}).get("sam2_segmentation_seconds"),
                    "items_count": len(items),
                    "skipped_count": len(skipped),
                    "mask_count": sum(1 for item in summary_items if item["mask_area"] > 0),
                    "total_kcal_calc": round(sum(item["kcal"] for item in summary_items), 1),
                    "items": summary_items,
                    "skipped": skipped,
                }
        except Exception as exc:
            row["wall_seconds"] = round(time.time() - started, 3)
            row["error"] = f"{type(exc).__name__}: {exc}"
        results.append(row)
        print(json.dumps({"name": row["name"], "route": row["route"], **row.get("summary", {}), "error": row.get("error")}, ensure_ascii=False), flush=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved={output_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=SERVICE_ROOT / "outputs" / f"step80_full_pipeline_batch_{int(time.time())}.json")
    args = parser.parse_args()
    run_batch(args.output)


if __name__ == "__main__":
    main()
