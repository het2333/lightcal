"""Import remaining supplemental local datasets from ../data.

This preserves local assets that are useful but should not be duplicated into
the primary foods/recipes tables:
  - Taiwan nutrient XML long table
  - Ta-da interactions, menu ratings, and dish rows
  - MIRecipe image metadata and stats
  - XiaChuFang conversation-format training data
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
LOCAL_DATA_DIR = ROOT.parent / "data"
FOODS_DB = ROOT / "data" / "foods.db"
RECIPES_DB = ROOT / "data" / "recipes.db"
REPORT_DIR = ROOT / "data" / "reports"

TAIWAN_XML = LOCAL_DATA_DIR / "20_1.xml"
TA_DA_DIR = LOCAL_DATA_DIR / "Ta-da-recipe-dataset-main"
TA_DA_INTERACTIONS = TA_DA_DIR / "demo_interactions.csv"
TA_DA_MENU_RATINGS = TA_DA_DIR / "demo_data_rating_menus.csv"
TA_DA_DISHES = TA_DA_DIR / "Knowledge Graph Data" / "dishes.csv"
MIRECIPE_DIR = LOCAL_DATA_DIR / "recipeData-main"
MIRECIPE_IMAGE_INFO = MIRECIPE_DIR / "ImageInfo.csv"
MIRECIPE_STATS = [MIRECIPE_DIR / "Stats.csv", MIRECIPE_DIR / "Stats-new1.csv"]
TRAINING_JSON = LOCAL_DATA_DIR / "tran_dataset_single_0.json"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    text = str(value).strip().replace(",", "")
    if not text:
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(match.group(0)) if match else None


def parse_int(value: Any) -> int | None:
    number = parse_float(value)
    return int(number) if number is not None else None


def clean(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def parse_listish(text: str) -> str:
    text = text.strip()
    if not text:
        return "[]"
    try:
        return json.dumps(json.loads(text.replace("'", '"')), ensure_ascii=False)
    except json.JSONDecodeError:
        return json.dumps([text], ensure_ascii=False)


def ensure_food_tables(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS taiwan_food_nutrients_long (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            food_code TEXT NOT NULL,
            food_category TEXT DEFAULT '',
            data_category TEXT DEFAULT '',
            food_name TEXT NOT NULL,
            common_name TEXT DEFAULT '',
            english_name TEXT DEFAULT '',
            description TEXT DEFAULT '',
            waste_percent REAL,
            nutrient_category TEXT DEFAULT '',
            nutrient_name TEXT NOT NULL,
            unit TEXT DEFAULT '',
            amount_per_100g TEXT DEFAULT '',
            amount_per_100g_numeric REAL,
            sample_count INTEGER,
            stddev TEXT DEFAULT '',
            amount_per_unit TEXT DEFAULT '',
            unit_weight TEXT DEFAULT '',
            amount_per_unit_weight TEXT DEFAULT '',
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_taiwan_nutrients_food ON taiwan_food_nutrients_long(food_code)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_taiwan_nutrients_name ON taiwan_food_nutrients_long(nutrient_name)")


def import_taiwan_xml(conn: sqlite3.Connection, batch_size: int) -> int:
    ensure_food_tables(conn)
    conn.execute("DELETE FROM taiwan_food_nutrients_long WHERE source_path = ?", (str(TAIWAN_XML),))
    rows = []
    imported = 0
    imported_at = now_iso()
    for _, elem in ET.iterparse(TAIWAN_XML, events=("end",)):
        if elem.tag != "rows":
            continue
        item = {child.tag: child.text for child in elem}
        food_code = clean(item.get("整合編號"))
        food_name = clean(item.get("樣品名稱"))
        nutrient_name = clean(item.get("分析項"))
        if food_code and food_name and nutrient_name:
            rows.append(
                (
                    food_code,
                    clean(item.get("食品分類")),
                    clean(item.get("資料類別")),
                    food_name,
                    clean(item.get("俗名")),
                    clean(item.get("樣品英文名稱")),
                    clean(item.get("內容物描述")),
                    parse_float(item.get("廢棄率")),
                    clean(item.get("分析項分類")),
                    nutrient_name,
                    clean(item.get("含量單位")),
                    clean(item.get("每100克含量")),
                    parse_float(item.get("每100克含量")),
                    parse_int(item.get("樣本數")),
                    clean(item.get("標準差")),
                    clean(item.get("每單位含量")),
                    clean(item.get("每單位重")),
                    clean(item.get("每單位重含量")),
                    str(TAIWAN_XML),
                    imported_at,
                )
            )
        elem.clear()
        if len(rows) >= batch_size:
            conn.executemany(
                """
                INSERT INTO taiwan_food_nutrients_long
                    (food_code, food_category, data_category, food_name, common_name,
                     english_name, description, waste_percent, nutrient_category,
                     nutrient_name, unit, amount_per_100g, amount_per_100g_numeric,
                     sample_count, stddev, amount_per_unit, unit_weight,
                     amount_per_unit_weight, source_path, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            imported += len(rows)
            rows = []
    if rows:
        conn.executemany(
            """
            INSERT INTO taiwan_food_nutrients_long
                (food_code, food_category, data_category, food_name, common_name,
                 english_name, description, waste_percent, nutrient_category,
                 nutrient_name, unit, amount_per_100g, amount_per_100g_numeric,
                 sample_count, stddev, amount_per_unit, unit_weight,
                 amount_per_unit_weight, source_path, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        imported += len(rows)
    return imported


def ensure_recipe_tables(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS ta_da_interactions (
            menus_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            rating REAL,
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL,
            PRIMARY KEY (menus_id, user_id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS ta_da_menu_ratings (
            menus_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            average_score REAL,
            favorites_count INTEGER,
            views_count INTEGER,
            technique TEXT DEFAULT '',
            taste TEXT DEFAULT '',
            cook_time TEXT DEFAULT '',
            difficulty TEXT DEFAULT '',
            main_ingredients_json TEXT DEFAULT '[]',
            side_ingredients_json TEXT DEFAULT '[]',
            contraindications_json TEXT DEFAULT '[]',
            sugar_text TEXT DEFAULT '',
            fat_text TEXT DEFAULT '',
            calories_text TEXT DEFAULT '',
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS ta_da_dishes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            technique TEXT DEFAULT '',
            taste TEXT DEFAULT '',
            cook_time TEXT DEFAULT '',
            difficulty TEXT DEFAULT '',
            main_ingredients_json TEXT DEFAULT '[]',
            side_ingredients_json TEXT DEFAULT '[]',
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS mirecipe_image_info (
            recipe_id TEXT NOT NULL,
            total_num_of_step INTEGER,
            file_name TEXT NOT NULL,
            step_num INTEGER,
            relative_position REAL,
            category_num INTEGER,
            subset_num INTEGER,
            image_url TEXT DEFAULT '',
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL,
            PRIMARY KEY (recipe_id, file_name)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS mirecipe_stats (
            recipe_id TEXT PRIMARY KEY,
            ingredients_count INTEGER,
            seasonings_count INTEGER,
            steps_count INTEGER,
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_training_conversations (
            id INTEGER PRIMARY KEY,
            system TEXT DEFAULT '',
            user_input TEXT NOT NULL,
            assistant_output TEXT NOT NULL,
            source_key TEXT NOT NULL,
            source_path TEXT NOT NULL,
            imported_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_training_conversations_input ON recipe_training_conversations(user_input)")


def import_ta_da_interactions(conn: sqlite3.Connection) -> int:
    conn.execute("DELETE FROM ta_da_interactions WHERE source_path = ?", (str(TA_DA_INTERACTIONS),))
    rows = []
    imported_at = now_iso()
    with TA_DA_INTERACTIONS.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(
                (
                    clean(row.get("menus_id")),
                    clean(row.get("user_id")),
                    parse_float(row.get("评分")),
                    str(TA_DA_INTERACTIONS),
                    imported_at,
                )
            )
    conn.executemany(
        """
        INSERT OR REPLACE INTO ta_da_interactions
            (menus_id, user_id, rating, source_path, imported_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def import_ta_da_menu_ratings(conn: sqlite3.Connection) -> int:
    conn.execute("DELETE FROM ta_da_menu_ratings WHERE source_path = ?", (str(TA_DA_MENU_RATINGS),))
    rows = []
    imported_at = now_iso()
    with TA_DA_MENU_RATINGS.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(
                (
                    clean(row.get("menus_id")),
                    clean(row.get("名字")),
                    parse_float(row.get("平均分")),
                    parse_int(row.get("收藏")),
                    parse_int(row.get("浏览")),
                    clean(row.get("工艺")),
                    clean(row.get("口味")),
                    clean(row.get("时间")),
                    clean(row.get("难度")),
                    parse_listish(row.get("主料") or ""),
                    parse_listish(row.get("辅料") or ""),
                    parse_listish(row.get("禁忌综合") or ""),
                    clean(row.get("糖")),
                    clean(row.get("脂肪")),
                    clean(row.get("热量")),
                    str(TA_DA_MENU_RATINGS),
                    imported_at,
                )
            )
    conn.executemany(
        """
        INSERT OR REPLACE INTO ta_da_menu_ratings
            (menus_id, name, average_score, favorites_count, views_count,
             technique, taste, cook_time, difficulty, main_ingredients_json,
             side_ingredients_json, contraindications_json, sugar_text,
             fat_text, calories_text, source_path, imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def import_ta_da_dishes(conn: sqlite3.Connection) -> int:
    conn.execute("DELETE FROM ta_da_dishes WHERE source_path = ?", (str(TA_DA_DISHES),))
    rows = []
    imported_at = now_iso()
    with TA_DA_DISHES.open(encoding="gb18030", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(
                (
                    clean(row.get("菜名")),
                    clean(row.get("工艺")),
                    clean(row.get("口味")),
                    clean(row.get("时间")),
                    clean(row.get("难度")),
                    parse_listish(row.get("主料") or ""),
                    parse_listish(row.get("辅料") or ""),
                    str(TA_DA_DISHES),
                    imported_at,
                )
            )
    conn.executemany(
        """
        INSERT INTO ta_da_dishes
            (name, technique, taste, cook_time, difficulty,
             main_ingredients_json, side_ingredients_json, source_path, imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def import_mirecipe_image_info(conn: sqlite3.Connection) -> int:
    conn.execute("DELETE FROM mirecipe_image_info WHERE source_path = ?", (str(MIRECIPE_IMAGE_INFO),))
    rows = []
    imported_at = now_iso()
    with MIRECIPE_IMAGE_INFO.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(
                (
                    clean(row.get("Recipe_id")),
                    parse_int(row.get("totalNumOfStep")),
                    clean(row.get("FileName")),
                    parse_int(row.get("Step_num")),
                    parse_float(row.get("Nper")),
                    parse_int(row.get("Category_num")),
                    parse_int(row.get("SubsetNum")),
                    clean(row.get("ImgLink")),
                    str(MIRECIPE_IMAGE_INFO),
                    imported_at,
                )
            )
    conn.executemany(
        """
        INSERT OR REPLACE INTO mirecipe_image_info
            (recipe_id, total_num_of_step, file_name, step_num,
             relative_position, category_num, subset_num, image_url,
             source_path, imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def import_mirecipe_stats(conn: sqlite3.Connection) -> int:
    total = 0
    imported_at = now_iso()
    for path in MIRECIPE_STATS:
        conn.execute("DELETE FROM mirecipe_stats WHERE source_path = ?", (str(path),))
        rows = []
        with path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                rows.append(
                    (
                        clean(row.get("recipeID")),
                        parse_int(row.get("Ingredients")),
                        parse_int(row.get("Seasonings")),
                        parse_int(row.get("Steps")),
                        str(path),
                        imported_at,
                    )
                )
        conn.executemany(
            """
            INSERT OR REPLACE INTO mirecipe_stats
                (recipe_id, ingredients_count, seasonings_count, steps_count,
                 source_path, imported_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        total += len(rows)
    return total


def iter_json_array(path: Path) -> Iterable[dict[str, Any]]:
    decoder = json.JSONDecoder()
    with path.open(encoding="utf-8", errors="replace") as handle:
        buffer = ""
        in_array = False
        eof = False
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                eof = True
            buffer += chunk
            pos = 0
            while True:
                while pos < len(buffer) and buffer[pos].isspace():
                    pos += 1
                if not in_array:
                    if pos < len(buffer) and buffer[pos] == "[":
                        in_array = True
                        pos += 1
                    else:
                        break
                while pos < len(buffer) and buffer[pos].isspace():
                    pos += 1
                if pos < len(buffer) and buffer[pos] == ",":
                    pos += 1
                    continue
                if pos < len(buffer) and buffer[pos] == "]":
                    return
                try:
                    obj, end = decoder.raw_decode(buffer, pos)
                except json.JSONDecodeError:
                    break
                if isinstance(obj, dict):
                    yield obj
                pos = end
            buffer = buffer[pos:]
            if eof:
                if buffer.strip() not in {"", "]"}:
                    raise json.JSONDecodeError("Trailing incomplete JSON", buffer, 0)
                return


def import_training_conversations(conn: sqlite3.Connection, batch_size: int, limit: int | None) -> int:
    conn.execute("DELETE FROM recipe_training_conversations WHERE source_path = ?", (str(TRAINING_JSON),))
    imported = 0
    rows = []
    imported_at = now_iso()
    for item in iter_json_array(TRAINING_JSON):
        conversations = item.get("conversation") or []
        if not conversations:
            continue
        turn = conversations[0]
        rows.append(
            (
                imported + len(rows) + 1,
                clean(turn.get("system")),
                clean(turn.get("input")),
                str(turn.get("output") or ""),
                "xiachufang_conversation_training",
                str(TRAINING_JSON),
                imported_at,
            )
        )
        if len(rows) >= batch_size:
            conn.executemany(
                """
                INSERT INTO recipe_training_conversations
                    (id, system, user_input, assistant_output, source_key, source_path, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            imported += len(rows)
            rows = []
            conn.commit()
            if imported % 100000 == 0:
                print(f"  imported training conversations: {imported}", flush=True)
            if limit is not None and imported >= limit:
                return imported
    if rows and (limit is None or imported < limit):
        if limit is not None:
            rows = rows[: max(0, limit - imported)]
        conn.executemany(
            """
            INSERT INTO recipe_training_conversations
                (id, system, user_input, assistant_output, source_key, source_path, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        imported += len(rows)
    return imported


def write_report(counts: dict[str, int]) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Local `/cal/data` Supplemental Import Report",
        "",
        f"Generated: {now_iso()}",
        "",
        "## Imported Supplemental Tables",
        "",
    ]
    for key, count in counts.items():
        lines.append(f"- {key}: {count}")
    lines.append("")
    path = REPORT_DIR / "local_cal_data_supplemental_import.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-training", action="store_true")
    parser.add_argument("--training-limit", type=int, default=-1)
    parser.add_argument("--batch-size", type=int, default=10000)
    args = parser.parse_args()

    counts: dict[str, int] = {}

    food_conn = sqlite3.connect(FOODS_DB)
    food_conn.execute("PRAGMA journal_mode=WAL")
    food_conn.execute("PRAGMA synchronous=NORMAL")
    counts["taiwan_food_nutrients_long"] = import_taiwan_xml(food_conn, args.batch_size)
    food_conn.commit()
    food_conn.close()

    recipe_conn = sqlite3.connect(RECIPES_DB)
    recipe_conn.execute("PRAGMA journal_mode=WAL")
    recipe_conn.execute("PRAGMA synchronous=NORMAL")
    ensure_recipe_tables(recipe_conn)
    counts["ta_da_interactions"] = import_ta_da_interactions(recipe_conn)
    counts["ta_da_menu_ratings"] = import_ta_da_menu_ratings(recipe_conn)
    counts["ta_da_dishes"] = import_ta_da_dishes(recipe_conn)
    counts["mirecipe_image_info"] = import_mirecipe_image_info(recipe_conn)
    counts["mirecipe_stats"] = import_mirecipe_stats(recipe_conn)
    recipe_conn.commit()

    if not args.skip_training:
        limit = None if args.training_limit < 0 else args.training_limit
        counts["recipe_training_conversations"] = import_training_conversations(
            recipe_conn,
            args.batch_size,
            limit,
        )
        recipe_conn.commit()

    recipe_conn.close()
    report = write_report(counts)
    print(f"Counts: {counts}")
    print(f"Report: {report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
