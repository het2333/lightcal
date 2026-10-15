"""Build validated food database views/tables.

This does not pretend every nutrition row is perfect. It creates a practical
"trusted enough for product use" layer by keeping source provenance, assigning
trust tiers, and excluding rows that fail broad nutrition sanity checks.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "foods.db"
REPORT_PATH = ROOT / "data" / "reports" / "food_accuracy_validation.md"


def build() -> dict[str, int]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        conn.executescript(
            """
            DROP TABLE IF EXISTS food_accuracy_scored;
            DROP TABLE IF EXISTS food_accuracy_issues;
            DROP TABLE IF EXISTS foods_verified_clean;

            CREATE TABLE food_accuracy_scored AS
            WITH base AS (
                SELECT
                    f.*,
                    lower(trim(coalesce(f.name, ''))) AS name_lc,
                    lower(trim(coalesce(f.source, ''))) AS source_lc,
                    (
                        coalesce(f.protein, 0) * 4.0
                        + coalesce(f.carbs, 0) * 4.0
                        + coalesce(f.fat, 0) * 9.0
                    ) AS macro_kcal
                FROM foods_clean f
            ),
            scored AS (
                SELECT
                    *,
                    CASE
                        WHEN source_lc LIKE '%user_fix%' THEN 'A_user_verified'
                        WHEN source_lc LIKE '%foundation%' THEN 'A_official_reference'
                        WHEN source_lc LIKE '%survey%' THEN 'A_official_reference'
                        WHEN source_lc LIKE '%台湾食品营养%' THEN 'A_official_reference'
                        WHEN source_lc = '中国食物成分表' THEN 'A_official_reference'
                        WHEN source_lc LIKE '%usda / harvard%' THEN 'A_official_reference'
                        WHEN source_lc LIKE '%branded foods%' THEN 'B_label_database'
                        WHEN source_lc LIKE '%open food facts%' THEN 'B_crowd_label_database'
                        ELSE 'C_needs_manual_review'
                    END AS quality_tier,
                    CASE
                        WHEN source_lc LIKE '%user_fix%' THEN 0.98
                        WHEN source_lc LIKE '%foundation%' THEN 0.95
                        WHEN source_lc LIKE '%survey%' THEN 0.93
                        WHEN source_lc LIKE '%台湾食品营养%' THEN 0.93
                        WHEN source_lc = '中国食物成分表' THEN 0.92
                        WHEN source_lc LIKE '%usda / harvard%' THEN 0.90
                        WHEN source_lc LIKE '%branded foods%' THEN 0.82
                        WHEN source_lc LIKE '%open food facts%' THEN 0.76
                        ELSE 0.45
                    END AS quality_score,
                    CASE
                        WHEN name_lc = '' THEN 'missing_name'
                        WHEN calories IS NULL THEN 'missing_calories'
                        WHEN calories < 0 OR calories > 950 THEN 'calories_out_of_range'
                        WHEN protein < 0 OR protein > 100 THEN 'protein_out_of_range'
                        WHEN carbs < 0 OR carbs > 100 THEN 'carbs_out_of_range'
                        WHEN fat < 0 OR fat > 100 THEN 'fat_out_of_range'
                        WHEN fiber < 0 OR fiber > 80 THEN 'fiber_out_of_range'
                        WHEN sugar < 0 OR sugar > 100 THEN 'sugar_out_of_range'
                        WHEN added_sugar < 0 OR added_sugar > 100 THEN 'added_sugar_out_of_range'
                        WHEN sodium < 0 OR sodium > 20000 THEN 'sodium_out_of_range'
                        WHEN calories = 0 AND macro_kcal > 25 THEN 'zero_calorie_macro_conflict'
                        WHEN calories > 80 AND macro_kcal > 80 AND (
                            calories < macro_kcal * 0.45 OR calories > macro_kcal * 2.25
                        ) THEN 'macro_energy_mismatch'
                        WHEN (
                            name_lc LIKE '%菜%' OR name_lc LIKE '%蔬%' OR name_lc LIKE '%甘蓝%'
                            OR name_lc LIKE '%芹%' OR name_lc LIKE '%西芹%' OR name_lc LIKE '%胡萝卜%'
                            OR name_lc LIKE '%萝卜%' OR name_lc LIKE '%番茄%' OR name_lc LIKE '%黄瓜%'
                            OR name_lc LIKE '%蘑菇%' OR name_lc LIKE '%香菇%' OR name_lc LIKE '%西兰花%'
                            OR name_lc LIKE '%生菜%' OR name_lc LIKE '%菠菜%'
                        )
                        AND NOT (
                            name_lc LIKE '%干%' OR name_lc LIKE '%脱水%' OR name_lc LIKE '%粉%'
                            OR name_lc LIKE '%调味%' OR name_lc LIKE '%茶%' OR name_lc LIKE '%浓缩%'
                            OR name_lc LIKE '%酱%' OR name_lc LIKE '%油%' OR name_lc LIKE '%薯片%'
                            OR name_lc LIKE '%脆片%' OR name_lc LIKE '%饼干%' OR name_lc LIKE '%膨化%'
                        )
                        AND (calories > 140 OR protein > 18 OR carbs > 35 OR fat > 12)
                        THEN 'fresh_food_density_suspicious'
                        ELSE ''
                    END AS issue_reason
                FROM base
            )
            SELECT * FROM scored;

            CREATE TABLE food_accuracy_issues AS
            SELECT * FROM food_accuracy_scored
            WHERE issue_reason != '' OR quality_tier = 'C_needs_manual_review';

            CREATE TABLE foods_verified_clean AS
            SELECT
                id, name, calories, protein, carbs, fat, fiber, sugar, added_sugar,
                sodium, sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
                calcium, iron, potassium, serving_size, processing_level, barcode,
                source, created_at, normalized_name, quality_tier, quality_score,
                'sanity_checked' AS quality_status
            FROM food_accuracy_scored
            WHERE issue_reason = ''
              AND quality_tier != 'C_needs_manual_review';

            CREATE INDEX idx_foods_verified_name ON foods_verified_clean(normalized_name);
            CREATE INDEX idx_foods_verified_display_name ON foods_verified_clean(name);
            CREATE INDEX idx_foods_verified_barcode ON foods_verified_clean(barcode);
            CREATE INDEX idx_foods_verified_tier ON foods_verified_clean(quality_tier);
            CREATE INDEX idx_food_accuracy_issues_name ON food_accuracy_issues(normalized_name);
            CREATE INDEX idx_food_accuracy_issues_reason ON food_accuracy_issues(issue_reason);
            """
        )
        conn.commit()

        stats = {
            "raw_foods": conn.execute("SELECT count(*) FROM foods").fetchone()[0],
            "foods_clean": conn.execute("SELECT count(*) FROM foods_clean").fetchone()[0],
            "foods_verified_clean": conn.execute("SELECT count(*) FROM foods_verified_clean").fetchone()[0],
            "food_accuracy_issues": conn.execute("SELECT count(*) FROM food_accuracy_issues").fetchone()[0],
        }
        write_report(conn, stats)
        return stats
    finally:
        conn.close()


def write_report(conn: sqlite3.Connection, stats: dict[str, int]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tier_rows = conn.execute(
        """
        SELECT quality_tier, count(*) AS count
        FROM foods_verified_clean
        GROUP BY quality_tier
        ORDER BY count DESC
        """
    ).fetchall()
    issue_rows = conn.execute(
        """
        SELECT coalesce(nullif(issue_reason, ''), 'needs_manual_review') AS reason, count(*) AS count
        FROM food_accuracy_issues
        GROUP BY reason
        ORDER BY count DESC
        LIMIT 20
        """
    ).fetchall()

    lines = [
        "# Food Accuracy Validation Report",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat()}",
        "",
        "## Counts",
        "",
        f"- raw foods: {stats['raw_foods']}",
        f"- foods_clean: {stats['foods_clean']}",
        f"- foods_verified_clean: {stats['foods_verified_clean']}",
        f"- food_accuracy_issues: {stats['food_accuracy_issues']}",
        "",
        "## Verified Rows By Trust Tier",
        "",
        "| Tier | Rows |",
        "| --- | ---: |",
    ]
    lines.extend(f"| {row['quality_tier']} | {row['count']} |" for row in tier_rows)
    lines.extend([
        "",
        "## Top Issue Reasons",
        "",
        "| Reason | Rows |",
        "| --- | ---: |",
    ])
    lines.extend(f"| {row['reason']} | {row['count']} |" for row in issue_rows)
    lines.extend([
        "",
        "## Accuracy Policy",
        "",
        "- A tier: official/reference or user-verified data, highest confidence.",
        "- B tier: large product label/barcode databases, useful but still checked at runtime.",
        "- C tier: OCR/generated/unreviewed sources, excluded from foods_verified_clean until manually reviewed.",
        "- This table guarantees traceability and sanity checks, not absolute nutrition truth.",
    ])
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    print(build())
