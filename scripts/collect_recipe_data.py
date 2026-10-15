"""Collect public/open recipe data with ingredients and cooking steps.

This collector stores recipe data separately from foods.db because recipe
instructions carry different licensing and attribution requirements.

Examples:
  python scripts/collect_recipe_data.py --import-markdown
  python scripts/collect_recipe_data.py --collect-themealdb
  python scripts/collect_recipe_data.py --collect-wikibooks
"""

from __future__ import annotations

import argparse
import bz2
import csv
import hashlib
import html as html_lib
import json
import re
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
RAW_DIR = DATA_DIR / "raw" / "recipes"
REPORT_DIR = DATA_DIR / "reports"
DB_PATH = DATA_DIR / "recipes.db"


@dataclass(frozen=True)
class RecipeSource:
    key: str
    label: str
    url: str
    raw_path: Path
    license_name: str
    attribution: str
    commercial_ready: bool = True


SOURCES = {
    "public_domain_recipes": RecipeSource(
        key="public_domain_recipes",
        label="Public Domain Recipes GitHub",
        url="https://github.com/ronaldl29/public-domain-recipes",
        raw_path=RAW_DIR / "git" / "public-domain-recipes",
        license_name="Unlicense / public domain dedication",
        attribution="Public Domain Recipes contributors",
    ),
    "based_cooking": RecipeSource(
        key="based_cooking",
        label="based.cooking GitHub",
        url="https://github.com/lukesmithxyz/based.cooking",
        raw_path=RAW_DIR / "git" / "based.cooking",
        license_name="Unlicense / public domain dedication",
        attribution="based.cooking contributors",
    ),
    "wikibooks_cookbook": RecipeSource(
        key="wikibooks_cookbook",
        label="Wikibooks Cookbook",
        url="https://en.wikibooks.org/wiki/Cookbook:Table_of_Contents",
        raw_path=RAW_DIR / "api" / "wikibooks_cookbook_pages.jsonl",
        license_name="Creative Commons Attribution-ShareAlike",
        attribution="Wikibooks Cookbook contributors",
    ),
    "wikibooks_cookbook_dump": RecipeSource(
        key="wikibooks_cookbook_dump",
        label="Wikibooks Cookbook XML dump",
        url="https://dumps.wikimedia.org/enwikibooks/latest/enwikibooks-latest-pages-articles.xml.bz2",
        raw_path=RAW_DIR / "api" / "enwikibooks-latest-pages-articles.xml.bz2",
        license_name="Creative Commons Attribution-ShareAlike",
        attribution="Wikibooks Cookbook contributors",
    ),
    "themealdb": RecipeSource(
        key="themealdb",
        label="TheMealDB public API",
        url="https://www.themealdb.com/api.php",
        raw_path=RAW_DIR / "api" / "themealdb_meals.jsonl",
        license_name="Public API; data license not explicit, review before commercial release",
        attribution="TheMealDB",
        commercial_ready=False,
    ),
    "open_recipe_project": RecipeSource(
        key="open_recipe_project",
        label="Open Recipe Project",
        url="https://github.com/reZach/open-recipe-project",
        raw_path=RAW_DIR / "git" / "open-recipe-project.zip",
        license_name="CC0 / public domain dedication",
        attribution="Open Recipe Project contributors",
    ),
    "myplate_kitchen": RecipeSource(
        key="myplate_kitchen",
        label="USDA MyPlate Kitchen archive",
        url="https://myplate.food/recipes",
        raw_path=RAW_DIR / "api" / "myplate_kitchen_recipes.jsonl",
        license_name="Public domain mark / U.S. federal works",
        attribution="USDA Center for Nutrition Policy and Promotion / SNAP-Ed contributors",
    ),
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stable_id(source_key: str, external_id: str) -> str:
    return hashlib.sha1(f"{source_key}:{external_id}".encode("utf-8")).hexdigest()[:16]


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_dir():
        for child in sorted(p for p in path.rglob("*") if p.is_file()):
            h.update(str(child.relative_to(path)).encode("utf-8"))
            h.update(str(child.stat().st_size).encode("ascii"))
        return h.hexdigest()
    if path.exists():
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                h.update(chunk)
    return h.hexdigest()


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_data_sources (
            key TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            url TEXT NOT NULL,
            license_name TEXT NOT NULL,
            attribution TEXT NOT NULL,
            commercial_ready INTEGER DEFAULT 1,
            raw_path TEXT,
            raw_sha256 TEXT,
            imported_count INTEGER DEFAULT 0,
            last_imported_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT DEFAULT '',
            cuisine TEXT DEFAULT '',
            category TEXT DEFAULT '',
            servings TEXT DEFAULT '',
            prep_time_minutes INTEGER,
            cook_time_minutes INTEGER,
            total_time_minutes INTEGER,
            image_url TEXT DEFAULT '',
            source_key TEXT NOT NULL,
            source_url TEXT DEFAULT '',
            source_external_id TEXT NOT NULL,
            license_name TEXT NOT NULL,
            attribution TEXT NOT NULL,
            commercial_ready INTEGER DEFAULT 1,
            raw_path TEXT DEFAULT '',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_ingredients (
            id TEXT PRIMARY KEY,
            recipe_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            text TEXT NOT NULL,
            name TEXT DEFAULT '',
            quantity TEXT DEFAULT '',
            unit TEXT DEFAULT '',
            FOREIGN KEY(recipe_id) REFERENCES recipes(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_steps (
            id TEXT PRIMARY KEY,
            recipe_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            text TEXT NOT NULL,
            FOREIGN KEY(recipe_id) REFERENCES recipes(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_tags (
            recipe_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            PRIMARY KEY(recipe_id, tag)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_nutrients (
            id TEXT PRIMARY KEY,
            recipe_id TEXT NOT NULL,
            nutrient TEXT NOT NULL,
            amount REAL,
            unit TEXT DEFAULT '',
            raw_value TEXT DEFAULT '',
            FOREIGN KEY(recipe_id) REFERENCES recipes(id)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS recipe_food_groups (
            id TEXT PRIMARY KEY,
            recipe_id TEXT NOT NULL,
            group_name TEXT NOT NULL,
            amount_text TEXT DEFAULT '',
            FOREIGN KEY(recipe_id) REFERENCES recipes(id)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recipes_title ON recipes(title)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_recipe ON recipe_ingredients(recipe_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recipe_steps_recipe ON recipe_steps(recipe_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recipe_nutrients_recipe ON recipe_nutrients(recipe_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_recipe_food_groups_recipe ON recipe_food_groups(recipe_id)")


def register_source(conn: sqlite3.Connection, source: RecipeSource, imported_count: int) -> None:
    conn.execute(
        """
        INSERT INTO recipe_data_sources
            (key, label, url, license_name, attribution, commercial_ready,
             raw_path, raw_sha256, imported_count, last_imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            label = excluded.label,
            url = excluded.url,
            license_name = excluded.license_name,
            attribution = excluded.attribution,
            commercial_ready = excluded.commercial_ready,
            raw_path = excluded.raw_path,
            raw_sha256 = excluded.raw_sha256,
            imported_count = excluded.imported_count,
            last_imported_at = excluded.last_imported_at
        """,
        (
            source.key,
            source.label,
            source.url,
            source.license_name,
            source.attribution,
            1 if source.commercial_ready else 0,
            str(source.raw_path.relative_to(ROOT)) if source.raw_path.exists() else "",
            file_sha256(source.raw_path),
            imported_count,
            now_iso(),
        ),
    )


def clean_text(text: str) -> str:
    text = html_lib.unescape(text)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[\[([^]|]+)\|([^]]+)\]\]", r"\2", text)
    text = re.sub(r"\[\[([^]]+)\]\]", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("'''", "").replace("''", "")
    text = text.replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", text).strip(" -*\t\r\n")


def clean_html_text(text: str) -> str:
    return clean_text(re.sub(r"<[^>]+>", " ", text))


def split_front_matter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    raw = text[3:end].strip()
    body = text[end + 4 :].lstrip()
    meta: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        meta[key.strip()] = value.strip().strip('"')
    return meta, body


def parse_minutes(value: str) -> int | None:
    value = value.lower()
    match = re.search(r"(\d+)", value)
    if not match:
        return None
    minutes = int(match.group(1))
    if "hour" in value or "hr" in value or "小时" in value:
        minutes *= 60
    return minutes


def parse_markdown_recipe(path: Path) -> dict[str, Any] | None:
    text = path.read_text(encoding="utf-8", errors="replace")
    meta, body = split_front_matter(text)
    title = meta.get("title", "").strip()
    if not title:
        title_match = re.search(r"^#\s+(.+)$", body, flags=re.MULTILINE)
        title = title_match.group(1).strip() if title_match else path.stem.replace("-", " ").title()
    title = clean_text(title)
    if not title:
        return None

    ingredients: list[str] = []
    steps: list[str] = []
    tags: list[str] = []
    prep: int | None = None
    cook: int | None = None
    servings = ""

    raw_tags = meta.get("tags", "")
    if raw_tags:
        tags = [clean_text(t) for t in re.split(r"[,\\[\\]'\"]+", raw_tags) if clean_text(t)]

    section = ""
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        heading = re.match(r"^#{1,4}\s+(.+)$", line)
        if heading:
            name = clean_text(heading.group(1)).lower()
            if any(word in name for word in ["ingredient", "材料", "配料"]):
                section = "ingredients"
            elif any(word in name for word in ["direction", "instruction", "method", "preparation", "procedure", "步骤", "做法"]):
                section = "steps"
            else:
                section = ""
            continue

        low = line.lower()
        if "prep time" in low:
            prep = parse_minutes(line)
        elif "cook time" in low:
            cook = parse_minutes(line)
        elif "serving" in low or "servings" in low:
            servings = clean_text(line.split(":", 1)[-1] if ":" in line else line)

        if section == "ingredients" and re.match(r"^[-*+]\s+", line):
            item = clean_text(re.sub(r"^[-*+]\s+", "", line))
            if item:
                ingredients.append(item)
        elif section == "steps" and re.match(r"^(\d+[.)]|[-*+])\s+", line):
            step = clean_text(re.sub(r"^(\d+[.)]|[-*+])\s+", "", line))
            if step:
                steps.append(step)

    if len(ingredients) < 1 or len(steps) < 1:
        return None
    return {
        "title": title,
        "description": "",
        "ingredients": ingredients,
        "steps": steps,
        "tags": tags,
        "servings": servings,
        "prep_time_minutes": prep,
        "cook_time_minutes": cook,
        "total_time_minutes": (prep or 0) + (cook or 0) if prep or cook else None,
        "source_url": "",
        "raw_path": str(path.relative_to(ROOT)),
    }


def parse_wikibooks_recipe(title: str, wikitext: str, page_id: str) -> dict[str, Any] | None:
    clean_title = title.replace("Cookbook:", "").strip()
    ingredients: list[str] = []
    steps: list[str] = []
    section = ""
    for raw_line in wikitext.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("|") or line.startswith("{|") or line.startswith("}}"):
            continue
        heading = re.match(r"^=+\s*(.+?)\s*=+$", line)
        if heading:
            name = clean_text(heading.group(1)).lower()
            if any(word in name for word in ["ingredient", "材料", "配料"]):
                section = "ingredients"
            elif any(word in name for word in ["procedure", "direction", "method", "instruction", "preparation", "步骤", "做法"]):
                section = "steps"
            else:
                section = ""
            continue
        if section == "ingredients" and re.match(r"^[*#]\s*", line):
            item = clean_text(re.sub(r"^[*#]\s*", "", line))
            if item and not item.startswith("Category:"):
                ingredients.append(item)
        elif section == "steps" and re.match(r"^[#*]\s*", line):
            step = clean_text(re.sub(r"^[#*]\s*", "", line))
            if step and not step.startswith("Category:"):
                steps.append(step)
    if len(ingredients) < 1 or len(steps) < 1:
        return None
    return {
        "title": clean_text(clean_title),
        "description": "",
        "ingredients": ingredients,
        "steps": steps,
        "tags": [],
        "servings": "",
        "prep_time_minutes": None,
        "cook_time_minutes": None,
        "total_time_minutes": None,
        "source_url": f"https://en.wikibooks.org/wiki/{urllib.parse.quote(title.replace(' ', '_'))}",
        "raw_path": f"wikibooks:{page_id}",
    }


def parse_nutrient_value(value: Any) -> tuple[float | None, str, str]:
    raw = clean_text(str(value or ""))
    if not raw:
        return None, "", ""
    match = re.search(r"-?\d+(?:\.\d+)?", raw.replace(",", ""))
    amount = float(match.group(0)) if match else None
    unit = clean_text(raw[match.end() :] if match else "")
    return amount, unit, raw


def normalize_nutrients(nutrition: Any) -> dict[str, Any]:
    if not isinstance(nutrition, dict):
        return {}
    normalized: dict[str, Any] = {}
    for key, value in nutrition.items():
        if value is None or key in {"@type"}:
            continue
        if isinstance(value, dict):
            count = value.get("count")
            unit = value.get("unit") or ""
            normalized[key] = f"{count} {unit}".strip() if count is not None else unit
        else:
            normalized[key] = value
    return normalized


def normalize_food_groups(food_groups: Any) -> list[dict[str, str]]:
    normalized: list[dict[str, str]] = []
    if not isinstance(food_groups, list):
        return normalized
    for item in food_groups:
        if isinstance(item, dict):
            name = clean_text(str(item.get("group_name") or item.get("name") or ""))
            amount = clean_text(str(item.get("amount_text") or item.get("amount") or ""))
        else:
            text = clean_text(str(item))
            if ":" in text:
                name, amount = [part.strip() for part in text.split(":", 1)]
            else:
                name, amount = text, ""
        if name:
            normalized.append({"group_name": name, "amount_text": amount})
    return normalized


def upsert_recipe(
    conn: sqlite3.Connection,
    source: RecipeSource,
    external_id: str,
    recipe: dict[str, Any],
) -> bool:
    title = clean_text(str(recipe.get("title") or ""))
    ingredients = [clean_text(str(x)) for x in recipe.get("ingredients", []) if clean_text(str(x))]
    steps = [clean_text(str(x)) for x in recipe.get("steps", []) if clean_text(str(x))]
    if not title or not ingredients or not steps:
        return False
    recipe_id = stable_id(source.key, external_id)
    conn.execute(
        """
        INSERT INTO recipes
            (id, title, description, cuisine, category, servings, prep_time_minutes,
             cook_time_minutes, total_time_minutes, image_url, source_key,
             source_url, source_external_id, license_name, attribution,
             commercial_ready, raw_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            description = excluded.description,
            cuisine = excluded.cuisine,
            category = excluded.category,
            servings = excluded.servings,
            prep_time_minutes = excluded.prep_time_minutes,
            cook_time_minutes = excluded.cook_time_minutes,
            total_time_minutes = excluded.total_time_minutes,
            image_url = excluded.image_url,
            source_url = excluded.source_url,
            license_name = excluded.license_name,
            attribution = excluded.attribution,
            commercial_ready = excluded.commercial_ready,
            raw_path = excluded.raw_path
        """,
        (
            recipe_id,
            title,
            recipe.get("description") or "",
            recipe.get("cuisine") or "",
            recipe.get("category") or "",
            recipe.get("servings") or "",
            recipe.get("prep_time_minutes"),
            recipe.get("cook_time_minutes"),
            recipe.get("total_time_minutes"),
            recipe.get("image_url") or "",
            source.key,
            recipe.get("source_url") or source.url,
            external_id,
            source.license_name,
            source.attribution,
            1 if source.commercial_ready else 0,
            recipe.get("raw_path") or "",
        ),
    )
    conn.execute("DELETE FROM recipe_ingredients WHERE recipe_id = ?", (recipe_id,))
    conn.execute("DELETE FROM recipe_steps WHERE recipe_id = ?", (recipe_id,))
    conn.execute("DELETE FROM recipe_tags WHERE recipe_id = ?", (recipe_id,))
    conn.execute("DELETE FROM recipe_nutrients WHERE recipe_id = ?", (recipe_id,))
    conn.execute("DELETE FROM recipe_food_groups WHERE recipe_id = ?", (recipe_id,))
    conn.executemany(
        "INSERT INTO recipe_ingredients (id, recipe_id, position, text) VALUES (?, ?, ?, ?)",
        [
            (stable_id(recipe_id, f"ingredient:{i}:{text}"), recipe_id, i, text)
            for i, text in enumerate(ingredients, start=1)
        ],
    )
    conn.executemany(
        "INSERT INTO recipe_steps (id, recipe_id, position, text) VALUES (?, ?, ?, ?)",
        [
            (stable_id(recipe_id, f"step:{i}:{text}"), recipe_id, i, text)
            for i, text in enumerate(steps, start=1)
        ],
    )
    tags = {clean_text(str(t)).lower() for t in recipe.get("tags", []) if clean_text(str(t))}
    if tags:
        conn.executemany(
            "INSERT OR IGNORE INTO recipe_tags (recipe_id, tag) VALUES (?, ?)",
            [(recipe_id, tag) for tag in sorted(tags)],
        )
    nutrients = normalize_nutrients(recipe.get("nutrition"))
    if nutrients:
        conn.executemany(
            """
            INSERT INTO recipe_nutrients (id, recipe_id, nutrient, amount, unit, raw_value)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    stable_id(recipe_id, f"nutrient:{name}:{raw}"),
                    recipe_id,
                    clean_text(str(name)),
                    parse_nutrient_value(raw)[0],
                    parse_nutrient_value(raw)[1],
                    parse_nutrient_value(raw)[2],
                )
                for name, raw in nutrients.items()
                if clean_text(str(name)) and parse_nutrient_value(raw)[2]
            ],
        )
    food_groups = normalize_food_groups(recipe.get("food_groups"))
    if food_groups:
        conn.executemany(
            "INSERT INTO recipe_food_groups (id, recipe_id, group_name, amount_text) VALUES (?, ?, ?, ?)",
            [
                (
                    stable_id(recipe_id, f"food_group:{i}:{item['group_name']}:{item['amount_text']}"),
                    recipe_id,
                    item["group_name"],
                    item["amount_text"],
                )
                for i, item in enumerate(food_groups, start=1)
            ],
        )
    return True


def import_markdown_source(conn: sqlite3.Connection, source_key: str) -> int:
    source = SOURCES[source_key]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}")
    imported = 0
    for path in sorted((source.raw_path / "content").glob("*.md")):
        recipe = parse_markdown_recipe(path)
        if recipe and upsert_recipe(conn, source, path.stem, recipe):
            imported += 1
    register_source(conn, source, imported)
    return imported


def fetch_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "QingKaRecipeCollector/0.1 contact=local"},
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code not in {429, 500, 502, 503, 504} or attempt == 5:
                raise
            retry_after = exc.headers.get("Retry-After")
            delay = int(retry_after) if retry_after and retry_after.isdigit() else (attempt + 1) * 10
            print(f"  API throttled ({exc.code}); waiting {delay}s")
            time.sleep(delay)
        except urllib.error.URLError:
            if attempt == 5:
                raise
            time.sleep((attempt + 1) * 5)
    raise RuntimeError("unreachable")


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "QingKaRecipeCollector/0.1 contact=local"},
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            if exc.code not in {429, 500, 502, 503, 504} or attempt == 5:
                raise
            retry_after = exc.headers.get("Retry-After")
            delay = int(retry_after) if retry_after and retry_after.isdigit() else (attempt + 1) * 10
            print(f"  HTTP throttled ({exc.code}); waiting {delay}s")
            time.sleep(delay)
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == 5:
                raise
            time.sleep((attempt + 1) * 5)
    raise RuntimeError("unreachable")


def parse_duration_minutes(value: Any) -> int | None:
    text = clean_text(str(value or ""))
    if not text:
        return None
    iso = re.fullmatch(r"P(?:T)?(?:(\d+)H)?(?:(\d+)M)?", text.upper())
    if iso:
        return int(iso.group(1) or 0) * 60 + int(iso.group(2) or 0)
    return parse_minutes(text)


def extract_json_ld_objects(html_text: str) -> list[Any]:
    objects: list[Any] = []
    scripts = re.findall(
        r"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
        html_text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    for script in scripts:
        raw = html_lib.unescape(script.strip())
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, list):
            objects.extend(payload)
        else:
            objects.append(payload)
    return objects


def jsonld_type(value: Any) -> set[str]:
    raw_type = value.get("@type") if isinstance(value, dict) else None
    if isinstance(raw_type, list):
        return {str(item) for item in raw_type}
    if raw_type:
        return {str(raw_type)}
    return set()


def find_jsonld_object(objects: list[Any], type_name: str) -> dict[str, Any] | None:
    for item in objects:
        if isinstance(item, dict) and type_name in jsonld_type(item):
            return item
    return None


def collect_themealdb(conn: sqlite3.Connection) -> int:
    source = SOURCES["themealdb"]
    source.raw_path.parent.mkdir(parents=True, exist_ok=True)
    seen: set[str] = set()
    imported = 0
    with source.raw_path.open("w", encoding="utf-8") as raw:
        for letter in "abcdefghijklmnopqrstuvwxyz":
            url = f"https://www.themealdb.com/api/json/v1/1/search.php?f={letter}"
            payload = fetch_json(url)
            for meal in payload.get("meals") or []:
                meal_id = str(meal.get("idMeal") or "")
                if not meal_id or meal_id in seen:
                    continue
                seen.add(meal_id)
                raw.write(json.dumps(meal, ensure_ascii=False) + "\n")
                ingredients = []
                for i in range(1, 21):
                    ingredient = clean_text(str(meal.get(f"strIngredient{i}") or ""))
                    measure = clean_text(str(meal.get(f"strMeasure{i}") or ""))
                    if ingredient:
                        ingredients.append(f"{measure} {ingredient}".strip())
                instructions = clean_text(str(meal.get("strInstructions") or ""))
                steps = [
                    clean_text(s)
                    for s in re.split(r"(?:\r?\n)+|(?<=[.!?])\s+(?=[A-Z])", instructions)
                    if len(clean_text(s)) > 8
                ]
                recipe = {
                    "title": meal.get("strMeal") or "",
                    "description": "",
                    "ingredients": ingredients,
                    "steps": steps,
                    "tags": [meal.get("strCategory") or "", meal.get("strArea") or ""],
                    "category": meal.get("strCategory") or "",
                    "cuisine": meal.get("strArea") or "",
                    "image_url": meal.get("strMealThumb") or "",
                    "source_url": meal.get("strSource") or source.url,
                    "raw_path": str(source.raw_path.relative_to(ROOT)),
                }
                if upsert_recipe(conn, source, meal_id, recipe):
                    imported += 1
            conn.commit()
            time.sleep(0.2)
    register_source(conn, source, imported)
    return imported


def open_recipe_minutes(value: Any) -> int | None:
    if not isinstance(value, dict):
        return None
    count = value.get("count")
    if count is None:
        return None
    try:
        minutes = int(float(count))
    except (TypeError, ValueError):
        return None
    unit = clean_text(str(value.get("time") or value.get("unit") or "minute")).lower()
    if unit.startswith("hour"):
        minutes *= 60
    return minutes


def open_recipe_ingredient_text(item: dict[str, Any], heading: str = "") -> str:
    count = item.get("count")
    unit = clean_text(str(item.get("unit") or ""))
    food = clean_text(str(item.get("food") or item.get("name") or ""))
    note = clean_text(str(item.get("note") or ""))
    parts = []
    if count is not None:
        parts.append(str(count).rstrip("0").rstrip(".") if isinstance(count, float) else str(count))
    if unit:
        parts.append(unit)
    if food:
        parts.append(food)
    text = " ".join(parts)
    if note:
        text = f"{text} ({note})" if text else note
    if heading and text:
        return f"{heading}: {text}"
    return text


def parse_open_recipe_project_json(payload: dict[str, Any], raw_path: str) -> dict[str, Any] | None:
    title = clean_text(str(payload.get("name") or ""))
    steps = [clean_text(str(step)) for step in payload.get("steps", []) if clean_text(str(step))]
    ingredients: list[str] = []
    ingredient_data = payload.get("ingredients") or {}
    if isinstance(ingredient_data, dict):
        for header in ingredient_data.get("headers") or []:
            heading = clean_text(str(header.get("name") or ""))
            for item in header.get("ingredients") or []:
                if isinstance(item, dict):
                    text = open_recipe_ingredient_text(item, heading)
                    if text:
                        ingredients.append(text)
        for item in ingredient_data.get("ungrouped") or []:
            if isinstance(item, dict):
                text = open_recipe_ingredient_text(item)
                if text:
                    ingredients.append(text)
    if not title or not ingredients or not steps:
        return None
    time_data = payload.get("time") or {}
    prep = open_recipe_minutes(time_data.get("prep"))
    cook = open_recipe_minutes(time_data.get("cook"))
    tags = []
    if payload.get("allergens"):
        tags.extend([f"allergen:{clean_text(str(x))}" for x in payload.get("allergens") if clean_text(str(x))])
    return {
        "title": title,
        "description": clean_text(str(payload.get("description") or "")),
        "ingredients": ingredients,
        "steps": steps,
        "tags": tags,
        "servings": str(payload.get("servings") or ""),
        "prep_time_minutes": prep,
        "cook_time_minutes": cook,
        "total_time_minutes": (prep or 0) + (cook or 0) if prep or cook else None,
        "nutrition": payload.get("nutrition") or {},
        "raw_path": raw_path,
    }


def import_open_recipe_project(conn: sqlite3.Connection) -> int:
    source = SOURCES["open_recipe_project"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}")
    imported = 0
    with zipfile.ZipFile(source.raw_path) as archive:
        names = sorted(name for name in archive.namelist() if name.endswith("/recipe.json"))
        for name in names:
            with archive.open(name) as handle:
                payload = json.loads(handle.read().decode("utf-8"))
            recipe = parse_open_recipe_project_json(payload, f"{source.raw_path.relative_to(ROOT)}:{name}")
            if recipe and upsert_recipe(conn, source, name, recipe):
                imported += 1
    register_source(conn, source, imported)
    return imported


def myplate_recipe_urls(index_html: str) -> list[str]:
    urls: list[str] = []
    objects = extract_json_ld_objects(index_html)
    item_list = find_jsonld_object(objects, "ItemList")
    if item_list:
        for item in item_list.get("itemListElement") or []:
            if not isinstance(item, dict):
                continue
            url = item.get("url") or item.get("item")
            if isinstance(url, dict):
                url = url.get("@id") or url.get("url")
            if isinstance(url, str) and "/recipes/" in url:
                urls.append(url)
    if not urls:
        for href in re.findall(r'href=["\'](/recipes/[^"\']+)["\']', index_html):
            urls.append(urllib.parse.urljoin("https://myplate.food", href))
    return sorted(dict.fromkeys(urls))


def parse_myplate_food_groups(html_text: str) -> list[dict[str, str]]:
    match = re.search(r"<h2>\s*Food groups\s*</h2>\s*<ul>(.*?)</ul>", html_text, flags=re.IGNORECASE | re.DOTALL)
    if not match:
        return []
    groups: list[dict[str, str]] = []
    for raw_li in re.findall(r"<li>(.*?)</li>", match.group(1), flags=re.IGNORECASE | re.DOTALL):
        text = clean_html_text(raw_li)
        if not text:
            continue
        if ":" in text:
            name, amount = [part.strip() for part in text.split(":", 1)]
        else:
            name, amount = text, ""
        groups.append({"group_name": name, "amount_text": amount})
    return groups


def parse_schema_recipe_instructions(instructions: Any) -> list[str]:
    steps: list[str] = []
    if isinstance(instructions, str):
        return [clean_text(instructions)] if clean_text(instructions) else []
    if not isinstance(instructions, list):
        return steps
    for item in instructions:
        if isinstance(item, str):
            text = clean_text(item)
            if text:
                steps.append(text)
        elif isinstance(item, dict):
            if "HowToSection" in jsonld_type(item):
                steps.extend(parse_schema_recipe_instructions(item.get("itemListElement")))
            else:
                text = clean_text(str(item.get("text") or item.get("name") or ""))
                if text:
                    steps.append(text)
    return steps


def parse_schema_recipe(
    recipe_json: dict[str, Any],
    url: str,
    html_text: str = "",
    food_groups: list[dict[str, str]] | None = None,
) -> dict[str, Any] | None:
    title = clean_text(str(recipe_json.get("name") or ""))
    ingredients = [clean_text(str(x)) for x in recipe_json.get("recipeIngredient") or [] if clean_text(str(x))]
    steps = parse_schema_recipe_instructions(recipe_json.get("recipeInstructions"))
    if not title or not ingredients or not steps:
        return None
    image = recipe_json.get("image") or ""
    if isinstance(image, list):
        image = image[0] if image else ""
    category = recipe_json.get("recipeCategory") or ""
    keywords = recipe_json.get("keywords") or ""
    tags = [clean_text(str(category))]
    if isinstance(keywords, str):
        tags.extend([clean_text(part) for part in keywords.split(",") if clean_text(part)])
    elif isinstance(keywords, list):
        tags.extend([clean_text(str(part)) for part in keywords if clean_text(str(part))])
    source_org = recipe_json.get("sourceOrganization") or {}
    if isinstance(source_org, dict) and source_org.get("name"):
        tags.append(clean_text(str(source_org.get("name"))))
    prep = parse_duration_minutes(recipe_json.get("prepTime"))
    cook = parse_duration_minutes(recipe_json.get("cookTime"))
    total = parse_duration_minutes(recipe_json.get("totalTime"))
    return {
        "title": title,
        "description": clean_text(str(recipe_json.get("description") or "")),
        "ingredients": ingredients,
        "steps": steps,
        "tags": tags,
        "servings": clean_text(str(recipe_json.get("recipeYield") or "")),
        "prep_time_minutes": prep,
        "cook_time_minutes": cook,
        "total_time_minutes": total or ((prep or 0) + (cook or 0) if prep or cook else None),
        "image_url": image if isinstance(image, str) else "",
        "category": clean_text(str(category)),
        "nutrition": recipe_json.get("nutrition") or {},
        "food_groups": food_groups if food_groups is not None else parse_myplate_food_groups(html_text),
        "source_url": clean_text(str(recipe_json.get("isBasedOn") or recipe_json.get("url") or url)),
        "raw_path": str(SOURCES["myplate_kitchen"].raw_path.relative_to(ROOT)),
    }


def read_myplate_cache(path: Path) -> dict[str, dict[str, Any]]:
    cached: dict[str, dict[str, Any]] = {}
    if not path.exists():
        return cached
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            url = record.get("url")
            if isinstance(url, str) and isinstance(record.get("recipe"), dict):
                cached[url] = record
    return cached


def collect_myplate_kitchen(conn: sqlite3.Connection, max_recipes: int | None = None) -> int:
    source = SOURCES["myplate_kitchen"]
    source.raw_path.parent.mkdir(parents=True, exist_ok=True)
    index_html = fetch_text(source.url)
    urls = myplate_recipe_urls(index_html)
    if max_recipes is not None:
        urls = urls[:max_recipes]
    cached = read_myplate_cache(source.raw_path)
    existing = {
        row[0]
        for row in conn.execute("SELECT source_external_id FROM recipes WHERE source_key = ?", (source.key,)).fetchall()
    }
    imported_this_run = 0
    skipped: list[str] = []
    with source.raw_path.open("a", encoding="utf-8") as raw:
        for i, url in enumerate(urls, start=1):
            slug = url.rstrip("/").rsplit("/", 1)[-1]
            if slug in existing:
                continue
            record = cached.get(url)
            if record:
                recipe_json = record["recipe"]
                food_groups = normalize_food_groups(record.get("food_groups"))
                recipe = parse_schema_recipe(recipe_json, url, food_groups=food_groups)
            else:
                try:
                    html_text = fetch_text(url)
                except Exception as exc:  # noqa: BLE001 - collector should continue past bad pages.
                    skipped.append(f"{url} ({type(exc).__name__})")
                    print(f"  skipped MyPlate page: {url} ({type(exc).__name__})", flush=True)
                    continue
                recipe_json = find_jsonld_object(extract_json_ld_objects(html_text), "Recipe")
                if not recipe_json:
                    skipped.append(f"{url} (missing Recipe JSON-LD)")
                    continue
                food_groups = parse_myplate_food_groups(html_text)
                raw.write(json.dumps({"url": url, "recipe": recipe_json, "food_groups": food_groups}, ensure_ascii=False) + "\n")
                recipe = parse_schema_recipe(recipe_json, url, html_text, food_groups)
            if recipe and upsert_recipe(conn, source, slug, recipe):
                existing.add(slug)
                imported_this_run += 1
            if i % 100 == 0:
                conn.commit()
                print(f"  imported MyPlate recipes total: {len(existing)}/{i}", flush=True)
            time.sleep(0.05)
    conn.commit()
    imported_total = conn.execute("SELECT COUNT(*) FROM recipes WHERE source_key = ?", (source.key,)).fetchone()[0]
    register_source(conn, source, imported_total)
    if skipped:
        skipped_path = RAW_DIR / "api" / "myplate_kitchen_skipped.txt"
        skipped_path.write_text("\n".join(skipped) + "\n", encoding="utf-8")
        print(f"  skipped pages written to: {skipped_path.relative_to(ROOT)}", flush=True)
    print(f"  imported this run: {imported_this_run}", flush=True)
    return imported_total


def wikibooks_namespace_id() -> int:
    payload = fetch_json("https://en.wikibooks.org/w/api.php?action=query&meta=siteinfo&siprop=namespaces&format=json")
    namespaces = payload.get("query", {}).get("namespaces", {})
    for key, meta in namespaces.items():
        if meta.get("*") == "Cookbook" or meta.get("canonical") == "Cookbook":
            return int(key)
    return 102


def wikibooks_all_titles(namespace_id: int) -> list[dict[str, Any]]:
    titles: list[dict[str, Any]] = []
    cont = ""
    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": str(namespace_id),
            "aplimit": "max",
            "format": "json",
        }
        if cont:
            params["apcontinue"] = cont
        payload = fetch_json("https://en.wikibooks.org/w/api.php?" + urllib.parse.urlencode(params))
        titles.extend(payload.get("query", {}).get("allpages", []))
        cont = payload.get("continue", {}).get("apcontinue", "")
        if not cont:
            break
        time.sleep(0.5)
    return titles


def wikibooks_page_contents(titles: list[str]) -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    for i in range(0, len(titles), 50):
        batch = titles[i : i + 50]
        params = {
            "action": "query",
            "prop": "revisions",
            "rvslots": "main",
            "rvprop": "content",
            "titles": "|".join(batch),
            "format": "json",
        }
        payload = fetch_json("https://en.wikibooks.org/w/api.php?" + urllib.parse.urlencode(params))
        pages.extend(payload.get("query", {}).get("pages", {}).values())
        time.sleep(0.5)
    return pages


def collect_wikibooks(conn: sqlite3.Connection, max_pages: int | None = None) -> int:
    source = SOURCES["wikibooks_cookbook"]
    source.raw_path.parent.mkdir(parents=True, exist_ok=True)
    namespace_id = wikibooks_namespace_id()
    all_pages = wikibooks_all_titles(namespace_id)
    if max_pages is not None:
        all_pages = all_pages[:max_pages]
    titles = [p["title"] for p in all_pages if str(p.get("title", "")).startswith("Cookbook:")]
    imported = 0
    with source.raw_path.open("w", encoding="utf-8") as raw:
        for page in wikibooks_page_contents(titles):
            title = page.get("title") or ""
            page_id = str(page.get("pageid") or title)
            revisions = page.get("revisions") or []
            if not revisions:
                continue
            slots = revisions[0].get("slots") or {}
            content = (slots.get("main") or {}).get("*") or revisions[0].get("*") or ""
            raw.write(json.dumps({"pageid": page_id, "title": title, "wikitext": content}, ensure_ascii=False) + "\n")
            recipe = parse_wikibooks_recipe(title, content, page_id)
            if recipe and upsert_recipe(conn, source, page_id, recipe):
                imported += 1
            if imported and imported % 250 == 0:
                conn.commit()
                print(f"  imported Wikibooks recipes: {imported}")
    conn.commit()
    register_source(conn, source, imported)
    return imported


def collect_wikibooks_dump(conn: sqlite3.Connection, max_pages: int | None = None) -> int:
    source = SOURCES["wikibooks_cookbook_dump"]
    if not source.raw_path.exists():
        raise FileNotFoundError(f"Missing {source.raw_path}")

    imported = 0
    scanned = 0
    with bz2.open(source.raw_path, "rb") as handle:
        context = ET.iterparse(handle, events=("end",))
        for _, elem in context:
            if not elem.tag.endswith("page"):
                continue
            title = ""
            page_id = ""
            wikitext = ""
            for child in elem:
                if child.tag.endswith("title"):
                    title = child.text or ""
                elif child.tag.endswith("id") and not page_id:
                    page_id = child.text or ""
                elif child.tag.endswith("revision"):
                    for rev_child in child.iter():
                        if rev_child.tag.endswith("text"):
                            wikitext = rev_child.text or ""
                            break
            if title.startswith("Cookbook:") and wikitext:
                scanned += 1
                recipe = parse_wikibooks_recipe(title, wikitext, page_id or title)
                if recipe and upsert_recipe(conn, source, page_id or title, recipe):
                    imported += 1
                    if imported % 250 == 0:
                        conn.commit()
                        print(f"  imported Wikibooks dump recipes: {imported}")
                if max_pages is not None and scanned >= max_pages:
                    elem.clear()
                    break
            elem.clear()
    conn.commit()
    register_source(conn, source, imported)
    return imported


def write_manifest() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "generated_at": now_iso(),
        "note": "Recipe instructions are licensed separately from nutrition data. Sources without explicit commercial data rights are marked commercial_ready=false.",
        "sources": [
            {
                "key": source.key,
                "label": source.label,
                "url": source.url,
                "license": source.license_name,
                "attribution": source.attribution,
                "commercial_ready": source.commercial_ready,
                "raw_path": str(source.raw_path.relative_to(ROOT)),
            }
            for source in SOURCES.values()
        ],
    }
    (DATA_DIR / "recipe_data_sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def write_report(conn: sqlite3.Connection) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    total = conn.execute("SELECT COUNT(*) FROM recipes").fetchone()[0]
    ingredients = conn.execute("SELECT COUNT(*) FROM recipe_ingredients").fetchone()[0]
    steps = conn.execute("SELECT COUNT(*) FROM recipe_steps").fetchone()[0]
    nutrients = conn.execute("SELECT COUNT(*) FROM recipe_nutrients").fetchone()[0]
    food_groups = conn.execute("SELECT COUNT(*) FROM recipe_food_groups").fetchone()[0]
    sources = conn.execute(
        "SELECT key, label, license_name, commercial_ready, imported_count, raw_path FROM recipe_data_sources ORDER BY key"
    ).fetchall()
    counts = conn.execute(
        "SELECT source_key, COUNT(*) AS count FROM recipes GROUP BY source_key ORDER BY count DESC"
    ).fetchall()
    lines = [
        "# Recipe Data Collection Report",
        "",
        f"Generated: {now_iso()}",
        f"Total recipes: {total}",
        f"Total ingredients rows: {ingredients}",
        f"Total cooking steps: {steps}",
        f"Total nutrient rows: {nutrients}",
        f"Total food-group rows: {food_groups}",
        "",
        "## Imported Sources",
        "",
        "| Source | License | Commercial ready | Imported | Raw path |",
        "| --- | --- | --- | ---: | --- |",
    ]
    for row in sources:
        ready = "yes" if row["commercial_ready"] else "needs review"
        lines.append(f"| {row['label']} | {row['license_name']} | {ready} | {row['imported_count']} | {row['raw_path']} |")
    lines.extend(["", "## Counts By Source", ""])
    for row in counts:
        lines.append(f"- {row['source_key']}: {row['count']}")
    lines.append("")
    path = REPORT_DIR / "recipe_data_collection.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--import-markdown", action="store_true", help="Import cloned markdown recipe repositories.")
    parser.add_argument("--collect-themealdb", action="store_true", help="Fetch and import TheMealDB public API.")
    parser.add_argument("--collect-wikibooks", action="store_true", help="Fetch and import Wikibooks Cookbook namespace.")
    parser.add_argument("--import-wikibooks-dump", action="store_true", help="Import downloaded Wikibooks XML dump.")
    parser.add_argument("--import-open-recipe-project", action="store_true", help="Import downloaded Open Recipe Project archive.")
    parser.add_argument("--collect-myplate", action="store_true", help="Fetch and import USDA MyPlate Kitchen archive pages.")
    parser.add_argument("--max-wikibooks", type=int, default=-1)
    parser.add_argument("--max-myplate", type=int, default=-1)
    args = parser.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    write_manifest()

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)

    if args.import_markdown:
        for key in ["public_domain_recipes", "based_cooking"]:
            print(f"Importing {key}...")
            print(f"  imported: {import_markdown_source(conn, key)}")
            conn.commit()
    if args.collect_themealdb:
        print("Collecting TheMealDB...")
        print(f"  imported: {collect_themealdb(conn)}")
        conn.commit()
    if args.collect_wikibooks:
        limit = None if args.max_wikibooks < 0 else args.max_wikibooks
        print("Collecting Wikibooks Cookbook...")
        print(f"  imported: {collect_wikibooks(conn, limit)}")
        conn.commit()
    if args.import_wikibooks_dump:
        limit = None if args.max_wikibooks < 0 else args.max_wikibooks
        print("Importing Wikibooks Cookbook dump...")
        print(f"  imported: {collect_wikibooks_dump(conn, limit)}")
        conn.commit()
    if args.import_open_recipe_project:
        print("Importing Open Recipe Project...")
        print(f"  imported: {import_open_recipe_project(conn)}")
        conn.commit()
    if args.collect_myplate:
        limit = None if args.max_myplate < 0 else args.max_myplate
        print("Collecting USDA MyPlate Kitchen archive...")
        print(f"  imported: {collect_myplate_kitchen(conn, limit)}")
        conn.commit()

    report = write_report(conn)
    conn.close()
    print(f"Report: {report.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
