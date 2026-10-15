"""Build a source-agnostic cleaned nutrition table.

The raw source tables stay intact for auditability. This script creates:
- foods_merged_clean: one merged nutrition row per normalized food name
- food_nutrition_anomalies: rows excluded from the merged table

Merged rows intentionally do not rank by source. Values are averaged after
basic sanity filters; runtime lookup applies query-specific checks as well.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "foods.db"

NUTRIENTS = [
    "calories", "protein", "carbs", "fat", "fiber", "sugar", "added_sugar",
    "sodium", "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
    "calcium", "iron", "potassium",
]

FRESH_PATTERNS = [
    "%菜%", "%蔬%", "%甘蓝%", "%芹%", "%西芹%", "%青椒%", "%彩椒%",
    "%甜椒%", "%胡萝卜%", "%萝卜%", "%番茄%", "%圣女果%", "%黄瓜%",
    "%苦瓜%", "%蘑菇%", "%香菇%", "%西兰花%", "%生菜%", "%韭葱%",
    "%菠菜%", "%芽菜%",
]
DRY_PATTERNS = [
    "%干%", "%脱水%", "%粉%", "%香辛料%", "%调味料%", "%茶%",
    "%浓缩%", "%酱%", "%油%", "%薯片%", "%脆片%", "%饼干%", "%膨化%",
]


def like_any(column: str, patterns: list[str]) -> str:
    return "(" + " OR ".join([f"{column} LIKE '{pattern}'" for pattern in patterns]) + ")"


def build() -> dict[str, int]:
    conn = sqlite3.connect(DB_PATH)
    try:
        source_table = "foods_clean"
        if not conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            (source_table,),
        ).fetchone():
            source_table = "foods"

        avg_cols = ",\n            ".join([f"ROUND(AVG({field}), 4) AS {field}" for field in NUTRIENTS])
        fresh_like = like_any("name", FRESH_PATTERNS)
        dry_like = like_any("name", DRY_PATTERNS)
        valid_where = f"""
            name IS NOT NULL
            AND trim(name) != ''
            AND calories > 0 AND calories <= 950
            AND protein BETWEEN 0 AND 100
            AND carbs BETWEEN 0 AND 100
            AND fat BETWEEN 0 AND 100
            AND fiber BETWEEN 0 AND 80
            AND sodium BETWEEN 0 AND 20000
            AND NOT (
                {fresh_like}
                AND NOT {dry_like}
                AND (
                    calories > 120
                    OR protein > 12
                    OR carbs > 30
                    OR fat > 8
                )
            )
        """

        conn.executescript(
            f"""
            DROP TABLE IF EXISTS foods_merged_clean;
            DROP TABLE IF EXISTS food_nutrition_anomalies;

            CREATE TABLE food_nutrition_anomalies AS
            SELECT *,
                   lower(trim(name)) AS normalized_name,
                   'nutrition_sanity_rejected' AS anomaly_reason
            FROM {source_table}
            WHERE NOT ({valid_where});

            CREATE TABLE foods_merged_clean AS
            SELECT
                'merged_' || lower(hex(randomblob(6))) AS id,
                MIN(name) AS name,
                {avg_cols},
                '100克' AS serving_size,
                CASE
                    WHEN SUM(CASE WHEN processing_level = 'ultra_processed' THEN 1 ELSE 0 END) > 0 THEN 'ultra_processed'
                    WHEN SUM(CASE WHEN processing_level = 'processed' THEN 1 ELSE 0 END) > 0 THEN 'processed'
                    WHEN SUM(CASE WHEN processing_level = 'minimally_processed' THEN 1 ELSE 0 END) > 0 THEN 'minimally_processed'
                    ELSE 'whole'
                END AS processing_level,
                '' AS barcode,
                'cleaned_merged' AS source,
                DATE('now') AS created_at,
                lower(trim(name)) AS normalized_name,
                COUNT(*) AS source_count,
                'ok' AS quality_status
            FROM {source_table}
            WHERE {valid_where}
            GROUP BY lower(trim(name));

            CREATE INDEX idx_foods_merged_clean_name ON foods_merged_clean(normalized_name);
            CREATE INDEX idx_foods_merged_clean_display_name ON foods_merged_clean(name);
            CREATE INDEX idx_food_nutrition_anomalies_name ON food_nutrition_anomalies(normalized_name);
            """
        )
        conn.commit()
        merged = conn.execute("SELECT COUNT(*) FROM foods_merged_clean").fetchone()[0]
        rejected = conn.execute("SELECT COUNT(*) FROM food_nutrition_anomalies").fetchone()[0]
        source = conn.execute(f"SELECT COUNT(*) FROM {source_table}").fetchone()[0]
        return {"source_rows": source, "merged_rows": merged, "rejected_rows": rejected}
    finally:
        conn.close()


if __name__ == "__main__":
    print(build())
