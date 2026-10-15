"""Food database service — SQLite-backed nutrition reference.

Mirrors Cal AI's /v6/foodDatabase with Harvard nutrition guidelines.
Includes barcode lookup, text search, and CRUD operations.
"""

import json
import re
import sqlite3
from datetime import date
from pathlib import Path
from typing import Any, Optional

from models.food import Food, ProcessingLevel

DATA_DIR = Path(__file__).parent.parent / "data"
DB_PATH = DATA_DIR / "foods.db"
RECIPES_DB_PATH = DATA_DIR / "recipes.db"
SEED_PATH = DATA_DIR / "harvard_foods.json"
NUTRIENT_FIELDS = [
    "calories", "protein", "carbs", "fat", "fiber", "sugar", "added_sugar",
    "sodium", "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
    "calcium", "iron", "potassium", "magnesium", "zinc", "folate", "vitamin_d",
    "vitamin_b12", "vitamin_e", "vitamin_k", "omega_3", "monounsaturated_fat",
    "polyunsaturated_fat",
]

FRESH_PRODUCE_RE = re.compile(
    r"菜|蔬|甘蓝|芹|西芹|青椒|彩椒|甜椒|辣椒|胡萝卜|萝卜|番茄|圣女果|黄瓜|苦瓜|蘑菇|香菇|菌|西兰花|花菜|生菜|韭葱|洋葱|芽菜|小白菜|菠菜|莴笋|南瓜|冬瓜|丝瓜|茄子"
)
DRY_OR_CONDENSED_RE = re.compile(r"干|脱水|粉|香辛料|调味料|茶|片剂|浓缩|酱|油|薯片|脆片|饼干|膨化")
PREP_SUFFIX_RE = re.compile(r"(切)?(片|丝|丁|块|条|段|粒|末|碎|圈|瓣)$")

LOCALIZED_FOOD_NAMES: dict[str, str] = {
    "Apple, raw, medium": "苹果",
    "Chicken breast, grilled, skinless": "烤鸡胸肉",
    "White rice, cooked": "熟白米饭",
    "Brown rice, cooked": "熟糙米饭",
    "Broccoli, steamed": "蒸西兰花",
    "Salmon, Atlantic, cooked": "熟三文鱼",
    "Egg, whole, large, boiled": "水煮鸡蛋",
    "Banana, raw, medium": "香蕉",
    "Olive oil, extra virgin": "特级初榨橄榄油",
    "Greek yogurt, plain, nonfat": "原味脱脂希腊酸奶",
    "Coca-Cola, original": "可口可乐",
    "Potato chips, plain, salted": "原味盐薯片",
    "Mixed green salad, no dressing": "混合蔬菜沙拉（无酱）",
    "Beef steak, sirloin, grilled": "烤西冷牛排",
    "Whole wheat bread, slice": "全麦面包片",
    "Instant ramen noodles, cooked": "方便面",
    "Orange juice, fresh squeezed": "鲜榨橙汁",
    "Pizza, cheese, regular crust": "芝士披萨",
    "Tofu, firm, raw": "北豆腐",
    "Almonds, raw": "生杏仁",
}

LOCALIZED_SERVING_SIZES: dict[str, str] = {
    "1 medium (182g)": "1 个中等大小（182克）",
    "100g": "100克",
    "1 large (50g)": "1 个大号（50克）",
    "1 tbsp (13.5g)": "1 汤匙（13.5克）",
    "100ml": "100毫升",
    "1 slice (32g)": "1 片（32克）",
    "100g dry": "干重 100克",
    "1 slice (100g)": "1 片（100克）",
}

LOCALIZED_FOOD_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"apple\s+juice", re.IGNORECASE), "苹果汁"),
    (re.compile(r"\bapples?\b", re.IGNORECASE), "苹果"),
    (re.compile(r"peanut\s+butter", re.IGNORECASE), "花生酱"),
    (re.compile(r"chicken.*salad", re.IGNORECASE), "鸡肉沙拉"),
    (re.compile(r"chicken\s+breast", re.IGNORECASE), "鸡胸肉"),
    (re.compile(r"\bbanana", re.IGNORECASE), "香蕉"),
    (re.compile(r"greek\s+yogurt|yogurt", re.IGNORECASE), "酸奶"),
    (re.compile(r"brown\s+rice", re.IGNORECASE), "糙米饭"),
    (re.compile(r"white\s+rice|\brice\b", re.IGNORECASE), "米饭"),
    (re.compile(r"broccoli", re.IGNORECASE), "西兰花"),
    (re.compile(r"salmon", re.IGNORECASE), "三文鱼"),
    (re.compile(r"\begg", re.IGNORECASE), "鸡蛋"),
    (re.compile(r"olive\s+oil", re.IGNORECASE), "橄榄油"),
    (re.compile(r"potato\s+chips|chips", re.IGNORECASE), "薯片"),
    (re.compile(r"green\s+salad|salad", re.IGNORECASE), "蔬菜沙拉"),
    (re.compile(r"beef|steak", re.IGNORECASE), "牛排"),
    (re.compile(r"whole\s+wheat\s+bread|bread", re.IGNORECASE), "全麦面包"),
    (re.compile(r"ramen|instant\s+noodles?", re.IGNORECASE), "方便面"),
    (re.compile(r"orange\s+juice", re.IGNORECASE), "橙汁"),
    (re.compile(r"pizza", re.IGNORECASE), "披萨"),
    (re.compile(r"tofu", re.IGNORECASE), "豆腐"),
    (re.compile(r"almonds?", re.IGNORECASE), "杏仁"),
    (re.compile(r"coca|cola|coke", re.IGNORECASE), "可乐"),
]


def _normalize_lookup_text(value: str) -> str:
    return re.sub(r"\s+", " ", (value or "").strip().lower())


def _strip_prep_suffix(value: str) -> str:
    text = (value or "").strip()
    if len(text) <= 2:
        return text
    stripped = PREP_SUFFIX_RE.sub("", text).strip()
    return stripped if len(stripped) >= 2 else text


def _canonical_food_name(value: str) -> str:
    text = re.sub(r"[（(].*?[）)]", "", value or "").strip()
    text = _strip_prep_suffix(text)
    if text in {"西洋芹菜", "西芹", "美芹"}:
        return "芹菜"
    if text in {"圣女果", "小番茄"}:
        return "番茄"
    if text in {"布鲁塞尔芽菜", "抱子甘蓝", "小圆白菜"}:
        return "抱子甘蓝"
    return text


def _looks_like_fresh_produce(text: str) -> bool:
    value = text or ""
    return bool(FRESH_PRODUCE_RE.search(value)) and not bool(DRY_OR_CONDENSED_RE.search(value))


def _nutrition_quality(query: str, row_name: str, nutrition: dict[str, float]) -> tuple[float, str, list[str]]:
    calories = float(nutrition.get("calories", 0) or 0)
    protein = float(nutrition.get("protein", 0) or 0)
    carbs = float(nutrition.get("carbs", 0) or 0)
    fat = float(nutrition.get("fat", 0) or 0)
    fiber = float(nutrition.get("fiber", 0) or 0)
    sodium = float(nutrition.get("sodium", 0) or 0)
    notes: list[str] = []
    score = 1.0

    if calories <= 0 or calories > 950:
        notes.append("热量缺失或超过常见每100克上限")
        score -= 0.7
    if min(protein, carbs, fat, fiber, sodium) < 0:
        notes.append("存在负营养值")
        score -= 0.8
    if protein > 100 or carbs > 100 or fat > 100 or fiber > 80:
        notes.append("宏量营养超过每100克合理范围")
        score -= 0.6
    macro_energy = protein * 4 + carbs * 4 + fat * 9
    if calories > 15 and macro_energy > 15:
        ratio = calories / macro_energy
        if ratio < 0.35 or ratio > 2.8:
            notes.append("热量和宏量营养不一致")
            score -= 0.25

    query_is_fresh = _looks_like_fresh_produce(_canonical_food_name(query))
    row_is_dry = bool(DRY_OR_CONDENSED_RE.search(row_name or ""))
    row_is_fresh = _looks_like_fresh_produce(row_name)
    if query_is_fresh and (row_is_fresh or not row_is_dry):
        if calories > 120:
            notes.append("新鲜蔬菜热量异常偏高")
            score -= 0.85
        if protein > 12 or carbs > 30 or fat > 8:
            notes.append("新鲜蔬菜宏量营养异常偏高")
            score -= 0.55
    if query_is_fresh and row_is_dry:
        notes.append("疑似干制/调味/浓缩食品，不适合新鲜食材估算")
        score -= 0.65

    if score >= 0.85:
        status = "ok"
    elif score >= 0.55:
        status = "review"
    else:
        status = "reject"
    return max(0.0, round(score, 3)), status, notes


def _lookup_terms(query: str) -> list[str]:
    query = (query or "").strip()
    terms = [query]
    normalized = query.lower()
    if normalized:
        for raw_name, localized_name in LOCALIZED_FOOD_NAMES.items():
            if normalized in raw_name.lower() or normalized in localized_name.lower():
                terms.extend([raw_name, localized_name])
    cleaned = re.sub(r"[（(].*?[）)]", "", query).strip()
    if cleaned and cleaned != query:
        terms.append(cleaned)
    stripped = _strip_prep_suffix(cleaned or query)
    if stripped and stripped != query:
        terms.append(stripped)
    canonical = _canonical_food_name(query)
    if canonical and canonical != query:
        terms.append(canonical)
    if "芹菜" in query:
        terms.extend(["芹菜", "西芹", "西洋芹菜"])
    if "青椒" in query or "甜椒" in query or "彩椒" in query:
        terms.extend(["青椒", "甜椒", "彩椒"])
    if "圣女果" in query or "小番茄" in query:
        terms.extend(["圣女果", "小番茄", "番茄"])
    return list(dict.fromkeys([term for term in terms if term]))


def _display_food_name(name: str, name_zh: str = "") -> str:
    if name_zh and name_zh.strip():
        return name_zh.strip()
    if name in LOCALIZED_FOOD_NAMES:
        return LOCALIZED_FOOD_NAMES[name]
    for pattern, localized_name in LOCALIZED_FOOD_PATTERNS:
        if pattern.search(name):
            return localized_name
    return name


def _display_serving_size(serving_size: str) -> str:
    if not serving_size:
        return "100克"
    if serving_size in LOCALIZED_SERVING_SIZES:
        return LOCALIZED_SERVING_SIZES[serving_size]
    return (
        serving_size
        .replace("Guideline amount per slice of bread/roll", "每片面包建议量")
        .replace("Guideline amount per sandwich", "每份三明治建议量")
        .replace("tablespoon", "汤匙")
        .replace("tbsp", "汤匙")
        .replace("sandwich", "三明治")
        .replace("slice of bread/roll", "片面包")
        .replace("edible portion", "可食部")
        .replace("portion", "份")
        .replace("g", "克")
        .replace("ml", "毫升")
    )


# ── Seed data ──────────────────────────────────────────────────────

SEED_FOODS: list[dict] = [
    {
        "name": "Apple, raw, medium",
        "calories": 95, "protein": 0.5, "carbs": 25, "fat": 0.3,
        "fiber": 4.4, "sugar": 19, "added_sugar": 0, "sodium": 2,
        "serving_size": "1 medium (182g)",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Chicken breast, grilled, skinless",
        "calories": 165, "protein": 31, "carbs": 0, "fat": 3.6,
        "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 74,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "White rice, cooked",
        "calories": 130, "protein": 2.7, "carbs": 28, "fat": 0.3,
        "fiber": 0.4, "sugar": 0.1, "added_sugar": 0, "sodium": 1,
        "serving_size": "100g",
        "processing_level": "minimally_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Brown rice, cooked",
        "calories": 123, "protein": 2.7, "carbs": 26, "fat": 1,
        "fiber": 1.6, "sugar": 0.4, "added_sugar": 0, "sodium": 4,
        "serving_size": "100g",
        "processing_level": "minimally_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Broccoli, steamed",
        "calories": 35, "protein": 2.4, "carbs": 7, "fat": 0.4,
        "fiber": 3.3, "sugar": 1.4, "added_sugar": 0, "sodium": 41,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Salmon, Atlantic, cooked",
        "calories": 208, "protein": 20, "carbs": 0, "fat": 13,
        "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 59,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Egg, whole, large, boiled",
        "calories": 78, "protein": 6.3, "carbs": 0.6, "fat": 5.3,
        "fiber": 0, "sugar": 0.6, "added_sugar": 0, "sodium": 62,
        "serving_size": "1 large (50g)",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Banana, raw, medium",
        "calories": 105, "protein": 1.3, "carbs": 27, "fat": 0.4,
        "fiber": 3.1, "sugar": 14, "added_sugar": 0, "sodium": 1,
        "serving_size": "1 medium (118g)",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Olive oil, extra virgin",
        "calories": 119, "protein": 0, "carbs": 0, "fat": 13.5,
        "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 0,
        "serving_size": "1 tbsp (13.5g)",
        "processing_level": "minimally_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Greek yogurt, plain, nonfat",
        "calories": 59, "protein": 10, "carbs": 3.6, "fat": 0.4,
        "fiber": 0, "sugar": 3.2, "added_sugar": 0, "sodium": 36,
        "serving_size": "100g",
        "processing_level": "minimally_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Coca-Cola, original",
        "calories": 42, "protein": 0, "carbs": 10.6, "fat": 0,
        "fiber": 0, "sugar": 10.6, "added_sugar": 10.6, "sodium": 4,
        "serving_size": "100ml",
        "processing_level": "ultra_processed",
        "barcode": "049000000443",
        "source": "USDA",
    },
    {
        "name": "Potato chips, plain, salted",
        "calories": 536, "protein": 7, "carbs": 53, "fat": 35,
        "fiber": 4.5, "sugar": 0.3, "added_sugar": 0, "sodium": 525,
        "serving_size": "100g",
        "processing_level": "ultra_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Mixed green salad, no dressing",
        "calories": 15, "protein": 1.5, "carbs": 2.8, "fat": 0.2,
        "fiber": 2, "sugar": 1, "added_sugar": 0, "sodium": 25,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Beef steak, sirloin, grilled",
        "calories": 206, "protein": 26, "carbs": 0, "fat": 11,
        "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 54,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Whole wheat bread, slice",
        "calories": 81, "protein": 4, "carbs": 14, "fat": 1.1,
        "fiber": 2, "sugar": 1.4, "added_sugar": 1.4, "sodium": 146,
        "serving_size": "1 slice (32g)",
        "processing_level": "processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Instant ramen noodles, cooked",
        "calories": 437, "protein": 10, "carbs": 60, "fat": 17,
        "fiber": 2.4, "sugar": 1.6, "added_sugar": 0, "sodium": 1855,
        "serving_size": "100g dry",
        "processing_level": "ultra_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Orange juice, fresh squeezed",
        "calories": 45, "protein": 0.7, "carbs": 10.4, "fat": 0.2,
        "fiber": 0.2, "sugar": 8.4, "added_sugar": 0, "sodium": 1,
        "serving_size": "100ml",
        "processing_level": "minimally_processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Pizza, cheese, regular crust",
        "calories": 266, "protein": 11, "carbs": 33, "fat": 10,
        "fiber": 2, "sugar": 3.6, "added_sugar": 1.1, "sodium": 598,
        "serving_size": "1 slice (100g)",
        "processing_level": "processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Tofu, firm, raw",
        "calories": 76, "protein": 8, "carbs": 1.9, "fat": 4.8,
        "fiber": 0.3, "sugar": 0.7, "added_sugar": 0, "sodium": 7,
        "serving_size": "100g",
        "processing_level": "processed",
        "barcode": "",
        "source": "USDA / Harvard",
    },
    {
        "name": "Almonds, raw",
        "calories": 579, "protein": 21, "carbs": 22, "fat": 50,
        "fiber": 12.5, "sugar": 4.4, "added_sugar": 0, "sodium": 1,
        "serving_size": "100g",
        "processing_level": "whole",
        "barcode": "",
        "source": "USDA / Harvard",
    },
]


class FoodDatabase:
    """SQLite food database with Cal AI-style feedback flywheel."""

    def __init__(self, db_path: Path | None = None):
        self.db_path = db_path or DB_PATH
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    @staticmethod
    def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
        row = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            (table,),
        ).fetchone()
        return bool(row)

    @staticmethod
    def _column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
        return any(row[1] == column for row in conn.execute(f"PRAGMA table_info({table})").fetchall())

    def _reference_food_table(self, conn: sqlite3.Connection) -> str:
        if self._table_exists(conn, "foods_corrected_clean"):
            return "foods_corrected_clean"
        if self._table_exists(conn, "foods_verified_clean"):
            return "foods_verified_clean"
        if self._table_exists(conn, "foods_merged_clean"):
            return "foods_merged_clean"
        if self._table_exists(conn, "foods_clean"):
            return "foods_clean"
        return "foods"

    def _indexed_exact_food_rows(
        self,
        conn: sqlite3.Connection,
        table: str,
        terms: list[str],
        limit: int,
    ) -> list[sqlite3.Row]:
        rows: list[sqlite3.Row] = []
        has_normalized_name = self._column_exists(conn, table, "normalized_name")
        has_name_zh = self._column_exists(conn, table, "name_zh")
        for term in terms:
            if has_normalized_name:
                zh_clause = " OR name_zh = ?" if has_name_zh else ""
                params: tuple[Any, ...]
                params = (term, term, limit * 10) if has_name_zh else (term, limit * 10)
                row_batch = conn.execute(
                    f"""
                    SELECT *
                    FROM {table}
                    WHERE normalized_name = lower(trim(?)){zh_clause}
                    ORDER BY length(name)
                    LIMIT ?
                    """,
                    params,
                ).fetchall()
            else:
                zh_clause = " OR name_zh = ?" if has_name_zh else ""
                params = (term, term, limit * 10) if has_name_zh else (term, limit * 10)
                row_batch = conn.execute(
                    f"""
                    SELECT *
                    FROM {table}
                    WHERE lower(trim(name)) = lower(trim(?)){zh_clause}
                    ORDER BY length(name)
                    LIMIT ?
                    """,
                    params,
                ).fetchall()
            rows.extend(row_batch)
            if len(rows) >= limit:
                break
        if rows:
            return rows

        for term in terms:
            if has_normalized_name:
                zh_clause = " OR name_zh LIKE ? || '%'" if has_name_zh else ""
                params = (term, term, limit * 10) if has_name_zh else (term, limit * 10)
                row_batch = conn.execute(
                    f"""
                    SELECT *
                    FROM {table}
                    WHERE normalized_name LIKE lower(trim(?)) || '%'{zh_clause}
                    ORDER BY length(name)
                    LIMIT ?
                    """,
                    params,
                ).fetchall()
            else:
                zh_clause = " OR name_zh LIKE ? || '%'" if has_name_zh else ""
                params = (term, term, limit * 10) if has_name_zh else (term, limit * 10)
                row_batch = conn.execute(
                    f"""
                    SELECT *
                    FROM {table}
                    WHERE name LIKE ? || '%'{zh_clause}
                    ORDER BY length(name)
                    LIMIT ?
                    """,
                    params,
                ).fetchall()
            rows.extend(row_batch)
            if len(rows) >= limit:
                break
        return rows

    def _init_db(self):
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS foods (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    calories REAL,
                    protein REAL,
                    carbs REAL,
                    fat REAL,
                    fiber REAL,
                    sugar REAL,
                    added_sugar REAL DEFAULT 0,
                    sodium REAL,
                    sat_fat REAL DEFAULT 0,
                    trans_fat REAL DEFAULT 0,
                    cholesterol REAL DEFAULT 0,
                    vitamin_a REAL DEFAULT 0,
                    vitamin_c REAL DEFAULT 0,
                    calcium REAL DEFAULT 0,
                    iron REAL DEFAULT 0,
                    potassium REAL DEFAULT 0,
                    magnesium REAL DEFAULT 0,
                    zinc REAL DEFAULT 0,
                    folate REAL DEFAULT 0,
                    vitamin_d REAL DEFAULT 0,
                    vitamin_b12 REAL DEFAULT 0,
                    vitamin_e REAL DEFAULT 0,
                    vitamin_k REAL DEFAULT 0,
                    omega_3 REAL DEFAULT 0,
                    monounsaturated_fat REAL DEFAULT 0,
                    polyunsaturated_fat REAL DEFAULT 0,
                    serving_size TEXT DEFAULT '100g',
                    grams_per_unit REAL DEFAULT 100,
                    processing_level TEXT DEFAULT 'whole',
                    barcode TEXT DEFAULT '',
                    source TEXT DEFAULT 'user',
                    created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            # Confidence tracking table (Cal AI flywheel)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS food_confidence (
                    food_id TEXT PRIMARY KEY,
                    food_name TEXT NOT NULL,
                    accurate_votes INTEGER DEFAULT 0,
                    inaccurate_votes INTEGER DEFAULT 0,
                    fix_count INTEGER DEFAULT 0,
                    report_count INTEGER DEFAULT 0,
                    last_updated TEXT DEFAULT CURRENT_TIMESTAMP,
                    source TEXT DEFAULT 'gemini',
                    FOREIGN KEY (food_id) REFERENCES foods(id)
                )
            """)
            # Correction log for audit trail
            conn.execute("""
                CREATE TABLE IF NOT EXISTS food_corrections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    food_id TEXT NOT NULL,
                    field_name TEXT NOT NULL,
                    old_value TEXT,
                    new_value TEXT,
                    note TEXT DEFAULT '',
                    corrected_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_foods_name ON foods(name)
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_foods_barcode ON foods(barcode)
            """)
            cols = [r[1] for r in conn.execute("PRAGMA table_info(foods)").fetchall()]
            for col in NUTRIENT_FIELDS:
                if col not in cols:
                    conn.execute(f"ALTER TABLE foods ADD COLUMN {col} REAL DEFAULT 0")
            if "grams_per_unit" not in cols:
                conn.execute("ALTER TABLE foods ADD COLUMN grams_per_unit REAL DEFAULT 100")
            if "barcode" not in cols:
                conn.execute("ALTER TABLE foods ADD COLUMN barcode TEXT DEFAULT ''")
            if "source" not in cols:
                conn.execute("ALTER TABLE foods ADD COLUMN source TEXT DEFAULT 'user'")

            # Seed with Harvard data if empty
            count = conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
            if count == 0:
                self._seed(conn)

    def _seed(self, conn: sqlite3.Connection):
        import uuid
        today = date.today().isoformat()
        for f in SEED_FOODS:
            food_id = uuid.uuid4().hex[:12]
            conn.execute(
                """INSERT INTO foods
                   (id, name, calories, protein, carbs, fat, fiber, sugar,
                    added_sugar, sodium, sat_fat, trans_fat, cholesterol,
                    vitamin_a, vitamin_c, calcium, iron, potassium,
                    serving_size, processing_level, barcode, source, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    food_id, f["name"], f["calories"], f["protein"],
                    f["carbs"], f["fat"], f["fiber"], f["sugar"],
                    f.get("added_sugar", 0), f["sodium"], f.get("sat_fat", 0),
                    f.get("trans_fat", 0), f.get("cholesterol", 0),
                    f.get("vitamin_a", 0), f.get("vitamin_c", 0),
                    f.get("calcium", 0), f.get("iron", 0), f.get("potassium", 0),
                    f["serving_size"], f["processing_level"],
                    f.get("barcode", ""), f["source"], today,
                ),
            )
        conn.commit()

    async def search(self, query: str, limit: int = 10) -> list[Food]:
        """Search foods by name."""
        normalized = query.strip().lower()
        terms = [query]
        if normalized:
            for raw_name, localized_name in LOCALIZED_FOOD_NAMES.items():
                if normalized in raw_name.lower() or normalized in localized_name.lower():
                    terms.append(raw_name)
                    terms.append(localized_name)
        terms = list(dict.fromkeys([term for term in terms if term]))
        if not terms:
            return []
        where = " OR ".join(["name LIKE ?"] * len(terms))
        params = [f"%{term}%" for term in terms]
        with self._get_conn() as conn:
            table = self._reference_food_table(conn)
            columns = ["name"]
            if self._column_exists(conn, table, "name_zh"):
                columns.append("name_zh")
            where = " OR ".join([f"{column} LIKE ?" for column in columns for _ in terms])
            params = [f"%{term}%" for column in columns for term in terms]
            rows = conn.execute(
                f"SELECT * FROM {table} WHERE {where} LIMIT ?",
                (*params, max(limit * 4, limit)),
            ).fetchall()
        foods = [self._row_to_food(r) for r in rows]
        unique: list[Food] = []
        seen: set[tuple[Any, ...]] = set()
        for food in foods:
            # Imported datasets may contain the same food once in English and
            # once in Chinese. The display localization makes both names equal,
            # so include the core nutrition and portion in the identity while
            # retaining genuinely different preparations or products.
            key = (
                _canonical_food_name(food.name).lower(),
                round(float(food.calories or 0), 3),
                round(float(food.protein or 0), 3),
                round(float(food.carbs or 0), 3),
                round(float(food.fat or 0), 3),
                round(float(food.grams_per_unit or 0), 3),
            )
            if key in seen:
                continue
            seen.add(key)
            unique.append(food)
            if len(unique) >= limit:
                break
        return unique

    def _rows_to_nutrition_candidates(
        self,
        rows: list[sqlite3.Row],
        name: str,
        limit: int,
    ) -> list[dict[str, Any]]:
        terms = _lookup_terms(name)
        if not terms:
            return []
        stripped_query = _normalize_lookup_text(_strip_prep_suffix(re.sub(r"[（(].*?[）)]", "", terms[0]).strip()))
        canonical_query = _normalize_lookup_text(_canonical_food_name(terms[0]))
        limit = max(1, min(20, int(limit or 5)))

        seen: set[str] = set()
        candidates = []
        for row in rows:
            row_id = str(row["id"])
            if row_id in seen:
                continue
            seen.add(row_id)
            original_name = str(row["name"] or "")
            translated_name = str(row["name_zh"] or "") if "name_zh" in row.keys() else ""
            row_name = _display_food_name(original_name, translated_name)
            match_names = [row_name, original_name]
            stripped_names = [
                _normalize_lookup_text(_strip_prep_suffix(re.sub(r"[（(].*?[）)]", "", value).strip()))
                for value in match_names
                if value
            ]
            canonical_names = [
                _normalize_lookup_text(_canonical_food_name(value))
                for value in match_names
                if value
            ]
            if stripped_query in stripped_names:
                match_score = 1.0
            elif canonical_query in canonical_names:
                match_score = 0.96
            elif stripped_query and any(value.startswith(stripped_query) for value in stripped_names):
                match_score = 0.92
            elif canonical_query and any(canonical_query in value for value in canonical_names):
                match_score = 0.82
            else:
                query_chars = [ch for ch in canonical_query if "\u4e00" <= ch <= "\u9fff"]
                shared = sum(1 for ch in query_chars if ch in row_name)
                match_score = min(0.75, 0.45 + 0.05 * shared) if query_chars else 0.5

            source = str(row["source"] or "")
            nutrition = {field: float(row[field] or 0) for field in NUTRIENT_FIELDS if field in row.keys()}
            quality_score, quality_status, quality_notes = _nutrition_quality(name, row_name, nutrition)
            if quality_status == "reject":
                continue
            candidates.append(
                {
                    "food_id": row_id,
                    "name": row_name,
                    "name_zh": translated_name or row_name,
                    "original_name": original_name,
                    "source": "cleaned_merged" if "merged" in source else source,
                    "source_count": int(row["source_count"]) if "source_count" in row.keys() and row["source_count"] else 1,
                    "serving_size": str(row["serving_size"] or "100g"),
                    "processing_level": str(row["processing_level"] or "whole"),
                    "per_100g_nutrition": nutrition,
                    "match_score": round(match_score, 3),
                    "quality_score": quality_score,
                    "quality_status": quality_status,
                    "quality_notes": quality_notes,
                }
            )
        candidates.sort(key=lambda item: (
            -float(item["quality_score"]),
            -float(item["match_score"]),
            len(str(item["name"])),
        ))
        return candidates[:limit]

    def find_nutrition_candidates_fast(self, name: str, limit: int = 3) -> list[dict[str, Any]]:
        """Return indexed exact/alias candidates only, suitable for low-latency photo estimates."""
        terms = _lookup_terms(name)
        if not terms:
            return []
        limit = max(1, min(10, int(limit or 3)))
        with self._get_conn() as conn:
            table = self._reference_food_table(conn)
            rows = self._indexed_exact_food_rows(conn, table, terms, limit)
        return self._rows_to_nutrition_candidates(rows, name, limit)

    def find_nutrition_candidates(self, name: str, limit: int = 5) -> list[dict[str, Any]]:
        """Return merged, source-agnostic, nutrition candidates with sanity checks."""
        terms = _lookup_terms(name)
        if not terms:
            return []
        limit = max(1, min(20, int(limit or 5)))

        with self._get_conn() as conn:
            table = self._reference_food_table(conn)
            rows = self._indexed_exact_food_rows(conn, table, terms, limit)

            if len(rows) < limit:
                columns = ["lower(name)"]
                if self._column_exists(conn, table, "name_zh"):
                    columns.append("name_zh")
                where_parts = []
                params = []
                for column in columns:
                    for term in terms:
                        if column == "lower(name)":
                            where_parts.append("lower(name) LIKE ?")
                            params.append(f"%{term.lower()}%")
                        else:
                            where_parts.append("name_zh LIKE ?")
                            params.append(f"%{term}%")
                where = " OR ".join(where_parts)
                row_batch = conn.execute(
                    f"""
                    SELECT *
                    FROM {table}
                    WHERE {where}
                    ORDER BY length(name)
                    LIMIT ?
                    """,
                    (*params, limit * 20),
                ).fetchall()
                rows.extend(row_batch)

        return self._rows_to_nutrition_candidates(rows, name, limit)

    def find_recipe_candidates(self, name: str, limit: int = 3) -> list[dict[str, Any]]:
        """Return similar cleaned recipe examples for mixed dish calibration."""
        recipe_db_path = self.db_path.parent / "recipes.db"
        if not recipe_db_path.exists():
            recipe_db_path = RECIPES_DB_PATH
        if not recipe_db_path.exists():
            return []

        terms = _lookup_terms(name)
        if not terms:
            return []
        limit = max(1, min(10, int(limit or 3)))

        conn = sqlite3.connect(str(recipe_db_path))
        conn.row_factory = sqlite3.Row
        try:
            if not self._table_exists(conn, "recipe_training_examples_clean"):
                return []
            rows: list[sqlite3.Row] = []
            for term in terms:
                row_batch = conn.execute(
                    """
                    SELECT recipe_title, ingredients_json, steps_json, source_key
                    FROM recipe_training_examples_clean
                    WHERE recipe_title = ?
                    LIMIT ?
                    """,
                    (term, limit),
                ).fetchall()
                rows.extend(row_batch)
                if len(rows) >= limit:
                    break
            if len(rows) < limit:
                where = " OR ".join(["recipe_title LIKE ?"] * len(terms))
                params = [f"%{term}%" for term in terms]
                rows.extend(
                    conn.execute(
                        f"""
                        SELECT recipe_title, ingredients_json, steps_json, source_key
                        FROM recipe_training_examples_clean
                        WHERE {where}
                        ORDER BY length(recipe_title)
                        LIMIT ?
                        """,
                        (*params, limit * 3),
                    ).fetchall()
                )
        finally:
            conn.close()

        seen: set[str] = set()
        candidates = []
        for row in rows:
            title = str(row["recipe_title"] or "")
            if title in seen:
                continue
            seen.add(title)
            try:
                ingredients = json.loads(row["ingredients_json"] or "[]")
            except Exception:
                ingredients = []
            try:
                steps = json.loads(row["steps_json"] or "[]")
            except Exception:
                steps = []
            candidates.append(
                {
                    "recipe_title": title,
                    "ingredients": ingredients[:16],
                    "steps_preview": steps[:6],
                    "source_key": str(row["source_key"] or ""),
                }
            )
            if len(candidates) >= limit:
                break
        return candidates

    async def lookup_barcode(self, barcode: str) -> Optional[Food]:
        """Look up a food by barcode."""
        clean_barcode = str(barcode or "").strip()
        if not re.fullmatch(r"\d{8,14}", clean_barcode):
            return None
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM foods WHERE barcode = ?", (clean_barcode,)
            ).fetchone()
        if row:
            return self._row_to_food(row)
        return None

    async def cache_barcode_food(self, food: Food, barcode: str, source: str) -> Food:
        """Persist an external barcode result so later scans stay local and fast."""
        clean_barcode = re.sub(r"\D", "", barcode or "")
        if not clean_barcode:
            return food
        food.barcode = clean_barcode
        food.nutrition_source = source
        with self._get_conn() as conn:
            columns = ["id", "name", *NUTRIENT_FIELDS, "serving_size", "grams_per_unit", "processing_level", "barcode", "source"]
            values = [
                food.id,
                food.name,
                *[float(getattr(food, field, 0) or 0) for field in NUTRIENT_FIELDS],
                food.serving_size,
                max(0.1, float(food.grams_per_unit or 100)),
                food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level),
                clean_barcode,
                source,
            ]
            placeholders = ",".join(["?"] * len(columns))
            updates = ",".join(f"{column}=excluded.{column}" for column in columns if column not in {"id", "barcode"})
            conn.execute(
                f"INSERT INTO foods ({','.join(columns)}) VALUES ({placeholders}) "
                f"ON CONFLICT(id) DO UPDATE SET {updates}, barcode=excluded.barcode",
                values,
            )
            conn.commit()
        return food

    async def add(self, food: Food) -> Food:
        """Add a food to the database."""
        with self._get_conn() as conn:
            columns = [
                "id", "name", *NUTRIENT_FIELDS, "serving_size", "grams_per_unit",
                "processing_level", "barcode", "source",
            ]
            values = [
                food.id,
                food.name,
                *[float(getattr(food, field, 0) or 0) for field in NUTRIENT_FIELDS],
                food.serving_size,
                max(0.1, float(food.grams_per_unit or 100)),
                food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level),
                food.barcode,
                food.nutrition_source or "user",
            ]
            placeholders = ",".join(["?"] * len(columns))
            conn.execute(
                f"INSERT OR REPLACE INTO foods ({','.join(columns)}) VALUES ({placeholders})",
                values,
            )
            conn.commit()
        return food

    async def suggest(self, prefix: str, limit: int = 5) -> list[str]:
        """Return food name suggestions for auto-complete."""
        normalized = prefix.strip().lower()
        terms = [prefix]
        if normalized:
            for raw_name, localized_name in LOCALIZED_FOOD_NAMES.items():
                if normalized in raw_name.lower() or normalized in localized_name.lower():
                    terms.append(raw_name)
                    terms.append(localized_name)
        terms = list(dict.fromkeys([term for term in terms if term]))
        if not terms:
            return []
        where = " OR ".join(["name LIKE ?"] * len(terms))
        params = [f"%{term}%" for term in terms]
        with self._get_conn() as conn:
            rows = conn.execute(
                f"SELECT DISTINCT name FROM foods WHERE {where} LIMIT ?",
                (*params, limit),
            ).fetchall()
        return [_display_food_name(r[0]) for r in rows]

    # ── Cal AI Flywheel: Fix / Report / Vote ──────────────────

    def fix_food(self, food_id: str, corrections: dict, note: str = "") -> dict:
        """Apply user corrections to a food. Returns list of corrected fields."""
        corrected = []
        with self._get_conn() as conn:
            old = conn.execute("SELECT * FROM foods WHERE id = ?", (food_id,)).fetchone()
            if not old:
                return {"status": "not_found", "corrected_fields": [], "message": "没有找到这项食物"}

            field_map = {
                "corrected_name": "name",
                "corrected_calories": "calories",
                "corrected_protein": "protein",
                "corrected_carbs": "carbs",
                "corrected_fat": "fat",
                "corrected_fiber": "fiber",
                "corrected_sugar": "sugar",
                "corrected_sodium": "sodium",
                "corrected_serving_size": "serving_size",
                "corrected_processing_level": "processing_level",
            }

            for req_field, db_field in field_map.items():
                new_val = corrections.get(req_field)
                if new_val is not None and str(new_val) != str(old[db_field]):
                    # Log correction
                    conn.execute(
                        "INSERT INTO food_corrections (food_id, field_name, old_value, new_value, note) VALUES (?, ?, ?, ?, ?)",
                        (food_id, db_field, str(old[db_field]), str(new_val), note),
                    )
                    # Apply
                    conn.execute(
                        f"UPDATE foods SET {db_field} = ?, source = 'user_fix' WHERE id = ?",
                        (new_val, food_id),
                    )
                    corrected.append(db_field)

            # Update fix count
            conn.execute(
                "INSERT INTO food_confidence (food_id, food_name, fix_count, source) "
                "VALUES (?, ?, 1, 'user_fix') "
                "ON CONFLICT(food_id) DO UPDATE SET "
                "fix_count = fix_count + 1, last_updated = CURRENT_TIMESTAMP",
                (food_id, old["name"]),
            )
            conn.commit()

        return {
            "status": "updated",
            "corrected_fields": corrected,
            "message": f"已更新 {len(corrected)} 项字段：{', '.join(corrected)}" if corrected else "无需修改",
        }

    def report_food(self, food_id: str, reason: str, detail: str = "") -> dict:
        """Report a food as having incorrect or inappropriate data."""
        with self._get_conn() as conn:
            conn.execute(
                "INSERT INTO food_confidence (food_id, food_name, report_count, source) "
                "VALUES (?, ?, 1, 'gemini') "
                "ON CONFLICT(food_id) DO UPDATE SET "
                "report_count = report_count + 1, last_updated = CURRENT_TIMESTAMP",
                (food_id, ""),
            )
            conn.commit()
        return {"status": "reported", "food_id": food_id, "reason": reason}

    def vote_food(self, food_id: str, vote: str) -> dict:
        """Vote on food data accuracy. 'accurate' or 'inaccurate'."""
        with self._get_conn() as conn:
            existing = conn.execute(
                "SELECT name FROM foods WHERE id = ?", (food_id,)
            ).fetchone()
            food_name = existing["name"] if existing else ""

            if vote == "accurate":
                conn.execute(
                    "INSERT INTO food_confidence (food_id, food_name, accurate_votes, source) "
                    "VALUES (?, ?, 1, 'gemini') "
                    "ON CONFLICT(food_id) DO UPDATE SET "
                    "accurate_votes = accurate_votes + 1, last_updated = CURRENT_TIMESTAMP",
                    (food_id, food_name),
                )
            elif vote == "inaccurate":
                conn.execute(
                    "INSERT INTO food_confidence (food_id, food_name, inaccurate_votes, source) "
                    "VALUES (?, ?, 1, 'gemini') "
                    "ON CONFLICT(food_id) DO UPDATE SET "
                    "inaccurate_votes = inaccurate_votes + 1, last_updated = CURRENT_TIMESTAMP",
                    (food_id, food_name),
                )
            elif vote == "helpful":
                conn.execute(
                    "INSERT INTO food_confidence (food_id, food_name, accurate_votes, source) "
                    "VALUES (?, ?, 1, 'gemini') "
                    "ON CONFLICT(food_id) DO UPDATE SET "
                    "accurate_votes = accurate_votes + 1, last_updated = CURRENT_TIMESTAMP",
                    (food_id, food_name),
                )
            conn.commit()

        return {"status": "voted", "food_id": food_id, "vote": vote}

    def get_confidence(self, food_id: str | None = None) -> list[dict]:
        """Get confidence data for a food or all foods."""
        with self._get_conn() as conn:
            if food_id:
                rows = conn.execute(
                    "SELECT * FROM food_confidence WHERE food_id = ?", (food_id,)
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM food_confidence ORDER BY accurate_votes DESC"
                ).fetchall()
        return [dict(r) for r in rows]

    def _row_to_food(self, row: sqlite3.Row) -> Food:
        name_zh = str(row["name_zh"] or "") if "name_zh" in row.keys() else ""
        return Food(
            id=row["id"],
            name=_display_food_name(row["name"], name_zh),
            calories=row["calories"],
            protein=row["protein"],
            carbs=row["carbs"],
            fat=row["fat"],
            fiber=row["fiber"],
            sugar=row["sugar"],
            added_sugar=row["added_sugar"] or 0,
            sodium=row["sodium"],
            sat_fat=row["sat_fat"] or 0,
            trans_fat=row["trans_fat"] or 0,
            cholesterol=row["cholesterol"] or 0,
            vitamin_a=row["vitamin_a"] or 0,
            vitamin_c=row["vitamin_c"] or 0,
            calcium=row["calcium"] or 0,
            iron=row["iron"] or 0,
            potassium=row["potassium"] or 0,
            magnesium=row["magnesium"] or 0 if "magnesium" in row.keys() else 0,
            zinc=row["zinc"] or 0 if "zinc" in row.keys() else 0,
            folate=row["folate"] or 0 if "folate" in row.keys() else 0,
            vitamin_d=row["vitamin_d"] or 0 if "vitamin_d" in row.keys() else 0,
            vitamin_b12=row["vitamin_b12"] or 0 if "vitamin_b12" in row.keys() else 0,
            vitamin_e=row["vitamin_e"] or 0 if "vitamin_e" in row.keys() else 0,
            vitamin_k=row["vitamin_k"] or 0 if "vitamin_k" in row.keys() else 0,
            omega_3=row["omega_3"] or 0 if "omega_3" in row.keys() else 0,
            monounsaturated_fat=row["monounsaturated_fat"] or 0 if "monounsaturated_fat" in row.keys() else 0,
            polyunsaturated_fat=row["polyunsaturated_fat"] or 0 if "polyunsaturated_fat" in row.keys() else 0,
            serving_size=_display_serving_size(row["serving_size"]),
            grams_per_unit=(row["grams_per_unit"] or 100) if "grams_per_unit" in row.keys() else 100,
            processing_level=ProcessingLevel(row["processing_level"]),
            barcode=(row["barcode"] or "") if "barcode" in row.keys() else "",
            nutrition_source=(row["source"] or "") if "source" in row.keys() else "",
        )
