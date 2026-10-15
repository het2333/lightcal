#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from PIL import Image

import probe_sam2_first_dino_filter as probe


def run_case(case: dict, base_out_dir: Path, args: argparse.Namespace) -> dict:
    case_name = case["name"]
    out_dir = base_out_dir / case_name
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    timings: dict[str, float] = {}

    targets = probe.load_targets(Path(case["targets"]))
    original = Image.open(case["image"]).convert("RGB")
    image = original.copy()
    if args.max_edge > 0:
        image.thumbnail((args.max_edge, args.max_edge))
    sx = image.width / original.width
    sy = image.height / original.height

    t0 = time.perf_counter()
    masks = probe.generate_masks(image, args.device, args.points_per_side, args.crop_n_layers)
    timings["sam2_seconds"] = round(time.perf_counter() - t0, 3)

    t0 = time.perf_counter()
    if args.dino_mode == "per_phrase":
        detections = probe.dino_detections_per_phrase(image, targets)
    else:
        detections = probe.dino_detections_combined(image, targets)
    timings["dino_seconds"] = round(time.perf_counter() - t0, 3)

    t0 = time.perf_counter()
    candidates = probe.score_mask_candidates(masks, detections)
    raw_matches = probe.best_match_per_target(candidates)
    unique_matches = probe.unique_match_per_mask(candidates)
    timings["match_seconds"] = round(time.perf_counter() - t0, 3)
    timings["total_seconds"] = round(time.perf_counter() - started, 3)

    raw_result_image = out_dir / "raw_matches.jpg"
    unique_result_image = out_dir / "unique_matches.jpg"
    probe.draw_result(image, masks, raw_matches, raw_result_image)
    probe.draw_result(image, masks, unique_matches, unique_result_image)

    raw_mask_ids = [match["mask_id"] for match in raw_matches.values()]
    duplicate_mask_ids = sorted({mask_id for mask_id in raw_mask_ids if raw_mask_ids.count(mask_id) > 1})
    summary = {
        "name": case_name,
        "image": case["image"],
        "scaled_image_size": [image.width, image.height],
        "scale": [sx, sy],
        "target_count": len(targets),
        "target_names": [target["name_zh"] for target in targets],
        "mask_count": len(masks),
        "dino_mode": args.dino_mode,
        "dino_detection_count": len([d for d in detections if d.get("bbox_xyxy")]),
        "candidate_count": len(candidates),
        "timings": timings,
        "raw_match_count": len(raw_matches),
        "raw_unmatched_targets": [target["name_zh"] for target in targets if target["name_zh"] not in raw_matches],
        "duplicate_mask_ids_in_raw_matches": duplicate_mask_ids,
        "unique_match_count": len(unique_matches),
        "unique_unmatched_targets": [target["name_zh"] for target in targets if target["name_zh"] not in unique_matches],
        "raw_matches": raw_matches,
        "unique_matches": unique_matches,
        "raw_result_image": str(raw_result_image),
        "unique_result_image": str(unique_result_image),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases-json", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--points-per-side", type=int, default=12)
    parser.add_argument("--crop-n-layers", type=int, default=0)
    parser.add_argument("--dino-mode", choices=["combined", "per_phrase"], default="combined")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    cases = json.loads(args.cases_json.read_text(encoding="utf-8"))
    summaries = []
    for case in cases:
        print(f"=== {case['name']} ===", flush=True)
        summary = run_case(case, args.out_dir, args)
        summaries.append(summary)
        compact = {
            "name": summary["name"],
            "target_count": summary["target_count"],
            "mask_count": summary["mask_count"],
            "dino_detection_count": summary["dino_detection_count"],
            "raw_match_count": summary["raw_match_count"],
            "unique_match_count": summary["unique_match_count"],
            "unique_unmatched_targets": summary["unique_unmatched_targets"],
            "duplicate_mask_ids_in_raw_matches": summary["duplicate_mask_ids_in_raw_matches"],
            "timings": summary["timings"],
        }
        print(json.dumps(compact, ensure_ascii=False, indent=2), flush=True)

    table = [
        {
            "name": item["name"],
            "target_count": item["target_count"],
            "mask_count": item["mask_count"],
            "dino_detection_count": item["dino_detection_count"],
            "raw_match_count": item["raw_match_count"],
            "unique_match_count": item["unique_match_count"],
            "unique_unmatched_targets": item["unique_unmatched_targets"],
            "duplicate_mask_ids_in_raw_matches": item["duplicate_mask_ids_in_raw_matches"],
            "sam2_seconds": item["timings"]["sam2_seconds"],
            "dino_seconds": item["timings"]["dino_seconds"],
            "total_seconds": item["timings"]["total_seconds"],
            "unique_result_image": item["unique_result_image"],
        }
        for item in summaries
    ]
    (args.out_dir / "batch_summary.json").write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    print("=== batch_summary ===")
    print(json.dumps(table, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
