"""Flag suspicious nutrition rows without modifying nutrition values.

This script creates food_nutrition_review_flags as a review queue. It is safe to
run while keeping the source nutrition untouched.
"""

from __future__ import annotations

import re
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "foods.db"
REPORT_PATH = ROOT / "data" / "reports" / "nutrition_issue_flags.md"

FRESH_RE = re.compile(
    r"菜|蔬|甘蓝|芹|西芹|青椒|彩椒|甜椒|胡萝卜|萝卜|番茄|圣女果|黄瓜|苦瓜|蘑菇|香菇|西兰花|生菜|菠菜|白菜|莴笋"
)
DRY_OR_DENSE_RE = re.compile(r"干|脱水|粉|调味|茶|浓缩|酱|油|薯片|脆片|饼干|膨化|籽|坚果")
NEAR_ZERO_DRINK_RE = re.compile(r"水|茶|绿茶|红茶|乌龙茶|普洱|黑咖啡|美式咖啡|清汤|汤水")
SWEET_DRINK_EXCLUDE_RE = re.compile(r"奶茶|拿铁|奶盖|果茶|甜茶|糖|蜂蜜|椰|奶|牛奶|豆浆|饮料|汽水|可乐|果汁|酸奶")
OIL_RE = re.compile(r"油|黄油|butter|oil|lard|shortening", re.I)
LEAN_MEAT_RE = re.compile(r"鸡胸|鱼|虾|瘦肉|火鸡|tuna|cod|shrimp|chicken breast", re.I)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    return bool(conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone())


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_nutrition_review_flags (
            food_id TEXT PRIMARY KEY,
            table_name TEXT NOT NULL,
            name TEXT NOT NULL,
            name_zh TEXT DEFAULT '',
            source TEXT DEFAULT '',
            calories REAL DEFAULT 0,
            protein REAL DEFAULT 0,
            carbs REAL DEFAULT 0,
            fat REAL DEFAULT 0,
            fiber REAL DEFAULT 0,
            sugar REAL DEFAULT 0,
            sodium REAL DEFAULT 0,
            macro_kcal REAL DEFAULT 0,
            issue_codes TEXT NOT NULL,
            severity TEXT NOT NULL,
            review_status TEXT NOT NULL DEFAULT 'pending',
            flagged_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_food_nutrition_review_status ON food_nutrition_review_flags(review_status)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_food_nutrition_review_severity ON food_nutrition_review_flags(severity)"
    )
    conn.commit()


def f(value: object) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def issue_codes(row: sqlite3.Row) -> tuple[list[str], float]:
    name = f"{row['name'] or ''} {row['name_zh'] if 'name_zh' in row.keys() else ''}".strip()
    name_lc = name.lower()
    calories = f(row["calories"])
    protein = f(row["protein"])
    carbs = f(row["carbs"])
    fat = f(row["fat"])
    fiber = f(row["fiber"])
    sugar = f(row["sugar"])
    sodium = f(row["sodium"])
    macro_kcal = protein * 4 + carbs * 4 + fat * 9

    issues: list[str] = []
    if not name.strip():
        issues.append("missing_name")
    if calories < 0 or calories > 950:
        issues.append("calories_out_of_range")
    if protein < 0 or protein > 100:
        issues.append("protein_out_of_range")
    if carbs < 0 or carbs > 100:
        issues.append("carbs_out_of_range")
    if fat < 0 or fat > 100:
        issues.append("fat_out_of_range")
    if fiber < 0 or fiber > 80:
        issues.append("fiber_out_of_range")
    if sugar < 0 or sugar > 100:
        issues.append("sugar_out_of_range")
    if sodium < 0 or sodium > 20000:
        issues.append("sodium_out_of_range")
    if calories == 0 and macro_kcal > 25:
        issues.append("zero_calorie_macro_conflict")
    if calories > 80 and macro_kcal > 80 and (calories < macro_kcal * 0.45 or calories > macro_kcal * 2.25):
        issues.append("macro_energy_mismatch")
    if NEAR_ZERO_DRINK_RE.search(name) and not SWEET_DRINK_EXCLUDE_RE.search(name) and calories > 30:
        issues.append("near_zero_drink_high_calorie")
    if FRESH_RE.search(name) and not DRY_OR_DENSE_RE.search(name) and (
        calories > 140 or protein > 18 or carbs > 35 or fat > 12
    ):
        issues.append("fresh_food_density_suspicious")
    if OIL_RE.search(name_lc) and calories < 500:
        issues.append("oil_too_low_calorie")
    if LEAN_MEAT_RE.search(name) and protein > 0 and fat > protein * 1.4:
        issues.append("lean_meat_fat_suspicious")
    if sugar > carbs + 1:
        issues.append("sugar_exceeds_carbs")
    if fiber > carbs + 1 and carbs > 0:
        issues.append("fiber_exceeds_carbs")
    if calories > 0 and macro_kcal == 0 and not NEAR_ZERO_DRINK_RE.search(name):
        issues.append("calorie_without_macros")
    return issues, macro_kcal


def severity_for(issues: list[str]) -> str:
    high = {
        "calories_out_of_range",
        "protein_out_of_range",
        "carbs_out_of_range",
        "fat_out_of_range",
        "zero_calorie_macro_conflict",
        "near_zero_drink_high_calorie",
        "oil_too_low_calorie",
    }
    medium = {
        "macro_energy_mismatch",
        "fresh_food_density_suspicious",
        "sodium_out_of_range",
        "sugar_exceeds_carbs",
        "fiber_exceeds_carbs",
    }
    if any(issue in high for issue in issues):
        return "high"
    if any(issue in medium for issue in issues):
        return "medium"
    return "low"


def scan(table: str = "foods_verified_clean", batch_size: int = 20000) -> dict[str, int]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        if not table_exists(conn, table):
            raise RuntimeError(f"table not found: {table}")
        ensure_schema(conn)
        flagged_at = now_iso()
        conn.execute("DELETE FROM food_nutrition_review_flags WHERE table_name = ?", (table,))
        conn.commit()

        total = 0
        flagged = 0
        issue_counter: Counter[str] = Counter()
        cursor = conn.execute(f"SELECT * FROM {table}")
        while True:
            rows = cursor.fetchmany(batch_size)
            if not rows:
                break
            inserts = []
            for row in rows:
                total += 1
                issues, macro_kcal = issue_codes(row)
                if not issues:
                    continue
                issue_counter.update(issues)
                flagged += 1
                inserts.append((
                    str(row["id"]),
                    table,
                    str(row["name"] or ""),
                    str(row["name_zh"] or "") if "name_zh" in row.keys() else "",
                    str(row["source"] or ""),
                    f(row["calories"]),
                    f(row["protein"]),
                    f(row["carbs"]),
                    f(row["fat"]),
                    f(row["fiber"]),
                    f(row["sugar"]),
                    f(row["sodium"]),
                    round(macro_kcal, 3),
                    ",".join(issues),
                    severity_for(issues),
                    "pending",
                    flagged_at,
                ))
            if inserts:
                conn.executemany(
                    """
                    INSERT OR REPLACE INTO food_nutrition_review_flags
                        (food_id, table_name, name, name_zh, source, calories,
                         protein, carbs, fat, fiber, sugar, sodium, macro_kcal,
                         issue_codes, severity, review_status, flagged_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    inserts,
                )
                conn.commit()

        stats = {
            "scanned": total,
            "flagged": flagged,
            "high": conn.execute(
                "SELECT count(*) FROM food_nutrition_review_flags WHERE table_name=? AND severity='high'",
                (table,),
            ).fetchone()[0],
            "medium": conn.execute(
                "SELECT count(*) FROM food_nutrition_review_flags WHERE table_name=? AND severity='medium'",
                (table,),
            ).fetchone()[0],
            "low": conn.execute(
                "SELECT count(*) FROM food_nutrition_review_flags WHERE table_name=? AND severity='low'",
                (table,),
            ).fetchone()[0],
        }
        write_report(conn, table, stats, issue_counter)
        return stats
    finally:
        conn.close()


def write_report(conn: sqlite3.Connection, table: str, stats: dict[str, int], issue_counter: Counter[str]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    rows = conn.execute(
        """
        SELECT issue_codes, severity, name, name_zh, calories, protein, carbs, fat, sodium
        FROM food_nutrition_review_flags
        WHERE table_name = ?
        ORDER BY
            CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
            calories DESC
        LIMIT 20
        """,
        (table,),
    ).fetchall()

    lines = [
        "# Nutrition Issue Flags",
        "",
        f"Generated: {now_iso()}",
        f"Table: {table}",
        "",
        "## Counts",
        "",
        f"- scanned: {stats['scanned']}",
        f"- flagged: {stats['flagged']}",
        f"- high: {stats['high']}",
        f"- medium: {stats['medium']}",
        f"- low: {stats['low']}",
        "",
        "## Issue Counts",
        "",
        "| Issue | Rows |",
        "| --- | ---: |",
    ]
    lines.extend(f"| {issue} | {count} |" for issue, count in issue_counter.most_common())
    lines.extend([
        "",
        "## Sample Review Queue",
        "",
        "| Severity | Issues | Name | Chinese | kcal | P | C | F | Na |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for row in rows:
        lines.append(
            f"| {row['severity']} | {row['issue_codes']} | {row['name']} | {row['name_zh'] or ''} | "
            f"{row['calories']} | {row['protein']} | {row['carbs']} | {row['fat']} | {row['sodium']} |"
        )
    lines.extend([
        "",
        "## Policy",
        "",
        "- This only marks suspicious nutrition rows; it does not change nutrient values.",
        "- Review high severity rows first. Use source label, barcode, and official data before correction.",
    ])
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    print(scan())
