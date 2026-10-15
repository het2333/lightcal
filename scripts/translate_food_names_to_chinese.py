"""Translate food names to Simplified Chinese without overwriting source names.

The script is resumable. It stores translations in food_name_translations and
also writes name_zh onto selected user-facing food tables when the column exists
or can be added.

Usage examples:
  python scripts/translate_food_names_to_chinese.py --provider local --limit 0
  python scripts/translate_food_names_to_chinese.py --provider deepseek --limit 5000 --batch-size 80
  python scripts/translate_food_names_to_chinese.py --provider mimo --limit 5000 --batch-size 80

Use --limit 0 to process all remaining rows. API translation for millions
of rows can take a long time and has API cost, so run it as a background job.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "foods.db"
REPORT_PATH = ROOT / "data" / "reports" / "food_name_translation.md"
CJK_RE = re.compile(r"[\u3400-\u9fff]")
MEANINGFUL_RE = re.compile(r"[A-Za-z0-9\u3400-\u9fff]")
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


def is_non_retryable_provider_error(exc: Exception) -> bool:
    response = getattr(exc, "response", None)
    status_code = getattr(response, "status_code", None)
    return status_code in {401, 402, 403}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_dotenv() -> None:
    env_path = ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key and key not in os.environ:
            os.environ[key] = value.strip().strip('"').strip("'")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(DB_PATH))
    parser.add_argument(
        "--tables",
        default="foods_verified_clean,foods_clean,foods_merged_clean,foods",
        help="Comma-separated table names to translate.",
    )
    parser.add_argument("--provider", choices=["local", "deepseek", "mimo"], default="local")
    parser.add_argument("--limit", type=int, default=10000, help="0 means no limit.")
    parser.add_argument("--batch-size", type=int, default=80)
    parser.add_argument("--sleep", type=float, default=0.2)
    return parser.parse_args()


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    return bool(conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone())


def column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    return any(row[1] == column for row in conn.execute(f'PRAGMA table_info("{table}")'))


def ensure_schema(conn: sqlite3.Connection, tables: list[str]) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_name_translations (
            source_table TEXT NOT NULL,
            source_id TEXT NOT NULL,
            original_name TEXT NOT NULL,
            name_zh TEXT NOT NULL,
            status TEXT NOT NULL,
            method TEXT NOT NULL,
            needs_review INTEGER DEFAULT 0,
            correction_note TEXT DEFAULT '',
            updated_at TEXT NOT NULL,
            PRIMARY KEY (source_table, source_id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_name_translation_cache (
            original_name TEXT PRIMARY KEY,
            name_zh TEXT NOT NULL,
            status TEXT NOT NULL,
            method TEXT NOT NULL,
            needs_review INTEGER DEFAULT 0,
            correction_note TEXT DEFAULT '',
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS food_name_translation_issues (
            source_table TEXT NOT NULL,
            source_id TEXT NOT NULL,
            original_name TEXT NOT NULL,
            issue_status TEXT NOT NULL,
            issue_note TEXT DEFAULT '',
            method TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (source_table, source_id, issue_status)
        )
        """
    )
    for table_name in ["food_name_translations", "food_name_translation_cache"]:
        if not column_exists(conn, table_name, "needs_review"):
            conn.execute(f'ALTER TABLE "{table_name}" ADD COLUMN needs_review INTEGER DEFAULT 0')
        if not column_exists(conn, table_name, "correction_note"):
            conn.execute(f'ALTER TABLE "{table_name}" ADD COLUMN correction_note TEXT DEFAULT ""')
    for table in tables:
        if table_exists(conn, table) and not column_exists(conn, table, "name_zh"):
            conn.execute(f'ALTER TABLE "{table}" ADD COLUMN name_zh TEXT DEFAULT ""')
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_food_name_translations_zh ON food_name_translations(name_zh)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_food_name_translation_cache_zh ON food_name_translation_cache(name_zh)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_food_name_translation_issues_status ON food_name_translation_issues(issue_status)"
    )
    conn.commit()


def source_id(row: sqlite3.Row) -> str:
    value = row["id"] if "id" in row.keys() else None
    return str(value or row["rowid"])


def local_translate(name: str) -> tuple[str, str] | None:
    text = re.sub(r"\s+", " ", (name or "").strip())
    if not text:
        return None
    if CJK_RE.search(text):
        return text, "already_chinese"
    if text in LOCALIZED_FOOD_NAMES:
        return LOCALIZED_FOOD_NAMES[text], "local_exact"
    return None


def invalid_source_name(name: str) -> bool:
    text = re.sub(r"\s+", " ", (name or "").strip())
    if not text:
        return True
    if text in {"...", "…", "-", "--", "n/a", "N/A", "null", "NULL", "unknown", "Unknown"}:
        return True
    return not bool(MEANINGFUL_RE.search(text))


def clean_translation(value: str) -> str:
    text = re.sub(r"\s+", " ", (value or "").strip())
    text = text.replace('""', '"').replace("''", "'")
    text = text.strip("。；;，,")
    if text in {"...", "…", "中文名", "简体中文名", "译名", "翻译"}:
        return ""
    return text[:160]


def review_translation(original_name: str, name_zh: str, status: str, method: str) -> tuple[str, str, str, int, str]:
    original = re.sub(r"\s+", " ", (original_name or "").strip())
    translated = clean_translation(name_zh)
    if invalid_source_name(original):
        return "", "invalid_source_name", method, 1, "源名称为空、占位或无有效字符"
    if not translated:
        return "", "pending", method, 1, "模型未返回可用中文名"

    note_parts: list[str] = []
    needs_review = 0
    if any(marker in translated for marker in ["首先", "用户", "规则", "JSON", "items数组", "解释"]):
        return "", "model_output_invalid", method, 1, "模型返回了解释或结构文本"
    if not CJK_RE.search(translated):
        needs_review = 1
        note_parts.append("中文名不含汉字，可能只是品牌/专有名词")
    if len(translated) > 120:
        needs_review = 1
        note_parts.append("中文名过长")
    if translated == original and not CJK_RE.search(original):
        needs_review = 1
        note_parts.append("外文名称未明显翻译")
    if translated != name_zh:
        note_parts.append("已清理引号/空白/占位符")
    return translated, status, method, needs_review, "；".join(note_parts)


def extract_items_payload(content: str) -> dict[str, Any]:
    text = str(content or "").strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char not in "{[":
            continue
        try:
            payload, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(payload, list):
            return {"items": payload}
        if isinstance(payload, dict) and isinstance(payload.get("items"), list):
            return payload
    raise ValueError(f"No JSON items found: {text[:500]}")


def deepseek_translate(names: list[str], client: Any) -> list[str]:
    indexed = [{"i": index, "name": name} for index, name in enumerate(names)]
    prompt = (
        "你是食品数据库名称翻译器。把食品/品牌商品名称翻译成简体中文。"
        "翻译时同时纠正明显名称问题：重复引号、乱码空白、大小写杂乱、OCR小错、口味/品类表达不自然。"
        "要求：保留品牌名或专有名词；只改食品名，不改营养；不要添加营养、克重、解释；无法确定时直译；"
        "只返回JSON，字段为items数组，每项包含原 i 和 zh。\n\n"
        f"输入：{json.dumps(indexed, ensure_ascii=False)}"
    )
    request_json = {
        "model": os.getenv("DEEPSEEK_MODEL", "deepseek-v4-flash"),
        "messages": [
            {"role": "system", "content": "只输出合法 JSON。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "max_tokens": max(512, min(4096, len(names) * 40)),
    }
    thinking = os.getenv("DEEPSEEK_THINKING", "disabled").strip().lower()
    if thinking in {"enabled", "disabled"}:
        request_json["thinking"] = {"type": thinking}

    response = client.post(
        os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/").removesuffix("/v1") + "/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}",
            "Content-Type": "application/json",
        },
        json=request_json,
    )
    response.raise_for_status()
    data = response.json()
    content = data["choices"][0]["message"]["content"]
    payload = extract_items_payload(content)
    results = [""] * len(names)
    for item in payload.get("items", []):
        try:
            index = int(item.get("i"))
        except (TypeError, ValueError):
            continue
        if 0 <= index < len(results):
            results[index] = clean_translation(str(item.get("zh") or item.get("name") or ""))
    return results


def mimo_translate(names: list[str], client: Any) -> list[str]:
    indexed = [{"i": index, "name": name} for index, name in enumerate(names)]
    prompt = (
        "不要输出思考过程，不要解释，不要复述规则。"
        "你是食品数据库名称翻译器。把食品/品牌商品名称翻译成简体中文。"
        "翻译时同时纠正明显名称问题：重复引号、乱码空白、大小写杂乱、OCR小错、口味/品类表达不自然。"
        "保留品牌名、系列名和专有名词；只翻译食品品类、口味、处理方式；"
        "只改食品名，不改营养；不要添加营养、克重、解释；不确定就直译。"
        "只返回一个JSON对象，字段为items数组，每项包含原 i 和 zh。\n\n"
        f"输入：{json.dumps(indexed, ensure_ascii=False)}"
    )
    request_json = {
        "model": os.getenv("MIMO_MODEL", "mimo-v2.5"),
        "messages": [
            {"role": "system", "content": "你是只输出JSON的翻译接口。禁止输出思考过程、解释和Markdown。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "max_completion_tokens": max(2048, min(4096, len(names) * 45)),
        "response_format": {"type": "json_object"},
        "thinking": {"type": "disabled"},
    }
    auth_header = os.getenv("MIMO_AUTH_HEADER", "api-key").strip().lower()
    if auth_header in {"authorization", "bearer"}:
        headers = {"Authorization": f"Bearer {os.environ['MIMO_API_KEY']}"}
    else:
        headers = {"api-key": os.environ["MIMO_API_KEY"]}
    response = client.post(
        os.getenv("MIMO_BASE_URL", "https://api.xiaomimimo.com/v1").rstrip("/") + "/chat/completions",
        headers={**headers, "Content-Type": "application/json"},
        json=request_json,
    )
    response.raise_for_status()
    data = response.json()
    message = data["choices"][0].get("message") or {}
    content = message.get("content") or message.get("reasoning_content") or ""
    if isinstance(content, list):
        content = "\n".join(str(item.get("text") or "") for item in content if isinstance(item, dict))
    if not str(content).strip():
        raise RuntimeError(f"MiMo returned empty content: {json.dumps(data, ensure_ascii=False)[:500]}")
    payload = extract_items_payload(content)
    results = [""] * len(names)
    for item in payload.get("items", []):
        try:
            index = int(item.get("i"))
        except (TypeError, ValueError):
            continue
        if 0 <= index < len(results):
            results[index] = clean_translation(str(item.get("zh") or item.get("name") or ""))
    return results


def api_translate_names(provider: str, names: list[str], client: Any, depth: int = 0) -> list[str]:
    if not names:
        return []
    last_error = ""
    for attempt in range(2):
        try:
            values = (
                deepseek_translate(names, client)
                if provider == "deepseek"
                else mimo_translate(names, client)
            )
            values = [clean_translation(value) for value in values]
            if len(values) == len(names) and all(values):
                return values
            last_error = f"incomplete response {sum(1 for value in values if value)}/{len(names)}"
        except Exception as exc:
            if is_non_retryable_provider_error(exc):
                raise RuntimeError(
                    f"{provider} API is unavailable: HTTP {exc.response.status_code}"
                ) from exc
            last_error = f"{type(exc).__name__}: {str(exc)[:180]}"
        time.sleep(min(3.0, 0.8 * (attempt + 1)))

    if len(names) == 1:
        print(f"translation skipped: {names[0][:80]} ({last_error})", flush=True)
        return [""]

    midpoint = max(1, len(names) // 2)
    print(f"translation retry split {len(names)} -> {midpoint}+{len(names) - midpoint} ({last_error})", flush=True)
    return (
        api_translate_names(provider, names[:midpoint], client, depth + 1)
        + api_translate_names(provider, names[midpoint:], client, depth + 1)
    )


def cached_translations(conn: sqlite3.Connection, names: list[str]) -> dict[str, sqlite3.Row]:
    unique = [name for name in dict.fromkeys(names) if name]
    found: dict[str, str] = {}
    for index in range(0, len(unique), 500):
        batch = unique[index:index + 500]
        placeholders = ",".join(["?"] * len(batch))
        rows = conn.execute(
            f"""
            SELECT *
            FROM food_name_translation_cache
            WHERE original_name IN ({placeholders})
            """,
            batch,
        ).fetchall()
        found.update({str(row["original_name"]): row for row in rows})
    return found


def select_rows(conn: sqlite3.Connection, table: str, batch_size: int, after_rowid: int) -> list[sqlite3.Row]:
    return conn.execute(
        f"""
        SELECT rowid, id, name
        FROM "{table}"
        WHERE coalesce(name, '') != ''
          AND (name_zh IS NULL OR trim(name_zh) = '')
          AND rowid > ?
          AND NOT EXISTS (
              SELECT 1
              FROM food_name_translation_issues i
              WHERE i.source_table = ?
                AND i.source_id = CAST("{table}".id AS TEXT)
                AND i.issue_status = 'invalid_source_name'
          )
        ORDER BY rowid
        LIMIT ?
        """,
        (after_rowid, table, batch_size),
    ).fetchall()


def write_translations(
    conn: sqlite3.Connection,
    table: str,
    rows: list[sqlite3.Row],
    translations: list[tuple[str, str, str, int, str]],
) -> int:
    updated_at = now_iso()
    update_rows = []
    translation_rows = []
    cache_rows = []
    issue_rows = []
    for row, (name_zh, status, method, needs_review, correction_note) in zip(rows, translations):
        name_zh = clean_translation(name_zh)
        sid = source_id(row)
        if not name_zh:
            if status not in {"pending"} or needs_review:
                issue_rows.append((table, sid, str(row["name"]), status, correction_note, method, updated_at))
            continue
        update_rows.append((name_zh, row["rowid"]))
        translation_rows.append((table, sid, str(row["name"]), name_zh, status, method, needs_review, correction_note, updated_at))
        if method != "cache":
            cache_rows.append((str(row["name"]), name_zh, status, method, needs_review, correction_note, updated_at))
    if not update_rows and not issue_rows:
        return 0
    if update_rows:
        conn.executemany(f'UPDATE "{table}" SET name_zh = ? WHERE rowid = ?', update_rows)
    if translation_rows:
        conn.executemany(
            """
            INSERT INTO food_name_translations
                (source_table, source_id, original_name, name_zh, status, method,
                 needs_review, correction_note, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_table, source_id) DO UPDATE SET
                original_name = excluded.original_name,
                name_zh = excluded.name_zh,
                status = excluded.status,
                method = excluded.method,
                needs_review = excluded.needs_review,
                correction_note = excluded.correction_note,
                updated_at = excluded.updated_at
            """,
            translation_rows,
        )
    if cache_rows:
        conn.executemany(
            """
            INSERT INTO food_name_translation_cache
                (original_name, name_zh, status, method, needs_review, correction_note, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(original_name) DO UPDATE SET
                name_zh = excluded.name_zh,
                status = excluded.status,
                method = excluded.method,
                needs_review = excluded.needs_review,
                correction_note = excluded.correction_note,
                updated_at = excluded.updated_at
            """,
            cache_rows,
        )
    if issue_rows:
        conn.executemany(
            """
            INSERT INTO food_name_translation_issues
                (source_table, source_id, original_name, issue_status, issue_note, method, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_table, source_id, issue_status) DO UPDATE SET
                original_name = excluded.original_name,
                issue_note = excluded.issue_note,
                method = excluded.method,
                updated_at = excluded.updated_at
            """,
            issue_rows,
        )
    conn.commit()
    return len(update_rows)


def process_table(
    conn: sqlite3.Connection,
    table: str,
    provider: str,
    limit: int,
    batch_size: int,
    sleep_seconds: float,
) -> dict[str, int]:
    stats = {"processed": 0, "translated": 0, "local": 0, "cache": 0, "api": 0, "skipped": 0}
    remaining = limit if limit > 0 else None
    client: Any | None = None
    if provider in {"deepseek", "mimo"}:
        import httpx

        if provider == "deepseek" and not os.getenv("DEEPSEEK_API_KEY"):
            raise RuntimeError("DEEPSEEK_API_KEY is required for --provider deepseek")
        if provider == "mimo" and not os.getenv("MIMO_API_KEY"):
            raise RuntimeError("MIMO_API_KEY is required for --provider mimo")
        timeout = float(os.getenv("MIMO_TIMEOUT_SECONDS", os.getenv("DEEPSEEK_TIMEOUT_SECONDS", "90")) or 90)
        client = httpx.Client(timeout=timeout, trust_env=False)

    try:
        last_rowid = 0
        while remaining is None or remaining > 0:
            take = batch_size if remaining is None else min(batch_size, remaining)
            rows = select_rows(conn, table, take, last_rowid)
            if not rows:
                break
            last_rowid = int(rows[-1]["rowid"])
            translations: list[tuple[str, str, str, int, str] | None] = []
            cached = cached_translations(conn, [str(row["name"]) for row in rows])
            api_rows: list[sqlite3.Row] = []
            api_names: list[str] = []
            for row in rows:
                raw_name = str(row["name"])
                if invalid_source_name(raw_name):
                    translations.append(("", "invalid_source_name", "local", 1, "源名称为空、占位或无有效字符"))
                    stats["skipped"] += 1
                    continue
                if raw_name in cached:
                    cached_row = cached[raw_name]
                    translations.append((
                        str(cached_row["name_zh"]),
                        "translated",
                        "cache",
                        int(cached_row["needs_review"] or 0) if "needs_review" in cached_row.keys() else 0,
                        str(cached_row["correction_note"] or "") if "correction_note" in cached_row.keys() else "",
                    ))
                    stats["cache"] += 1
                    continue
                local = local_translate(raw_name)
                if local:
                    translations.append(review_translation(raw_name, local[0], local[1], "local"))
                    stats["local"] += 1
                elif provider in {"deepseek", "mimo"}:
                    translations.append(None)
                    api_rows.append(row)
                    api_names.append(raw_name)
                else:
                    translations.append(None)
                    stats["skipped"] += 1

            if api_names and client:
                zh_values = api_translate_names(provider, api_names, client)
                api_iter = iter(zip(api_rows, zh_values))
                api_by_rowid = {row["rowid"]: zh for row, zh in api_iter}
                for index, row in enumerate(rows):
                    if translations[index] is None:
                        zh = api_by_rowid.get(row["rowid"], "")
                        if zh:
                            translations[index] = review_translation(str(row["name"]), zh, "translated", provider)
                            stats["api"] += 1
                        else:
                            stats["skipped"] += 1
                if sleep_seconds > 0:
                    time.sleep(sleep_seconds)

            writeable = [
                item if item is not None else ("", "pending", provider, 1, "模型未返回可用中文名")
                for item in translations
            ]
            updated = write_translations(conn, table, rows, writeable)
            stats["translated"] += updated
            stats["processed"] += len(rows)
            if remaining is not None:
                remaining -= len(rows)
            print(f"{table}: processed={stats['processed']} translated={stats['translated']}", flush=True)
    finally:
        if client:
            client.close()
    return stats


def write_report(results: dict[str, dict[str, int]]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# 食品名称中文翻译",
        "",
        f"生成时间：{now_iso()}",
        "",
        "| Table | Processed | Translated | Local | Cache | API | Skipped |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for table, stats in results.items():
        lines.append(
            f"| {table} | {stats['processed']} | {stats['translated']} | "
            f"{stats['local']} | {stats.get('cache', 0)} | {stats['api']} | {stats['skipped']} |"
        )
    lines.extend([
        "",
        "## 说明",
        "",
        "- 原始 name 字段不覆盖，中文展示名写入 name_zh。",
        "- food_name_translations 保存翻译来源和状态，支持继续跑批和人工复核。",
        "- local 只处理已有中文名和少量内置精确映射；外文全量翻译可使用 --provider mimo 或 --provider deepseek 分批运行。",
    ])
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    load_dotenv()
    args = parse_args()
    tables = [table.strip() for table in args.tables.split(",") if table.strip()]
    conn = sqlite3.connect(args.db, timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=60000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    try:
        existing_tables = [table for table in tables if table_exists(conn, table)]
        ensure_schema(conn, existing_tables)
        results = {}
        for table in existing_tables:
            results[table] = process_table(
                conn,
                table=table,
                provider=args.provider,
                limit=args.limit,
                batch_size=max(1, min(200, args.batch_size)),
                sleep_seconds=args.sleep,
            )
        write_report(results)
        print(json.dumps(results, ensure_ascii=False, indent=2))
    finally:
        conn.close()


if __name__ == "__main__":
    main()
