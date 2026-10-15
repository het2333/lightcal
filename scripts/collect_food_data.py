"""Collect lawful public food nutrition data into data/foods.db.

The collector keeps raw source files under data/raw and imports normalized
nutrition rows into the app's SQLite food database. It deliberately avoids
copying private competitor databases.

Examples:
  python scripts/collect_food_data.py --import-usda
  python scripts/collect_food_data.py --collect-openfoodfacts --off-pages 3
  python scripts/collect_food_data.py --download-large --import-branded --max-branded 50000
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import sqlite3
import time
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
RAW_DIR = DATA_DIR / "raw"
REPORT_DIR = DATA_DIR / "reports"
DB_PATH = DATA_DIR / "foods.db"


@dataclass(frozen=True)
class Source:
    key: str
    label: str
    url: str
    raw_path: Path
    license_name: str
    attribution: str
    large: bool = False


SOURCES = {
    "usda_foundation": Source(
        key="usda_foundation",
        label="USDA FoodData Central Foundation Foods 2026-04-30",
        url="https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_csv_2026-04-30.zip",
        raw_path=RAW_DIR / "usda" / "FoodData_Central_foundation_food_csv_2026-04-30.zip",
        license_name="US public domain / USDA FoodData Central",
        attribution="U.S. Department of Agriculture, Agricultural Research Service. FoodData Central.",
    ),
    "usda_survey": Source(
        key="usda_survey",
        label="USDA FoodData Central Survey/FNDDS Foods 2024-10-31",
        url="https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_survey_food_json_2024-10-31.zip",
        raw_path=RAW_DIR / "usda" / "FoodData_Central_survey_food_json_2024-10-31.zip",
        license_name="US public domain / USDA FoodData Central",
        attribution="U.S. Department of Agriculture, Agricultural Research Service. FoodData Central.",
    ),
    "usda_branded": Source(
        key="usda_branded",
        label="USDA FoodData Central Branded Foods 2026-04-30",
        url="https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_csv_2026-04-30.zip",
        raw_path=RAW_DIR / "usda" / "FoodData_Central_branded_food_csv_2026-04-30.zip",
        license_name="US public domain / USDA FoodData Central",
        attribution="U.S. Department of Agriculture, Agricultural Research Service. FoodData Central.",
        large=True,
    ),
    "openfoodfacts_full": Source(
        key="openfoodfacts_full",
        label="Open Food Facts full product dump",
        url="https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz",
        raw_path=RAW_DIR / "openfoodfacts" / "en.openfoodfacts.org.products.csv.gz",
        license_name="Open Database License (ODbL)",
        attribution="Open Food Facts contributors. Product data licensed under ODbL.",
        large=True,
    ),
    "china_food_composition_v6_ocr": Source(
        key="china_food_composition_v6_ocr",  # gitleaks:allow -- public dataset identifier
        label="中国食物成分表标准版第6版 OCR JSON（需复核）",
        url="https://github.com/Sanotsu/china-food-composition-data",
        raw_path=RAW_DIR / "china-food-composition-data" / "json_data_vision_251206_Qwen2-5-VL-72B-Instruct",
        license_name="Copyright status requires review; original table copyright retained by authors/publisher",
        attribution="Sanotsu/china-food-composition-data; original source: 中国食物成分表标准版第6版",
    ),
}


NUTRIENTS = {
    "calories": {1008, 2047, 2048},
    "protein": {1003},
    "carbs": {1005},
    "fat": {1004},
    "fiber": {1079, 1006},
    "sugar": {2000},
    "sodium": {1093},
    "sat_fat": {1258},
    "trans_fat": {1257},
    "cholesterol": {1253},
    "vitamin_a": {1106},
    "vitamin_c": {1162},
    "calcium": {1087},
    "iron": {1089},
    "potassium": {1092},
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stable_id(source_key: str, external_id: str) -> str:
    digest = hashlib.sha1(f"{source_key}:{external_id}".encode("utf-8")).hexdigest()
    return digest[:12]


def as_float(value: Any, default: float = 0.0) -> float:
    if value in (None, ""):
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_int(value: Any) -> int | None:
    if value in (None, ""):
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def normalize_processing_level(name: str, source_key: str) -> str:
    lower = name.lower()
    ultra_words = [
        "soda", "cola", "chips", "candy", "cookie", "instant", "frozen meal",
        "nugget", "energy drink", "蛋糕", "薯片", "可乐", "饼干", "方便面",
    ]
    processed_words = [
        "bread", "cheese", "noodle", "pasta", "yogurt", "sausage", "ham",
        "面包", "奶酪", "酸奶", "香肠", "火腿", "饺子", "包子",
    ]
    if source_key in {"usda_branded", "openfoodfacts"}:
        return "processed"
    if any(word in lower for word in ultra_words):
        return "ultra_processed"
    if any(word in lower for word in processed_words):
        return "processed"
    return "whole"


def find_zip_member(zf: zipfile.ZipFile, suffix: str) -> str:
    for name in zf.namelist():
        if name.endswith(suffix):
            return name
    raise FileNotFoundError(f"Could not find {suffix} in {zf.filename}")


def iter_zip_csv(zip_path: Path, suffix: str) -> Iterable[dict[str, str]]:
    with zipfile.ZipFile(zip_path) as zf:
        member = find_zip_member(zf, suffix)
        with zf.open(member) as handle:
            text = (line.decode("utf-8-sig", errors="replace") for line in handle)
            yield from csv.DictReader(text)


def read_zip_json(zip_path: Path, suffix: str) -> Any:
    with zipfile.ZipFile(zip_path) as zf:
        member = find_zip_member(zf, suffix)
        with zf.open(member) as handle:
            return json.load(handle)


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_data_sources (
            key TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            url TEXT NOT NULL,
            license_name TEXT NOT NULL,
            attribution TEXT NOT NULL,
            raw_path TEXT,
            raw_sha256 TEXT,
            imported_count INTEGER DEFAULT 0,
            last_imported_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_source_records (
            source_key TEXT NOT NULL,
            external_id TEXT NOT NULL,
            food_id TEXT NOT NULL,
            raw_name TEXT NOT NULL,
            license_name TEXT NOT NULL,
            imported_at TEXT NOT NULL,
            PRIMARY KEY (source_key, external_id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_aliases (
            id TEXT PRIMARY KEY,
            food_id TEXT NOT NULL,
            alias TEXT NOT NULL,
            locale TEXT DEFAULT 'zh-CN',
            source TEXT DEFAULT 'curated',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    for col in [
        "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
        "calcium", "iron", "potassium",
    ]:
        existing = [r[1] for r in conn.execute("PRAGMA table_info(foods)").fetchall()]
        if col not in existing:
            conn.execute(f"ALTER TABLE foods ADD COLUMN {col} REAL DEFAULT 0")


def file_sha256(path: Path) -> str:
    if path.is_dir():
        h = hashlib.sha256()
        for child in sorted(p for p in path.iterdir() if p.is_file()):
            h.update(child.name.encode("utf-8"))
            h.update(str(child.stat().st_size).encode("ascii"))
        return h.hexdigest()
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def register_source(conn: sqlite3.Connection, source: Source, imported_count: int) -> None:
    sha = file_sha256(source.raw_path) if source.raw_path.exists() else ""
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
            str(source.raw_path.relative_to(ROOT)) if source.raw_path.exists() else "",
            sha,
            imported_count,
            now_iso(),
        ),
    )


def upsert_food(
    conn: sqlite3.Connection,
    source: Source,
    external_id: str,
    item: dict[str, Any],
) -> bool:
    name = str(item.get("name") or "").strip()
    if not name:
        return False
    calories = as_float(item.get("calories"))
    protein = as_float(item.get("protein"))
    carbs = as_float(item.get("carbs"))
    fat = as_float(item.get("fat"))
    if calories <= 0 and protein <= 0 and carbs <= 0 and fat <= 0:
        return False

    food_id = stable_id(source.key, external_id)
    conn.execute(
        """
        INSERT INTO foods
            (id, name, calories, protein, carbs, fat, fiber, sugar, added_sugar,
             sodium, sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
             calcium, iron, potassium, serving_size, processing_level, barcode,
             source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_DATE)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            calories = excluded.calories,
            protein = excluded.protein,
            carbs = excluded.carbs,
            fat = excluded.fat,
            fiber = excluded.fiber,
            sugar = excluded.sugar,
            added_sugar = excluded.added_sugar,
            sodium = excluded.sodium,
            sat_fat = excluded.sat_fat,
            trans_fat = excluded.trans_fat,
            cholesterol = excluded.cholesterol,
            vitamin_a = excluded.vitamin_a,
            vitamin_c = excluded.vitamin_c,
            calcium = excluded.calcium,
            iron = excluded.iron,
            potassium = excluded.potassium,
            serving_size = excluded.serving_size,
            processing_level = excluded.processing_level,
            barcode = excluded.barcode,
            source = excluded.source
        """,
        (
            food_id,
            name,
            calories,
            protein,
            carbs,
            fat,
            as_float(item.get("fiber")),
            as_float(item.get("sugar")),
            as_float(item.get("added_sugar")),
            as_float(item.get("sodium")),
            as_float(item.get("sat_fat")),
            as_float(item.get("trans_fat")),
            as_float(item.get("cholesterol")),
            as_float(item.get("vitamin_a")),
            as_float(item.get("vitamin_c")),
            as_float(item.get("calcium")),
            as_float(item.get("iron")),
            as_float(item.get("potassium")),
            item.get("serving_size") or "100g",
            item.get("processing_level") or normalize_processing_level(name, source.key),
            item.get("barcode") or "",
            source.label,
        ),
    )
    conn.execute(
        """
        INSERT INTO food_source_records
            (source_key, external_id, food_id, raw_name, license_name, imported_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_key, external_id) DO UPDATE SET
            food_id = excluded.food_id,
            raw_name = excluded.raw_name,
            license_name = excluded.license_name,
            imported_at = excluded.imported_at
        """,
        (source.key, external_id, food_id, name, source.license_name, now_iso()),
    )
    return True


def upsert_food_batch(
    conn: sqlite3.Connection,
    source: Source,
    rows: list[tuple[str, dict[str, Any]]],
) -> int:
    if not rows:
        return 0

    food_rows = []
    source_rows = []
    imported_at = now_iso()
    for external_id, item in rows:
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        calories = as_float(item.get("calories"))
        protein = as_float(item.get("protein"))
        carbs = as_float(item.get("carbs"))
        fat = as_float(item.get("fat"))
        if calories <= 0 and protein <= 0 and carbs <= 0 and fat <= 0:
            continue
        food_id = stable_id(source.key, external_id)
        food_rows.append(
            (
                food_id,
                name,
                calories,
                protein,
                carbs,
                fat,
                as_float(item.get("fiber")),
                as_float(item.get("sugar")),
                as_float(item.get("added_sugar")),
                as_float(item.get("sodium")),
                as_float(item.get("sat_fat")),
                as_float(item.get("trans_fat")),
                as_float(item.get("cholesterol")),
                as_float(item.get("vitamin_a")),
                as_float(item.get("vitamin_c")),
                as_float(item.get("calcium")),
                as_float(item.get("iron")),
                as_float(item.get("potassium")),
                item.get("serving_size") or "100g",
                item.get("processing_level") or normalize_processing_level(name, source.key),
                item.get("barcode") or "",
                source.label,
            )
        )
        source_rows.append((source.key, external_id, food_id, name, source.license_name, imported_at))

    conn.executemany(
        """
        INSERT INTO foods
            (id, name, calories, protein, carbs, fat, fiber, sugar, added_sugar,
             sodium, sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
             calcium, iron, potassium, serving_size, processing_level, barcode,
             source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_DATE)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            calories = excluded.calories,
            protein = excluded.protein,
            carbs = excluded.carbs,
            fat = excluded.fat,
            fiber = excluded.fiber,
            sugar = excluded.sugar,
            added_sugar = excluded.added_sugar,
            sodium = excluded.sodium,
            sat_fat = excluded.sat_fat,
            trans_fat = excluded.trans_fat,
            cholesterol = excluded.cholesterol,
            vitamin_a = excluded.vitamin_a,
            vitamin_c = excluded.vitamin_c,
            calcium = excluded.calcium,
            iron = excluded.iron,
            potassium = excluded.potassium,
            serving_size = excluded.serving_size,
            processing_level = excluded.processing_level,
            barcode = excluded.barcode,
            source = excluded.source
        """,
        food_rows,
    )
    conn.executemany(
        """
        INSERT INTO food_source_records
            (source_key, external_id, food_id, raw_name, license_name, imported_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_key, external_id) DO UPDATE SET
            food_id = excluded.food_id,
            raw_name = excluded.raw_name,
            license_name = excluded.license_name,
            imported_at = excluded.imported_at
        """,
        source_rows,
    )
    return len(food_rows)


def extract_nutrients_from_csv(
    zip_path: Path,
    target_ids: set[str] | None = None,
) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for row in iter_zip_csv(zip_path, "food_nutrient.csv"):
        fdc_id = row.get("fdc_id", "")
        if target_ids is not None and fdc_id not in target_ids:
            continue
        nutrient_id = as_int(row.get("nutrient_id"))
        if not fdc_id or nutrient_id is None:
            continue
        for field, ids in NUTRIENTS.items():
            if nutrient_id in ids:
                result.setdefault(fdc_id, {})
                if field == "calories" and result[fdc_id].get("calories", 0) > 0:
                    continue
                result[fdc_id][field] = as_float(row.get("amount"))
                break
    return result


def serving_sizes_from_zip(zip_path: Path) -> dict[str, str]:
    units: dict[str, str] = {}
    try:
        for row in iter_zip_csv(zip_path, "measure_unit.csv"):
            unit_id = row.get("id", "")
            name = row.get("name") or row.get("abbreviation") or ""
            if unit_id and name:
                units[unit_id] = name
    except FileNotFoundError:
        pass

    portions: dict[str, str] = {}
    try:
        for row in iter_zip_csv(zip_path, "food_portion.csv"):
            fdc_id = row.get("fdc_id", "")
            if not fdc_id or fdc_id in portions:
                continue
            grams = as_float(row.get("gram_weight"))
            amount = as_float(row.get("amount"), 1)
            unit = units.get(row.get("measure_unit_id", ""), "").strip()
            modifier = (row.get("modifier") or "").strip()
            label = modifier or f"{amount:g} {unit}".strip()
            if label and grams > 0:
                portions[fdc_id] = f"{label} ({grams:g}g)"
    except FileNotFoundError:
        pass
    return portions


def import_usda_foundation(conn: sqlite3.Connection) -> int:
    source = SOURCES["usda_foundation"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}. Download it first.")

    nutrients = extract_nutrients_from_csv(source.raw_path)
    portions = serving_sizes_from_zip(source.raw_path)
    imported = 0
    seen_names: set[str] = set()
    for row in iter_zip_csv(source.raw_path, "food.csv"):
        fdc_id = row.get("fdc_id", "")
        description = (row.get("description") or "").strip()
        data_type = row.get("data_type", "")
        if data_type != "foundation_food" or not fdc_id or fdc_id not in nutrients:
            continue
        normalized_name = description.lower()
        if normalized_name in seen_names:
            continue
        seen_names.add(normalized_name)
        item = {
            "name": description.title() if description.isupper() else description,
            **nutrients[fdc_id],
            "serving_size": portions.get(fdc_id, "100g"),
            "processing_level": normalize_processing_level(description, source.key),
        }
        if upsert_food(conn, source, fdc_id, item):
            imported += 1
    register_source(conn, source, imported)
    return imported


def nutrient_map_from_food(food: dict[str, Any]) -> dict[str, float]:
    values: dict[str, float] = {}
    for row in food.get("foodNutrients") or []:
        nutrient = row.get("nutrient") or {}
        nutrient_id = as_int(nutrient.get("id"))
        if nutrient_id is None:
            continue
        for field, ids in NUTRIENTS.items():
            if nutrient_id in ids:
                if field == "calories" and values.get("calories", 0) > 0:
                    continue
                values[field] = as_float(row.get("amount"))
                break
    return values


def serving_from_food(food: dict[str, Any]) -> str:
    for portion in food.get("foodPortions") or []:
        grams = as_float(portion.get("gramWeight"))
        desc = (portion.get("portionDescription") or "").strip()
        if grams > 0 and desc and "not specified" not in desc.lower():
            return f"{desc} ({grams:g}g)"
    return "100g"


def import_usda_survey(conn: sqlite3.Connection) -> int:
    source = SOURCES["usda_survey"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}. Download it first.")

    payload = read_zip_json(source.raw_path, "surveyDownload.json")
    imported = 0
    seen_names: set[str] = set()
    for food in payload.get("SurveyFoods", []):
        fdc_id = str(food.get("fdcId") or food.get("foodCode") or "")
        name = (food.get("description") or "").strip()
        if not fdc_id or not name:
            continue
        normalized_name = name.lower()
        if normalized_name in seen_names:
            continue
        seen_names.add(normalized_name)
        nutrients = nutrient_map_from_food(food)
        item = {
            "name": name,
            **nutrients,
            "serving_size": serving_from_food(food),
            "processing_level": normalize_processing_level(name, source.key),
        }
        if upsert_food(conn, source, fdc_id, item):
            imported += 1
    register_source(conn, source, imported)
    return imported


def import_usda_branded(conn: sqlite3.Connection, max_rows: int | None = None) -> int:
    source = SOURCES["usda_branded"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}. Download it first.")

    branded: dict[str, dict[str, str]] = {}
    target_cap = None if max_rows is None else max_rows * 3
    for row in iter_zip_csv(source.raw_path, "branded_food.csv"):
        fdc_id = row.get("fdc_id", "")
        if fdc_id:
            branded[fdc_id] = row
        if target_cap is not None and len(branded) >= target_cap:
            break

    target_ids = set(branded)
    nutrients = extract_nutrients_from_csv(source.raw_path, target_ids)

    imported = 0
    for row in iter_zip_csv(source.raw_path, "food.csv"):
        if max_rows is not None and imported >= max_rows:
            break
        fdc_id = row.get("fdc_id", "")
        description = (row.get("description") or "").strip()
        if not fdc_id or fdc_id not in branded or fdc_id not in nutrients:
            continue
        meta = branded[fdc_id]
        brand = (meta.get("brand_owner") or meta.get("brand_name") or "").strip()
        name = f"{brand} {description}".strip() if brand else description
        serving = meta.get("serving_size") or ""
        unit = meta.get("serving_size_unit") or "g"
        item = {
            "name": name,
            **nutrients[fdc_id],
            "serving_size": f"{serving}{unit}" if serving else "100g",
            "processing_level": normalize_processing_level(name, source.key),
            "barcode": meta.get("gtin_upc") or "",
        }
        if upsert_food(conn, source, fdc_id, item):
            imported += 1
        if imported and imported % 10000 == 0:
            conn.commit()
            print(f"  imported branded rows: {imported}")
    register_source(conn, source, imported)
    return imported


def import_usda_branded_streaming(conn: sqlite3.Connection, max_rows: int | None = None) -> int:
    source = SOURCES["usda_branded"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}. Download it first.")

    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")

    print("  loading branded metadata...")
    branded: dict[str, tuple[str, str, str, str]] = {}
    target_cap = None if max_rows is None else max_rows * 3
    for row in iter_zip_csv(source.raw_path, "branded_food.csv"):
        fdc_id = row.get("fdc_id", "")
        if not fdc_id:
            continue
        branded[fdc_id] = (
            (row.get("brand_owner") or row.get("brand_name") or "").strip(),
            row.get("gtin_upc") or "",
            row.get("serving_size") or "",
            row.get("serving_size_unit") or "g",
        )
        if target_cap is not None and len(branded) >= target_cap:
            break

    print(f"  metadata rows: {len(branded)}")
    print("  loading food names...")
    names: dict[str, str] = {}
    target_ids = set(branded)
    for row in iter_zip_csv(source.raw_path, "food.csv"):
        fdc_id = row.get("fdc_id", "")
        if fdc_id in target_ids:
            description = (row.get("description") or "").strip()
            if description:
                names[fdc_id] = description

    print(f"  name rows: {len(names)}")
    print("  streaming nutrients and writing foods...")

    nutrient_to_field = {
        nutrient_id: field
        for field, ids in NUTRIENTS.items()
        for nutrient_id in ids
    }
    imported = 0
    batch: list[tuple[str, dict[str, Any]]] = []

    def flush_food(fdc_id: str | None, values: dict[str, float]) -> None:
        nonlocal imported, batch
        if not fdc_id or fdc_id not in branded or fdc_id not in names:
            return
        brand, barcode, serving, unit = branded[fdc_id]
        description = names[fdc_id]
        name = f"{brand} {description}".strip() if brand else description
        item = {
            "name": name,
            **values,
            "serving_size": f"{serving}{unit}" if serving else "100g",
            "processing_level": normalize_processing_level(name, source.key),
            "barcode": barcode,
        }
        batch.append((fdc_id, item))
        if len(batch) >= 5000:
            imported += upsert_food_batch(conn, source, batch)
            batch = []
            conn.commit()
            if imported and imported % 50000 == 0:
                print(f"  imported branded rows: {imported}")

    current_id: str | None = None
    current_values: dict[str, float] = {}
    for row in iter_zip_csv(source.raw_path, "food_nutrient.csv"):
        fdc_id = row.get("fdc_id", "")
        if fdc_id not in target_ids:
            continue
        if current_id is not None and fdc_id != current_id:
            flush_food(current_id, current_values)
            if max_rows is not None and imported >= max_rows:
                break
            current_values = {}
        current_id = fdc_id
        nutrient_id = as_int(row.get("nutrient_id"))
        if nutrient_id is None:
            continue
        field = nutrient_to_field.get(nutrient_id)
        if field:
            if field == "calories" and current_values.get("calories", 0) > 0:
                continue
            current_values[field] = as_float(row.get("amount"))

    if max_rows is None or imported < max_rows:
        flush_food(current_id, current_values)
    if batch:
        imported += upsert_food_batch(conn, source, batch)
        conn.commit()

    if max_rows is not None:
        imported = min(imported, max_rows)
    register_source(conn, source, imported)
    return imported


def off_api_url(country: str, page: int, page_size: int) -> str:
    params = {
        "page": str(page),
        "page_size": str(page_size),
        "countries_tags_en": country,
        "fields": ",".join(
            [
                "code",
                "product_name",
                "product_name_zh",
                "generic_name",
                "brands",
                "quantity",
                "serving_size",
                "nutriments",
            ]
        ),
    }
    return "https://world.openfoodfacts.org/api/v2/search?" + urllib.parse.urlencode(params)


def off_item(product: dict[str, Any]) -> dict[str, Any] | None:
    nutriments = product.get("nutriments") or {}
    name = (
        product.get("product_name_zh")
        or product.get("product_name")
        or product.get("generic_name")
        or ""
    ).strip()
    if not name:
        return None
    return {
        "name": name,
        "calories": as_float(nutriments.get("energy-kcal_100g")),
        "protein": as_float(nutriments.get("proteins_100g")),
        "carbs": as_float(nutriments.get("carbohydrates_100g")),
        "fat": as_float(nutriments.get("fat_100g")),
        "fiber": as_float(nutriments.get("fiber_100g")),
        "sugar": as_float(nutriments.get("sugars_100g")),
        "sodium": as_float(nutriments.get("sodium_100g")) * 1000,
        "sat_fat": as_float(nutriments.get("saturated-fat_100g")),
        "serving_size": product.get("serving_size") or product.get("quantity") or "100g",
        "barcode": product.get("code") or "",
        "processing_level": "processed",
    }


def off_row_item(row: dict[str, str]) -> tuple[str, dict[str, Any]] | None:
    code = (row.get("code") or "").strip()
    name = (
        row.get("product_name")
        or row.get("generic_name")
        or row.get("abbreviated_product_name")
        or ""
    ).strip()
    if not code or not name:
        return None
    item = {
        "name": name,
        "calories": as_float(row.get("energy-kcal_100g")),
        "protein": as_float(row.get("proteins_100g")),
        "carbs": as_float(row.get("carbohydrates_100g")),
        "fat": as_float(row.get("fat_100g")),
        "fiber": as_float(row.get("fiber_100g")),
        "sugar": as_float(row.get("sugars_100g")),
        "sodium": as_float(row.get("sodium_100g")) * 1000,
        "sat_fat": as_float(row.get("saturated-fat_100g")),
        "trans_fat": as_float(row.get("trans-fat_100g")),
        "cholesterol": as_float(row.get("cholesterol_100g")) * 1000,
        "serving_size": row.get("serving_size") or row.get("quantity") or "100g",
        "barcode": code,
        "processing_level": "processed",
    }
    return code, item


def import_openfoodfacts_full(conn: sqlite3.Connection, max_rows: int | None = None) -> int:
    source = SOURCES["openfoodfacts_full"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}. Download it first.")

    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    csv.field_size_limit(1024 * 1024 * 64)

    imported = 0
    batch: list[tuple[str, dict[str, Any]]] = []
    with gzip.open(source.raw_path, "rt", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            parsed = off_row_item(row)
            if not parsed:
                continue
            batch.append(parsed)
            if len(batch) >= 5000:
                imported += upsert_food_batch(conn, source, batch)
                batch = []
                conn.commit()
                if imported and imported % 50000 == 0:
                    print(f"  imported Open Food Facts rows: {imported}")
                if max_rows is not None and imported >= max_rows:
                    break
    if batch and (max_rows is None or imported < max_rows):
        imported += upsert_food_batch(conn, source, batch)
        conn.commit()
    if max_rows is not None:
        imported = min(imported, max_rows)
    register_source(conn, source, imported)
    return imported


def collect_openfoodfacts_api(
    conn: sqlite3.Connection,
    country: str,
    pages: int,
    page_size: int,
) -> int:
    source = Source(
        key="openfoodfacts",
        label=f"Open Food Facts API country={country}",
        url="https://world.openfoodfacts.org/cgi/search.pl",
        raw_path=RAW_DIR / "openfoodfacts" / f"{country}_api_products.jsonl",
        license_name="Open Database License (ODbL)",
        attribution="Open Food Facts contributors. Product data licensed under ODbL.",
    )
    source.raw_path.parent.mkdir(parents=True, exist_ok=True)
    imported = 0
    with source.raw_path.open("a", encoding="utf-8") as raw:
        for page in range(1, pages + 1):
            url = off_api_url(country, page, page_size)
            print(f"  fetching Open Food Facts {country} page {page}/{pages}")
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "QingKaFoodDataCollector/0.1 contact=local"},
            )
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = json.loads(response.read().decode("utf-8"))
            products = payload.get("products") or []
            if not products:
                break
            for product in products:
                raw.write(json.dumps(product, ensure_ascii=False) + "\n")
                code = str(product.get("code") or "")
                item = off_item(product)
                if code and item and upsert_food(conn, source, code, item):
                    imported += 1
            conn.commit()
            time.sleep(1)
    register_source(conn, source, imported)
    return imported


def import_openfoodfacts_pages(conn: sqlite3.Connection, country: str) -> int:
    source = Source(
        key="openfoodfacts",
        label=f"Open Food Facts API country={country}",
        url="https://world.openfoodfacts.org/cgi/search.pl",
        raw_path=RAW_DIR / "openfoodfacts" / "off_api_pages",
        license_name="Open Database License (ODbL)",
        attribution="Open Food Facts contributors. Product data licensed under ODbL.",
    )
    pages_dir = source.raw_path
    if not pages_dir.exists():
        raise FileNotFoundError(f"Missing {pages_dir}. Fetch API pages first.")

    imported = 0
    for page_path in sorted(pages_dir.glob(f"{country}_page_*.json")):
        text = page_path.read_text(encoding="utf-8")
        if not text.lstrip().startswith("{"):
            print(f"  skip non-json Open Food Facts page: {page_path.name}")
            continue
        payload = json.loads(text)
        for product in payload.get("products") or []:
            code = str(product.get("code") or "")
            item = off_item(product)
            if code and item and upsert_food(conn, source, code, item):
                imported += 1
        conn.commit()
    register_source(conn, source, imported)
    return imported


def download_source(source: Source) -> None:
    source.raw_path.parent.mkdir(parents=True, exist_ok=True)
    if source.raw_path.exists() and source.raw_path.stat().st_size > 0:
        print(f"  exists: {source.raw_path.relative_to(ROOT)}")
        return
    print(f"  download: {source.label}")
    with urllib.request.urlopen(source.url, timeout=120) as response:
        with source.raw_path.open("wb") as handle:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)


def write_manifest() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "generated_at": now_iso(),
        "note": "Only public/licensed food data sources are listed. Competitor private databases are excluded.",
        "sources": [
            {
                "key": source.key,
                "label": source.label,
                "url": source.url,
                "license": source.license_name,
                "attribution": source.attribution,
                "raw_path": str(source.raw_path.relative_to(ROOT)),
                "large": source.large,
            }
            for source in SOURCES.values()
        ],
    }
    (DATA_DIR / "food_data_sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def write_report(conn: sqlite3.Connection) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    rows = conn.execute(
        "SELECT key, label, license_name, imported_count, raw_path, last_imported_at FROM food_data_sources ORDER BY key"
    ).fetchall()
    source_counts = conn.execute(
        "SELECT source, COUNT(*) AS count FROM foods GROUP BY source ORDER BY count DESC"
    ).fetchall()
    total = conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    report = [
        "# Food Data Collection Report",
        "",
        f"Generated: {now_iso()}",
        f"Total foods in foods.db: {total}",
        "",
        "## Imported Public Sources",
        "",
        "| Source | License | Imported | Raw file |",
        "| --- | --- | ---: | --- |",
    ]
    for row in rows:
        report.append(
            f"| {row['label']} | {row['license_name']} | {row['imported_count']} | {row['raw_path']} |"
        )
    report.extend(["", "## Database Counts By Source", ""])
    for row in source_counts:
        report.append(f"- {row['source']}: {row['count']}")
    report.extend(["", "## Registered But Not Fully Imported", ""])
    imported_keys = {row["key"] for row in rows}
    for source in SOURCES.values():
        if source.key in imported_keys:
            continue
        partials = sorted(source.raw_path.parent.glob(source.raw_path.name + ".partial*"))
        if source.raw_path.exists():
            status = f"raw downloaded at {source.raw_path.relative_to(ROOT)}"
        elif partials:
            names = ", ".join(str(p.relative_to(ROOT)) for p in partials)
            status = f"partial/incomplete files: {names}"
        else:
            status = "not downloaded"
        report.append(f"- {source.label}: {status}")
    report.append("")
    path = REPORT_DIR / "food_data_collection.md"
    path.write_text("\n".join(report), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--download-small", action="store_true", help="Download small USDA datasets.")
    parser.add_argument("--download-large", action="store_true", help="Download large USDA/OpenFoodFacts dumps.")
    parser.add_argument("--import-usda", action="store_true", help="Import USDA Foundation and Survey datasets.")
    parser.add_argument("--import-branded", action="store_true", help="Import USDA branded foods if downloaded.")
    parser.add_argument("--stream-branded", action="store_true", help="Use streaming importer for USDA branded foods.")
    parser.add_argument("--max-branded", type=int, default=50000, help="Limit branded import; use -1 for all.")
    parser.add_argument("--collect-openfoodfacts", action="store_true", help="Collect Open Food Facts via API.")
    parser.add_argument("--import-openfoodfacts-pages", action="store_true", help="Import downloaded Open Food Facts API pages.")
    parser.add_argument("--import-openfoodfacts-full", action="store_true", help="Import Open Food Facts full TSV gzip dump.")
    parser.add_argument("--max-openfoodfacts", type=int, default=-1, help="Limit Open Food Facts full import; -1 for all.")
    parser.add_argument("--off-country", default="china", help="Open Food Facts country tag, e.g. china.")
    parser.add_argument("--off-pages", type=int, default=5)
    parser.add_argument("--off-page-size", type=int, default=1000)
    args = parser.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    write_manifest()

    if args.download_small:
        download_source(SOURCES["usda_foundation"])
        download_source(SOURCES["usda_survey"])
    if args.download_large:
        download_source(SOURCES["usda_branded"])
        print("  Open Food Facts full dump is registered in data/food_data_sources.json.")
        print("  It is very large; use curl -L -C - if you decide to store the full dump locally.")

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)

    if args.import_usda:
        print("Importing USDA Foundation...")
        print(f"  imported: {import_usda_foundation(conn)}")
        conn.commit()
        print("Importing USDA Survey/FNDDS...")
        print(f"  imported: {import_usda_survey(conn)}")
        conn.commit()
    if args.import_branded:
        limit = None if args.max_branded < 0 else args.max_branded
        print("Importing USDA Branded...")
        importer = import_usda_branded_streaming if args.stream_branded else import_usda_branded
        print(f"  imported: {importer(conn, limit)}")
        conn.commit()
    if args.collect_openfoodfacts:
        print("Collecting Open Food Facts API...")
        print(
            f"  imported: {collect_openfoodfacts_api(conn, args.off_country, args.off_pages, args.off_page_size)}"
        )
        conn.commit()
    if args.import_openfoodfacts_pages:
        print("Importing downloaded Open Food Facts API pages...")
        print(f"  imported: {import_openfoodfacts_pages(conn, args.off_country)}")
        conn.commit()
    if args.import_openfoodfacts_full:
        limit = None if args.max_openfoodfacts < 0 else args.max_openfoodfacts
        print("Importing Open Food Facts full dump...")
        print(f"  imported: {import_openfoodfacts_full(conn, limit)}")
        conn.commit()

    report_path = write_report(conn)
    conn.close()
    print(f"Report: {report_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
