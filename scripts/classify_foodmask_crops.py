#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import re
import time
import urllib.request
from pathlib import Path
from typing import Any


PROMPT = """请只判断图片中蓝色框或中心区域的主要对象，不要识别背景。
输出纯 JSON 对象，不要解释，不要 Markdown：
{
  "is_food": true,
  "name_zh": "中文食物/饮品名；如果不是食物写非食物",
  "category": "主食/肉类/蔬菜/饮品/甜点/小吃/餐具/背景/其他",
  "confidence": 0.0,
  "density_g_per_ml": 0.0,
  "kcal100_estimate": 0,
  "reason": "一句中文理由"
}
如果主要对象是盘子、碗、杯子、桌面、纸、包装或空容器，is_food=false。饮料本身可算食物/饮品，但只看到空杯或容器时不要算。"""


def image_data_url(path: Path) -> str:
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:image/jpeg;base64,{data}"


def extract_json(text: str) -> dict[str, Any]:
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        return {"parse_error": "no_json", "raw": text}
    try:
        return json.loads(match.group(0))
    except Exception as exc:
        return {"parse_error": f"{type(exc).__name__}: {exc}", "raw": text}


def classify_crop(endpoint: str, image_path: Path, timeout: int) -> tuple[dict[str, Any], float, str]:
    payload = {
        "model": "Food-GR1-step80",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": image_data_url(image_path)}},
                    {"type": "text", "text": PROMPT},
                ],
            }
        ],
        "temperature": 0,
        "max_tokens": 192,
    }
    started = time.perf_counter()
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    elapsed = time.perf_counter() - started
    text = body.get("choices", [{}])[0].get("message", {}).get("content", "")
    return extract_json(text), round(elapsed, 3), text


def resolve_crop_path(service_dir: Path, crop_path: str) -> Path:
    path = Path(crop_path)
    if path.is_absolute():
        return path
    return service_dir / path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service"))
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8003/v1/chat/completions")
    parser.add_argument("--max-crops-per-case", type=int, default=5)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    results = []
    for summary_path in sorted(args.input_dir.glob("*/summary.json")):
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        case_result = {
            "name": summary["name"],
            "candidate_count": summary["candidate_count"],
            "items": [],
        }
        print(f"=== {summary['name']} ===", flush=True)
        for candidate in summary.get("candidates", [])[: args.max_crops_per_case]:
            crop_path = resolve_crop_path(args.service_dir, candidate["crop_path"])
            try:
                parsed, seconds, raw_text = classify_crop(args.endpoint, crop_path, args.timeout)
            except Exception as exc:
                parsed, seconds, raw_text = {"error": f"{type(exc).__name__}: {exc}"}, 0.0, ""
            item = {
                "candidate_index": candidate["candidate_index"],
                "mask_id": candidate["mask_id"],
                "food_mask_score": candidate["food_mask_score"],
                "dino_phrase": candidate["dino_phrase"],
                "crop_path": str(crop_path),
                "classification_seconds": seconds,
                "classification": parsed,
                "raw_text": raw_text,
            }
            case_result["items"].append(item)
            compact = {
                "idx": item["candidate_index"],
                "mask": item["mask_id"],
                "score": item["food_mask_score"],
                "dino": item["dino_phrase"],
                "sec": seconds,
                "cls": parsed,
            }
            print(json.dumps(compact, ensure_ascii=False), flush=True)
        results.append(case_result)

    output_path = args.input_dir / "foodmask_identification.json"
    output_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
