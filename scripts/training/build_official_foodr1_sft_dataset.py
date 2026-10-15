#!/usr/bin/env python3
"""Build a small official Food-R1-style SFT set for GLM-4.6V-Flash.

This intentionally creates a compact, finishable dataset first. It uses:
- Food-101 parquet images for food-name visual supervision.
- FoodDialogues rgb images and nutrition dialogues for image+nutrition JSON.
- MM-Food-100K CSV rows for text-to-nutrition-density JSON supervision.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
from collections import defaultdict
from pathlib import Path
from typing import Any

import pandas as pd
import pyarrow.parquet as pq


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


FOOD101_ZH = {
    "apple_pie": "苹果派",
    "baby_back_ribs": "烤排骨",
    "baklava": "果仁蜜饼",
    "beef_carpaccio": "生牛肉片",
    "beef_tartare": "鞑靼牛肉",
    "beet_salad": "甜菜沙拉",
    "beignets": "贝奈特饼",
    "bibimbap": "拌饭",
    "bread_pudding": "面包布丁",
    "breakfast_burrito": "墨西哥卷饼",
    "bruschetta": "意式烤面包",
    "caesar_salad": "凯撒沙拉",
    "cannoli": "奶油卷",
    "caprese_salad": "番茄芝士沙拉",
    "carrot_cake": "胡萝卜蛋糕",
    "ceviche": "酸橘汁腌鱼",
    "cheesecake": "芝士蛋糕",
    "cheese_plate": "奶酪拼盘",
    "chicken_curry": "咖喱鸡",
    "chicken_quesadilla": "鸡肉芝士饼",
    "chicken_wings": "鸡翅",
    "chocolate_cake": "巧克力蛋糕",
    "chocolate_mousse": "巧克力慕斯",
    "churros": "吉拿棒",
    "clam_chowder": "蛤蜊浓汤",
    "club_sandwich": "三明治",
    "crab_cakes": "蟹饼",
    "creme_brulee": "焦糖布丁",
    "croque_madame": "火腿芝士三明治",
    "cup_cakes": "纸杯蛋糕",
    "deviled_eggs": "魔鬼蛋",
    "donuts": "甜甜圈",
    "dumplings": "饺子",
    "edamame": "毛豆",
    "eggs_benedict": "班尼迪克蛋",
    "escargots": "蜗牛",
    "falafel": "炸鹰嘴豆丸",
    "filet_mignon": "菲力牛排",
    "fish_and_chips": "炸鱼薯条",
    "foie_gras": "鹅肝",
    "french_fries": "薯条",
    "french_onion_soup": "洋葱汤",
    "french_toast": "法式吐司",
    "fried_calamari": "炸鱿鱼",
    "fried_rice": "炒饭",
    "frozen_yogurt": "冻酸奶",
    "garlic_bread": "蒜蓉面包",
    "gnocchi": "意式面疙瘩",
    "greek_salad": "希腊沙拉",
    "grilled_cheese_sandwich": "芝士三明治",
    "grilled_salmon": "烤三文鱼",
    "guacamole": "牛油果酱",
    "gyoza": "煎饺",
    "hamburger": "汉堡",
    "hot_and_sour_soup": "酸辣汤",
    "hot_dog": "热狗",
    "huevos_rancheros": "牧场鸡蛋",
    "hummus": "鹰嘴豆泥",
    "ice_cream": "冰淇淋",
    "lasagna": "千层面",
    "lobster_bisque": "龙虾浓汤",
    "lobster_roll_sandwich": "龙虾三明治",
    "macaroni_and_cheese": "芝士通心粉",
    "macarons": "马卡龙",
    "miso_soup": "味噌汤",
    "mussels": "贻贝",
    "nachos": "玉米片",
    "omelette": "煎蛋卷",
    "onion_rings": "洋葱圈",
    "oysters": "牡蛎",
    "pad_thai": "泰式炒河粉",
    "paella": "海鲜饭",
    "pancakes": "松饼",
    "panna_cotta": "奶冻",
    "peking_duck": "北京烤鸭",
    "pho": "越南粉",
    "pizza": "披萨",
    "pork_chop": "猪排",
    "poutine": "肉汁薯条",
    "prime_rib": "烤肋排",
    "pulled_pork_sandwich": "猪肉三明治",
    "ramen": "拉面",
    "ravioli": "馄饨",
    "red_velvet_cake": "红丝绒蛋糕",
    "risotto": "烩饭",
    "samosa": "咖喱角",
    "sashimi": "刺身",
    "scallops": "扇贝",
    "seaweed_salad": "海藻沙拉",
    "shrimp_and_grits": "虾仁玉米粥",
    "spaghetti_bolognese": "肉酱意面",
    "spaghetti_carbonara": "培根蛋酱意面",
    "spring_rolls": "春卷",
    "steak": "牛排",
    "strawberry_shortcake": "草莓蛋糕",
    "sushi": "寿司",
    "tacos": "塔可",
    "takoyaki": "章鱼烧",
    "tiramisu": "提拉米苏",
    "tuna_tartare": "金枪鱼塔塔",
    "waffles": "华夫饼",
}


ENERGY_DEFAULTS = {
    "dessert": (320, 5, 45, 14, 2, 180),
    "snack": (420, 8, 42, 24, 3, 520),
    "soup": (65, 4, 7, 2, 1, 420),
    "drink": (45, 0, 11, 0, 0, 15),
    "vegetable": (55, 3, 9, 1, 3, 120),
    "protein": (210, 22, 2, 12, 0, 260),
    "staple": (170, 5, 32, 3, 2, 220),
    "mixed_dish": (180, 9, 20, 7, 2, 360),
}


def normalize_en(name: str) -> str:
    return str(name or "").strip().lower().replace("_", " ")


def guess_category(name: str) -> str:
    n = normalize_en(name)
    if any(k in n for k in ["cake", "pie", "mousse", "macaron", "ice cream", "pudding", "brulee", "donut", "churros"]):
        return "dessert"
    if any(k in n for k in ["soup", "bisque", "chowder"]):
        return "soup"
    if any(k in n for k in ["salad", "edamame", "guacamole", "hummus", "seaweed"]):
        return "vegetable"
    if any(k in n for k in ["beef", "chicken", "pork", "salmon", "fish", "steak", "duck", "sashimi", "oyster", "scallop", "lobster", "crab", "mussel"]):
        return "protein"
    if any(k in n for k in ["rice", "ramen", "pasta", "spaghetti", "pizza", "bread", "toast", "noodle", "pho", "paella", "risotto", "waffle", "pancake"]):
        return "staple"
    if any(k in n for k in ["fries", "rings", "chips", "nachos", "falafel", "samosa", "spring rolls"]):
        return "snack"
    return "mixed_dish"


def zh_name(name: str) -> str:
    key = str(name or "").strip().lower().replace(" ", "_").replace("-", "_")
    if key in FOOD101_ZH:
        return FOOD101_ZH[key]
    words = {
        "fried": "炸", "rice": "饭", "chicken": "鸡肉", "beef": "牛肉", "pork": "猪肉",
        "fish": "鱼", "soup": "汤", "salad": "沙拉", "noodles": "面", "dumplings": "饺子",
        "egg": "鸡蛋", "eggs": "鸡蛋", "cake": "蛋糕", "sandwich": "三明治", "pizza": "披萨",
        "burger": "汉堡", "salmon": "三文鱼", "shrimp": "虾", "vegetables": "蔬菜",
    }
    n = normalize_en(name)
    translated = "".join(words.get(w, "") for w in re.split(r"[^a-zA-Z]+", n) if w)
    return translated or "食物"


def density_for(name: str) -> tuple[float, float, float, float, float, float]:
    return ENERGY_DEFAULTS[guess_category(name)]


def physical_density_for_category(category: str) -> float:
    return DEFAULT_DENSITY_BY_CATEGORY.get(str(category or "").lower(), 0.75)


def make_target(
    name_en: str,
    *,
    kcal100: float | None = None,
    p100: float | None = None,
    c100: float | None = None,
    f100: float | None = None,
    fi100: float | None = None,
    na100: float | None = None,
    confidence: float = 0.75,
) -> dict[str, Any]:
    if kcal100 is None:
        kcal100, p100, c100, f100, fi100, na100 = density_for(name_en)
    category = guess_category(name_en)
    detector = normalize_en(name_en) or "food"
    item = {
        "name_zh": zh_name(name_en),
        "detector_phrase": detector,
        "category": category,
        "liquid": category in {"soup", "drink"},
        "mixed_dish": category == "mixed_dish",
        "confidence": round(float(confidence), 2),
        "density_g_per_ml": physical_density_for_category(category),
        "kcal100": round(float(kcal100 or 0), 1),
        "p100": round(float(p100 or 0), 1),
        "c100": round(float(c100 or 0), 1),
        "f100": round(float(f100 or 0), 1),
        "fi100": round(float(fi100 or 0), 1),
        "na100": round(float(na100 or 0), 1),
    }
    return {"items": [item], "detector_prompt_en": detector}


def chat_sample(target: dict[str, Any], image: Path | None = None, user_text: str | None = None, source: str = "") -> dict[str, Any]:
    content = user_text if user_text else "<image>\n" + PROMPT
    sample = {
        "messages": [
            {"role": "user", "content": content},
            {"role": "assistant", "content": json.dumps(target, ensure_ascii=False, separators=(",", ":"))},
        ],
        "metadata": {"source": source},
    }
    if image is not None:
        sample["images"] = [str(image)]
    return sample


def food101_labels(parquet_path: Path) -> list[str]:
    metadata = pq.ParquetFile(parquet_path).schema_arrow.metadata
    hf = json.loads(metadata[b"huggingface"].decode("utf-8"))
    return hf["info"]["features"]["label"]["names"]


def add_food101_samples(root: Path, image_dir: Path, per_class: int, samples: list[dict[str, Any]]) -> int:
    data_dir = root / "Food-101" / "data"
    first = next(data_dir.glob("train-*.parquet"))
    labels = food101_labels(first)
    counts: dict[int, int] = defaultdict(int)
    added = 0
    image_dir.mkdir(parents=True, exist_ok=True)
    for parquet_path in sorted(data_dir.glob("train-*.parquet")):
        table = pq.read_table(parquet_path, columns=["image", "label"])
        for row_idx, row in enumerate(table.to_pylist()):
            label = int(row["label"])
            if counts[label] >= per_class:
                continue
            label_name = labels[label]
            image_bytes = row["image"]["bytes"]
            image_path = image_dir / "food101" / label_name / f"{parquet_path.stem}_{row_idx}.jpg"
            image_path.parent.mkdir(parents=True, exist_ok=True)
            if not image_path.exists():
                image_path.write_bytes(image_bytes)
            samples.append(chat_sample(make_target(label_name, confidence=0.9), image_path, source="Food-101"))
            counts[label] += 1
            added += 1
        if len(counts) == len(labels) and all(v >= per_class for v in counts.values()):
            break
    return added


def extract_fooddialogues_images(root: Path, image_dir: Path, dish_ids: list[str]) -> None:
    fd = root / "FoodDialogues"
    list_path = image_dir / "fooddialogues_extract_list.txt"
    list_path.parent.mkdir(parents=True, exist_ok=True)
    paths = [f"images/{dish_id}/rgb.png" for dish_id in dict.fromkeys(dish_ids)]
    list_path.write_text("\n".join(paths) + "\n", encoding="utf-8")
    target_dir = image_dir / "fooddialogues"
    target_dir.mkdir(parents=True, exist_ok=True)
    missing = [p for p in paths if not (target_dir / p).exists()]
    if not missing:
        return
    cmd = (
        "set -euo pipefail; "
        f"cd {fd}; "
        f"cat images.tar.gz.001 images.tar.gz.002 images.tar.gz.003 | "
        f"tar -xzf - -C {target_dir} -T {list_path}"
    )
    result = subprocess.run(["bash", "-lc", cmd], check=False)
    if result.returncode:
        print(f"warning: FoodDialogues image extraction was partial, rc={result.returncode}; missing images will be skipped")


def parse_dialogue_nutrition(conversations: list[dict[str, str]]) -> tuple[float | None, float | None, float | None, float | None]:
    text = "\n".join(str(c.get("value", "")) for c in conversations)
    def grab(tag: str) -> float | None:
        m = re.search(rf"([0-9]+(?:\.[0-9]+)?)\[{tag}\]", text)
        return float(m.group(1)) if m else None
    return grab("CAL"), grab("PRO"), grab("CARB"), grab("FAT")


def add_fooddialogues_samples(root: Path, image_dir: Path, limit: int, samples: list[dict[str, Any]]) -> int:
    fd = root / "FoodDialogues"
    rows = json.loads((fd / "FoodDialogues_train.json").read_text(encoding="utf-8"))[:limit]
    dish_ids = [row["dish_id"] for row in rows]
    extract_fooddialogues_images(root, image_dir, dish_ids)
    added = 0
    for row in rows:
        name_en = (row.get("dish_content") or ["food"])[0]
        kcal, protein, carbs, fat = parse_dialogue_nutrition(row.get("conversations") or [])
        if kcal is None:
            continue
        image_path = image_dir / "fooddialogues" / "images" / row["dish_id"] / "rgb.png"
        if not image_path.exists():
            continue
        # FoodDialogues gives serving totals. Without serving grams, use the values as a
        # weak density hint so the model learns food-specific nutrition language.
        target = make_target(name_en, kcal100=kcal, p100=protein or 0, c100=carbs or 0, f100=fat or 0, fi100=0, na100=0, confidence=0.72)
        samples.append(chat_sample(target, image_path, source="FoodDialogues"))
        added += 1
    return added


def portion_grams(portion_size: str) -> float:
    grams = 0.0
    for value in re.findall(r":\s*([0-9]+(?:\.[0-9]+)?)\s*g", str(portion_size)):
        grams += float(value)
    return grams


def add_mm_food_samples(root: Path, limit: int, samples: list[dict[str, Any]]) -> int:
    path = root / "MM-Food-100K" / "MM-Food-100K.csv"
    added = 0
    for chunk in pd.read_csv(path, chunksize=2000):
        for row in chunk.to_dict(orient="records"):
            grams = portion_grams(str(row.get("portion_size", "")))
            if not grams or not math.isfinite(grams):
                continue
            try:
                nut = json.loads(row.get("nutritional_profile") or "{}")
            except Exception:
                continue
            kcal = float(nut.get("calories_kcal") or 0)
            if kcal <= 0:
                continue
            name = str(row.get("dish_name") or "food")
            target = make_target(
                name,
                kcal100=kcal / grams * 100,
                p100=float(nut.get("protein_g") or 0) / grams * 100,
                c100=float(nut.get("carbohydrate_g") or 0) / grams * 100,
                f100=float(nut.get("fat_g") or 0) / grams * 100,
                fi100=0,
                na100=0,
                confidence=0.78,
            )
            user = (
                "根据以下官方食物记录，输出同样结构的中文 JSON，营养字段必须换算为每100克：\n"
                f"dish_name={name}\ningredients={row.get('ingredients')}\nportion_size={row.get('portion_size')}\n"
                f"nutritional_profile={row.get('nutritional_profile')}\nJSON:"
            )
            samples.append(chat_sample(target, image=None, user_text=user, source="MM-Food-100K"))
            added += 1
            if added >= limit:
                return added
    return added


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official-root", type=Path, default=Path("/root/autodl-tmp/glm_food_r1_experiment/official_data"))
    parser.add_argument("--work-dir", type=Path, default=Path("/root/autodl-tmp/glm_food_r1_experiment/data/official_sft_assets"))
    parser.add_argument("--out", type=Path, default=Path("/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_sft.jsonl"))
    parser.add_argument("--food101-per-class", type=int, default=2)
    parser.add_argument("--fooddialogues-limit", type=int, default=160)
    parser.add_argument("--mm-limit", type=int, default=160)
    args = parser.parse_args()

    samples: list[dict[str, Any]] = []
    counts = {
        "food101": add_food101_samples(args.official_root, args.work_dir, args.food101_per_class, samples),
        "fooddialogues": add_fooddialogues_samples(args.official_root, args.work_dir, args.fooddialogues_limit, samples),
        "mm_food": add_mm_food_samples(args.official_root, args.mm_limit, samples),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        for sample in samples:
            handle.write(json.dumps(sample, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(args.out), "samples": len(samples), "counts": counts}, ensure_ascii=False))


if __name__ == "__main__":
    main()
