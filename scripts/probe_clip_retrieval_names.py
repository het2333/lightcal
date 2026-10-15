#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont
from transformers import ChineseCLIPModel, ChineseCLIPProcessor


@dataclass
class Case:
    name: str
    image: Path


DEFAULT_CASES = [
    Case("depth_cola_can", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_cab838efdd31/rgb.jpg")),
    Case("depth_pot_bowl", Path("/root/autodl-tmp/cal_food_compare_assets/depth_captures/cap_04f23a03f8bb/rgb.jpg")),
    Case("rgb_fried_platter", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/fried_platter/rgb.jpg")),
    Case("rgb_cafeteria_meal", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/cafeteria_meal/rgb.jpg")),
    Case("rgb_vegetable_board", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/vegetable_board/rgb.jpg")),
    Case("rgb_img6388", Path("/root/autodl-tmp/cal_food_compare_assets/rgb/img_6388.jpg")),
]


CJK_RE = re.compile(r"[\u4e00-\u9fff]")
BAD_NAME_RE = re.compile(
    r"(做法|教程|小贴士|步骤|怎么|如何|视频|合集|大全|窍门|好吃到|太香|下饭又营养|孔老师|零失败|懒人|"
    r"翻译后的名称|品牌|未知|其他|食物|一餐|套餐|拼盘|适量|少许|口味|风味|经典|优选|精选|#|http|www|@)"
)
PUNCT_RE = re.compile(r"[!！?？。；;：:、，,《》<>【】\\[\\]{}()（）|/\\\\]")


def has_cjk(text: str) -> bool:
    return bool(CJK_RE.search(text))


def clean_name(raw: str) -> str:
    text = str(raw or "").strip()
    text = re.sub(r"\s+", "", text)
    text = text.strip("\"'`“”‘’")
    return text


def is_good_candidate(name: str, max_chars: int) -> bool:
    name = clean_name(name)
    if not name or not has_cjk(name):
        return False
    if len(name) > max_chars:
        return False
    if BAD_NAME_RE.search(name):
        return False
    punct_count = len(PUNCT_RE.findall(name))
    if punct_count > 1:
        return False
    if sum(ch.isdigit() for ch in name) > 2:
        return False
    if len(set(name)) <= 1:
        return False
    return True


def add_candidate(rows: list[dict[str, str]], seen: set[str], name: str, source: str, max_chars: int) -> None:
    name = clean_name(name)
    if not is_good_candidate(name, max_chars=max_chars):
        return
    key = name.casefold()
    if key in seen:
        return
    seen.add(key)
    rows.append({"name": name, "source": source})


def load_candidates(args: argparse.Namespace) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()

    if args.candidate_file:
        raw = json.loads(args.candidate_file.read_text(encoding="utf-8"))
        for item in raw:
            if isinstance(item, str):
                add_candidate(rows, seen, item, "candidate_file", args.max_name_chars)
            elif isinstance(item, dict):
                add_candidate(rows, seen, str(item.get("name") or item.get("name_zh") or ""), str(item.get("source") or "candidate_file"), args.max_name_chars)
        return rows

    if args.recipes_db.exists():
        con = sqlite3.connect(args.recipes_db)
        con.row_factory = sqlite3.Row
        try:
            for row in con.execute(
                """
                SELECT DISTINCT title
                FROM recipes_clean
                WHERE COALESCE(title, '') <> ''
                LIMIT ?
                """,
                (args.recipe_scan_limit,),
            ):
                add_candidate(rows, seen, row["title"], "recipe", args.max_name_chars)
                if sum(1 for item in rows if item["source"] == "recipe") >= args.max_recipe_candidates:
                    break
        finally:
            con.close()

    if args.recipes_db.exists():
        con = sqlite3.connect(args.recipes_db)
        con.row_factory = sqlite3.Row
        try:
            for row in con.execute("SELECT DISTINCT name FROM ta_da_dishes WHERE COALESCE(name, '') <> ''"):
                add_candidate(rows, seen, row["name"], "ta_da_dish", args.max_name_chars)
        except sqlite3.OperationalError:
            pass
        finally:
            con.close()

    if args.foods_db.exists():
        con = sqlite3.connect(args.foods_db)
        con.row_factory = sqlite3.Row
        try:
            for row in con.execute(
                """
                SELECT DISTINCT COALESCE(NULLIF(name_zh, ''), name) AS name
                FROM foods_merged_clean
                WHERE COALESCE(NULLIF(name_zh, ''), name, '') <> ''
                LIMIT ?
                """,
                (args.food_scan_limit,),
            ):
                add_candidate(rows, seen, row["name"], "food", args.max_food_name_chars)
                if sum(1 for item in rows if item["source"] == "food") >= args.max_food_candidates:
                    break
        finally:
            con.close()

    extras = [
        "米饭",
        "黑米",
        "炒饭",
        "炒面",
        "面条",
        "炸鸡",
        "薯条",
        "香肠",
        "蛋挞",
        "胡萝卜",
        "卷心菜",
        "紫甘蓝",
        "生菜",
        "洋葱",
        "蘑菇",
        "番茄",
        "黄瓜",
        "虾",
        "茶",
        "可乐",
        "奶茶",
        "柠檬茶",
    ]
    for name in extras:
        add_candidate(rows, seen, name, "manual_core", args.max_name_chars)

    return rows


def cache_key(args: argparse.Namespace, candidates: list[dict[str, str]]) -> str:
    payload = {
        "model": args.model,
        "count": len(candidates),
        "first": candidates[:20],
        "last": candidates[-20:],
    }
    return hashlib.sha1(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:16]


def normalize_rows(vectors: np.ndarray) -> np.ndarray:
    vectors = vectors.astype("float32", copy=False)
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return vectors / norms


def encode_texts(
    model: ChineseCLIPModel,
    processor: ChineseCLIPProcessor,
    texts: list[str],
    device: str,
    batch_size: int,
) -> np.ndarray:
    all_features: list[np.ndarray] = []
    for start in range(0, len(texts), batch_size):
        batch = texts[start : start + batch_size]
        inputs = processor(text=batch, padding=True, truncation=True, return_tensors="pt").to(device)
        with torch.inference_mode():
            features = model.get_text_features(**inputs)
        if not isinstance(features, torch.Tensor):
            output = features
            features = getattr(output, "pooler_output", None)
            if features is None:
                features = getattr(output, "text_embeds", None)
        if not isinstance(features, torch.Tensor):
            raise RuntimeError("ChineseCLIP text features did not return a tensor")
        all_features.append(features.detach().float().cpu().numpy())
        print(json.dumps({"event": "text_batch", "done": min(start + len(batch), len(texts)), "total": len(texts)}, ensure_ascii=False), flush=True)
    return normalize_rows(np.concatenate(all_features, axis=0))


def load_or_build_text_index(
    args: argparse.Namespace,
    model: ChineseCLIPModel,
    processor: ChineseCLIPProcessor,
    candidates: list[dict[str, str]],
) -> tuple[np.ndarray, Path]:
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    key = cache_key(args, candidates)
    cache_path = args.cache_dir / f"chinese_clip_text_index_{key}.npz"
    if cache_path.exists() and not args.rebuild_text_cache:
        data = np.load(cache_path, allow_pickle=False)
        return data["embeddings"].astype("float32"), cache_path

    names = [item["name"] for item in candidates]
    embeddings = encode_texts(model, processor, names, args.device, args.text_batch_size)
    np.savez_compressed(
        cache_path,
        embeddings=embeddings,
        names=np.array(names, dtype=object),
        sources=np.array([item["source"] for item in candidates], dtype=object),
    )
    return embeddings, cache_path


def resize_image(image: Image.Image, max_edge: int) -> Image.Image:
    out = image.convert("RGB")
    if max_edge > 0 and max(out.size) > max_edge:
        out = out.copy()
        out.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return out


def encode_images(
    model: ChineseCLIPModel,
    processor: ChineseCLIPProcessor,
    images: list[Image.Image],
    device: str,
) -> np.ndarray:
    inputs = processor(images=images, return_tensors="pt").to(device)
    with torch.inference_mode():
        features = model.get_image_features(**inputs)
    if not isinstance(features, torch.Tensor):
        output = features
        features = getattr(output, "pooler_output", None)
        if features is None:
            features = getattr(output, "image_embeds", None)
    if not isinstance(features, torch.Tensor):
        raise RuntimeError("ChineseCLIP image features did not return a tensor")
    return normalize_rows(features.detach().float().cpu().numpy())


def topk_for_embedding(
    query: np.ndarray,
    text_embeddings: np.ndarray,
    candidates: list[dict[str, str]],
    k: int,
) -> list[dict[str, Any]]:
    scores = text_embeddings @ query.astype("float32")
    if k >= len(scores):
        indices = np.argsort(-scores)
    else:
        top = np.argpartition(-scores, k)[:k]
        indices = top[np.argsort(-scores[top])]
    return [
        {
            "name": candidates[int(idx)]["name"],
            "source": candidates[int(idx)]["source"],
            "score": round(float(scores[int(idx)]), 5),
        }
        for idx in indices[:k]
    ]


def load_boxes(path: Path | None) -> dict[str, list[dict[str, Any]]]:
    if not path:
        return {}
    rows = json.loads(path.read_text(encoding="utf-8"))
    by_case: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        boxes: list[dict[str, Any]] = []
        for summary in row.get("prompt_summaries") or []:
            for inst in summary.get("instances") or []:
                bbox = inst.get("bbox_xyxy")
                if isinstance(bbox, list) and len(bbox) == 4:
                    boxes.append(
                        {
                            "bbox_xyxy": bbox,
                            "source_prompt": summary.get("prompt"),
                            "source_name": summary.get("name_zh"),
                            "source_score": inst.get("score"),
                        }
                    )
        for key in ("foodsam2", "foodsam3"):
            payload = row.get(key)
            if not isinstance(payload, dict):
                continue
            for inst in payload.get("accepted_masks") or []:
                bbox = inst.get("bbox_xyxy")
                if isinstance(bbox, list) and len(bbox) == 4:
                    boxes.append(
                        {
                            "bbox_xyxy": bbox,
                            "source_prompt": inst.get("source_prompt") or inst.get("label") or key,
                            "source_name": inst.get("label") or key,
                            "source_score": inst.get("score"),
                        }
                    )
        by_case[str(row.get("case") or row.get("case_id"))] = boxes
    return by_case


def crop_box(image: Image.Image, bbox: list[float], pad_ratio: float) -> Image.Image:
    width, height = image.size
    x1, y1, x2, y2 = [float(v) for v in bbox]
    pad = max(x2 - x1, y2 - y1) * pad_ratio
    x1 = max(0, int(round(x1 - pad)))
    y1 = max(0, int(round(y1 - pad)))
    x2 = min(width, int(round(x2 + pad)))
    y2 = min(height, int(round(y2 + pad)))
    if x2 <= x1 or y2 <= y1:
        return image
    return image.crop((x1, y1, x2, y2)).convert("RGB")


def load_font(size: int = 15) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def draw_crop_results(image: Image.Image, boxes: list[dict[str, Any]], output_path: Path) -> None:
    image = image.convert("RGB")
    draw = ImageDraw.Draw(image)
    font = load_font(13)
    for idx, box in enumerate(boxes, start=1):
        bbox = box["bbox_xyxy"]
        name = (box.get("retrieval_top") or [{}])[0].get("name", "?")
        score = (box.get("retrieval_top") or [{}])[0].get("score", 0)
        draw.rectangle(bbox, outline=(35, 210, 255), width=3)
        draw.text(
            (float(bbox[0]) + 3, float(bbox[1]) + 3),
            f"{idx}:{name} {score}",
            fill=(255, 255, 255),
            stroke_width=2,
            stroke_fill=(0, 0, 0),
            font=font,
        )
    image.save(output_path, quality=92)


def run(args: argparse.Namespace) -> None:
    args.out_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    candidates = load_candidates(args)
    (args.out_dir / "retrieval_candidates.json").write_text(json.dumps(candidates, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"event": "candidates", "count": len(candidates)}, ensure_ascii=False), flush=True)

    model_started = time.perf_counter()
    processor = ChineseCLIPProcessor.from_pretrained(args.model)
    model = ChineseCLIPModel.from_pretrained(args.model).to(args.device).eval()
    print(json.dumps({"event": "model_loaded", "seconds": round(time.perf_counter() - model_started, 3)}, ensure_ascii=False), flush=True)

    text_embeddings, cache_path = load_or_build_text_index(args, model, processor, candidates)
    print(json.dumps({"event": "text_index_ready", "cache": str(cache_path), "shape": list(text_embeddings.shape)}, ensure_ascii=False), flush=True)

    boxes_by_case = load_boxes(args.sam3_summary)
    if args.images:
        custom_cases: list[Case] = []
        for index, value in enumerate(args.images, start=1):
            if "::" in value:
                name, raw_path = value.split("::", 1)
            else:
                raw_path = value
                name = Path(value).stem or f"image_{index}"
            custom_cases.append(Case(name, Path(raw_path)))
        cases = custom_cases
    else:
        cases = DEFAULT_CASES[args.start :]
    if args.limit is not None:
        cases = cases[: args.limit]

    rows: list[dict[str, Any]] = []
    for case in cases:
        image = resize_image(Image.open(case.image), args.max_edge)
        image_vec = encode_images(model, processor, [image], args.device)[0]
        whole_top = topk_for_embedding(image_vec, text_embeddings, candidates, args.top_k)
        crop_rows: list[dict[str, Any]] = []
        boxes = boxes_by_case.get(case.name, [])[: args.max_crops]
        if boxes:
            crops = [resize_image(crop_box(image, box["bbox_xyxy"], args.crop_pad_ratio), args.crop_max_edge) for box in boxes]
            crop_vecs = encode_images(model, processor, crops, args.device)
            for box, crop_vec in zip(boxes, crop_vecs):
                top = topk_for_embedding(crop_vec, text_embeddings, candidates, args.top_k)
                crop_rows.append({**box, "retrieval_top": top})
            annotated = args.out_dir / f"{case.name}_retrieval_crops.jpg"
            draw_crop_results(image.copy(), crop_rows, annotated)
        else:
            annotated = None
        row = {
            "case": case.name,
            "image": str(case.image),
            "whole_image_top": whole_top,
            "crop_results": crop_rows,
            "annotated_image": str(annotated) if annotated else None,
        }
        rows.append(row)
        print(
            json.dumps(
                {
                    "case": case.name,
                    "whole_top": [item["name"] for item in whole_top[:5]],
                    "crop_top": [((crop.get("retrieval_top") or [{}])[0].get("name")) for crop in crop_rows[:8]],
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    (args.out_dir / "clip_retrieval_results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"event": "done", "seconds": round(time.perf_counter() - started, 3), "out_dir": str(args.out_dir)}, ensure_ascii=False), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--foods-db", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/data/foods.db"))
    parser.add_argument("--recipes-db", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/data/recipes.db"))
    parser.add_argument("--out-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/outputs/clip_retrieval_20260705"))
    parser.add_argument("--cache-dir", type=Path, default=Path("/root/autodl-tmp/depth-pipeline-service/cache"))
    parser.add_argument("--model", default="OFA-Sys/chinese-clip-vit-base-patch16")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--max-edge", type=int, default=768)
    parser.add_argument("--crop-max-edge", type=int, default=384)
    parser.add_argument("--crop-pad-ratio", type=float, default=0.08)
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--text-batch-size", type=int, default=128)
    parser.add_argument("--max-name-chars", type=int, default=12)
    parser.add_argument("--max-food-name-chars", type=int, default=8)
    parser.add_argument("--recipe-scan-limit", type=int, default=200000)
    parser.add_argument("--food-scan-limit", type=int, default=200000)
    parser.add_argument("--max-recipe-candidates", type=int, default=30000)
    parser.add_argument("--max-food-candidates", type=int, default=5000)
    parser.add_argument("--sam3-summary", type=Path)
    parser.add_argument("--candidate-file", type=Path)
    parser.add_argument("--images", action="append", default=[], help="Custom image path or name::path. Repeatable.")
    parser.add_argument("--max-crops", type=int, default=24)
    parser.add_argument("--rebuild-text-cache", action="store_true")
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
