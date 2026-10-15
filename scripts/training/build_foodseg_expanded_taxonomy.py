#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FOODS_DB = ROOT / "data" / "foods.db"
DEFAULT_RECIPES_DB = ROOT / "data" / "recipes.db"
DEFAULT_FOOD_LABELS = ROOT / "data" / "foodsdb_visual_retrieval_labels.json"
DEFAULT_CORE_LABELS = ROOT / "data" / "retrieval_core_food_labels_zh.json"
DEFAULT_OUT = ROOT / "data" / "foodseg_expanded_taxonomy.json"


FOODSEG103_SEED = [
    ("rice", "米饭", "staple", "real_mask_seed"),
    ("noodles", "面条", "staple", "real_mask_seed"),
    ("bread", "面包", "staple", "real_mask_seed"),
    ("pork", "猪肉", "protein", "real_mask_seed"),
    ("beef", "牛肉", "protein", "real_mask_seed"),
    ("chicken duck", "鸡肉", "protein", "real_mask_seed"),
    ("fish", "鱼肉", "protein", "real_mask_seed"),
    ("shrimp", "虾", "protein", "real_mask_seed"),
    ("egg", "鸡蛋", "protein", "real_mask_seed"),
    ("tofu", "豆腐", "protein", "real_mask_seed"),
    ("carrot", "胡萝卜", "vegetable", "real_mask_seed"),
    ("cabbage", "卷心菜", "vegetable", "real_mask_seed"),
    ("lettuce", "生菜", "vegetable", "real_mask_seed"),
    ("onion", "洋葱", "vegetable", "real_mask_seed"),
    ("tomato", "番茄", "vegetable", "real_mask_seed"),
    ("cucumber", "黄瓜", "vegetable", "real_mask_seed"),
    ("mushroom", "蘑菇", "vegetable", "real_mask_seed"),
    ("pepper", "青椒", "vegetable", "real_mask_seed"),
    ("broccoli", "西兰花", "vegetable", "real_mask_seed"),
    ("celery stick", "芹菜", "vegetable", "real_mask_seed"),
    ("potato", "土豆", "vegetable", "real_mask_seed"),
    ("corn", "玉米", "vegetable", "real_mask_seed"),
    ("soup", "汤", "liquid", "real_mask_seed"),
    ("sauce", "酱汁", "liquid", "real_mask_seed"),
    ("juice", "果汁", "drink", "real_mask_seed"),
    ("tea", "茶", "drink", "pseudo_or_retrieval"),
]

HAND_CLASSES = [
    ("fried chicken", "炸鸡", "dish_or_item", "pseudo_mask"),
    ("fried chicken nuggets", "炸鸡块", "dish_or_item", "pseudo_mask"),
    ("chicken wings", "鸡翅", "dish_or_item", "pseudo_mask"),
    ("french fries", "薯条", "dish_or_item", "pseudo_mask"),
    ("sausage", "香肠", "dish_or_item", "pseudo_mask"),
    ("hot dog", "热狗", "dish_or_item", "pseudo_mask"),
    ("egg tart", "蛋挞", "dessert", "pseudo_mask"),
    ("fried noodles", "炒面", "staple", "pseudo_mask"),
    ("fried rice", "炒饭", "staple", "pseudo_mask"),
    ("black rice", "黑米", "staple", "pseudo_mask"),
    ("purple rice", "紫米饭", "staple", "pseudo_mask"),
    ("cola", "可乐", "drink_packaging", "ocr_or_retrieval"),
    ("milk tea", "奶茶", "drink_packaging", "ocr_or_retrieval"),
]

BAD_VISUAL_WORDS = [
    "卡路里",
    "热量",
    "蛋白质",
    "碳水",
    "脂肪",
    "营养",
    "千卡",
    "大卡",
    "毫升",
    "克装",
    "家庭装",
    "分享装",
    "组合装",
    "礼盒",
    "促销",
    "配方",
    "系列",
    "品牌",
    "牌",
    "无糖",
    "低脂",
    "脱脂",
    "减脂",
    "低卡",
    "低糖",
    "高蛋白",
    "有机",
    "特级",
    "半盐",
    "无盐",
    "超加工",
    "原味",
    "风味",
    "口味",
    "包装",
    "添加",
    "高钙",
    "即食",
    "速食",
    "方便",
    "冷冻",
    "冷藏",
    "新鲜",
    "精选",
    "优质",
    "美味",
    "经典",
    "自制",
    "空气炸锅",
    "教程",
    "做法",
    "小贴士",
    "记录",
    "早餐都吃",
]
BAD_EXACT = {
    "浅棕色长方形",
    "米色圆圈",
    "绿色圆圈",
    "适量",
    "少许",
    "清水",
    "水",
    "盐",
    "糖",
    "油",
    "生抽",
    "老抽",
    "料酒",
    "蚝油",
    "味精",
    "鸡精",
    "白糖",
    "冰糖",
    "红糖",
    "蜂蜜",
    "黑胡椒",
    "白胡椒",
    "八角",
    "桂皮",
    "香叶",
    "淀粉",
    "泡打粉",
    "小苏打",
}
BAD_STARTS = tuple("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ%+#@&!！?？。.,，、:：;；-_/\\([{（【")
BAD_UNIT_STARTS = (
    "勺",
    "茶勺",
    "汤勺",
    "克",
    "个",
    "块",
    "把",
    "朵",
    "滴",
    "片",
    "根",
    "条",
    "颗",
    "粒",
    "杯",
    "碗",
    "包",
    "袋",
    "丢丢",
)
BAD_CONDIMENT_TOKENS = (
    "盐",
    "糖",
    "生抽",
    "老抽",
    "酱油",
    "料酒",
    "蚝油",
    "醋",
    "胡椒",
    "花椒",
    "香油",
    "芝麻油",
    "橄榄油",
    "黄油",
    "玉米油",
    "植物油",
    "食用油",
    "辣椒粉",
    "五香粉",
    "孜然粉",
    "咖喱粉",
    "面粉",
    "低筋粉",
    "高筋粉",
)
MODIFIER_PREFIXES = (
    "熟",
    "生",
    "干",
    "湿",
    "鲜",
    "嫩",
    "老",
    "小",
    "大",
    "纯",
    "无骨",
    "去皮",
    "带皮",
    "切片",
    "切块",
    "切丁",
    "去壳",
    "带壳",
)
INGREDIENT_UNIT_RE = re.compile(
    r"^[约大概少许适量若干]*[0-9一二三四五六七八九十半两几./~\-—]+"
    r"(?:g|G|克|kg|千克|斤|两|ml|ML|毫升|升|L|个|只|颗|粒|片|块|根|条|把|撮|勺|汤匙|茶匙|杯|碗|包|袋|瓶|罐|盒)?"
)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
NON_FOOD_PUNCT_RE = re.compile(r"[0-9a-zA-Z#＃%@\"'`~^_=<>$|：:（）()【】\[\]]|http|www", re.I)


@dataclass
class Taxon:
    name_zh: str
    name_en: str = ""
    group: str = "unknown"
    train_mode: str = "retrieval_only"
    sources: set[str] = field(default_factory=set)
    aliases_zh: set[str] = field(default_factory=set)
    aliases_en: set[str] = field(default_factory=set)
    support_count: int = 0
    quality_score: float = 0.0


def clean_name(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "").strip())


def normalize_visual_name(value: Any) -> str:
    name = clean_name(value)
    name = re.sub(r"[（(][^()（）]{0,8}[）)]", "", name)
    name = re.sub(r"^[\"'“”‘’【】\[\]（）()<>《》]+|[\"'“”‘’【】\[\]（）()<>《》]+$", "", name)
    name = name.replace("西红柿", "番茄")
    name = name.replace("土豆", "马铃薯") if name == "土豆泥粉" else name
    name = name.replace("鸡胸脯肉", "鸡胸肉")
    name = name.replace("鸡脯肉", "鸡胸肉")
    name = name.replace("青瓜", "黄瓜")
    for prefix in MODIFIER_PREFIXES:
        if name.startswith(prefix) and len(name) > len(prefix) + 1:
            name = name[len(prefix) :]
            break
    return name


def usable_visual_name(name: str, max_len: int = 12) -> bool:
    name = normalize_visual_name(name)
    if not name or name in BAD_EXACT:
        return False
    if name.startswith(BAD_STARTS):
        return False
    if name.startswith(BAD_UNIT_STARTS):
        return False
    if name.endswith(("适量", "少许")):
        return False
    if not CJK_RE.search(name):
        return False
    if not re.match(r"^[\u4e00-\u9fff]", name):
        return False
    if len(name) > max_len:
        return False
    if any(word in name for word in BAD_VISUAL_WORDS):
        return False
    if any(token in name for token in BAD_CONDIMENT_TOKENS) and not any(
        keep in name for keep in ("蛋糕", "饼干", "面包", "薯片", "薯条", "巧克力", "奶油", "黄油鸡")
    ):
        return False
    if NON_FOOD_PUNCT_RE.search(name):
        return False
    if re.search(r"[🧡🧸✨‼️⭐❤🍳🍰🍞🍜🍱🍲🍵🍗🍖🍤🍋🍊🍉🥗🥘🥣🥤]", name):
        return False
    if name.count("的") > 0 or name.count("和") > 1:
        return False
    return True


def visual_group(name: str) -> str:
    if any(token in name for token in ("米饭", "黑米", "紫米", "饭", "面", "粉", "馒头", "包子", "饺子", "薯条")):
        return "staple"
    if any(token in name for token in ("鸡", "猪", "牛", "羊", "鱼", "虾", "肉", "蛋", "豆腐", "香肠")):
        return "protein"
    if any(token in name for token in ("菜", "胡萝卜", "洋葱", "番茄", "黄瓜", "蘑菇", "西兰花", "青椒", "土豆", "红薯")):
        return "vegetable"
    if any(token in name for token in ("茶", "可乐", "奶茶", "果汁", "咖啡", "汤")):
        return "drink_or_liquid"
    if any(token in name for token in ("苹果", "香蕉", "草莓", "橙", "梨", "葡萄", "西瓜", "芒果", "蓝莓")):
        return "fruit"
    if any(token in name for token in ("蛋挞", "蛋糕", "冰淇淋", "巧克力", "饼干")):
        return "dessert"
    return "food"


def add_taxon(
    taxa: dict[str, Taxon],
    name_zh: str,
    *,
    name_en: str = "",
    group: str | None = None,
    train_mode: str,
    source: str,
    support_count: int = 1,
    quality_score: float = 0.0,
) -> None:
    raw_name_zh = clean_name(name_zh)
    name_zh = normalize_visual_name(raw_name_zh)
    if not usable_visual_name(name_zh, max_len=18):
        return
    key = name_zh
    taxon = taxa.get(key)
    if taxon is None:
        taxon = Taxon(
            name_zh=name_zh,
            name_en=name_en,
            group=group or visual_group(name_zh),
            train_mode=train_mode,
            support_count=support_count,
            quality_score=quality_score,
        )
        taxa[key] = taxon
    else:
        if name_en:
            taxon.aliases_en.add(name_en)
        if raw_name_zh and raw_name_zh != name_zh:
            taxon.aliases_zh.add(raw_name_zh)
        if train_mode_priority(train_mode) < train_mode_priority(taxon.train_mode):
            taxon.train_mode = train_mode
        if group and taxon.group == "unknown":
            taxon.group = group
        taxon.support_count += support_count
        taxon.quality_score = max(taxon.quality_score, quality_score)
    taxon.sources.add(source)


def train_mode_priority(value: str) -> int:
    order = {
        "real_mask_seed": 0,
        "pseudo_mask": 1,
        "ocr_or_retrieval": 2,
        "pseudo_or_retrieval": 2,
        "retrieval_only": 3,
    }
    return order.get(value, 9)


def load_json_labels(path: Path) -> list[str]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    labels: list[str] = []
    for item in raw:
        if isinstance(item, str):
            labels.append(item)
        elif isinstance(item, dict):
            labels.append(str(item.get("name") or item.get("name_zh") or ""))
    return labels


def add_foods_db_names(taxa: dict[str, Taxon], foods_db: Path, max_names: int) -> None:
    if not foods_db.exists():
        return
    con = sqlite3.connect(foods_db)
    con.row_factory = sqlite3.Row
    counter: Counter[str] = Counter()
    source_by_name: dict[str, set[str]] = defaultdict(set)
    try:
        table_weights = {
            "foods": 5,
            "foods_corrected_clean": 4,
            "foods_verified_clean": 3,
            "foods_merged_clean": 2,
            "foods_clean": 1,
        }
        for table in table_weights:
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                continue
            columns = {str(row[1]) for row in con.execute(f"PRAGMA table_info({table})")}
            if "name_zh" not in columns:
                continue
            query = (
                f"SELECT name_zh, COUNT(*) AS c FROM {table} "
                "WHERE COALESCE(name_zh, '') <> '' "
                "GROUP BY name_zh ORDER BY c DESC LIMIT 20000"
            )
            for row in con.execute(query):
                name = normalize_visual_name(row["name_zh"])
                if not usable_visual_name(name, max_len=10):
                    continue
                count = int(row["c"] or 1)
                weighted = count * table_weights[table]
                counter[name] += weighted
                source_by_name[name].add(f"{table}.name_zh")
        for name, score in counter.most_common(max_names):
            add_taxon(
                taxa,
                name,
                train_mode="retrieval_only",
                source=",".join(sorted(source_by_name[name])),
                support_count=int(score),
                quality_score=min(1.0, 0.15 + score ** 0.5 / 40),
            )
    finally:
        con.close()


def parse_ingredient_name(text: str) -> str:
    name = clean_name(text)
    name = INGREDIENT_UNIT_RE.sub("", name)
    name = re.sub(r"^[适量少许若干些许一点点]+", "", name)
    name = re.sub(r"[，,、/（(].*$", "", name)
    name = re.sub(r"(切丁|切块|切片|切丝|去皮|去籽|去核|焯水|泡发|洗净|剁碎|末|碎)$", "", name)
    return normalize_visual_name(name)


def add_recipe_ingredient_names(taxa: dict[str, Taxon], recipes_db: Path, max_rows: int, max_names: int) -> None:
    if not recipes_db.exists():
        return
    con = sqlite3.connect(recipes_db)
    con.row_factory = sqlite3.Row
    counter: Counter[str] = Counter()
    try:
        if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='recipe_ingredients'").fetchone():
            return
        query = (
            "SELECT text, COUNT(*) AS c FROM recipe_ingredients "
            "WHERE COALESCE(text, '') <> '' "
            "GROUP BY text ORDER BY c DESC LIMIT ?"
        )
        for row in con.execute(query, (max_rows,)):
            name = parse_ingredient_name(row["text"])
            if not usable_visual_name(name, max_len=8):
                continue
            counter[name] += int(row["c"] or 1)
        for name, count in counter.most_common(max_names):
            add_taxon(
                taxa,
                name,
                train_mode="pseudo_or_retrieval",
                source="recipe_ingredients.text",
                support_count=count,
                quality_score=min(1.0, 0.2 + count ** 0.5 / 100),
            )
    finally:
        con.close()


def add_recipe_title_names(taxa: dict[str, Taxon], recipes_db: Path, max_rows: int, max_names: int) -> None:
    if not recipes_db.exists():
        return
    con = sqlite3.connect(recipes_db)
    con.row_factory = sqlite3.Row
    counter: Counter[str] = Counter()
    try:
        tables = [("recipes_clean", "title"), ("recipe_training_examples_clean", "recipe_title")]
        for table, column in tables:
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                continue
            if column not in {str(row[1]) for row in con.execute(f"PRAGMA table_info({table})")}:
                continue
            query = (
                f"SELECT {column} AS title FROM {table} "
                "WHERE COALESCE(title, '') <> '' AND length(title) <= 10 LIMIT ?"
            )
            for row in con.execute(query, (max_rows,)):
                name = normalize_visual_name(row["title"])
                if not usable_visual_name(name, max_len=8):
                    continue
                if len(name) < 2:
                    continue
                counter[name] += 1
        for name, count in counter.most_common(max_names):
            add_taxon(
                taxa,
                name,
                train_mode="retrieval_only",
                source="recipe_short_titles",
                support_count=count,
                quality_score=min(0.7, 0.1 + count ** 0.5 / 80),
            )
    finally:
        con.close()


def write_outputs(taxa: dict[str, Taxon], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for idx, taxon in enumerate(
        sorted(taxa.values(), key=lambda t: (train_mode_priority(t.train_mode), t.group, t.name_zh)),
        start=1,
    ):
        rows.append(
            {
                "id": idx,
                "name_zh": taxon.name_zh,
                "name_en": taxon.name_en,
                "group": taxon.group,
                "train_mode": taxon.train_mode,
                "sources": sorted(taxon.sources),
                "aliases_zh": sorted(taxon.aliases_zh),
                "aliases_en": sorted(taxon.aliases_en),
                "support_count": taxon.support_count,
                "quality_score": round(taxon.quality_score, 4),
            }
        )
    output.write_text(json.dumps({"classes": rows}, ensure_ascii=False, indent=2), encoding="utf-8")
    tsv = output.with_suffix(".tsv")
    tsv.write_text(
        "\n".join(
            ["id\tname_zh\tname_en\tgroup\ttrain_mode\tsources"]
            + [
                f"{row['id']}\t{row['name_zh']}\t{row['name_en']}\t{row['group']}\t{row['train_mode']}\t{','.join(row['sources'])}"
                for row in rows
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--foods-db", type=Path, default=DEFAULT_FOODS_DB)
    parser.add_argument("--recipes-db", type=Path, default=DEFAULT_RECIPES_DB)
    parser.add_argument("--food-labels", type=Path, default=DEFAULT_FOOD_LABELS)
    parser.add_argument("--core-labels", type=Path, default=DEFAULT_CORE_LABELS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--max-foods-db-names", type=int, default=500)
    parser.add_argument("--include-recipes", action="store_true")
    parser.add_argument("--max-recipe-ingredient-rows", type=int, default=50000)
    parser.add_argument("--max-recipe-ingredient-names", type=int, default=500)
    parser.add_argument("--max-recipe-title-rows", type=int, default=100000)
    parser.add_argument("--max-recipe-title-names", type=int, default=500)
    parser.add_argument("--target-classes", type=int, default=0)
    args = parser.parse_args()

    taxa: dict[str, Taxon] = {}
    for name_en, name_zh, group, mode in FOODSEG103_SEED:
        add_taxon(taxa, name_zh, name_en=name_en, group=group, train_mode=mode, source="FoodSeg103_seed")
    for name_en, name_zh, group, mode in HAND_CLASSES:
        add_taxon(taxa, name_zh, name_en=name_en, group=group, train_mode=mode, source="CAL_hand_seed")
    for name in load_json_labels(args.core_labels):
        add_taxon(taxa, name, train_mode="pseudo_or_retrieval", source=args.core_labels.name)
    for name in load_json_labels(args.food_labels):
        add_taxon(taxa, name, train_mode="retrieval_only", source=args.food_labels.name)
    add_foods_db_names(taxa, args.foods_db, args.max_foods_db_names)
    if args.include_recipes:
        add_recipe_ingredient_names(
            taxa,
            args.recipes_db,
            max_rows=args.max_recipe_ingredient_rows,
            max_names=args.max_recipe_ingredient_names,
        )
        if args.target_classes <= 0 or len(taxa) < args.target_classes:
            add_recipe_title_names(
                taxa,
                args.recipes_db,
                max_rows=args.max_recipe_title_rows,
                max_names=args.max_recipe_title_names,
            )

    write_outputs(taxa, args.out)
    counts: dict[str, int] = {}
    for taxon in taxa.values():
        counts[taxon.train_mode] = counts.get(taxon.train_mode, 0) + 1
    print(json.dumps({"out": str(args.out), "classes": len(taxa), "by_train_mode": counts}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
