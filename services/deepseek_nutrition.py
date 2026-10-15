"""Validated DeepSeek fallback for missing or unusable nutrition rows."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


COMPLEX_DISH_TOKENS = ("麻辣烫", "麻辣拌", "冒菜", "火锅", "麻辣香锅", "关东煮")
ALLOWED_CATEGORIES = {
    "staple", "protein", "vegetable", "mixed_dish", "soup", "drink",
    "sauce", "dessert", "snack", "fruit", "other",
}


def nutrition_lookup_needs_generation(name: str, lookup: dict[str, Any] | None) -> bool:
    if not lookup:
        return True
    if str(lookup.get("source") or "").startswith("deepseek_estimate"):
        return False
    text = str(name or "").strip()
    ingredient_count = int(lookup.get("ingredient_count") or 0)
    source = str(lookup.get("row_source") or "")
    return (
        any(token in text for token in COMPLEX_DISH_TOKENS)
        and source.startswith("ta_da_dishes_ingredients")
        and ingredient_count < 3
    )


def validate_generated_nutrition(raw: dict[str, Any], fallback_name: str) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None

    def number(key: str, default: float = 0.0) -> float:
        try:
            return float(raw.get(key, default))
        except (TypeError, ValueError):
            return default

    values = {
        "kcal100": number("kcal100"),
        "p100": number("p100"),
        "c100": number("c100"),
        "f100": number("f100"),
        "fi100": number("fi100"),
        "na100": number("na100"),
        "density_g_per_ml": number("density_g_per_ml"),
    }
    if not 5 <= values["kcal100"] <= 900:
        return None
    if any(not 0 <= values[key] <= 100 for key in ("p100", "c100", "f100", "fi100")):
        return None
    if values["p100"] + values["c100"] + values["f100"] > 115:
        return None
    if not 0 <= values["na100"] <= 8000:
        return None
    if not 0.2 <= values["density_g_per_ml"] <= 1.3:
        return None
    if any(token in fallback_name for token in COMPLEX_DISH_TOKENS):
        values["density_g_per_ml"] = max(0.55, min(values["density_g_per_ml"], 0.95))

    macro_kcal = values["p100"] * 4 + values["c100"] * 4 + values["f100"] * 9
    if abs(macro_kcal - values["kcal100"]) > max(60.0, values["kcal100"] * 0.4):
        return None

    fallback_has_cjk = bool(re.search(r"[\u3400-\u9fff]", fallback_name))
    canonical = fallback_name if fallback_has_cjk else str(raw.get("canonical_name") or fallback_name).strip()
    canonical = canonical or fallback_name
    display = str(raw.get("display_name") or canonical).strip() or canonical
    category = str(raw.get("category") or "other").strip().lower()
    if category not in ALLOWED_CATEGORIES:
        category = "other"
    aliases = [str(value).strip() for value in (raw.get("aliases") or []) if str(value).strip()]
    aliases = list(dict.fromkeys([fallback_name, display, canonical, *aliases]))[:12]
    confidence = min(0.72, max(0.35, number("confidence", 0.58)))
    return {
        "canonical_name": canonical,
        "display_name": display,
        "category": category,
        **{key: round(value, 2) for key, value in values.items()},
        "confidence": round(confidence, 3),
        "aliases": aliases,
        "assumptions": str(raw.get("assumptions") or "").strip()[:500],
        "source": "deepseek_estimate_v1",
    }


class DeepSeekNutritionFallback:
    def __init__(
        self,
        db_path: str,
        api_key: str = "",
        api_key_file: str = "",
        api_url: str = "https://api.deepseek.com/chat/completions",
        model: str = "deepseek-chat",
        timeout_seconds: float = 30.0,
    ) -> None:
        self.db_path = str(db_path or "")
        self.api_key = str(api_key or "").strip()
        self.api_key_file = str(api_key_file or "").strip()
        self.api_url = api_url
        self.model = model
        self.timeout_seconds = timeout_seconds

    def _resolved_key(self) -> str:
        if self.api_key:
            return self.api_key
        if not self.api_key_file:
            return ""
        try:
            return Path(self.api_key_file).read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def available(self) -> bool:
        return bool(self.db_path and Path(self.db_path).exists() and self._resolved_key())

    def generate_and_store(self, name: str, category_hint: str = "") -> dict[str, Any] | None:
        name = str(name or "").strip()
        key = self._resolved_key()
        if not name or not key:
            return None
        prompt = (
            "请为中国常见食物生成一条可用于热量估算的严格 JSON 数据。\n"
            f"食物名：{name}\n类别提示：{category_hint or '未知'}\n"
            "字段：canonical_name, display_name, category, kcal100, p100, c100, f100, "
            "fi100, na100, density_g_per_ml, confidence, aliases, assumptions。\n"
            "所有营养值按可食部分每100克；na100单位毫克；密度单位g/ml。"
            "麻辣烫/火锅类按照片 mask 中可见的捞出固体食材平均值估算，不把大量汤底计入。"
            "这类固体应按蔬菜、豆制品、丸滑肉类和面/粉的综合平均，不要用清汤或单一蔬菜的低热量值。"
            "若原名是中文，canonical_name 必须保留该中文名。"
            "不要输出 Markdown，不要输出区间，只输出一个 JSON 对象。"
        )
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": "你是严谨的营养数据标注器，必须输出合理且自洽的 JSON。"},
                {"role": "user", "content": prompt},
            ],
            "response_format": {"type": "json_object"},
            "temperature": 0.1,
            "max_tokens": 600,
        }
        request = urllib.request.Request(
            self.api_url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = json.loads(response.read().decode("utf-8"))
            content = body["choices"][0]["message"]["content"]
            content = re.sub(r"^```(?:json)?\s*|\s*```$", "", str(content).strip(), flags=re.IGNORECASE)
            record = validate_generated_nutrition(json.loads(content), name)
            if record is None:
                return None
            self._store(name, record, content)
            return {
                "canonical_name": record["canonical_name"],
                "category": record["category"],
                "density_g_per_ml": record["density_g_per_ml"],
                "nutrition_per_100g": {
                    "calories": record["kcal100"],
                    "protein_g": record["p100"],
                    "carbs_g": record["c100"],
                    "fat_g": record["f100"],
                    "fiber_g": record["fi100"],
                    "sodium_mg": record["na100"],
                },
                "source": record["source"],
                "ingredient_count": 0,
                "row_source": record["source"],
                "confidence": record["confidence"],
            }
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, urllib.error.URLError):
            return None

    def _store(self, query_name: str, record: dict[str, Any], raw_response: str) -> None:
        conn = sqlite3.connect(self.db_path, timeout=20)
        try:
            conn.execute(
                """CREATE TABLE IF NOT EXISTS ai_nutrition_generation_v1 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    query_name TEXT NOT NULL,
                    canonical_name TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    validated_json TEXT NOT NULL,
                    raw_response TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )"""
            )
            canonical = record["canonical_name"]
            if record["category"] in {"mixed_dish", "soup"}:
                conn.execute(
                    """INSERT INTO dish_lookup_v1
                    (canonical_dish, display_name, normalized_name, category, kcal100, p100, c100, f100,
                     fi100, na100, density_g_per_ml, source, recipe_count, ingredient_count,
                     matched_ingredient_count, total_grams, matched_grams, confidence, flags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, ?, ?)
                    ON CONFLICT(canonical_dish) DO UPDATE SET
                      display_name=excluded.display_name, normalized_name=excluded.normalized_name,
                      category=excluded.category, kcal100=excluded.kcal100, p100=excluded.p100,
                      c100=excluded.c100, f100=excluded.f100, fi100=excluded.fi100,
                      na100=excluded.na100, density_g_per_ml=excluded.density_g_per_ml,
                      source=excluded.source, confidence=excluded.confidence, flags=excluded.flags""",
                    (
                        canonical, record["display_name"], canonical.lower(), record["category"],
                        record["kcal100"], record["p100"], record["c100"], record["f100"],
                        record["fi100"], record["na100"], record["density_g_per_ml"], record["source"],
                        record["confidence"], json.dumps({"assumptions": record["assumptions"]}, ensure_ascii=False),
                    ),
                )
                for alias in record["aliases"]:
                    conn.execute(
                        """INSERT INTO dish_alias_v1(alias, normalized_alias, canonical_dish, confidence, match_type)
                        VALUES (?, ?, ?, ?, 'deepseek_generated_alias')
                        ON CONFLICT(alias) DO UPDATE SET canonical_dish=excluded.canonical_dish,
                          normalized_alias=excluded.normalized_alias, confidence=excluded.confidence,
                          match_type=excluded.match_type""",
                        (alias, alias.lower(), canonical, record["confidence"]),
                    )
            else:
                conn.execute(
                    """INSERT INTO nutrition_lookup_v1
                    (canonical_name, display_name, normalized_name, category, kcal100, p100, c100, f100,
                     fi100, na100, density_g_per_ml, source, source_table, source_count, confidence, flags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'deepseek_api', 1, ?, ?)
                    ON CONFLICT(canonical_name) DO UPDATE SET
                      display_name=excluded.display_name, normalized_name=excluded.normalized_name,
                      category=excluded.category, kcal100=excluded.kcal100, p100=excluded.p100,
                      c100=excluded.c100, f100=excluded.f100, fi100=excluded.fi100,
                      na100=excluded.na100, density_g_per_ml=excluded.density_g_per_ml,
                      source=excluded.source, source_table=excluded.source_table,
                      confidence=excluded.confidence, flags=excluded.flags""",
                    (
                        canonical, record["display_name"], canonical.lower(), record["category"],
                        record["kcal100"], record["p100"], record["c100"], record["f100"],
                        record["fi100"], record["na100"], record["density_g_per_ml"], record["source"],
                        record["confidence"], json.dumps({"assumptions": record["assumptions"]}, ensure_ascii=False),
                    ),
                )
                for alias in record["aliases"]:
                    conn.execute(
                        """INSERT INTO nutrition_alias_v1(alias, normalized_alias, canonical_name, match_type, confidence)
                        VALUES (?, ?, ?, 'deepseek_generated_alias', ?)
                        ON CONFLICT(alias) DO UPDATE SET canonical_name=excluded.canonical_name,
                          normalized_alias=excluded.normalized_alias, match_type=excluded.match_type,
                          confidence=excluded.confidence""",
                        (alias, alias.lower(), canonical, record["confidence"]),
                    )
            conn.execute(
                """INSERT INTO ai_nutrition_generation_v1
                (query_name, canonical_name, provider, model, validated_json, raw_response)
                VALUES (?, ?, 'deepseek', ?, ?, ?)""",
                (query_name, canonical, self.model, json.dumps(record, ensure_ascii=False), raw_response),
            )
            conn.commit()
        finally:
            conn.close()
