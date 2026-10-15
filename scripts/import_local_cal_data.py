"""Import local datasets from ../data into the app databases.

This script covers the data folder beside cal-repro:
  - Taiwan food nutrition Excel into foods.db
  - Ta-da food knowledge graph into foods.db
  - Ta-da demo recipes, MIRecipe/Haodou, and XiaChuFang recipes into recipes.db

Large recipe imports are streamed in batches so reruns do not require loading
the whole corpus into memory.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sqlite3
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import openpyxl

from collect_food_data import (
    DB_PATH as FOODS_DB_PATH,
    Source,
    as_float as food_float,
    ensure_schema as ensure_food_schema,
    normalize_processing_level,
    stable_id as food_stable_id,
    upsert_food_batch,
    write_report as write_food_report,
)
from collect_recipe_data import (
    DB_PATH as RECIPES_DB_PATH,
    RecipeSource,
    clean_text,
    ensure_schema as ensure_recipe_schema,
    stable_id as recipe_stable_id,
    write_report as write_recipe_report,
)


ROOT = Path(__file__).resolve().parent.parent
LOCAL_DATA_DIR = ROOT.parent / "data"
REPORT_DIR = ROOT / "data" / "reports"


TAIWAN_XLSX = LOCAL_DATA_DIR / "食品營養成分資料庫2025版UPDATE1EXCEL(另開新視窗).xlsx"
TA_DA_FOOD_CSV = LOCAL_DATA_DIR / "Ta-da-recipe-dataset-main" / "Knowledge Graph Data" / "food.csv"
TA_DA_RECIPE_CSV = LOCAL_DATA_DIR / "Ta-da-recipe-dataset-main" / "demo-recipe.csv"
MIRECIPE_FILES = [
    LOCAL_DATA_DIR / "recipeData-main" / "recipeData.json",
    LOCAL_DATA_DIR / "recipeData-main" / "recipeData-new1.json",
]
XIACHUFANG_JSONL = LOCAL_DATA_DIR / "XiaChuFang" / "data" / "recipe_corpus_full.json"


TAIWAN_SOURCE = Source(
    key="taiwan_food_nutrition_2025_update1",
    label="台湾食品营养成分资料库 2025 UPDATE1",
    url="local:/data/食品營養成分資料庫2025版UPDATE1EXCEL",
    raw_path=TAIWAN_XLSX,
    license_name="Open data / terms require review before commercial release",
    attribution="台湾食品营养成分资料库 2025 UPDATE1",
)
TA_DA_FOOD_SOURCE = Source(
    key="ta_da_food_kg",
    label="Ta-da Recipe Dataset food knowledge graph（需复核）",
    url="https://github.com/Eimo-Bai/Ta-da-recipe-dataset",
    raw_path=TA_DA_FOOD_CSV,
    license_name="Dataset license/terms require review before commercial release",
    attribution="Ta-da Recipe Dataset contributors",
)

TA_DA_RECIPE_SOURCE = RecipeSource(
    key="ta_da_recipe_dataset_demo",
    label="Ta-da Recipe Dataset demo recipes（需复核）",
    url="https://github.com/Eimo-Bai/Ta-da-recipe-dataset",
    raw_path=TA_DA_RECIPE_CSV,
    license_name="Dataset license/terms require review before commercial release",
    attribution="Ta-da Recipe Dataset contributors",
)
MIRECIPE_SOURCE = RecipeSource(
    key="mirecipe_haodou",
    label="MIRecipe / Haodou recipeData（需复核）",
    url="https://github.com/bimissing/recipeData",
    raw_path=LOCAL_DATA_DIR / "recipeData-main",
    license_name="Dataset license/terms require review before commercial release",
    attribution="MIRecipe / Haodou recipeData contributors",
)
XIACHUFANG_SOURCE = RecipeSource(
    key="xiachufang_recipe_corpus",
    label="XiaChuFang Recipe Corpus 下厨房食谱语料库（需复核）",
    url="https://orion.hyper.ai/datasets/28489",
    raw_path=XIACHUFANG_JSONL,
    license_name="Dataset license/terms require review before commercial release",
    attribution="Baidu, Beijing Institute for General Artificial Intelligence, Tsinghua University / HyperAI mirror",
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def file_sha256(path: Path) -> str:
    if not path.exists():
        return ""
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def path_text(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def register_food_source(conn: sqlite3.Connection, source: Source, imported_count: int) -> None:
    conn.execute(
        """
        INSERT INTO food_data_sources
            (key, label, url, license_name, attribution, raw_path, raw_sha256,
             imported_count, last_imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            label = excluded.label,
            url = excluded.url,
            license_name = excluded.license_name,
            attribution = excluded.attribution,
            raw_path = excluded.raw_path,
            raw_sha256 = excluded.raw_sha256,
            imported_count = excluded.imported_count,
            last_imported_at = excluded.last_imported_at
        """,
        (
            source.key,
            source.label,
            source.url,
            source.license_name,
            source.attribution,
            path_text(source.raw_path),
            file_sha256(source.raw_path),
            imported_count,
            now_iso(),
        ),
    )


def register_recipe_source(conn: sqlite3.Connection, source: RecipeSource, imported_count: int) -> None:
    raw_hash = file_sha256(source.raw_path) if source.raw_path.is_file() else ""
    conn.execute(
        """
        INSERT INTO recipe_data_sources
            (key, label, url, license_name, attribution, commercial_ready,
             raw_path, raw_sha256, imported_count, last_imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            label = excluded.label,
            url = excluded.url,
            license_name = excluded.license_name,
            attribution = excluded.attribution,
            commercial_ready = excluded.commercial_ready,
            raw_path = excluded.raw_path,
            raw_sha256 = excluded.raw_sha256,
            imported_count = excluded.imported_count,
            last_imported_at = excluded.last_imported_at
        """,
        (
            source.key,
            source.label,
            source.url,
            source.license_name,
            source.attribution,
            0,
            path_text(source.raw_path),
            raw_hash,
            imported_count,
            now_iso(),
        ),
    )


def parse_number(value: Any, default: float = 0.0) -> float:
    if value in (None, ""):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip().replace(",", "")
    if not text or text in {"-", "—", "Trace", "Tr"}:
        return default
    match = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(match.group(0)) if match else default


def import_taiwan_foods(conn: sqlite3.Connection) -> int:
    workbook = openpyxl.load_workbook(TAIWAN_XLSX, read_only=True, data_only=True)
    sheet = workbook["台灣食品成分表"]
    rows_iter = sheet.iter_rows(values_only=True)
    next(rows_iter, None)
    headers = [str(value).strip() if value is not None else "" for value in next(rows_iter)]
    index = {name: i for i, name in enumerate(headers) if name}

    def value(row: tuple[Any, ...], name: str) -> Any:
        i = index.get(name)
        return row[i] if i is not None and i < len(row) else None

    rows: list[tuple[str, dict[str, Any]]] = []
    for row in rows_iter:
        external_id = str(value(row, "整合編號") or "").strip()
        name = str(value(row, "樣品名稱") or "").strip()
        if not external_id or not name:
            continue
        item = {
            "name": name,
            "calories": parse_number(value(row, "熱量(kcal)")),
            "protein": parse_number(value(row, "粗蛋白(g)")),
            "carbs": parse_number(value(row, "總碳水化合物(g)")),
            "fat": parse_number(value(row, "粗脂肪(g)")),
            "fiber": parse_number(value(row, "膳食纖維(g)")),
            "sugar": parse_number(value(row, "糖質總量(g)")),
            "added_sugar": 0,
            "sodium": parse_number(value(row, "鈉(mg)")),
            "sat_fat": parse_number(value(row, "飽和脂肪(g)")),
            "trans_fat": parse_number(value(row, "反式脂肪(mg)")) / 1000,
            "cholesterol": parse_number(value(row, "膽固醇(mg)")),
            "vitamin_a": parse_number(value(row, "視網醇當量(RE)(ug)")),
            "vitamin_c": parse_number(value(row, "維生素C(mg)")),
            "calcium": parse_number(value(row, "鈣(mg)")),
            "iron": parse_number(value(row, "鐵(mg)")),
            "potassium": parse_number(value(row, "鉀(mg)")),
            "serving_size": "100g edible portion",
            "processing_level": normalize_processing_level(f"{value(row, '食品分類')} {name}", TAIWAN_SOURCE.key),
            "barcode": "",
        }
        rows.append((external_id, item))
    imported = upsert_food_batch(conn, TAIWAN_SOURCE, rows)
    register_food_source(conn, TAIWAN_SOURCE, imported)
    return imported


NUTRIENT_NAME_MAP = {
    "热量": "calories",
    "蛋白质": "protein",
    "脂肪": "fat",
    "碳水化合物": "carbs",
    "膳食纤维": "fiber",
    "糖": "sugar",
    "钠": "sodium",
    "钾": "potassium",
    "钙": "calcium",
    "铁": "iron",
    "胆固醇": "cholesterol",
    "维生素A": "vitamin_a",
    "维生素C": "vitamin_c",
}


def parse_ta_da_nutrients(text: str) -> dict[str, float]:
    result: dict[str, float] = {}
    for part in text.split(","):
        match = re.search(r"([\u4e00-\u9fa5A-Za-z0-9]+)\s*([0-9.]+)\s*([\u4e00-\u9fa5]+)?", part)
        if not match:
            continue
        raw_name, raw_value, unit = match.groups()
        field = NUTRIENT_NAME_MAP.get(raw_name)
        if not field:
            continue
        amount = parse_number(raw_value)
        if unit == "克" and amount > 100 and field not in {"calories"}:
            amount /= 1000
        result[field] = amount
    return result


def import_ta_da_foods(conn: sqlite3.Connection) -> int:
    rows: list[tuple[str, dict[str, Any]]] = []
    with TA_DA_FOOD_CSV.open(encoding="gb18030", newline="") as handle:
        reader = csv.DictReader(handle)
        for idx, row in enumerate(reader, start=1):
            name = clean_text(row.get("食物名") or "")
            if not name:
                continue
            nutrients = parse_ta_da_nutrients(row.get("营养价值") or "")
            item = {
                "name": name,
                "calories": nutrients.get("calories", 0),
                "protein": nutrients.get("protein", 0),
                "carbs": nutrients.get("carbs", 0),
                "fat": nutrients.get("fat", 0),
                "fiber": nutrients.get("fiber", 0),
                "sugar": nutrients.get("sugar", 0),
                "added_sugar": 0,
                "sodium": nutrients.get("sodium", 0),
                "cholesterol": nutrients.get("cholesterol", 0),
                "vitamin_a": nutrients.get("vitamin_a", 0),
                "vitamin_c": nutrients.get("vitamin_c", 0),
                "calcium": nutrients.get("calcium", 0),
                "iron": nutrients.get("iron", 0),
                "potassium": nutrients.get("potassium", 0),
                "serving_size": "100g",
                "processing_level": normalize_processing_level(name, TA_DA_FOOD_SOURCE.key),
                "barcode": "",
            }
            rows.append((str(idx), item))
    imported = upsert_food_batch(conn, TA_DA_FOOD_SOURCE, rows)
    register_food_source(conn, TA_DA_FOOD_SOURCE, imported)
    return imported


def chunked(iterable: Iterable[Any], size: int) -> Iterable[list[Any]]:
    batch = []
    for item in iterable:
        batch.append(item)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


@dataclass
class RecipeRecord:
    source: RecipeSource
    external_id: str
    title: str
    description: str
    ingredients: list[str]
    steps: list[str]
    tags: list[str]
    image_url: str = ""
    nutrients: dict[str, Any] | None = None


def insert_recipe_batch(conn: sqlite3.Connection, records: list[RecipeRecord]) -> int:
    recipe_rows = []
    ingredient_rows = []
    step_rows = []
    tag_rows = []
    nutrient_rows = []
    for record in records:
        title = clean_text(record.title)
        if not title:
            continue
        source = record.source
        recipe_id = recipe_stable_id(source.key, record.external_id)
        recipe_rows.append(
            (
                recipe_id,
                title,
                clean_text(record.description),
                "",
                "",
                "",
                None,
                None,
                None,
                record.image_url,
                source.key,
                source.url,
                record.external_id,
                source.license_name,
                source.attribution,
                0,
                path_text(source.raw_path),
            )
        )
        for i, text in enumerate(record.ingredients, start=1):
            text = clean_text(text)
            if text:
                ingredient_rows.append((f"{recipe_id}:i:{i}", recipe_id, i, text))
        for i, text in enumerate(record.steps, start=1):
            text = clean_text(text)
            if text:
                step_rows.append((f"{recipe_id}:s:{i}", recipe_id, i, text))
        for tag in sorted({clean_text(tag).lower() for tag in record.tags if clean_text(tag)}):
            tag_rows.append((recipe_id, tag))
        for name, raw in (record.nutrients or {}).items():
            amount = parse_number(raw)
            if amount <= 0:
                continue
            nutrient_rows.append((f"{recipe_id}:n:{name}", recipe_id, name, amount, "", str(raw)))

    conn.executemany(
        """
        INSERT INTO recipes
            (id, title, description, cuisine, category, servings, prep_time_minutes,
             cook_time_minutes, total_time_minutes, image_url, source_key,
             source_url, source_external_id, license_name, attribution,
             commercial_ready, raw_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            description = excluded.description,
            image_url = excluded.image_url,
            source_url = excluded.source_url,
            license_name = excluded.license_name,
            attribution = excluded.attribution,
            commercial_ready = excluded.commercial_ready,
            raw_path = excluded.raw_path
        """,
        recipe_rows,
    )
    conn.executemany(
        "INSERT OR REPLACE INTO recipe_ingredients (id, recipe_id, position, text) VALUES (?, ?, ?, ?)",
        ingredient_rows,
    )
    conn.executemany(
        "INSERT OR REPLACE INTO recipe_steps (id, recipe_id, position, text) VALUES (?, ?, ?, ?)",
        step_rows,
    )
    conn.executemany("INSERT OR IGNORE INTO recipe_tags (recipe_id, tag) VALUES (?, ?)", tag_rows)
    conn.executemany(
        """
        INSERT OR REPLACE INTO recipe_nutrients
            (id, recipe_id, nutrient, amount, unit, raw_value)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        nutrient_rows,
    )
    return len(recipe_rows)


def ingredient_texts(items: Any) -> list[str]:
    result: list[str] = []
    if not isinstance(items, list):
        return result
    for item in items:
        if isinstance(item, dict):
            name = clean_text(str(item.get("name") or ""))
            weight = clean_text(str(item.get("weight") or ""))
            text = f"{name} {weight}".strip()
        else:
            text = clean_text(str(item))
        if text:
            result.append(text)
    return result


def import_mirecipe(conn: sqlite3.Connection, batch_size: int) -> int:
    imported = 0
    for path in MIRECIPE_FILES:
        data = json.loads(path.read_text(encoding="utf-8"))
        records = []
        for key, item in data.items():
            ingredients = ingredient_texts(item.get("ingredients"))
            ingredients.extend(ingredient_texts(item.get("seasonings")))
            instructions = item.get("instructions") or []
            steps = []
            image_url = ""
            for step in instructions:
                if isinstance(step, dict):
                    if not image_url and step.get("imgLink"):
                        image_url = str(step.get("imgLink"))
                    steps.append(str(step.get("description") or ""))
                else:
                    steps.append(str(step))
            desc = clean_text(str(item.get("briefDes") or ""))
            tips = clean_text(str(item.get("tips") or ""))
            if tips:
                desc = f"{desc}\nTips: {tips}".strip()
            records.append(
                RecipeRecord(
                    source=MIRECIPE_SOURCE,
                    external_id=str(item.get("recipeID") or key),
                    title=str(item.get("recipeName") or ""),
                    description=desc,
                    ingredients=ingredients,
                    steps=steps,
                    tags=["MIRecipe", "好豆"],
                    image_url=image_url,
                )
            )
            if len(records) >= batch_size:
                imported += insert_recipe_batch(conn, records)
                conn.commit()
                records = []
        if records:
            imported += insert_recipe_batch(conn, records)
            conn.commit()
    register_recipe_source(conn, MIRECIPE_SOURCE, imported)
    return imported


def import_ta_da_recipes(conn: sqlite3.Connection, batch_size: int) -> int:
    imported = 0
    records = []
    with TA_DA_RECIPE_CSV.open(encoding="gb18030", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            title = row.get("名字") or ""
            ingredients = []
            ingredients.extend(parse_python_list_text(row.get("主料") or ""))
            ingredients.extend(parse_python_list_text(row.get("辅料") or ""))
            desc = "；".join(
                part
                for part in [
                    f"工艺: {row.get('工艺') or ''}",
                    f"口味: {row.get('口味') or ''}",
                    f"时间: {row.get('时间') or ''}",
                    f"难度: {row.get('难度') or ''}",
                    f"收藏: {row.get('收藏') or ''}",
                    f"浏览: {row.get('浏览') or ''}",
                ]
                if part.strip()
            )
            nutrients = {
                "sugar": row.get("糖") or "",
                "fat": row.get("脂肪") or "",
                "calories": row.get("热量") or "",
            }
            records.append(
                RecipeRecord(
                    source=TA_DA_RECIPE_SOURCE,
                    external_id=str(row.get("menus_id") or title),
                    title=title,
                    description=desc,
                    ingredients=ingredients,
                    steps=[],
                    tags=[row.get("工艺") or "", row.get("口味") or "", row.get("难度") or ""],
                    nutrients=nutrients,
                )
            )
            if len(records) >= batch_size:
                imported += insert_recipe_batch(conn, records)
                conn.commit()
                records = []
    if records:
        imported += insert_recipe_batch(conn, records)
        conn.commit()
    register_recipe_source(conn, TA_DA_RECIPE_SOURCE, imported)
    return imported


def parse_python_list_text(text: str) -> list[str]:
    text = text.strip()
    if not text:
        return []
    try:
        value = json.loads(text.replace("'", '"'))
        if isinstance(value, list):
            return [clean_text(str(item)) for item in value if clean_text(str(item))]
    except json.JSONDecodeError:
        pass
    return [clean_text(text)] if text else []


def import_xiachufang(conn: sqlite3.Connection, batch_size: int, limit: int | None = None) -> int:
    imported = 0
    records: list[RecipeRecord] = []
    with XIACHUFANG_JSONL.open(encoding="utf-8", errors="replace") as handle:
        for line_no, line in enumerate(handle, start=1):
            if limit is not None and line_no > limit:
                break
            text = line.strip()
            if not text:
                continue
            try:
                item = json.loads(text)
            except json.JSONDecodeError:
                continue
            records.append(
                RecipeRecord(
                    source=XIACHUFANG_SOURCE,
                    external_id=str(line_no),
                    title=str(item.get("name") or ""),
                    description=str(item.get("description") or ""),
                    ingredients=[str(x) for x in item.get("recipeIngredient") or []],
                    steps=[str(x) for x in item.get("recipeInstructions") or []],
                    tags=[str(item.get("dish") or ""), *[str(x) for x in item.get("keywords") or []]],
                )
            )
            if len(records) >= batch_size:
                imported += insert_recipe_batch(conn, records)
                conn.commit()
                records = []
                if imported % 50000 == 0:
                    print(f"  imported XiaChuFang recipes: {imported}", flush=True)
    if records:
        imported += insert_recipe_batch(conn, records)
        conn.commit()
    register_recipe_source(conn, XIACHUFANG_SOURCE, imported)
    return imported


def write_local_report(food_counts: dict[str, int], recipe_counts: dict[str, int], skipped: list[str]) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Local `/cal/data` Import Report",
        "",
        f"Generated: {now_iso()}",
        f"Local data dir: {LOCAL_DATA_DIR}",
        "",
        "## Imported Food/Nutrition Sources",
        "",
    ]
    for key, count in food_counts.items():
        lines.append(f"- {key}: {count}")
    lines.extend(["", "## Imported Recipe Sources", ""])
    for key, count in recipe_counts.items():
        lines.append(f"- {key}: {count}")
    lines.extend(["", "## Recognized But Not Imported", ""])
    for item in skipped:
        lines.append(f"- {item}")
    lines.append("")
    path = REPORT_DIR / "local_cal_data_import.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-xiachufang", action="store_true", help="Skip the 1.5M-row XiaChuFang JSONL corpus.")
    parser.add_argument("--xiachufang-limit", type=int, default=-1, help="Limit XiaChuFang rows for a smoke run.")
    parser.add_argument("--batch-size", type=int, default=5000)
    args = parser.parse_args()

    food_conn = sqlite3.connect(FOODS_DB_PATH)
    food_conn.row_factory = sqlite3.Row
    ensure_food_schema(food_conn)
    food_conn.execute("PRAGMA journal_mode=WAL")
    food_conn.execute("PRAGMA synchronous=NORMAL")
    food_counts = {
        TAIWAN_SOURCE.key: import_taiwan_foods(food_conn),
        TA_DA_FOOD_SOURCE.key: import_ta_da_foods(food_conn),
    }
    food_conn.commit()
    food_report = write_food_report(food_conn)
    food_conn.close()

    recipe_conn = sqlite3.connect(RECIPES_DB_PATH)
    recipe_conn.row_factory = sqlite3.Row
    ensure_recipe_schema(recipe_conn)
    recipe_conn.execute("PRAGMA journal_mode=WAL")
    recipe_conn.execute("PRAGMA synchronous=NORMAL")
    recipe_counts = {
        TA_DA_RECIPE_SOURCE.key: import_ta_da_recipes(recipe_conn, args.batch_size),
        MIRECIPE_SOURCE.key: import_mirecipe(recipe_conn, args.batch_size),
    }
    if args.skip_xiachufang:
        skipped = [
            "XiaChuFang recipe_corpus_full.json skipped by flag.",
            "tran_dataset_single_0.json skipped because it is a conversation-format derivative of XiaChuFang recipes.",
            "20_1.xml skipped because the Taiwan Excel source is the normalized wide table already imported.",
        ]
    else:
        limit = None if args.xiachufang_limit < 0 else args.xiachufang_limit
        recipe_counts[XIACHUFANG_SOURCE.key] = import_xiachufang(recipe_conn, args.batch_size, limit)
        skipped = [
            "tran_dataset_single_0.json skipped because it is a conversation-format derivative of XiaChuFang recipes.",
            "20_1.xml skipped because the Taiwan Excel source is the normalized wide table already imported.",
        ]
    recipe_conn.commit()
    recipe_report = write_recipe_report(recipe_conn)
    recipe_conn.close()

    local_report = write_local_report(food_counts, recipe_counts, skipped)
    print(f"Food counts: {food_counts}")
    print(f"Recipe counts: {recipe_counts}")
    print(f"Local report: {local_report.relative_to(ROOT)}")
    print(f"Food report: {food_report.relative_to(ROOT)}")
    print(f"Recipe report: {recipe_report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
