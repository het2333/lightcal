"""Import Chinese Food Composition Table JSON data into foods.db.

The raw JSON files are expected under:
  data/raw/china-food-composition-data/json_data_vision_251206_Qwen2-5-VL-72B-Instruct

The source repository states the data was OCR / vision-model extracted from
China Food Composition Table Standard Edition (6th edition), and should be
reviewed for copyright and recognition accuracy before commercial use.
"""

from __future__ import annotations

import json
import re
import sqlite3
from collections import Counter
from pathlib import Path
from typing import Any

from collect_food_data import (
    DB_PATH,
    RAW_DIR,
    REPORT_DIR,
    ROOT,
    Source,
    ensure_schema,
    normalize_processing_level,
    register_source,
    stable_id,
    upsert_food_batch,
    write_report,
)


SOURCE = Source(
    key="china_food_composition_v6_ocr",  # gitleaks:allow -- public dataset identifier
    label="中国食物成分表标准版第6版 OCR JSON（需复核）",
    url="https://github.com/Sanotsu/china-food-composition-data",
    raw_path=RAW_DIR
    / "china-food-composition-data"
    / "json_data_vision_251206_Qwen2-5-VL-72B-Instruct",
    license_name="Copyright status requires review; original table copyright retained by authors/publisher",
    attribution="Sanotsu/china-food-composition-data; original source: 中国食物成分表标准版第6版",
)

GI_SOURCE_KEY = "china_food_gi"
GI_PATH = RAW_DIR / "china-food-composition-data" / "json_gi_of_foods" / "glycemic_index_of_foods.json"


def as_float(value: Any) -> float:
    if value is None:
        return 0.0
    text = str(value).strip()
    if not text or text in {"—", "-", "--", "…", "NA", "N/A"}:
        return 0.0
    if text.lower() in {"tr", "trace", "微量"}:
        return 0.0
    text = text.replace(",", "")
    match = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(match.group(0)) if match else 0.0


def file_category(path: Path) -> str:
    name = path.stem
    if name.startswith("merged_"):
        name = name[len("merged_") :]
    return name


def normalize_food(item: dict[str, Any], category: str, row_index: int) -> tuple[str, dict[str, Any]] | None:
    name = str(item.get("foodName") or "").strip()
    if not name:
        return None

    external_id = str(item.get("foodCode") or "").strip()
    if not external_id:
        external_id = stable_id(category, f"{row_index}:{name}")

    source_item = {
        "name": name,
        "calories": as_float(item.get("energyKCal")),
        "protein": as_float(item.get("protein")),
        "carbs": as_float(item.get("CHO")),
        "fat": as_float(item.get("fat")),
        "fiber": as_float(item.get("dietaryFiber")),
        "sugar": 0,
        "added_sugar": 0,
        "sodium": as_float(item.get("Na")),
        "cholesterol": as_float(item.get("cholesterol")),
        "vitamin_a": as_float(item.get("vitaminA")),
        "vitamin_c": as_float(item.get("vitaminC")),
        "calcium": as_float(item.get("Ca")),
        "iron": as_float(item.get("Fe")),
        "potassium": as_float(item.get("K")),
        "serving_size": "100g edible portion",
        "processing_level": normalize_processing_level(f"{category} {name}", SOURCE.key),
        "barcode": "",
    }
    return external_id, source_item


def load_food_rows() -> tuple[list[tuple[str, dict[str, Any]]], Counter[str]]:
    if not SOURCE.raw_path.exists():
        raise FileNotFoundError(f"Missing raw directory: {SOURCE.raw_path}")

    rows: list[tuple[str, dict[str, Any]]] = []
    categories: Counter[str] = Counter()
    for path in sorted(SOURCE.raw_path.glob("merged_*.json")):
        category = file_category(path)
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            continue
        for index, item in enumerate(data, start=1):
            if not isinstance(item, dict):
                continue
            parsed = normalize_food(item, category, index)
            if not parsed:
                continue
            rows.append(parsed)
            categories[category] += 1
    return rows, categories


def ensure_gi_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_glycemic_index (
            id TEXT PRIMARY KEY,
            food_name TEXT NOT NULL,
            gi REAL NOT NULL,
            food_group TEXT DEFAULT '',
            source_key TEXT NOT NULL,
            raw_index INTEGER,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_food_gi_name ON food_glycemic_index(food_name)")


def import_gi(conn: sqlite3.Connection) -> int:
    ensure_gi_schema(conn)
    if not GI_PATH.exists():
        return 0
    data = json.loads(GI_PATH.read_text(encoding="utf-8"))
    rows = []
    for group in data if isinstance(data, list) else []:
        group_name = str(group.get("foodGroup") or "").strip()
        for item in group.get("list") or []:
            name = str(item.get("foodName") or "").strip().lstrip("*").strip()
            gi = as_float(item.get("GI"))
            raw_index = int(as_float(item.get("index")))
            if not name or gi <= 0:
                continue
            rows.append(
                (
                    stable_id(GI_SOURCE_KEY, f"{raw_index}:{group_name}:{name}"),
                    name,
                    gi,
                    group_name,
                    GI_SOURCE_KEY,
                    raw_index,
                )
            )
    conn.execute("DELETE FROM food_glycemic_index WHERE source_key = ?", (GI_SOURCE_KEY,))
    conn.executemany(
        """
        INSERT INTO food_glycemic_index
            (id, food_name, gi, food_group, source_key, raw_index)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return len(rows)


def write_china_report(total_foods: int, categories: Counter[str], gi_count: int) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Chinese Food Composition Import",
        "",
        f"Source: {SOURCE.label}",
        f"Raw path: {SOURCE.raw_path.relative_to(ROOT)}",
        f"Imported foods: {total_foods}",
        f"Imported GI rows: {gi_count}",
        "",
        "## Category Counts",
        "",
    ]
    for category, count in categories.most_common():
        lines.append(f"- {category}: {count}")
    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- Values are per 100g edible portion unless the original source row implies otherwise.",
            "- Sugar and added sugar are stored as 0 because these fields are not present in the source JSON.",
            "- This source requires copyright and OCR accuracy review before commercial release.",
            "",
        ]
    )
    path = REPORT_DIR / "chinese_food_composition_import.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    rows, categories = load_food_rows()
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    imported = upsert_food_batch(conn, SOURCE, rows)
    register_source(conn, SOURCE, imported)
    gi_count = import_gi(conn)
    conn.commit()
    china_report = write_china_report(imported, categories, gi_count)
    food_report = write_report(conn)
    conn.close()
    print(f"Imported Chinese food rows: {imported}")
    print(f"Imported GI rows: {gi_count}")
    print(f"Report: {china_report.relative_to(ROOT)}")
    print(f"Food report: {food_report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
