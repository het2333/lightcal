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


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode("ascii")


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
    return as_float(item.get("kcal_per_100g"), 0.0) or as_float(item.get("kcal100"), 0.0)


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
        "mask_conf": round(as_float(seg.get("mask_confidence"), 0.0), 4),
        "volume_method": vol.get("volume_method") or "",
        "volume_fallback": bool(vol.get("fallback")),
    }


def compact_response(data: dict[str, Any]) -> dict[str, Any]:
    output = dict(data)
    for key in ("segmentations", "detections"):
        output[key] = data.get(key, [])
    for item in output.get("items", []) or []:
        if isinstance(item, dict) and isinstance(item.get("segmentation"), dict):
            preview = item["segmentation"].get("mask_preview_base64")
            if isinstance(preview, str):
                item["segmentation"]["mask_preview_base64"] = f"<base64:{len(preview)} chars>"
    return output


def run(images_dir: Path, output: Path) -> None:
    rows = []
    paths = sorted(
        p
        for p in images_dir.iterdir()
        if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}
    )
    for path in paths:
        started = time.time()
        with Image.open(path) as image:
            metadata = {"rgb": {"width": image.width, "height": image.height}}
        row: dict[str, Any] = {"name": path.stem, "path": str(path)}
        try:
            response = requests.post(
                SERVICE_URL,
                json={
                    "rgb_base64": b64(path),
                    "metadata": metadata,
                    "capture_id": f"complex_{path.stem}",
                },
                timeout=1200,
            )
            row["http_status"] = response.status_code
            row["wall_seconds"] = round(time.time() - started, 3)
            if response.status_code >= 400:
                row["error"] = response.text[:1200]
            else:
                data = response.json()
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
                    "fallback_count": sum(1 for item in summary_items if item["volume_fallback"]),
                    "total_kcal_calc": round(sum(item["kcal"] for item in summary_items), 1),
                    "items": summary_items,
                    "skipped": skipped,
                }
                row["response"] = compact_response(data)
        except Exception as exc:
            row["wall_seconds"] = round(time.time() - started, 3)
            row["error"] = f"{type(exc).__name__}: {exc}"
        rows.append(row)
        print(json.dumps({"name": row["name"], **row.get("summary", {}), "error": row.get("error")}, ensure_ascii=False), flush=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved={output}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.images_dir, args.output)


if __name__ == "__main__":
    main()
