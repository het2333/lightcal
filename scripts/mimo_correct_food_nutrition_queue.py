"""Use MiMo to correct rows that rule-based checks could not fix.

This consumes food_nutrition_review_queue and writes corrections into
food_nutrition_corrections. Original imported data is never overwritten.
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

import httpx

from correct_food_nutrition import DB_PATH, NUTRIENTS, build_corrected_table, write_report


ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = ROOT / "data" / "reports" / "mimo_nutrition_correction.md"


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
        if key.strip() and key.strip() not in os.environ:
            os.environ[key.strip()] = value.strip().strip('"').strip("'")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(DB_PATH))
    parser.add_argument("--limit", type=int, default=100, help="0 means all remaining rows.")
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--sleep", type=float, default=0.2)
    parser.add_argument("--no-rebuild", action="store_true")
    return parser.parse_args()


def extract_items_payload(content: str) -> dict[str, Any]:
    text = str(content or "").strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            payload, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict) and isinstance(payload.get("items"), list):
            return payload
    raise ValueError(f"No JSON object with items found: {text[:500]}")


def as_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def original_nutrition(row: sqlite3.Row) -> dict[str, float]:
    try:
        payload = json.loads(str(row["original_nutrition_json"] or "{}"))
    except json.JSONDecodeError:
        payload = {}
    return {field: as_float(payload.get(field), 0.0) for field in NUTRIENTS}


def normalize_nutrition(raw: dict[str, Any], fallback: dict[str, float]) -> dict[str, float]:
    n = {}
    for field in NUTRIENTS:
        n[field] = as_float(raw.get(field), fallback.get(field, 0.0))
    n["protein"] = clamp(n["protein"], 0, 100)
    n["carbs"] = clamp(n["carbs"], 0, 100)
    n["fat"] = clamp(n["fat"], 0, 100)
    n["fiber"] = clamp(n["fiber"], 0, 80)
    n["sugar"] = clamp(n["sugar"], 0, 100)
    n["added_sugar"] = clamp(n["added_sugar"], 0, 100)
    n["sodium"] = clamp(n["sodium"], 0, 20000)
    n["sat_fat"] = clamp(n["sat_fat"], 0, 100)
    n["trans_fat"] = clamp(n["trans_fat"], 0, 100)
    n["cholesterol"] = clamp(n["cholesterol"], 0, 10000)
    n["vitamin_a"] = max(0, n["vitamin_a"])
    n["vitamin_c"] = max(0, n["vitamin_c"])
    n["calcium"] = max(0, n["calcium"])
    n["iron"] = max(0, n["iron"])
    n["potassium"] = max(0, n["potassium"])

    macro_kcal = n["protein"] * 4 + n["carbs"] * 4 + n["fat"] * 9
    n["calories"] = clamp(n["calories"], 0, 950)
    if macro_kcal > 25 and (n["calories"] <= 0 or n["calories"] < macro_kcal * 0.35 or n["calories"] > macro_kcal * 2.8):
        n["calories"] = clamp(macro_kcal, 0, 950)
    return {field: round(float(n[field]), 4) for field in NUTRIENTS}


def mimo_correct(items: list[dict[str, Any]], client: httpx.Client) -> list[dict[str, Any]]:
    prompt = (
        "你是食品营养数据库审校器。输入每项都是每100克营养数据，可能有错误。"
        "请直接修正每100克营养，不要要求人工复核。"
        "规则：calories单位kcal；protein/carbs/fat/fiber/sugar/added_sugar/sat_fat/trans_fat单位g；"
        "sodium/cholesterol/vitamin_a/vitamin_c/calcium/iron/potassium单位mg。"
        "宏量营养需大致自洽：热量约等于蛋白*4+碳水*4+脂肪*9；包装食品可按常识略有偏差。"
        "如果钠、糖、纤维或宏量营养明显离谱，请按食物名称、来源和常识修正。"
        "不确定也要给合理估算，并降低confidence。只返回JSON对象。"
        "格式：{\"items\":[{\"id\":\"...\",\"nutrition\":{\"calories\":0,\"protein\":0,\"carbs\":0,\"fat\":0,\"fiber\":0,\"sugar\":0,\"added_sugar\":0,\"sodium\":0,\"sat_fat\":0,\"trans_fat\":0,\"cholesterol\":0,\"vitamin_a\":0,\"vitamin_c\":0,\"calcium\":0,\"iron\":0,\"potassium\":0},\"confidence\":0.72,\"note\":\"...\"}]}\n\n"
        f"输入：{json.dumps(items, ensure_ascii=False)}"
    )
    auth_header = os.getenv("MIMO_AUTH_HEADER", "api-key").strip().lower()
    if auth_header in {"authorization", "bearer"}:
        headers = {"Authorization": f"Bearer {os.environ['MIMO_API_KEY']}"}
    else:
        headers = {"api-key": os.environ["MIMO_API_KEY"]}
    response = client.post(
        os.getenv("MIMO_BASE_URL", "https://api.xiaomimimo.com/v1").rstrip("/") + "/chat/completions",
        headers={**headers, "Content-Type": "application/json"},
        json={
            "model": os.getenv("MIMO_MODEL", "mimo-v2.5"),
            "messages": [
                {"role": "system", "content": "你是只输出JSON的营养数据修正接口。禁止输出思考过程、解释和Markdown。"},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0,
        "max_completion_tokens": max(4096, min(8192, len(items) * 280)),
            "response_format": {"type": "json_object"},
            "thinking": {"type": "disabled"},
        },
    )
    response.raise_for_status()
    data = response.json()
    message = data["choices"][0].get("message") or {}
    content = message.get("content") or message.get("reasoning_content") or ""
    if isinstance(content, list):
        content = "\n".join(str(item.get("text") or "") for item in content if isinstance(item, dict))
    payload = extract_items_payload(str(content))
    return payload.get("items", [])


def correct_batch(provider_items: list[dict[str, Any]], client: httpx.Client) -> dict[str, dict[str, Any]]:
    if not provider_items:
        return {}
    last_error = ""
    for attempt in range(2):
        try:
            rows = mimo_correct(provider_items, client)
            found: dict[str, dict[str, Any]] = {}
            for row in rows:
                item_id = str(row.get("id") or "")
                nutrition = row.get("nutrition") if isinstance(row.get("nutrition"), dict) else {}
                if item_id and nutrition:
                    found[item_id] = row
            if len(found) == len(provider_items):
                return found
            last_error = f"incomplete response {len(found)}/{len(provider_items)}"
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {str(exc)[:180]}"
        time.sleep(0.8 * (attempt + 1))

    if len(provider_items) == 1:
        print(f"mimo nutrition skipped: {provider_items[0]['name'][:80]} ({last_error})", flush=True)
        return {}
    midpoint = max(1, len(provider_items) // 2)
    print(f"mimo nutrition retry split {len(provider_items)} -> {midpoint}+{len(provider_items) - midpoint} ({last_error})", flush=True)
    result = correct_batch(provider_items[:midpoint], client)
    result.update(correct_batch(provider_items[midpoint:], client))
    return result


def select_queue(conn: sqlite3.Connection, limit: int) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT q.*, i.serving_size, i.processing_level, i.barcode
        FROM food_nutrition_review_queue q
        LEFT JOIN food_accuracy_issues i ON i.id = q.food_id
        ORDER BY q.rowid
        LIMIT ?
        """,
        (limit,),
    ).fetchall()


def write_corrections(conn: sqlite3.Connection, rows: list[sqlite3.Row], corrections: dict[str, dict[str, Any]]) -> int:
    corrected_at = now_iso()
    correction_rows = []
    delete_ids = []
    for row in rows:
        food_id = str(row["food_id"])
        result = corrections.get(food_id)
        if not result:
            continue
        fallback = original_nutrition(row)
        raw_nutrition = result.get("nutrition") if isinstance(result.get("nutrition"), dict) else {}
        nutrition = normalize_nutrition(raw_nutrition, fallback)
        confidence = clamp(as_float(result.get("confidence"), 0.62), 0.35, 0.95)
        note = str(result.get("note") or "MiMo按名称、异常原因和营养常识自动修正")[:240]
        correction_rows.append((
            food_id,
            str(row["name"] or ""),
            str(row["normalized_name"] or ""),
            str(row["source"] or ""),
            str(row["issue_reason"] or "mimo_review"),
            str(row["original_nutrition_json"] or "{}"),
            json.dumps(nutrition, ensure_ascii=False, sort_keys=True),
            "mimo_nutrition_correction",
            confidence,
            note,
            corrected_at,
        ))
        delete_ids.append((food_id,))
    if not correction_rows:
        return 0
    conn.executemany(
        """
        INSERT OR REPLACE INTO food_nutrition_corrections
            (food_id, name, normalized_name, source, issue_reason,
             original_nutrition_json, corrected_nutrition_json,
             correction_method, correction_confidence, correction_note, corrected_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        correction_rows,
    )
    conn.executemany("DELETE FROM food_nutrition_review_queue WHERE food_id = ?", delete_ids)
    conn.commit()
    return len(correction_rows)


def write_mimo_report(conn: sqlite3.Connection, stats: dict[str, int]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# MiMo Nutrition Corrections",
        "",
        f"Generated: {now_iso()}",
        "",
        f"- processed: {stats['processed']}",
        f"- corrected: {stats['corrected']}",
        f"- remaining_review_queue: {stats['remaining']}",
        "",
        "MiMo corrections are stored as correction_method=mimo_nutrition_correction.",
    ]
    REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    load_dotenv()
    args = parse_args()
    if not os.getenv("MIMO_API_KEY"):
        raise RuntimeError("MIMO_API_KEY is required")
    conn = sqlite3.connect(args.db, timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=60000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    timeout = float(os.getenv("MIMO_TIMEOUT_SECONDS", "120") or 120)
    client = httpx.Client(timeout=timeout, trust_env=False)
    remaining_limit = args.limit if args.limit > 0 else None
    stats = {"processed": 0, "corrected": 0, "remaining": 0}
    try:
        while remaining_limit is None or remaining_limit > 0:
            take = max(1, min(args.batch_size, remaining_limit if remaining_limit is not None else args.batch_size))
            rows = select_queue(conn, take)
            if not rows:
                break
            provider_items = []
            for row in rows:
                provider_items.append({
                    "id": str(row["food_id"]),
                    "name": str(row["name"] or ""),
                    "source": str(row["source"] or ""),
                    "issue_reason": str(row["issue_reason"] or ""),
                    "serving_size": str(row["serving_size"] or "100g") if "serving_size" in row.keys() else "100g",
                    "processing_level": str(row["processing_level"] or "") if "processing_level" in row.keys() else "",
                    "nutrition": original_nutrition(row),
                })
            corrections = correct_batch(provider_items, client)
            written = write_corrections(conn, rows, corrections)
            stats["processed"] += len(rows)
            stats["corrected"] += written
            if remaining_limit is not None:
                remaining_limit -= len(rows)
            stats["remaining"] = conn.execute("SELECT count(*) FROM food_nutrition_review_queue").fetchone()[0]
            print(
                f"mimo_nutrition: processed={stats['processed']} corrected={stats['corrected']} remaining={stats['remaining']}",
                flush=True,
            )
            if args.sleep > 0:
                time.sleep(args.sleep)

        if not args.no_rebuild:
            conn.execute("DROP TABLE IF EXISTS foods_corrected_clean")
            build_corrected_table(conn)
            report_stats = {
                "issue_rows_scanned": conn.execute("SELECT count(*) FROM food_accuracy_issues").fetchone()[0],
                "auto_corrected_rows": conn.execute("SELECT count(*) FROM food_nutrition_corrections").fetchone()[0],
                "review_queue_rows": conn.execute("SELECT count(*) FROM food_nutrition_review_queue").fetchone()[0],
                "foods_corrected_clean": conn.execute("SELECT count(*) FROM foods_corrected_clean").fetchone()[0],
            }
            write_report(conn, report_stats)
        stats["remaining"] = conn.execute("SELECT count(*) FROM food_nutrition_review_queue").fetchone()[0]
        write_mimo_report(conn, stats)
        print(json.dumps(stats, ensure_ascii=False, indent=2))
    finally:
        client.close()
        conn.close()


if __name__ == "__main__":
    main()
