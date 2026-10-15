#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
FOODS_DB = ROOT / "data" / "foods.db"

DIRTY_KEYWORDS = [
    "翻译后的名称",
    "好吃到",
    "真好吃",
    "好好吃",
    "孔老师",
    "大厨教",
    "教你",
    "教程",
    "做法",
    "怎么做",
    "如何做",
    "菜谱",
    "食谱",
    "步骤",
    "视频",
    "合集",
    "大全",
    "宝宝辅食",
    "辅食",
    "味蕾上的",
    "宿舍",
    "空气炸鸡翅",
    "无油万岁",
]

BAD_SYMBOL_RE = re.compile(r"^[#＃]+")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def dirty_reasons_for_value(value: Any) -> list[str]:
    text = normalize(value)
    if not text:
        return []
    reasons: list[str] = []
    if BAD_SYMBOL_RE.search(text):
        reasons.append("starts_with_hash")
    if text in {"####*", "#", "＃"}:
        reasons.append("symbol_junk")
    for keyword in DIRTY_KEYWORDS:
        if keyword in text:
            reasons.append(f"keyword:{keyword}")
    return reasons


def ensure_audit_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS deleted_dirty_food_names (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            rowid_value INTEGER NOT NULL,
            source_id TEXT DEFAULT '',
            name TEXT DEFAULT '',
            name_zh TEXT DEFAULT '',
            reasons_json TEXT NOT NULL,
            row_json TEXT NOT NULL,
            deleted_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_deleted_dirty_food_names_table ON deleted_dirty_food_names(table_name)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_deleted_dirty_food_names_name ON deleted_dirty_food_names(name)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_deleted_dirty_food_names_name_zh ON deleted_dirty_food_names(name_zh)")


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})")}


def existing_tables(conn: sqlite3.Connection) -> set[str]:
    return {
        str(row[0])
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }


def dirty_reasons(row: sqlite3.Row, columns: set[str]) -> list[str]:
    reasons: list[str] = []
    for col in ("name", "name_zh", "normalized_name"):
        if col not in columns:
            continue
        for reason in dirty_reasons_for_value(row[col]):
            reasons.append(f"{col}:{reason}")
    return reasons


def delete_dirty_from_table(
    conn: sqlite3.Connection,
    table: str,
    dry_run: bool,
    batch_size: int,
) -> dict[str, int]:
    columns = table_columns(conn, table)
    if "name" not in columns and "name_zh" not in columns and "normalized_name" not in columns:
        return {"scanned": 0, "matched": 0}
    select_cols = ["rowid AS rowid_value", "*"]
    cursor = conn.execute(f"SELECT {', '.join(select_cols)} FROM {table}")
    scanned = 0
    matched = 0
    deleted_at = now_iso()
    audit_rows: list[tuple[str, int, str, str, str, str, str, str]] = []
    delete_rowids: list[tuple[int]] = []

    for row in cursor:
        scanned += 1
        reasons = dirty_reasons(row, columns)
        if not reasons:
            continue
        matched += 1
        rowid = int(row["rowid_value"])
        source_id = normalize(row["id"]) if "id" in columns else ""
        name = normalize(row["name"]) if "name" in columns else ""
        name_zh = normalize(row["name_zh"]) if "name_zh" in columns else ""
        compact = {
            "rowid_value": rowid,
            "id": source_id,
            "name": name,
            "name_zh": name_zh,
        }
        for optional_key in ("source", "barcode", "quality_status", "quality_tier"):
            if optional_key in columns:
                compact[optional_key] = row[optional_key]
        audit_rows.append(
            (
                table,
                rowid,
                source_id,
                name,
                name_zh,
                json.dumps(reasons, ensure_ascii=False, separators=(",", ":")),
                json.dumps(compact, ensure_ascii=False, default=str, separators=(",", ":")),
                deleted_at,
            )
        )
        delete_rowids.append((rowid,))
        if len(delete_rowids) >= batch_size:
            if not dry_run:
                conn.executemany(
                    """
                    INSERT INTO deleted_dirty_food_names
                        (table_name, rowid_value, source_id, name, name_zh, reasons_json, row_json, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    audit_rows,
                )
                conn.executemany(f"DELETE FROM {table} WHERE rowid = ?", delete_rowids)
                conn.commit()
            audit_rows.clear()
            delete_rowids.clear()

    if delete_rowids and not dry_run:
        conn.executemany(
            """
            INSERT INTO deleted_dirty_food_names
                (table_name, rowid_value, source_id, name, name_zh, reasons_json, row_json, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            audit_rows,
        )
        conn.executemany(f"DELETE FROM {table} WHERE rowid = ?", delete_rowids)
        conn.commit()

    return {"scanned": scanned, "matched": matched}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=FOODS_DB)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--batch-size", type=int, default=5000)
    parser.add_argument(
        "--tables",
        nargs="*",
        default=[
            "foods",
            "foods_clean",
            "foods_merged_clean",
            "foods_verified_clean",
            "foods_corrected_clean",
        ],
    )
    args = parser.parse_args()

    conn = sqlite3.connect(args.db, timeout=120)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=120000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    ensure_audit_table(conn)

    present = existing_tables(conn)
    stats: dict[str, dict[str, int]] = {}
    for table in args.tables:
        if table not in present:
            continue
        stats[table] = delete_dirty_from_table(conn, table, args.dry_run, args.batch_size)
        print(json.dumps({"table": table, **stats[table], "dry_run": args.dry_run}, ensure_ascii=False), flush=True)

    audit_count = conn.execute("SELECT count(*) FROM deleted_dirty_food_names").fetchone()[0]
    conn.close()
    print(json.dumps({"dry_run": args.dry_run, "stats": stats, "audit_rows_total": audit_count}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
