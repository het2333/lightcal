"""Clean, deduplicate, and standardize imported food/recipe datasets.

Raw imported tables are preserved for traceability. This script creates clean
tables that downstream training or app code can use directly.
"""

from __future__ import annotations

import ast
import hashlib
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
FOODS_DB = ROOT / "data" / "foods.db"
RECIPES_DB = ROOT / "data" / "recipes.db"
REPORT_DIR = ROOT / "data" / "reports"

CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
SPACE_RE = re.compile(r"[ \t\r\f\v]+")
TRAILING_RECIPE_PROMPT_RE = re.compile(
    r"(?:的做法|怎么做|如何做|怎样做|制作方法|菜谱|食谱)\s*[？?。!！]*$"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize_text(value: str) -> str:
    value = CONTROL_RE.sub("", value or "")
    value = value.replace("\u3000", " ")
    value = SPACE_RE.sub(" ", value)
    lines = [line.strip() for line in value.splitlines()]
    return "\n".join(line for line in lines if line).strip()


def normalize_title(value: str) -> str:
    value = normalize_text(value).strip("\"'“”‘’ ")
    value = TRAILING_RECIPE_PROMPT_RE.sub("", value)
    return value.strip("\"'“”‘’ -_")


def normalize_item(value: Any) -> str:
    return normalize_text(str(value)).strip(" ,，;；")


def find_python_list(text: str, start: int = 0) -> tuple[str, int] | None:
    list_start = text.find("[", start)
    if list_start < 0:
        return None

    quote: str | None = None
    escaped = False
    depth = 0
    for index in range(list_start, len(text)):
        char = text[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {"'", '"'}:
            quote = char
            continue
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return text[list_start : index + 1], index + 1
    return None


def parse_python_list(block: str) -> list[str]:
    parsed = ast.literal_eval(block)
    if not isinstance(parsed, list):
        raise ValueError("不是列表")
    return [item for item in (normalize_item(item) for item in parsed) if item]


def parse_training_output(output: str) -> tuple[list[str], list[str]]:
    first = find_python_list(output, 0)
    if not first:
        raise ValueError("未找到食材列表")
    ingredients = parse_python_list(first[0])

    second = find_python_list(output, first[1])
    if not second:
        raise ValueError("未找到步骤列表")
    steps = parse_python_list(second[0])

    if not ingredients:
        raise ValueError("食材列表为空")
    if not steps:
        raise ValueError("步骤列表为空")
    return ingredients, steps


def content_hash(recipe_title: str, ingredients: list[str], steps: list[str]) -> str:
    payload = {
        "recipe_title": recipe_title,
        "ingredients": ingredients,
        "steps": steps,
    }
    data = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def clean_training_conversations(conn: sqlite3.Connection, batch_size: int = 5000) -> dict[str, int]:
    conn.executescript(
        """
        DROP TABLE IF EXISTS recipe_training_examples_clean;
        DROP TABLE IF EXISTS recipe_training_examples_rejected;

        CREATE TABLE recipe_training_examples_clean (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_row_id INTEGER NOT NULL,
            recipe_title TEXT NOT NULL,
            ingredients_json TEXT NOT NULL,
            steps_json TEXT NOT NULL,
            ingredients_count INTEGER NOT NULL,
            steps_count INTEGER NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            source_key TEXT NOT NULL,
            source_path TEXT NOT NULL,
            cleaned_at TEXT NOT NULL
        );

        CREATE TABLE recipe_training_examples_rejected (
            source_row_id INTEGER PRIMARY KEY,
            reason TEXT NOT NULL,
            user_input TEXT DEFAULT '',
            assistant_output_preview TEXT DEFAULT '',
            source_key TEXT NOT NULL,
            cleaned_at TEXT NOT NULL
        );
        """
    )

    total = 0
    valid = 0
    rejected = 0
    cleaned_at = now_iso()
    clean_rows: list[tuple[Any, ...]] = []
    rejected_rows: list[tuple[Any, ...]] = []

    cursor = conn.execute(
        """
        SELECT id, user_input, assistant_output, source_key, source_path
        FROM recipe_training_conversations
        ORDER BY id
        """
    )
    while True:
        rows = cursor.fetchmany(batch_size)
        if not rows:
            break
        for row_id, user_input, assistant_output, source_key, source_path in rows:
            total += 1
            try:
                recipe_title = normalize_title(user_input)
                if not recipe_title:
                    raise ValueError("菜名为空")
                ingredients, steps = parse_training_output(assistant_output)
                digest = content_hash(recipe_title, ingredients, steps)
                clean_rows.append(
                    (
                        row_id,
                        recipe_title,
                        json.dumps(ingredients, ensure_ascii=False, separators=(",", ":")),
                        json.dumps(steps, ensure_ascii=False, separators=(",", ":")),
                        len(ingredients),
                        len(steps),
                        digest,
                        source_key,
                        source_path,
                        cleaned_at,
                    )
                )
                valid += 1
            except Exception as exc:  # noqa: BLE001 - keep a reject audit trail.
                rejected_rows.append(
                    (
                        row_id,
                        str(exc)[:200],
                        normalize_text(user_input)[:500],
                        normalize_text(assistant_output)[:1000],
                        source_key,
                        cleaned_at,
                    )
                )
                rejected += 1

        if clean_rows:
            conn.executemany(
                """
                INSERT OR IGNORE INTO recipe_training_examples_clean
                    (source_row_id, recipe_title, ingredients_json, steps_json,
                     ingredients_count, steps_count, content_hash, source_key,
                     source_path, cleaned_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                clean_rows,
            )
            clean_rows.clear()
        if rejected_rows:
            conn.executemany(
                """
                INSERT INTO recipe_training_examples_rejected
                    (source_row_id, reason, user_input, assistant_output_preview,
                     source_key, cleaned_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                rejected_rows,
            )
            rejected_rows.clear()
        conn.commit()
        if total % 100000 == 0:
            print(f"recipe_training_conversations cleaned: {total}", flush=True)

    conn.executescript(
        """
        CREATE INDEX idx_training_clean_title
            ON recipe_training_examples_clean(recipe_title);
        CREATE INDEX idx_training_clean_source_row
            ON recipe_training_examples_clean(source_row_id);
        """
    )
    clean_count = conn.execute("SELECT count(*) FROM recipe_training_examples_clean").fetchone()[0]
    return {
        "training_raw_rows": total,
        "training_valid_rows": valid,
        "training_clean_rows": clean_count,
        "training_duplicate_rows_removed": valid - clean_count,
        "training_rejected_rows": rejected,
    }


def clean_foods(conn: sqlite3.Connection) -> dict[str, int]:
    conn.executescript(
        """
        DROP TABLE IF EXISTS foods_clean;
        DROP TABLE IF EXISTS food_duplicate_groups;

        CREATE TEMP TABLE food_keep_rowids AS
        SELECT min(rowid) AS keep_rowid, count(*) AS duplicate_count
        FROM foods
        GROUP BY
            lower(trim(name)),
            coalesce(serving_size, ''),
            coalesce(source, ''),
            coalesce(calories, -999999999),
            coalesce(protein, -999999999),
            coalesce(carbs, -999999999),
            coalesce(fat, -999999999),
            coalesce(fiber, -999999999),
            coalesce(sugar, -999999999),
            coalesce(added_sugar, -999999999),
            coalesce(sodium, -999999999),
            coalesce(sat_fat, -999999999),
            coalesce(trans_fat, -999999999),
            coalesce(cholesterol, -999999999),
            coalesce(vitamin_a, -999999999),
            coalesce(vitamin_c, -999999999),
            coalesce(calcium, -999999999),
            coalesce(iron, -999999999),
            coalesce(potassium, -999999999);

        CREATE TABLE foods_clean AS
        SELECT f.*,
               lower(trim(f.name)) AS normalized_name
        FROM foods f
        JOIN food_keep_rowids k ON f.rowid = k.keep_rowid;

        CREATE TABLE food_duplicate_groups AS
        SELECT
            lower(trim(name)) AS normalized_name,
            coalesce(serving_size, '') AS serving_size,
            coalesce(source, '') AS source,
            coalesce(calories, -999999999) AS calories,
            coalesce(protein, -999999999) AS protein,
            coalesce(carbs, -999999999) AS carbs,
            coalesce(fat, -999999999) AS fat,
            count(*) AS duplicate_count,
            min(id) AS kept_or_first_food_id
        FROM foods
        GROUP BY
            lower(trim(name)),
            coalesce(serving_size, ''),
            coalesce(source, ''),
            coalesce(calories, -999999999),
            coalesce(protein, -999999999),
            coalesce(carbs, -999999999),
            coalesce(fat, -999999999),
            coalesce(fiber, -999999999),
            coalesce(sugar, -999999999),
            coalesce(added_sugar, -999999999),
            coalesce(sodium, -999999999),
            coalesce(sat_fat, -999999999),
            coalesce(trans_fat, -999999999),
            coalesce(cholesterol, -999999999),
            coalesce(vitamin_a, -999999999),
            coalesce(vitamin_c, -999999999),
            coalesce(calcium, -999999999),
            coalesce(iron, -999999999),
            coalesce(potassium, -999999999)
        HAVING count(*) > 1;

        CREATE INDEX idx_foods_clean_name ON foods_clean(normalized_name);
        CREATE INDEX idx_food_duplicate_groups_name ON food_duplicate_groups(normalized_name);
        DROP TABLE food_keep_rowids;
        """
    )
    raw = conn.execute("SELECT count(*) FROM foods").fetchone()[0]
    clean = conn.execute("SELECT count(*) FROM foods_clean").fetchone()[0]
    groups = conn.execute("SELECT count(*) FROM food_duplicate_groups").fetchone()[0]
    return {
        "food_raw_rows": raw,
        "food_clean_rows": clean,
        "food_duplicate_rows_removed": raw - clean,
        "food_duplicate_groups": groups,
    }


def build_recipe_clean_indexes(conn: sqlite3.Connection) -> dict[str, int]:
    conn.executescript(
        """
        DROP TABLE IF EXISTS recipes_clean;
        DROP TABLE IF EXISTS recipe_duplicate_title_groups;

        CREATE TABLE recipes_clean AS
        SELECT r.*,
               lower(trim(r.title)) AS normalized_title
        FROM recipes r;

        CREATE TABLE recipe_duplicate_title_groups AS
        SELECT
            source_key,
            lower(trim(title)) AS normalized_title,
            count(*) AS recipe_count,
            min(id) AS first_recipe_id
        FROM recipes
        GROUP BY source_key, lower(trim(title))
        HAVING count(*) > 1;

        CREATE INDEX idx_recipes_clean_title ON recipes_clean(normalized_title);
        CREATE INDEX idx_recipe_duplicate_title_groups_title
            ON recipe_duplicate_title_groups(source_key, normalized_title);
        """
    )
    raw = conn.execute("SELECT count(*) FROM recipes").fetchone()[0]
    clean = conn.execute("SELECT count(*) FROM recipes_clean").fetchone()[0]
    title_groups = conn.execute("SELECT count(*) FROM recipe_duplicate_title_groups").fetchone()[0]
    title_extra_rows = conn.execute(
        "SELECT coalesce(sum(recipe_count - 1), 0) FROM recipe_duplicate_title_groups"
    ).fetchone()[0]
    return {
        "recipe_raw_rows": raw,
        "recipe_clean_rows": clean,
        "recipe_duplicate_title_groups": title_groups,
        "recipe_duplicate_title_extra_rows": title_extra_rows,
    }


def write_report(food_stats: dict[str, int], recipe_stats: dict[str, int]) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# 数据清洗与标准化",
        "",
        f"生成时间：{now_iso()}",
        "",
        "## 食品数据",
        "",
    ]
    for key, value in food_stats.items():
        lines.append(f"- {key}: {value}")
    lines.extend(["", "## 菜谱与训练数据", ""])
    for key, value in recipe_stats.items():
        lines.append(f"- {key}: {value}")
    lines.extend(
        [
            "",
            "## 新增标准表",
            "",
            "- foods.db: foods_clean, food_duplicate_groups",
            "- recipes.db: recipes_clean, recipe_duplicate_title_groups",
            "- recipes.db: recipe_training_examples_clean, recipe_training_examples_rejected",
            "",
            "## 说明",
            "",
            "- 原始导入表未删除，便于追溯来源。",
            "- recipe_training_examples_clean 去掉了 system prompt、自然语言模板和原始 assistant 长文本，只保留菜名、食材列表、步骤列表和来源行号。",
            "- foods_clean 按名称、来源、份量和营养数值的精确签名去重，避免误合并同名但营养不同的食品。",
            "- recipes_clean 先做标准标题字段；同名菜谱只登记到 recipe_duplicate_title_groups，未强行删除，因为同名菜谱可能是不同做法。",
            "",
        ]
    )
    path = REPORT_DIR / "data_cleaning_standardization.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    food_conn = sqlite3.connect(FOODS_DB)
    food_conn.execute("PRAGMA journal_mode=WAL")
    food_conn.execute("PRAGMA synchronous=NORMAL")
    print("Cleaning foods...", flush=True)
    food_stats = clean_foods(food_conn)
    food_conn.commit()
    food_conn.close()

    recipe_conn = sqlite3.connect(RECIPES_DB)
    recipe_conn.execute("PRAGMA journal_mode=WAL")
    recipe_conn.execute("PRAGMA synchronous=NORMAL")
    print("Standardizing recipes...", flush=True)
    recipe_stats = build_recipe_clean_indexes(recipe_conn)
    print("Cleaning training conversations...", flush=True)
    recipe_stats.update(clean_training_conversations(recipe_conn))
    recipe_conn.commit()
    recipe_conn.close()

    report = write_report(food_stats, recipe_stats)
    print(json.dumps({**food_stats, **recipe_stats}, ensure_ascii=False, indent=2))
    print(f"Report: {report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
