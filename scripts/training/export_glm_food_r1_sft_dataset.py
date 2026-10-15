"""Export confirmed depth-meal records as GLM/Food-R1 style SFT JSONL.

The output uses a common multimodal chat JSONL shape accepted by recent
ms-swift versions:
{"messages": [...], "images": ["/abs/path/rgb.jpg"], "metadata": {...}}
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path


PROMPT = """只识别图片中明显可见食物，返回紧凑 JSON，无解释。
字段只要：name_zh, detector_phrase, category, liquid, mixed_dish, confidence, density_g_per_ml, kcal100, p100, c100, f100, fi100, na100。
name_zh 必须使用中文食物名，不要输出英文；可以保留具体做法、风味、品牌或品类信息。
detector_phrase 必须是英文短语，用于开放词汇检测；detector_prompt_en 用这些英文短语以英文句点分隔。
density_g_per_ml 是可食部分物理密度，用于把体积ml换算成克重；必须大于0，不确定就按类别估计并降低confidence。
kcal100/p100/c100/f100/fi100/na100 是每100克可食部分营养密度，不是本次总营养；分别是千卡、蛋白克、碳水克、脂肪克、纤维克、钠毫克。
密度参考：水/清汤/茶1.0；米饭/炒饭0.75；熟面0.7；炒菜0.65；肉块0.95；炸物0.55；面包/蛋糕0.35；酱料1.05。
不要输出克重、体积、风险项、建议或不可见食物。
拼盘/套餐按明显不同食物拆分；同类重复物可合并。
JSON:{"items":[{"name_zh":"","detector_phrase":"","category":"staple|protein|vegetable|mixed_dish|soup|drink|sauce|dessert|snack","liquid":false,"mixed_dish":false,"confidence":0.0,"density_g_per_ml":0,"kcal100":0,"p100":0,"c100":0,"f100":0,"fi100":0,"na100":0}],"detector_prompt_en":""}"""


DEFAULT_DENSITY_BY_CATEGORY = {
    "staple": 0.75,
    "protein": 0.95,
    "vegetable": 0.65,
    "mixed_dish": 0.75,
    "soup": 1.0,
    "drink": 1.0,
    "sauce": 1.05,
    "dessert": 0.45,
    "snack": 0.55,
}


def per_100g(value: float, grams: float) -> float:
    if grams <= 0:
        return 0.0
    return round(float(value or 0) / grams * 100.0, 1)


def density_for_row(row: sqlite3.Row) -> float:
    try:
        density = float(row["density_g_per_ml"] or 0)
    except Exception:
        density = 0.0
    if density > 0:
        return round(density, 3)
    category = str(row["category"] or "mixed_dish").lower()
    return DEFAULT_DENSITY_BY_CATEGORY.get(category, 0.75)


def item_to_target(row: sqlite3.Row) -> dict:
    grams = float(row["estimated_grams"] or 0)
    detector_phrase = row["detector_phrase"] or row["name_en"] or row["name_zh"] or "food"
    return {
        "name_zh": row["name_zh"],
        "detector_phrase": detector_phrase,
        "category": row["category"] or "mixed_dish",
        "liquid": bool(row["liquid"]),
        "mixed_dish": bool(row["mixed_dish"]),
        "confidence": round(float(row["detector_score"] or row["volume_confidence"] or 0.65), 2),
        "density_g_per_ml": density_for_row(row),
        "kcal100": per_100g(row["calories"], grams),
        "p100": per_100g(row["protein_g"], grams),
        "c100": per_100g(row["carbs_g"], grams),
        "f100": per_100g(row["fat_g"], grams),
        "fi100": per_100g(row["fiber_g"], grams),
        "na100": per_100g(row["sodium_mg"], grams),
    }


def export_dataset(db_path: Path, output_path: Path, min_items: int = 1) -> int:
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    meals = con.execute(
        """
        SELECT ml.id, ml.capture_id, ml.estimation_mode, mc.rgb_url, mc.depth_source, mc.user_hint, mc.container_hint
        FROM meal_logs ml
        JOIN meal_captures mc ON mc.id = ml.capture_id
        WHERE COALESCE(mc.rgb_url, '') <> ''
        ORDER BY ml.created_at
        """
    ).fetchall()

    output_path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with output_path.open("w", encoding="utf-8") as handle:
        for meal in meals:
            image_path = Path(meal["rgb_url"])
            if not image_path.exists():
                continue
            items = con.execute(
                """
                SELECT * FROM meal_items
                WHERE meal_id=? AND estimated_grams > 0
                ORDER BY created_at, id
                """,
                (meal["id"],),
            ).fetchall()
            if len(items) < min_items:
                continue
            target_items = [item_to_target(row) for row in items]
            detector_prompt = " . ".join(dict.fromkeys(item["detector_phrase"] for item in target_items if item["detector_phrase"]))
            target = {"items": target_items, "detector_prompt_en": detector_prompt or "food"}
            sample = {
                "messages": [
                    {"role": "user", "content": "<image>\n" + PROMPT},
                    {"role": "assistant", "content": json.dumps(target, ensure_ascii=False, separators=(",", ":"))},
                ],
                "images": [str(image_path)],
                "metadata": {
                    "meal_id": meal["id"],
                    "capture_id": meal["capture_id"],
                    "depth_source": meal["depth_source"],
                    "estimation_mode": meal["estimation_mode"],
                },
            }
            handle.write(json.dumps(sample, ensure_ascii=False) + "\n")
            count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=Path("/opt/cal-repro/data/depth_meal.db"))
    parser.add_argument("--out", type=Path, default=Path("/root/autodl-tmp/glm_food_r1_experiment/data/sft_depth_meals.jsonl"))
    parser.add_argument("--min-items", type=int, default=1)
    args = parser.parse_args()
    count = export_dataset(args.db, args.out, args.min_items)
    print(json.dumps({"output": str(args.out), "samples": count}, ensure_ascii=False))


if __name__ == "__main__":
    main()
