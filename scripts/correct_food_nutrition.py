"""Build a corrected nutrition layer from verified rows and fixable issues.

Original imported rows are not overwritten. Corrections are stored with a
method, confidence, and note so they can be audited or rolled back.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "foods.db"
REPORT_PATH = ROOT / "data" / "reports" / "food_nutrition_corrections.md"

NUTRIENTS = [
    "calories", "protein", "carbs", "fat", "fiber", "sugar", "added_sugar",
    "sodium", "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
    "calcium", "iron", "potassium",
]
FIXABLE_REASONS = {
    "missing_calories",
    "calories_out_of_range",
    "zero_calorie_macro_conflict",
    "macro_energy_mismatch",
    "fresh_food_density_suspicious",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    return bool(conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone())


def column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    return any(row[1] == column for row in conn.execute(f'PRAGMA table_info("{table}")'))


def value(row: sqlite3.Row, field: str, default: float = 0.0) -> float:
    try:
        return float(row[field] or default)
    except (TypeError, ValueError, KeyError, IndexError):
        return default


def nutrient_dict(row: sqlite3.Row) -> dict[str, float]:
    return {field: round(value(row, field), 4) for field in NUTRIENTS}


def macro_kcal(nutrition: dict[str, float]) -> float:
    return (
        float(nutrition.get("protein", 0) or 0) * 4
        + float(nutrition.get("carbs", 0) or 0) * 4
        + float(nutrition.get("fat", 0) or 0) * 9
    )


def macros_plausible(nutrition: dict[str, float]) -> bool:
    return (
        0 <= nutrition.get("protein", 0) <= 100
        and 0 <= nutrition.get("carbs", 0) <= 100
        and 0 <= nutrition.get("fat", 0) <= 100
        and 0 <= nutrition.get("fiber", 0) <= 80
        and 0 <= nutrition.get("sugar", 0) <= 100
        and 0 <= nutrition.get("sodium", 0) <= 20000
    )


def reference_nutrition(conn: sqlite3.Connection, normalized_name: str) -> dict[str, float] | None:
    rows = conn.execute(
        f"""
        SELECT {", ".join([f"AVG({field}) AS {field}" for field in NUTRIENTS])},
               COUNT(*) AS row_count
        FROM foods_verified_clean
        WHERE normalized_name = ?
        """,
        (normalized_name,),
    ).fetchone()
    if not rows or int(rows["row_count"] or 0) <= 0:
        return None
    nutrition = {field: round(value(rows, field), 4) for field in NUTRIENTS}
    if not macros_plausible(nutrition) or nutrition["calories"] <= 0 or nutrition["calories"] > 950:
        return None
    return nutrition


def correction_for_row(conn: sqlite3.Connection, row: sqlite3.Row) -> tuple[dict[str, float], str, float, str] | None:
    reason = str(row["issue_reason"] or "")
    if reason not in FIXABLE_REASONS:
        return None

    original = nutrient_dict(row)
    normalized_name = str(row["normalized_name"] or "").strip()
    ref = reference_nutrition(conn, normalized_name) if normalized_name else None
    if ref and reason in {"fresh_food_density_suspicious", "calories_out_of_range", "macro_energy_mismatch"}:
        return ref, "same_name_verified_reference", 0.86, f"同名高可信记录均值修正：{reason}"

    if not macros_plausible(original):
        return None

    kcal_from_macro = round(macro_kcal(original), 2)
    if 0 < kcal_from_macro <= 950 and reason in {
        "missing_calories",
        "calories_out_of_range",
        "zero_calorie_macro_conflict",
        "macro_energy_mismatch",
    }:
        corrected = dict(original)
        corrected["calories"] = kcal_from_macro
        confidence = 0.82 if reason in {"zero_calorie_macro_conflict", "macro_energy_mismatch"} else 0.74
        return corrected, "macro_energy_recalculation", confidence, f"按蛋白/碳水/脂肪换算热量修正：{reason}"

    return None


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        DROP TABLE IF EXISTS food_nutrition_corrections;
        DROP TABLE IF EXISTS food_nutrition_review_queue;
        DROP TABLE IF EXISTS foods_corrected_clean;

        CREATE TABLE food_nutrition_corrections (
            food_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT DEFAULT '',
            source TEXT DEFAULT '',
            issue_reason TEXT NOT NULL,
            original_nutrition_json TEXT NOT NULL,
            corrected_nutrition_json TEXT NOT NULL,
            correction_method TEXT NOT NULL,
            correction_confidence REAL NOT NULL,
            correction_note TEXT DEFAULT '',
            corrected_at TEXT NOT NULL
        );

        CREATE TABLE food_nutrition_review_queue (
            food_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT DEFAULT '',
            source TEXT DEFAULT '',
            issue_reason TEXT NOT NULL,
            original_nutrition_json TEXT NOT NULL,
            review_note TEXT DEFAULT '',
            queued_at TEXT NOT NULL
        );
        """
    )
    conn.commit()


def build_corrected_table(conn: sqlite3.Connection) -> None:
    verified_has_zh = column_exists(conn, "foods_verified_clean", "name_zh")
    issue_has_zh = column_exists(conn, "food_accuracy_issues", "name_zh")
    verified_name_zh = "coalesce(v.name_zh, cache.name_zh, '')" if verified_has_zh else "coalesce(cache.name_zh, '')"
    issue_name_zh = "coalesce(i.name_zh, cache.name_zh, '')" if issue_has_zh else "coalesce(cache.name_zh, '')"

    conn.executescript(
        f"""
        CREATE TABLE foods_corrected_clean AS
        SELECT
            v.id, v.name,
            v.calories, v.protein, v.carbs, v.fat, v.fiber, v.sugar, v.added_sugar,
            v.sodium, v.sat_fat, v.trans_fat, v.cholesterol, v.vitamin_a, v.vitamin_c,
            v.calcium, v.iron, v.potassium,
            v.serving_size, v.processing_level, v.barcode, v.source, v.created_at,
            v.normalized_name, v.quality_tier, v.quality_score,
            'sanity_checked' AS quality_status,
            {verified_name_zh} AS name_zh,
            0 AS nutrition_corrected,
            '' AS nutrition_correction_method,
            1.0 AS nutrition_correction_confidence
        FROM foods_verified_clean v
        LEFT JOIN food_name_translation_cache cache ON cache.original_name = v.name

        UNION ALL

        SELECT
            i.id, i.name,
            json_extract(c.corrected_nutrition_json, '$.calories') AS calories,
            json_extract(c.corrected_nutrition_json, '$.protein') AS protein,
            json_extract(c.corrected_nutrition_json, '$.carbs') AS carbs,
            json_extract(c.corrected_nutrition_json, '$.fat') AS fat,
            json_extract(c.corrected_nutrition_json, '$.fiber') AS fiber,
            json_extract(c.corrected_nutrition_json, '$.sugar') AS sugar,
            json_extract(c.corrected_nutrition_json, '$.added_sugar') AS added_sugar,
            json_extract(c.corrected_nutrition_json, '$.sodium') AS sodium,
            json_extract(c.corrected_nutrition_json, '$.sat_fat') AS sat_fat,
            json_extract(c.corrected_nutrition_json, '$.trans_fat') AS trans_fat,
            json_extract(c.corrected_nutrition_json, '$.cholesterol') AS cholesterol,
            json_extract(c.corrected_nutrition_json, '$.vitamin_a') AS vitamin_a,
            json_extract(c.corrected_nutrition_json, '$.vitamin_c') AS vitamin_c,
            json_extract(c.corrected_nutrition_json, '$.calcium') AS calcium,
            json_extract(c.corrected_nutrition_json, '$.iron') AS iron,
            json_extract(c.corrected_nutrition_json, '$.potassium') AS potassium,
            i.serving_size, i.processing_level, i.barcode, i.source, i.created_at,
            i.normalized_name, i.quality_tier,
            min(0.99, i.quality_score + 0.05) AS quality_score,
            'nutrition_corrected' AS quality_status,
            {issue_name_zh} AS name_zh,
            1 AS nutrition_corrected,
            c.correction_method AS nutrition_correction_method,
            c.correction_confidence AS nutrition_correction_confidence
        FROM food_accuracy_issues i
        JOIN food_nutrition_corrections c ON c.food_id = i.id
        LEFT JOIN food_name_translation_cache cache ON cache.original_name = i.name
        WHERE c.correction_confidence >= 0.72
           OR c.correction_method = 'mimo_nutrition_correction';

        CREATE INDEX idx_foods_corrected_name ON foods_corrected_clean(normalized_name);
        CREATE INDEX idx_foods_corrected_display_name ON foods_corrected_clean(name);
        CREATE INDEX idx_foods_corrected_name_zh ON foods_corrected_clean(name_zh);
        CREATE INDEX idx_foods_corrected_barcode ON foods_corrected_clean(barcode);
        CREATE INDEX idx_foods_corrected_quality ON foods_corrected_clean(quality_status);
        """
    )
    conn.commit()


def write_report(conn: sqlite3.Connection, stats: dict[str, int]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    method_rows = conn.execute(
        """
        SELECT correction_method, count(*) AS count
        FROM food_nutrition_corrections
        GROUP BY correction_method
        ORDER BY count DESC
        """
    ).fetchall()
    review_rows = conn.execute(
        """
        SELECT issue_reason, count(*) AS count
        FROM food_nutrition_review_queue
        GROUP BY issue_reason
        ORDER BY count DESC
        LIMIT 20
        """
    ).fetchall()
    lines = [
        "# Food Nutrition Corrections",
        "",
        f"Generated: {now_iso()}",
        "",
        "## Counts",
        "",
        f"- issue_rows_scanned: {stats['issue_rows_scanned']}",
        f"- auto_corrected_rows: {stats['auto_corrected_rows']}",
        f"- review_queue_rows: {stats['review_queue_rows']}",
        f"- foods_corrected_clean: {stats['foods_corrected_clean']}",
        "",
        "## Correction Methods",
        "",
        "| Method | Rows |",
        "| --- | ---: |",
    ]
    lines.extend(f"| {row['correction_method']} | {row['count']} |" for row in method_rows)
    lines.extend([
        "",
        "## Review Queue",
        "",
        "| Issue | Rows |",
        "| --- | ---: |",
    ])
    lines.extend(f"| {row['issue_reason']} | {row['count']} |" for row in review_rows)
    lines.extend([
        "",
        "## Policy",
        "",
        "- 原始 foods/foods_clean 不覆盖。",
        "- 同名高可信参考可修正整组营养。",
        "- 宏量营养自洽时可重算 calories。",
        "- 无法可靠判断的进入 food_nutrition_review_queue。",
    ])
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build() -> dict[str, int]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    try:
        if not table_exists(conn, "foods_verified_clean") or not table_exists(conn, "food_accuracy_issues"):
            raise RuntimeError("Run scripts/build_food_accuracy_views.py first.")
        ensure_schema(conn)
        corrected_rows = []
        review_rows = []
        corrected_at = now_iso()
        cursor = conn.execute("SELECT * FROM food_accuracy_issues ORDER BY rowid")
        while True:
            rows = cursor.fetchmany(5000)
            if not rows:
                break
            for row in rows:
                issue_reason = str(row["issue_reason"] or "needs_manual_review")
                original = nutrient_dict(row)
                correction = correction_for_row(conn, row)
                if correction:
                    corrected, method, confidence, note = correction
                    corrected_rows.append((
                        str(row["id"]),
                        str(row["name"] or ""),
                        str(row["normalized_name"] or ""),
                        str(row["source"] or ""),
                        issue_reason,
                        json.dumps(original, ensure_ascii=False, sort_keys=True),
                        json.dumps(corrected, ensure_ascii=False, sort_keys=True),
                        method,
                        confidence,
                        note,
                        corrected_at,
                    ))
                else:
                    review_note = "无法通过同名可信参考或宏量能量关系可靠修正"
                    review_rows.append((
                        str(row["id"]),
                        str(row["name"] or ""),
                        str(row["normalized_name"] or ""),
                        str(row["source"] or ""),
                        issue_reason,
                        json.dumps(original, ensure_ascii=False, sort_keys=True),
                        review_note,
                        corrected_at,
                    ))
            if corrected_rows:
                conn.executemany(
                    """
                    INSERT OR REPLACE INTO food_nutrition_corrections
                        (food_id, name, normalized_name, source, issue_reason,
                         original_nutrition_json, corrected_nutrition_json,
                         correction_method, correction_confidence, correction_note, corrected_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    corrected_rows,
                )
                corrected_rows.clear()
            if review_rows:
                conn.executemany(
                    """
                    INSERT OR REPLACE INTO food_nutrition_review_queue
                        (food_id, name, normalized_name, source, issue_reason,
                         original_nutrition_json, review_note, queued_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    review_rows,
                )
                review_rows.clear()
            conn.commit()

        build_corrected_table(conn)
        stats = {
            "issue_rows_scanned": conn.execute("SELECT count(*) FROM food_accuracy_issues").fetchone()[0],
            "auto_corrected_rows": conn.execute("SELECT count(*) FROM food_nutrition_corrections").fetchone()[0],
            "review_queue_rows": conn.execute("SELECT count(*) FROM food_nutrition_review_queue").fetchone()[0],
            "foods_corrected_clean": conn.execute("SELECT count(*) FROM foods_corrected_clean").fetchone()[0],
        }
        write_report(conn, stats)
        return stats
    finally:
        conn.close()


if __name__ == "__main__":
    print(build())
