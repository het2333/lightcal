"""Convert imported business text fields in SQLite databases to Simplified Chinese.

The conversion uses macOS Foundation/ICU through scripts/hant_to_hans.swift.
Identifiers, URLs, file paths, and raw source files are intentionally left as-is.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent.parent
FOODS_DB = ROOT / "data" / "foods.db"
RECIPES_DB = ROOT / "data" / "recipes.db"
REPORT_DIR = ROOT / "data" / "reports"
LOCAL_DATA_DIR = ROOT.parent / "data"
SWIFT_HELPER = ROOT / "scripts" / "hant_to_hans.swift"
HANT_VARIANT_CANDIDATES = "".join(
    dict.fromkeys(
        """
        臺灣營養資料庫貝類鯖飽維膽數據說來壓檢驗樣單種熱鹼鈉鉀鈣鐵鋅鎂
        磷葉蘿蔔纖鹽醣湯飯麵餅餃餛飩豬雞鴨鵝魚蝦蟹乾鮮罐頭調燴燉醬
        亞菸離胺絲麩纈釋補體開視窗與為這個對後裡裏還無將時會黃紅綠
        藍麥粥薑蒜蔥藥獻適蘋點鐘週歲萬億條塊顆盤碗鹵滷壽鋪捲貼釵鬢
        鶏焼団國韓實歷臘臨選發辦產質總網頁圖號碼級標籤題驟準備浸潤
        撈瀝灑煉鍋蓋邊滾渾餡鹹甜軟硬鳳蓮莖莢蘆筍蘑菇棗龍魷鮑鰻鱈
        鯛鯉鯽鱸鰱鯧鰹鯡鯨鵪鶉
        """
    )
)
_HANT_VARIANT_MARKERS: str | None = None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def convert_texts(values: Iterable[str]) -> dict[str, str]:
    unique = [value for value in dict.fromkeys(values) if value]
    if not unique:
        return {}

    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = "/private/tmp/codex-clang-module-cache"
    proc = subprocess.Popen(
        ["swift", str(SWIFT_HELPER)],
        cwd=str(ROOT),
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    payload = "".join(
        base64.b64encode(value.encode("utf-8")).decode("ascii") + "\n"
        for value in unique
    )
    stdout, stderr = proc.communicate(payload)
    code = proc.returncode
    if code != 0:
        raise RuntimeError(f"Swift converter failed: {stderr}")
    lines = stdout.splitlines()
    if len(lines) != len(unique):
        raise RuntimeError(f"Swift converter returned {len(lines)} rows for {len(unique)} inputs")
    converted: dict[str, str] = {}
    for value, line in zip(unique, lines):
        converted[value] = base64.b64decode(line.strip()).decode("utf-8") if line.strip() else value
    return converted


def hant_variant_markers() -> str:
    """Build a SQLite GLOB character class for Han characters changed by Hant-Hans."""
    global _HANT_VARIANT_MARKERS
    if _HANT_VARIANT_MARKERS is not None:
        return _HANT_VARIANT_MARKERS

    chars = [char for char in HANT_VARIANT_CANDIDATES if not char.isspace()]
    converted = convert_texts(chars)
    _HANT_VARIANT_MARKERS = "".join(
        char for char in chars if converted.get(char, char) != char
    )
    return _HANT_VARIANT_MARKERS


def simplify_rows(
    conn: sqlite3.Connection,
    table: str,
    columns: list[str],
    where_sql: str = "",
    where_params: tuple[object, ...] = (),
    batch_size: int = 10000,
) -> int:
    where = f" WHERE {where_sql}" if where_sql else ""
    selected_cols = ", ".join(f'"{column}"' for column in columns)
    query = f'SELECT rowid, {selected_cols} FROM "{table}"{where}'
    updated = 0

    cursor = conn.execute(query, where_params)
    while True:
        rows = cursor.fetchmany(batch_size)
        if not rows:
            break
        originals: list[str] = []
        for row in rows:
            originals.extend(str(value) for value in row[1:] if isinstance(value, str) and value)
        converted = convert_texts(originals)
        updates = []
        for row in rows:
            rowid = row[0]
            values = list(row[1:])
            new_values = []
            changed = False
            for value in values:
                if isinstance(value, str) and value:
                    new_value = converted.get(value, value)
                    changed = changed or new_value != value
                    new_values.append(new_value)
                else:
                    new_values.append(value)
            if changed:
                updates.append((*new_values, rowid))
        if updates:
            assignments = ", ".join(f'"{column}" = ?' for column in columns)
            update_sql = f'UPDATE "{table}" SET {assignments} WHERE rowid = ?'
            try:
                conn.executemany(update_sql, updates)
            except sqlite3.IntegrityError:
                conn.rollback()
                for update in updates:
                    try:
                        conn.execute(update_sql, update)
                    except sqlite3.IntegrityError:
                        if table == "recipe_tags" and columns == ["tag"]:
                            conn.execute('DELETE FROM "recipe_tags" WHERE rowid = ?', (update[-1],))
                        else:
                            raise
            updated += len(updates)
            conn.commit()
    return updated


def simplify_rows_with_hant_markers(
    conn: sqlite3.Connection,
    table: str,
    columns: list[str],
    markers: str,
    base_where_sql: str = "",
    batch_size: int = 50000,
) -> int:
    marker_re = re.compile(f"[{re.escape(markers)}]")
    where = f" WHERE {base_where_sql}" if base_where_sql else ""
    selected_cols = ", ".join(f'"{column}"' for column in columns)
    query = f'SELECT rowid, {selected_cols} FROM "{table}"{where}'
    updated = 0

    cursor = conn.execute(query)
    while True:
        rows = cursor.fetchmany(batch_size)
        if not rows:
            break

        candidate_rows = []
        originals: list[str] = []
        for row in rows:
            values = row[1:]
            if any(
                isinstance(value, str) and value and marker_re.search(value)
                for value in values
            ):
                candidate_rows.append(row)
                originals.extend(
                    value for value in values if isinstance(value, str) and value
                )
        if not candidate_rows:
            continue

        converted = convert_texts(originals)
        updates = []
        for row in candidate_rows:
            rowid = row[0]
            values = list(row[1:])
            new_values = []
            changed = False
            for value in values:
                if isinstance(value, str) and value:
                    new_value = converted.get(value, value)
                    changed = changed or new_value != value
                    new_values.append(new_value)
                else:
                    new_values.append(value)
            if changed:
                updates.append((*new_values, rowid))
        if updates:
            assignments = ", ".join(f'"{column}" = ?' for column in columns)
            update_sql = f'UPDATE "{table}" SET {assignments} WHERE rowid = ?'
            try:
                conn.executemany(update_sql, updates)
            except sqlite3.IntegrityError:
                conn.rollback()
                for update in updates:
                    try:
                        conn.execute(update_sql, update)
                    except sqlite3.IntegrityError:
                        if table == "recipe_tags" and columns == ["tag"]:
                            conn.execute('DELETE FROM "recipe_tags" WHERE rowid = ?', (update[-1],))
                        else:
                            raise
            updated += len(updates)
            conn.commit()
    return updated


def record_count(counts: dict[str, int], key: str, count: int) -> None:
    counts[key] = count
    print(f"{key}: {count}", flush=True)


def ensure_local_catalog(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS local_cal_data_files (
            path TEXT PRIMARY KEY,
            file_name TEXT NOT NULL,
            file_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT DEFAULT '',
            import_status TEXT NOT NULL,
            target_tables TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            cataloged_at TEXT NOT NULL
        )
        """
    )


def classify_file(path: Path) -> tuple[str, str, str]:
    suffix = path.suffix.lower()
    rel = str(path.relative_to(LOCAL_DATA_DIR))
    if path.name == ".DS_Store":
        return "system_metadata", "跳过", "macOS Finder 元数据，不属于业务数据"
    if suffix in {".md", ".txt"}:
        return "documentation", "已登记", "数据集说明文档，已保留文件清单"
    if suffix in {".jpg", ".png"}:
        return "image_asset", "已登记", "数据集说明/示例图片，已保留文件清单"
    if suffix == ".py":
        return "script", "已登记", "数据集下载或训练脚本，已保留文件清单"
    if rel == "20_1.xml":
        return "nutrition_xml", "已导入", "taiwan_food_nutrients_long"
    if rel.endswith("食品營養成分資料庫2025版UPDATE1EXCEL(另開新視窗).xlsx"):
        return "nutrition_xlsx", "已导入", "foods"
    if rel.endswith("Ta-da-recipe-dataset-main/Knowledge Graph Data/food.csv"):
        return "food_kg_csv", "已导入", "foods"
    if rel.endswith("Ta-da-recipe-dataset-main/demo-recipe.csv"):
        return "recipe_csv", "已导入", "recipes"
    if rel.endswith("Ta-da-recipe-dataset-main/demo_interactions.csv"):
        return "interaction_csv", "已导入", "ta_da_interactions"
    if rel.endswith("Ta-da-recipe-dataset-main/demo_data_rating_menus.csv"):
        return "rating_csv", "已导入", "ta_da_menu_ratings"
    if rel.endswith("Ta-da-recipe-dataset-main/Knowledge Graph Data/dishes.csv") or rel == "dishes.csv":
        return "dish_csv", "已导入", "ta_da_dishes"
    if rel.endswith("recipeData-main/ImageInfo.csv"):
        return "image_metadata_csv", "已导入", "mirecipe_image_info"
    if rel.endswith("recipeData-main/Stats.csv") or rel.endswith("recipeData-main/Stats-new1.csv"):
        return "stats_csv", "已导入", "mirecipe_stats"
    if rel.endswith("recipeData-main/recipeData.json") or rel.endswith("recipeData-main/recipeData-new1.json"):
        return "recipe_json", "已导入", "recipes"
    if rel.endswith("XiaChuFang/data/recipe_corpus_full.json"):
        return "recipe_jsonl", "已导入", "recipes"
    if rel == "tran_dataset_single_0.json":
        return "training_json", "已导入", "recipe_training_conversations"
    if suffix == ".zip":
        return "archive_duplicate", "重复归档", "压缩包内容已由解压后的 JSON 导入"
    return "other", "已登记", "已保留文件清单"


def catalog_local_files(conn: sqlite3.Connection) -> int:
    ensure_local_catalog(conn)
    rows = []
    cataloged_at = now_iso()
    for path in sorted(p for p in LOCAL_DATA_DIR.rglob("*") if p.is_file()):
        file_type, status, notes = classify_file(path)
        target_tables = notes if status == "已导入" else ""
        rows.append(
            (
                str(path),
                path.name,
                file_type,
                path.stat().st_size,
                file_sha256(path) if path.stat().st_size < 1024 * 1024 * 200 else "",
                status,
                target_tables,
                notes,
                cataloged_at,
            )
        )
    conn.execute("DELETE FROM local_cal_data_files")
    conn.executemany(
        """
        INSERT INTO local_cal_data_files
            (path, file_name, file_type, size_bytes, sha256, import_status,
             target_tables, notes, cataloged_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def write_report(counts: dict[str, int], catalog_count: int) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# 数据库简体中文归一化",
        "",
        f"生成时间：{now_iso()}",
        "",
        "## 更新行数",
        "",
    ]
    for key, count in counts.items():
        lines.append(f"- {key}: {count}")
    lines.extend(
        [
            "",
            "## 本地文件清单",
            "",
            f"- local_cal_data_files: {catalog_count}",
            "",
            "## 说明",
            "",
            "- 数据库中的业务文本字段已使用 macOS Foundation/ICU 的 Hant-Hans 规则转换为简体中文。",
            "- ID、URL、图片链接和真实文件系统路径保持原样，便于继续追溯原始来源。",
            "- 非中文内容只做汉字简体归一化，不做额外机器翻译。",
            "",
        ]
    )
    path = REPORT_DIR / "simplified_chinese_normalization.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    counts: dict[str, int] = {}
    markers = hant_variant_markers()

    food_conn = sqlite3.connect(FOODS_DB)
    food_conn.execute("PRAGMA journal_mode=WAL")
    food_conn.execute("PRAGMA synchronous=NORMAL")
    record_count(
        counts,
        "foods",
        simplify_rows_with_hant_markers(
            food_conn,
            "foods",
            ["name", "serving_size", "source"],
            markers,
        ),
    )
    record_count(
        counts,
        "foods:taiwan_serving_size_normalized",
        food_conn.execute(
            "UPDATE foods SET serving_size = ? WHERE source IN (?, ?)",
            ("每100克可食部分", "台湾食品营养成分资料库 2025 UPDATE1", "台灣食品營養成分資料庫 2025 UPDATE1"),
        ).rowcount,
    )
    record_count(
        counts,
        "food_confidence",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_confidence",
            ["food_name", "source"],
            markers,
        ),
    )
    record_count(
        counts,
        "food_corrections",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_corrections",
            ["field_name", "old_value", "new_value", "note"],
            markers,
        ),
    )
    record_count(
        counts,
        "food_log_history",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_log_history",
            [
                "food_name",
                "serving_size",
                "processing_level",
                "meal_category",
                "original_nutrition_json",
                "leftover_nutrition_json",
            ],
            markers,
        ),
    )
    record_count(
        counts,
        "food_data_sources",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_data_sources",
            ["label", "license_name", "attribution"],
            markers,
        ),
    )
    record_count(
        counts,
        "food_source_records",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_source_records",
            ["raw_name", "license_name"],
            markers,
        ),
    )
    record_count(
        counts,
        "food_aliases",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_aliases",
            ["alias", "source"],
            markers,
        ),
    )
    record_count(
        counts,
        "food_glycemic_index",
        simplify_rows_with_hant_markers(
            food_conn,
            "food_glycemic_index",
            ["food_name", "food_group"],
            markers,
        ),
    )
    record_count(
        counts,
        "taiwan_food_nutrients_long",
        simplify_rows_with_hant_markers(
            food_conn,
            "taiwan_food_nutrients_long",
            [
                "food_category",
                "data_category",
                "food_name",
                "common_name",
                "english_name",
                "description",
                "nutrient_category",
                "nutrient_name",
                "unit",
                "amount_per_100g",
                "stddev",
                "amount_per_unit",
                "unit_weight",
                "amount_per_unit_weight",
            ],
            markers,
        ),
    )
    food_conn.commit()
    food_conn.close()

    recipe_conn = sqlite3.connect(RECIPES_DB)
    recipe_conn.execute("PRAGMA journal_mode=WAL")
    recipe_conn.execute("PRAGMA synchronous=NORMAL")
    record_count(
        counts,
        "recipe_data_sources",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_data_sources",
            ["label", "license_name", "attribution"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipes",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipes",
            ["title", "description", "cuisine", "category", "servings", "license_name", "attribution"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_ingredients",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_ingredients",
            ["text", "name", "quantity", "unit"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_steps",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_steps",
            ["text"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_tags",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_tags",
            ["tag"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_nutrients",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_nutrients",
            ["nutrient", "unit", "raw_value"],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_food_groups",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_food_groups",
            ["group_name", "amount_text"],
            markers,
        ),
    )
    record_count(
        counts,
        "ta_da_menu_ratings",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "ta_da_menu_ratings",
            [
                "name",
                "technique",
                "taste",
                "cook_time",
                "difficulty",
                "main_ingredients_json",
                "side_ingredients_json",
                "contraindications_json",
                "sugar_text",
                "fat_text",
                "calories_text",
            ],
            markers,
        ),
    )
    record_count(
        counts,
        "ta_da_dishes",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "ta_da_dishes",
            [
                "name",
                "technique",
                "taste",
                "cook_time",
                "difficulty",
                "main_ingredients_json",
                "side_ingredients_json",
            ],
            markers,
        ),
    )
    record_count(
        counts,
        "recipe_training_conversations",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "recipe_training_conversations",
            ["system", "user_input", "assistant_output"],
            markers,
        ),
    )
    record_count(
        counts,
        "local_cal_data_files",
        simplify_rows_with_hant_markers(
            recipe_conn,
            "local_cal_data_files",
            ["import_status", "target_tables", "notes"],
            markers,
        ),
    )
    catalog_count = catalog_local_files(recipe_conn)
    recipe_conn.commit()
    recipe_conn.close()

    report = write_report(counts, catalog_count)
    print(f"Counts: {json.dumps(counts, ensure_ascii=False)}")
    print(f"Cataloged files: {catalog_count}")
    print(f"Report: {report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
