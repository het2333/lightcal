#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent.parent
RECIPES_DB = ROOT / "data" / "recipes.db"

PUNCT_RE = re.compile(r"[#&~【】\[\]{}^♥『』]")
CJK_RE = re.compile(r"[\u4e00-\u9fff]")

DIRTY_KEYWORDS = [
    "味蕾上的",
    "宿舍",
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
    "图片",
    "借图",
    "好吃",
    "超好吃",
    "太香",
    "舔盘",
    "下饭又营养",
    "赶紧学",
    "快手",
    "懒人",
    "简单速成",
    "零失败",
    "宝宝辅食",
    "辅食",
    "仪式感",
    "每日健康午餐",
    "day",
    "Day",
    "早餐夜宵均可",
    "生日快乐",
    "无油万岁",
    "万岁",
    "家庭版",
    "小烤箱",
    "减肥版",
    "少油版",
    "电饭煲",
    "微波炉",
    "压面机版",
    "烤箱版",
]

EXACT_DIRTY_TITLES = {
    "空气炸鸡翅&薯条",
    "味蕾上的宿舍~",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean_title(value: str) -> str:
    return re.sub(r"\s+", "", str(value or "").strip())


def dirty_reasons(title: str) -> list[str]:
    title = clean_title(title)
    reasons: list[str] = []
    if not title:
        return ["empty"]
    if title in EXACT_DIRTY_TITLES:
        reasons.append("exact_dirty_title")
    if PUNCT_RE.search(title):
        reasons.append("dirty_punctuation")
    for keyword in DIRTY_KEYWORDS:
        if keyword in title:
            reasons.append(f"keyword:{keyword}")
    if len(title) > 18 and ("，" in title or "," in title or "-" in title or "—" in title):
        reasons.append("sentence_like_long_title")
    return reasons


def ensure_audit_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS deleted_dirty_recipe_titles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            rowid_value INTEGER NOT NULL,
            source_id TEXT DEFAULT '',
            title TEXT NOT NULL,
            reasons_json TEXT NOT NULL,
            row_json TEXT NOT NULL,
            deleted_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_deleted_dirty_recipe_titles_table ON deleted_dirty_recipe_titles(table_name)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_deleted_dirty_recipe_titles_title ON deleted_dirty_recipe_titles(title)"
    )


def iter_table_rows(conn: sqlite3.Connection, table: str, title_col: str, source_col: str) -> Iterable[sqlite3.Row]:
    return conn.execute(f"SELECT rowid AS rowid_value, * FROM {table} WHERE COALESCE({title_col}, '') <> ''")


def delete_dirty_from_table(
    conn: sqlite3.Connection,
    table: str,
    title_col: str,
    source_col: str,
    dry_run: bool,
    batch_size: int,
) -> dict[str, int]:
    deleted_at = now_iso()
    scanned = 0
    matched = 0
    audit_rows: list[tuple[str, int, str, str, str, str, str]] = []
    delete_rowids: list[tuple[int]] = []

    for row in iter_table_rows(conn, table, title_col, source_col):
        scanned += 1
        title = str(row[title_col] or "")
        reasons = dirty_reasons(title)
        if not reasons:
            continue
        matched += 1
        source_id = str(row[source_col] or "") if source_col in row.keys() else ""
        compact_row = {
            "rowid_value": int(row["rowid_value"]),
            "source_id": source_id,
            "title": title,
        }
        for optional_key in ("source_key", "source_path", "source_url", "source_external_id"):
            if optional_key in row.keys():
                compact_row[optional_key] = row[optional_key]
        audit_rows.append(
            (
                table,
                int(row["rowid_value"]),
                source_id,
                title,
                json.dumps(reasons, ensure_ascii=False, separators=(",", ":")),
                json.dumps(compact_row, ensure_ascii=False, default=str, separators=(",", ":")),
                deleted_at,
            )
        )
        delete_rowids.append((int(row["rowid_value"]),))
        if len(delete_rowids) >= batch_size:
            if not dry_run:
                conn.executemany(
                    """
                    INSERT INTO deleted_dirty_recipe_titles
                        (table_name, rowid_value, source_id, title, reasons_json, row_json, deleted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
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
            INSERT INTO deleted_dirty_recipe_titles
                (table_name, rowid_value, source_id, title, reasons_json, row_json, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            audit_rows,
        )
        conn.executemany(f"DELETE FROM {table} WHERE rowid = ?", delete_rowids)
        conn.commit()

    return {"scanned": scanned, "matched": matched}


def cleanup_duplicate_groups(conn: sqlite3.Connection) -> int:
    if not conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='recipe_duplicate_title_groups'"
    ).fetchone():
        return 0
    rows = conn.execute("SELECT rowid, normalized_title FROM recipe_duplicate_title_groups").fetchall()
    rowids = [(int(row["rowid"]),) for row in rows if dirty_reasons(str(row["normalized_title"] or ""))]
    if rowids:
        conn.executemany("DELETE FROM recipe_duplicate_title_groups WHERE rowid = ?", rowids)
        conn.commit()
    return len(rowids)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=RECIPES_DB)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--batch-size", type=int, default=5000)
    args = parser.parse_args()

    conn = sqlite3.connect(args.db, timeout=120)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    ensure_audit_table(conn)

    specs = [
        ("recipes", "title", "id"),
        ("recipes_clean", "title", "id"),
        ("recipe_training_examples_clean", "recipe_title", "source_row_id"),
    ]
    stats: dict[str, dict[str, int]] = {}
    for table, title_col, source_col in specs:
        if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
            continue
        stats[table] = delete_dirty_from_table(conn, table, title_col, source_col, args.dry_run, args.batch_size)
        print(json.dumps({"table": table, **stats[table], "dry_run": args.dry_run}, ensure_ascii=False), flush=True)

    duplicate_groups_deleted = 0 if args.dry_run else cleanup_duplicate_groups(conn)
    audit_count = conn.execute("SELECT count(*) FROM deleted_dirty_recipe_titles").fetchone()[0]
    conn.close()
    print(
        json.dumps(
            {
                "dry_run": args.dry_run,
                "stats": stats,
                "duplicate_groups_deleted": duplicate_groups_deleted,
                "audit_rows_total": audit_count,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
