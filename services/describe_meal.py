"""LLM-based food analysis service — the core describeMeal pipeline.

Pipeline:
  Image/Text → LLM Provider (智谱/DeepSeek/Gemini) → JSON → Food list

Supports multiple LLM backends via LLMProvider abstraction.
"""

import asyncio
import hashlib
import json
import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Any, Optional

from models.food import Food, DescribeMealRequest, DescribeMealResponse, ScanSource
from services.open_food_facts import OpenFoodFactsService
from models.health import HealthScore, ArtificialScore, NetCarbsScore, AddedSugarScore
from services.health_scorer import HealthScorer
from services.food_database import (
    FoodDatabase,
    NUTRIENT_FIELDS as DATABASE_NUTRIENT_FIELDS,
    _display_food_name,
    _display_serving_size,
)
from services.llm_providers import DeepSeekProvider, LLMProvider
from services.depth_cloud_pipeline import DepthCloudPipelineClient
from services.depth_nutrition import calculate_item_nutrition, estimate_weight_from_volume


PROMPT_DIR = Path(__file__).parent.parent / "prompts"
PHOTO_DETECTION_PROMPT = (PROMPT_DIR / "food_photo_detection.txt").read_text(encoding="utf-8")
PHOTO_NUTRITION_REVIEW_PROMPT = (PROMPT_DIR / "food_photo_nutrition_review.txt").read_text(encoding="utf-8")
PHOTO_DIRECT_NUTRITION_PROMPT = (PROMPT_DIR / "food_photo_direct_nutrition.txt").read_text(encoding="utf-8")
PHOTO_FAST_DETECTION_PROMPT = (PROMPT_DIR / "food_photo_fast_detection.txt").read_text(encoding="utf-8")
PHOTO_DETECTION_USER_PROMPT = (
    "直接识别图片中的可见食物，并输出食物名、克重、可见数量描述、烹饪方式、置信度。"
    "如果没有深度数据，必须按单目图片估重：用餐具/容器尺度、2D面积占比、可见数量、形态体积和常见份量模板估算。"
    "禁止输出任何营养数字。只返回 food_photo_detection.txt 要求的严格 JSON。"
)
PHOTO_DIRECT_NUTRITION_USER_PROMPT = (
    "直接识别图片中的可见食物，并输出食物名、克重、可见数量描述、烹饪方式、置信度、"
    "卡路里、蛋白质、碳水、脂肪、膳食纤维、钠。"
    "拼盘要逐项检查并拆出，不要用“等”省略明显可见的不同小食。"
    "同一堆同一种食物不要用近义名称反复输出。"
    "如果没有深度数据，必须按单目图片估重：用餐具/容器尺度、2D面积占比、可见数量、形态体积和常见份量模板估算。"
    "克重必须精确到个位数，不要到十位数。"
    "只返回 food_photo_direct_nutrition.txt 要求的紧凑 JSON，第一字符必须是左花括号。"
)
PHOTO_DIRECT_NUTRITION_RETRY_USER_PROMPT = (
    "重新从图片分析，不要复制旧答案。请先判断哪些是同类重复物，先合并；"
    "再拆分清楚可见且营养差异明显的项目。"
    "不要把同一食材、同一烹饪方式、营养密度接近的食物重复列名。"
    "克重必须根据图片估计，不要输出50/100/150/200/250这种占位数。"
    "每项都要包含数量描述、烹饪方式、置信度和营养。"
    "只返回 food_photo_direct_nutrition.txt 要求的严格 JSON，第一字符必须是左花括号。"
)
PHOTO_FAST_DETECTION_USER_PROMPT = (
    "请只识别这张图片中可见食物的名称和可食克重，不要输出任何营养数字。"
    "如果是油炸拼盘，请逐项检查并拆出不同小食。"
    "如果没有深度数据，必须按单目图片估重：用餐具/容器尺度、2D面积占比、可见数量、形态体积和常见份量模板估算。"
    "只返回 food_photo_fast_detection.txt 要求的严格 JSON。"
)
MAX_PHOTO_ITEMS = 20
FRESH_PHOTO_FOOD_RE = re.compile(
    r"菜|蔬|甘蓝|芹|西芹|青椒|彩椒|甜椒|辣椒|胡萝卜|萝卜|番茄|圣女果|黄瓜|苦瓜|蘑菇|香菇|菌|西兰花|花菜|生菜|韭葱|洋葱|芽菜|小白菜|菠菜|莴笋|南瓜|冬瓜|丝瓜|茄子"
)
DRY_OR_CONDENSED_FOOD_RE = re.compile(r"干|脱水|粉|香辛料|调味料|茶|浓缩|酱|油|薯片|脆片|饼干|膨化")
LOW_CALORIE_LIQUID_RE = re.compile(r"饮用水|矿泉水|白水|清水|茶水|茶|绿茶|红茶|乌龙茶|普洱|黑咖啡|美式咖啡|清汤|汤水")
LOW_CALORIE_LIQUID_EXCLUDE_RE = re.compile(r"奶茶|拿铁|奶盖|果茶|甜茶|糖|蜂蜜|椰|奶|牛奶|豆浆|饮料|瓶|康师傅|蛋糕|饼|巧克力|雪糕|冰淇淋|粉|蛋|粥|浓汤|羹|酱|油")
DIRECT_NUTRITION_PROFILES = [
    (re.compile(r"薯条|炸薯条|french\s*fries", re.I), {"calories": 312, "protein": 3.4, "carbs": 41, "fat": 15, "fiber": 3.8, "sodium": 260}),
    (re.compile(r"蛋挞|葡挞|egg\s*tart", re.I), {"calories": 300, "protein": 5.5, "carbs": 34, "fat": 16, "fiber": 0.8, "sodium": 180}),
    (re.compile(r"烤肠|香肠|热狗肠|sausage", re.I), {"calories": 290, "protein": 12, "carbs": 5, "fat": 25, "fiber": 0, "sodium": 850}),
    (re.compile(r"芝士条|奶酪条|起司条|长条裹粉|裹粉小食|鱼条|虾条|橙色长条|cheese\s*stick", re.I), {"calories": 330, "protein": 12, "carbs": 25, "fat": 20, "fiber": 1, "sodium": 650}),
    (re.compile(r"薯角|土豆角|土豆块|炸土豆|potato\s*wedge", re.I), {"calories": 230, "protein": 3, "carbs": 32, "fat": 10, "fiber": 3, "sodium": 280}),
    (re.compile(r"洋葱圈|onion\s*ring", re.I), {"calories": 350, "protein": 4, "carbs": 40, "fat": 19, "fiber": 2.5, "sodium": 520}),
    (re.compile(r"炸丸|丸子|鱼丸|虾丸|土豆球|芝士球", re.I), {"calories": 260, "protein": 8, "carbs": 22, "fat": 16, "fiber": 1.5, "sodium": 520}),
    (re.compile(r"炸鸡|鸡块|鸡米花|鸡翅|鸡排|鸡腿|nugget|fried\s*chicken", re.I), {"calories": 280, "protein": 15, "carbs": 12, "fat": 18, "fiber": 1, "sodium": 600}),
]
PHOTO_DUPLICATE_GROUPS: list[tuple[re.Pattern[str], str, str, str]] = []


def _debug_log(message: str) -> None:
    try:
        print(message)
    except OSError:
        pass


def _debug_exception() -> None:
    try:
        import traceback

        _debug_log(traceback.format_exc())
    except Exception:
        pass


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)) or default)
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class DescribeMealService:
    """Analyze food from images, text, or barcodes using any LLM provider."""

    def __init__(self, provider: LLMProvider | None, food_db: FoodDatabase | None = None):
        self.provider = provider
        deepseek_key = os.getenv("DEEPSEEK_API_KEY", "").strip()
        review_provider = os.getenv("PHOTO_NUTRITION_REVIEW_PROVIDER", "deepseek").strip().lower()
        use_external_review = review_provider == "deepseek" and deepseek_key and not os.getenv("PYTEST_CURRENT_TEST")
        self.nutrition_review_provider: LLMProvider | None = DeepSeekProvider(deepseek_key) if use_external_review else None
        self.scorer = HealthScorer()
        self.food_db = food_db or FoodDatabase()
        self.open_food_facts = OpenFoodFactsService()

    async def analyze(self, request: DescribeMealRequest) -> DescribeMealResponse:
        """Main entry point — route to the appropriate analysis method."""
        source = request.source
        estimation_metadata = None

        if source in (ScanSource.image_scan, ScanSource.describe_meal, ScanSource.library):
            if not request.image_base64:
                raise ValueError("需要先提供图片")
            capture_context = {
                "depth_metadata": request.depth_metadata or {},
                "capture_metadata": request.capture_metadata or {},
            }
            foods, description, estimation_metadata = await self._analyze_image(
                request.image_base64,
                capture_context=capture_context,
            )

        elif source == ScanSource.manually:
            if not request.text:
                raise ValueError("请输入食物描述")
            foods, description = await self._analyze_text(request.text)

        elif source == ScanSource.barcode_scan:
            if not request.barcode:
                raise ValueError("请输入条形码")
            foods, description = await self._lookup_barcode(request.barcode)

        elif source == ScanSource.barcode_camera:
            if not request.image_base64:
                raise ValueError("需要先提供条形码图片")
            foods, description = await self._analyze_barcode_image(request.image_base64)

        else:
            foods, description = [], "暂不支持这种扫描方式"

        # Vision estimates are not trusted nutrition references until explicitly reviewed.
        if foods and _env_bool("PHOTO_ANALYSIS_FLYWHEEL_ENABLED", False):
            self._save_to_db(foods)

        # Fallback: if model returned 0 nutrition, calculate from DB
        if foods and any(f.calories == 0 and f.protein == 0 for f in foods):
            foods = self._enrich_from_db(foods)

        # Health score
        if foods:
            scores = self.scorer.score_foods(foods)
            avg_total = round(sum(s.total for s in scores) / len(scores))
            from models.health import HealthScore, ArtificialScore, NetCarbsScore, AddedSugarScore
            health_score = HealthScore(
                total=avg_total,
                artificial_score=ArtificialScore(score=round(sum(s.artificial_score.score for s in scores) / len(scores)), level="", description=""),
                net_carbs_score=NetCarbsScore(score=round(sum(s.net_carbs_score.score for s in scores) / len(scores)), net_carbs_per_100g=0, total_carbs=0, fiber=0, level=""),
                added_sugar_score=AddedSugarScore(score=round(sum(s.added_sugar_score.score for s in scores) / len(scores)), added_sugar_per_100g=0, level=""),
                description=f"Aggregate health score across {len(foods)} food items",
            )
        else:
            health_score = None

        return DescribeMealResponse(
            foods=foods,
            health_score=health_score,
            description=description,
            estimation_metadata=estimation_metadata,
        )

    @staticmethod
    def _extract_grams(serving_size: str) -> float:
        """Extract gram weight from serving_size like '210g (3 wings)' or '约210克'."""
        import re as _re
        ss = str(serving_size)
        # Match: 210g, 210克, 约210克, 210ml
        for pat in [r'(\d+)\s*g', r'(\d+)\s*克', r'(\d+)\s*ml', r'(\d+)\s*毫升']:
            match = _re.search(pat, ss, _re.IGNORECASE)
            if match:
                return float(match.group(1))
        return 0

    # Default per-item weights (grams) for common food types
    DEFAULT_ITEM_WEIGHTS = {
        "wing": 70, "鸡翅": 70, "drumstick": 90, "鸡腿": 90,
        "sausage": 50, "香肠": 50, "hot dog": 80, "热狗": 80,
        "egg tart": 70, "蛋挞": 70,
        "pizza": 130, "披萨": 130,
        "onion ring": 18, "洋葱圈": 18,
        "fries": 100, "薯条": 100, "fry": 100,
        "nugget": 25, "鸡块": 25, "nuggets": 25,
        "bread": 40, "面包": 40, "roll": 60, "bun": 60,
        "cookie": 20, "饼干": 20, "曲奇": 20,
        "rice": 150, "米饭": 150, "饭": 150,
        "drink": 355, "soda": 355, "cola": 355, "可乐": 355,
        "juice": 240, "果汁": 240, "橙汁": 240,
        "beer": 355, "啤酒": 355,
        "chicken breast": 150, "鸡胸肉": 150,
        "steak": 200, "牛排": 200,
        "fish": 150, "鱼": 150, "salmon": 150, "三文鱼": 150,
        "vegetable": 100, "蔬菜": 100, "broccoli": 100, "西兰花": 100,
        "salad": 150, "沙拉": 150,
        "soup": 250, "汤": 250,
        "egg": 50, "鸡蛋": 50, "蛋": 50,
        "tofu": 150, "豆腐": 150,
        "chip": 50, "薯片": 50,
        "chocolate": 40, "巧克力": 40,
        "ice cream": 100, "冰淇淋": 100, "雪糕": 100,
    }

    @classmethod
    def _guess_item_weight(cls, food_name: str) -> float:
        """Guess per-item weight from food name keywords."""
        name_lower = food_name.lower()
        for keyword, weight in cls.DEFAULT_ITEM_WEIGHTS.items():
            if keyword in name_lower:
                return weight
        return 100  # default: assume 100g per item/portion

    def _enrich_from_db(self, foods: list[Food]) -> list[Food]:
        """Fill nutrition from verified database × estimated portion weight."""
        enriched = []
        for f in foods:
            grams = self._extract_grams(f.serving_size)
            if grams <= 0:
                # Model didn't give grams — estimate from food name
                # Count pieces from serving_size text
                count = 1
                import re as _re
                count_match = _re.search(r'(\d+)\s*(个|块|根|片|杯|只|份|wings|pieces|pcs)', str(f.serving_size))
                if count_match:
                    count = int(count_match.group(1))
                per_item = self._guess_item_weight(f.name)
                grams = per_item * count
                # Update serving_size to include estimated grams
                orig = f.serving_size or ""
                f.serving_size = f"{grams:.0f}g ({orig})" if orig else f"{grams:.0f}g"

            # Look up in database — try exact, then keyword extraction
            conn = sqlite3.connect(str(self.food_db.db_path))
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT * FROM foods WHERE name LIKE ? LIMIT 1",
                (f"%{f.name}%",),
            ).fetchone()

            # Fallback: extract keywords from name and search
            if not row:
                keywords = f.name.replace(" ", "%").replace("(", "%").replace(")", "%")
                row = conn.execute(
                    "SELECT * FROM foods WHERE name LIKE ? LIMIT 1",
                    (f"%{keywords}%",),
                ).fetchone()

            # Fallback: search by food type hints (bidirectional CN/EN)
            if not row:
                name_lower = f.name.lower()
                hints = []
                for kw in [
                    "鸡翅", "chicken wing", "鸡腿", "drumstick", "鸡块", "nugget",
                    "薯条", "fry", "洋葱圈", "onion ring",
                    "披萨", "pizza", "香肠", "sausage", "蛋挞", "egg tart",
                    "面包", "bread", "米饭", "rice", "面条", "noodle",
                    "牛肉", "beef", "猪肉", "pork", "鱼", "fish", "三文鱼", "salmon",
                    "汤", "soup", "沙拉", "salad", "豆腐", "tofu", "蔬菜", "vegetable",
                    "西兰花", "broccoli", "可乐", "cola", "果汁", "juice", "啤酒", "beer",
                    "薯片", "chip", "巧克力", "chocolate", "虾", "shrimp",
                    "饺子", "dumpling", "包子", "bun", "汉堡", "burger",
                    "蛋", "egg", "蛋糕", "cake", "饼干", "cookie",
                ]:
                    if kw in name_lower:
                        hints.append(kw)
                for hint in hints:
                    row = conn.execute(
                        "SELECT * FROM foods WHERE name LIKE ? LIMIT 1",
                        (f"%{hint}%",),
                    ).fetchone()
                    if row:
                        break

            conn.close()
            db_food = self.food_db._row_to_food(row) if row else None

            if db_food and db_food.calories > 0:
                ratio = grams / 100.0
                f.calories = round(db_food.calories * ratio, 1)
                f.protein = round(db_food.protein * ratio, 1)
                f.carbs = round(db_food.carbs * ratio, 1)
                f.fat = round(db_food.fat * ratio, 1)
                f.fiber = round(db_food.fiber * ratio, 1)
                f.sugar = round(db_food.sugar * ratio, 1)
                f.added_sugar = round(db_food.added_sugar * ratio, 1)
                f.sodium = round(db_food.sodium * ratio, 1)

            # Clean food name: strip processing-level adjectives only
            import re as _re2
            clean_name = _re2.sub(
                r'^(超加工|ultra.processed|processed|加工)\s*',
                '', f.name, flags=_re2.IGNORECASE
            ).strip()
            if clean_name and clean_name != f.name:
                f.name = clean_name
            if db_food and re.search(r"[A-Za-z]", f.name):
                f.name = db_food.name
            else:
                f.name = _display_food_name(f.name)
            f.serving_size = _display_serving_size(f.serving_size)

            enriched.append(f)
        return enriched

    def _save_food_history(self, foods: list[Food]):
        """Save logged foods to history for quick-add."""
        conn = sqlite3.connect(str(self.food_db.db_path))
        conn.execute("""
            CREATE TABLE IF NOT EXISTS food_log_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                food_name TEXT, calories REAL, protein REAL, carbs REAL, fat REAL,
                fiber REAL, sugar REAL, sodium REAL, sat_fat REAL DEFAULT 0,
                trans_fat REAL DEFAULT 0, cholesterol REAL DEFAULT 0,
                vitamin_a REAL DEFAULT 0, vitamin_c REAL DEFAULT 0,
                calcium REAL DEFAULT 0, iron REAL DEFAULT 0, potassium REAL DEFAULT 0,
                serving_size TEXT, processing_level TEXT, logged_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        # Migrate old tables
        cols = [r[1] for r in conn.execute("PRAGMA table_info(food_log_history)").fetchall()]
        for col in DATABASE_NUTRIENT_FIELDS:
            if col not in cols:
                try:
                    conn.execute(f"ALTER TABLE food_log_history ADD COLUMN {col} REAL DEFAULT 0")
                except Exception:
                    pass
        for col, spec in {
            "grams_per_unit": "REAL DEFAULT 100",
            "quantity_count": "REAL DEFAULT NULL",
            "quantity_unit": "TEXT DEFAULT ''",
            "quantity_description": "TEXT DEFAULT ''",
            "barcode": "TEXT DEFAULT ''",
            "nutrition_source": "TEXT DEFAULT ''",
        }.items():
            if col not in cols:
                try:
                    conn.execute(f"ALTER TABLE food_log_history ADD COLUMN {col} {spec}")
                except Exception:
                    pass
        from datetime import date as _date
        today_str = _date.today().isoformat()
        for f in foods:
            columns = [
                "food_name", *DATABASE_NUTRIENT_FIELDS, "serving_size", "grams_per_unit",
                "quantity_count", "quantity_unit", "quantity_description", "processing_level",
                "barcode", "nutrition_source", "date",
            ]
            values = [
                f.name,
                *[float(getattr(f, field, 0) or 0) for field in DATABASE_NUTRIENT_FIELDS],
                f.serving_size,
                max(0.1, float(f.grams_per_unit or 100)),
                f.quantity_count,
                f.quantity_unit,
                f.quantity_description,
                f.processing_level.value,
                f.barcode,
                f.nutrition_source,
                today_str,
            ]
            conn.execute(
                f"INSERT INTO food_log_history ({','.join(columns)}) VALUES ({','.join(['?'] * len(columns))})",
                values,
            )
        conn.commit()
        conn.close()

    def _save_to_db(self, foods: list[Food]):
        """Persist analyzed foods to DB for flywheel (future lookups)."""
        conn = sqlite3.connect(str(self.food_db.db_path))
        for f in foods:
            try:
                normalized_name = re.sub(r"[\s,，、。.;；:：()（）\[\]【】/\\-]+", "", f.name).lower()
                if not normalized_name:
                    continue
                existing = conn.execute(
                    "SELECT id FROM foods WHERE LOWER(REPLACE(REPLACE(name, ' ', ''), '　', '')) = ? LIMIT 1",
                    (normalized_name,),
                ).fetchone()
                if existing:
                    continue
                columns = [
                    "id", "name", *DATABASE_NUTRIENT_FIELDS, "serving_size", "grams_per_unit",
                    "processing_level", "barcode", "source",
                ]
                values = [
                    f"vision_{hashlib.sha256(normalized_name.encode('utf-8')).hexdigest()[:20]}",
                    f.name,
                    *[float(getattr(f, field, 0) or 0) for field in DATABASE_NUTRIENT_FIELDS],
                    f.serving_size,
                    max(0.1, float(f.grams_per_unit or 100)),
                    f.processing_level.value,
                    f.barcode,
                    f.nutrition_source or "vision_analysis",
                ]
                conn.execute(
                    f"INSERT OR IGNORE INTO foods ({','.join(columns)}) VALUES ({','.join(['?'] * len(columns))})",
                    values,
                )
            except Exception:
                pass
        conn.commit()
        conn.close()

    def _photo_cache_enabled(self) -> bool:
        default = not bool(os.getenv("PYTEST_CURRENT_TEST"))
        return _env_bool("PHOTO_ANALYSIS_CACHE_ENABLED", default)

    def _photo_cache_key(self, image_base64: str, context_prompt: str) -> str:
        provider = self.provider
        model = str(getattr(provider, "model", "") or getattr(provider, "vision_model", ""))
        fingerprint = {
            "pipeline": "direct_image_nutrition_v2",
            "provider": type(provider).__name__ if provider is not None else "none",
            "model": model,
            "temperature": getattr(provider, "temperature", None),
            "system_prompt": hashlib.sha256(PHOTO_DIRECT_NUTRITION_PROMPT.encode("utf-8")).hexdigest(),
            "user_prompt": hashlib.sha256(PHOTO_DIRECT_NUTRITION_USER_PROMPT.encode("utf-8")).hexdigest(),
            "context_prompt": context_prompt,
            "image": hashlib.sha256(image_base64.encode("ascii", errors="ignore")).hexdigest(),
        }
        encoded = json.dumps(fingerprint, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

    @staticmethod
    def _ensure_photo_cache_table(conn: sqlite3.Connection) -> None:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS photo_analysis_cache (
                   cache_key TEXT PRIMARY KEY,
                   response_json TEXT NOT NULL,
                   created_at REAL NOT NULL,
                   accessed_at REAL NOT NULL
               )"""
        )

    def _get_cached_photo_result(
        self,
        cache_key: str,
    ) -> tuple[list[Food], str, dict[str, Any]] | None:
        if not self._photo_cache_enabled():
            return None
        ttl_seconds = _env_int("PHOTO_ANALYSIS_CACHE_TTL_SECONDS", 604800, 60, 2592000)
        now = time.time()
        try:
            with sqlite3.connect(str(self.food_db.db_path)) as conn:
                self._ensure_photo_cache_table(conn)
                row = conn.execute(
                    "SELECT response_json, created_at FROM photo_analysis_cache WHERE cache_key = ?",
                    (cache_key,),
                ).fetchone()
                if not row:
                    return None
                if now - float(row[1]) > ttl_seconds:
                    conn.execute("DELETE FROM photo_analysis_cache WHERE cache_key = ?", (cache_key,))
                    return None
                conn.execute(
                    "UPDATE photo_analysis_cache SET accessed_at = ? WHERE cache_key = ?",
                    (now, cache_key),
                )
            payload = json.loads(row[0])
            foods = [Food(**item) for item in payload.get("foods", [])]
            metadata = dict(payload.get("estimation_metadata") or {})
            metadata["cache_hit"] = True
            return foods, str(payload.get("description") or ""), metadata
        except (OSError, sqlite3.Error, TypeError, ValueError, json.JSONDecodeError):
            return None

    def _cache_photo_result(
        self,
        cache_key: str,
        foods: list[Food],
        description: str,
        metadata: dict[str, Any],
    ) -> None:
        if not self._photo_cache_enabled() or not foods:
            return
        now = time.time()
        max_entries = _env_int("PHOTO_ANALYSIS_CACHE_MAX_ENTRIES", 512, 16, 4096)
        payload = json.dumps(
            {
                "foods": [food.model_dump(mode="json") for food in foods],
                "description": description,
                "estimation_metadata": metadata,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        try:
            with sqlite3.connect(str(self.food_db.db_path)) as conn:
                self._ensure_photo_cache_table(conn)
                conn.execute(
                    """INSERT INTO photo_analysis_cache
                           (cache_key, response_json, created_at, accessed_at)
                       VALUES (?, ?, ?, ?)
                       ON CONFLICT(cache_key) DO UPDATE SET
                           response_json = excluded.response_json,
                           created_at = excluded.created_at,
                           accessed_at = excluded.accessed_at""",
                    (cache_key, payload, now, now),
                )
                conn.execute(
                    """DELETE FROM photo_analysis_cache
                       WHERE cache_key IN (
                           SELECT cache_key FROM photo_analysis_cache
                           ORDER BY accessed_at DESC LIMIT -1 OFFSET ?
                       )""",
                    (max_entries,),
                )
        except (OSError, sqlite3.Error, TypeError, ValueError):
            pass

    def _cross_reference_db(self, foods: list[Food]) -> list[Food]:
        """Cross-reference LLM results with the food database.

        If a matching food exists in DB with user-fixed data (source='user_fix'),
        prefer the DB values. If Gemini estimate and DB have similar values,
        use DB as ground truth (Harvard reference).
        """
        import sqlite3
        conn = sqlite3.connect(str(self.food_db.db_path))
        conn.row_factory = sqlite3.Row

        improved = []
        for f in foods:
            # Search DB for similar food name
            rows = conn.execute(
                "SELECT * FROM foods WHERE name LIKE ? LIMIT 3",
                (f"%{f.name}%",),
            ).fetchall()

            if rows:
                db_food = self.food_db._row_to_food(rows[0])
                # If DB has user-fixed data, trust it
                if rows[0]["source"] == "user_fix":
                    db_food.id = f.id  # keep original ID
                    improved.append(db_food)
                    continue
                # If values are close (<20% diff), use DB (Harvard reference)
                if db_food.calories > 0 and abs(f.calories - db_food.calories) / f.calories < 0.2:
                    # check confidence
                    conf_row = conn.execute(
                        "SELECT accurate_votes, fix_count FROM food_confidence WHERE food_id = ?",
                        (db_food.id,),
                    ).fetchone()
                    if conf_row and conf_row["accurate_votes"] >= 1:
                        db_food.id = f.id
                        improved.append(db_food)
                        continue
            improved.append(f)

        conn.close()
        return improved

    def _compress_image_base64(self, image_base64: str) -> str:
        """Validate and normalize image payload for vision API speed/stability."""
        try:
            import base64
            import binascii
            import io as _io

            raw_value = str(image_base64 or "").strip()
            if raw_value.lower().startswith("data:") and "," in raw_value:
                raw_value = raw_value.split(",", 1)[1]
            raw_value = re.sub(r"\s+", "", raw_value)
            raw_value += "=" * (-len(raw_value) % 4)
            raw = base64.b64decode(raw_value, validate=True)

            from PIL import Image

            img = Image.open(_io.BytesIO(raw))
            img.load()
            img = img.convert("RGB")

            max_dim = int(os.getenv("PHOTO_IMAGE_MAX_DIM", "768") or 768)
            max_dim = max(320, min(2048, max_dim))
            w, h = img.size
            if w > max_dim or h > max_dim:
                img.thumbnail((max_dim, max_dim), Image.LANCZOS)

            buf = _io.BytesIO()
            quality = int(os.getenv("PHOTO_IMAGE_JPEG_QUALITY", "72") or 72)
            quality = max(45, min(92, quality))
            img.save(buf, "JPEG", quality=quality, optimize=True)
            return base64.b64encode(buf.getvalue()).decode()
        except (binascii.Error, OSError, ValueError) as exc:
            raise ValueError("Invalid base64 image data") from exc

    @staticmethod
    def _extract_json_data(text: str) -> dict:
        if not text:
            return {}
        text = text.strip()
        answer_match = re.search(r"<answer>\s*(.*?)\s*</answer>", text, re.DOTALL | re.IGNORECASE)
        if answer_match:
            text = answer_match.group(1).strip()
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL | re.IGNORECASE).strip()
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
        try:
            data = json.loads(text)
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError:
            match = re.search(r"\{.*\}", text, re.DOTALL)
            if not match:
                return {}
            try:
                data = json.loads(match.group())
                return data if isinstance(data, dict) else {}
            except json.JSONDecodeError:
                return {}

    def _image_provider_error_message(self, error: Exception) -> str:
        raw = str(error).strip()
        lower = raw.lower()
        is_minicpm = "minicpm" in lower
        is_local_vision = is_minicpm or "local qwen-vl" in lower or "qwen-vl" in lower or "local vision" in lower
        model_label = str(getattr(self.provider, "PROVIDER_LABEL", "") or "").strip()
        if not model_label and hasattr(self.provider, "providers"):
            providers = getattr(self.provider, "providers", []) or []
            if providers:
                model_label = str(getattr(providers[0][1], "PROVIDER_LABEL", "") or "").strip()
        if not model_label:
            if "mimo" in lower:
                model_label = "MiMo"
            else:
                model_label = "MiniCPM-V" if is_minicpm else ("本地视觉模型" if is_local_vision else "当前视觉模型")
        if "does not support image" in lower:
            return raw or "当前模型不支持图片识别，请改用支持视觉的模型。"
        if "invalid api key" in lower or "invalid_key" in lower or "invalid_api_key" in lower:
            if is_local_vision or model_label.lower() != "mimo":
                return f"{model_label} 鉴权失败，图片识别没有完成。请检查本地隧道、服务 token 和鉴权头配置。"
            return "MiMo API Key 无效或不属于当前 API 域名，图片识别没有完成。请更换小米 MiMo 官方有效 key 后重试。"
        if "unauthorized" in lower or "401" in lower or "authentication" in lower:
            return f"{model_label} 鉴权失败，图片识别没有完成。请检查 API Key、API 域名和鉴权头配置。"
        if "connecterror" in lower or "connection" in lower or "network" in lower:
            return f"{model_label} 图片模型连接失败，当前没有完成图片识别。请稍后重试，或先用文字描述记录。"
        if "timeout" in lower or "timed out" in lower:
            return f"{model_label} 图片模型响应超时，当前没有完成图片识别。请稍后重试，或先用文字描述记录。"
        if (
            "mimo api error" in lower
            or "mimo api failed" in lower
            or "local qwen-vl api error" in lower
            or "local qwen-vl api failed" in lower
            or "minicpm-v api error" in lower
            or "minicpm-v api failed" in lower
            or "local vision api error" in lower
            or "local vision api failed" in lower
        ):
            detail = raw[:180]
            return f"{model_label} 图片模型调用失败：{detail}。请稍后重试，或先用文字描述记录。"
        detail = raw[:180] if raw else "未知错误"
        return f"图片模型调用失败：{detail}。请稍后重试，或先用文字描述记录。"

    def _parse_visual_estimates(self, text: str) -> tuple[list[dict[str, Any]], str]:
        data = self._extract_json_data(text)
        raw_items = data.get("items") or data.get("foods") or []
        if not isinstance(raw_items, list):
            return [], data.get("description", "") if isinstance(data.get("description"), str) else ""

        items: list[dict[str, Any]] = []
        for item in raw_items:
            if not isinstance(item, dict):
                continue
            name = str(
                item.get("name")
                or item.get("n")
                or item.get("food_name")
                or item.get("name_zh")
                or item.get("final_name_zh")
                or ""
            ).strip()
            if not name:
                continue
            grams_range_raw = (
                item.get("estimated_grams_range")
                or item.get("grams_range")
                or item.get("weight_grams_range")
                or []
            )
            grams_range: list[float] = []
            if isinstance(grams_range_raw, (list, tuple)) and len(grams_range_raw) >= 2:
                low = self._safe_float(grams_range_raw[0])
                high = self._safe_float(grams_range_raw[1])
                if low > 0 and high > 0:
                    grams_range = [min(low, high), max(low, high)]

            grams = self._safe_float(
                item.get("estimated_grams")
                or item.get("g")
                or item.get("grams")
                or item.get("weight_grams")
                or self._extract_grams(str(item.get("serving_size") or ""))
            )
            if grams <= 0 and grams_range:
                grams = sum(grams_range) / 2
            if grams <= 0:
                grams = self._guess_item_weight(name)
            if grams < 5 and name not in {"调味/配料", "调味料", "酱汁"}:
                continue
            grams = round(max(5.0, min(2500.0, grams)), 1)
            if not grams_range:
                grams_range = [round(max(1.0, grams * 0.75), 1), round(min(2500.0, grams * 1.25), 1)]
            else:
                grams_range = [round(max(1.0, grams_range[0]), 1), round(min(2500.0, grams_range[1]), 1)]

            quantity_raw = item.get("quantity") or item.get("q") or ""
            quantity_detail: dict[str, Any]
            unit = str(item.get("unit") or "")
            if isinstance(quantity_raw, dict):
                quantity_detail = dict(quantity_raw)
                unit = str(quantity_detail.get("unit") or unit or "")
                quantity_text = str(
                    quantity_detail.get("description")
                    or (
                        f"{quantity_detail.get('count')}{unit}"
                        if quantity_detail.get("count") is not None and unit
                        else quantity_detail.get("count", "")
                    )
                    or ""
                )
            else:
                quantity_text = str(quantity_raw or "")
                quantity_detail = {"description": quantity_text}
                if unit:
                    quantity_detail["unit"] = unit

            confidence = max(0.0, min(1.0, self._safe_float(
                item.get("visible_confidence") or item.get("confidence") or item.get("conf"),
                0.5,
            )))
            notes = str(
                item.get("notes")
                or item.get("reason")
                or item.get("uncertainty_reason")
                or item.get("weight_basis")
                or ""
            )
            display_name = _display_food_name(name)
            items.append(
                {
                    "pass1_id": str(item.get("pass1_id") or item.get("id") or f"F{len(items) + 1}"),
                    "name": display_name,
                    "name_zh": display_name,
                    "candidate_names": item.get("candidate_names") if isinstance(item.get("candidate_names"), list) else [],
                    "category": str(item.get("category") or ""),
                    "location": str(item.get("location") or ""),
                    "visible_form": str(item.get("visible_form") or ""),
                    "estimated_grams": grams,
                    "estimated_grams_range": grams_range,
                    "quantity": quantity_text,
                    "quantity_detail": quantity_detail,
                    "unit": unit,
                    "weight_basis": str(item.get("weight_basis") or ""),
                    "cooking_method": str(item.get("cooking_method") or item.get("method") or item.get("m") or "不确定"),
                    "is_mixed_dish": bool(item.get("is_mixed_dish") or item.get("mixed_dish")),
                    "visible_components": item.get("visible_components") if isinstance(item.get("visible_components"), list) else [],
                    "visible_confidence": round(confidence, 3),
                    "confidence": round(confidence, 3),
                    "uncertainty_reason": str(item.get("uncertainty_reason") or ""),
                    "notes": notes,
                }
            )
            if len(items) >= MAX_PHOTO_ITEMS:
                break
        description = data.get("title", "") or data.get("meal_title", "") or data.get("description", "") or data.get("d", "")
        if not description and isinstance(data.get("image_quality"), dict):
            description = str(data["image_quality"].get("note") or "")
        return items, description if isinstance(description, str) else ""

    def _parse_direct_nutrition_items(self, text: str) -> list[dict[str, Any]]:
        """Keep model-only vision fields that do not fit the Food schema."""
        data = self._extract_json_data(text)
        raw_items = data.get("foods") or data.get("items") or []
        if not isinstance(raw_items, list):
            return []

        items: list[dict[str, Any]] = []
        for raw in raw_items[:MAX_PHOTO_ITEMS]:
            if not isinstance(raw, dict):
                continue
            nutrition = raw.get("nutrition") if isinstance(raw.get("nutrition"), dict) else {}
            name = str(
                raw.get("name")
                or raw.get("n")
                or raw.get("name_zh")
                or raw.get("final_name_zh")
                or raw.get("food_name")
                or ""
            ).strip()
            if not name:
                continue
            grams = self._safe_float(
                raw.get("g")
                or raw.get("estimated_grams")
                or raw.get("serving_size_grams")
                or raw.get("grams")
            )
            confidence_raw = raw.get("conf") if raw.get("conf") is not None else raw.get("confidence")
            confidence = self._safe_float(confidence_raw, -1)
            item = {
                "name": _display_food_name(name),
                "estimated_grams": round(grams) if grams > 0 else None,
                "quantity": str(raw.get("q") or raw.get("quantity_desc") or raw.get("quantity") or "").strip(),
                "cooking_method": str(raw.get("m") or raw.get("cooking_method") or raw.get("method") or "").strip(),
                "visible_desc": str(raw.get("visible_desc") or "").strip(),
                "model_confidence": round(max(0.0, min(1.0, confidence)), 3) if confidence >= 0 else None,
                "model_direct_nutrition": {
                    "calories": self._safe_float(raw.get("kcal") or raw.get("calories_kcal") or raw.get("calories") or nutrition.get("calories_kcal") or nutrition.get("calories")),
                    "protein": self._safe_float(raw.get("p") or raw.get("protein_g") or raw.get("protein") or nutrition.get("protein_g") or nutrition.get("protein")),
                    "carbs": self._safe_float(raw.get("c") or raw.get("carbohydrate_g") or raw.get("carbs") or nutrition.get("carbohydrate_g") or nutrition.get("carbs")),
                    "fat": self._safe_float(raw.get("f") or raw.get("fat_g") or raw.get("fat") or nutrition.get("fat_g") or nutrition.get("fat")),
                    "fiber": self._safe_float(raw.get("fi") or raw.get("fiber_g") or raw.get("fiber") or nutrition.get("fiber_g") or nutrition.get("fiber")),
                    "sodium": self._safe_float(raw.get("na") or raw.get("sodium_mg") or raw.get("sodium") or nutrition.get("sodium_mg") or nutrition.get("sodium")),
                },
            }
            reason = str(raw.get("reason") or raw.get("r") or "").strip()
            if reason:
                item["model_reason"] = reason
            uncertainty = str(raw.get("nutrition_uncertainty") or "").strip()
            if uncertainty:
                item["nutrition_uncertainty"] = uncertainty
            items.append(item)
        return items

    @staticmethod
    def _scale_candidate_nutrition(candidate: dict[str, Any], grams: float) -> dict[str, float]:
        per_100g = candidate.get("per_100g_nutrition") or {}
        ratio = max(0, grams) / 100.0
        return {
            field: round(float(per_100g.get(field, 0) or 0) * ratio, 3)
            for field in [
                "calories", "protein", "carbs", "fat", "fiber", "sugar",
                "added_sugar", "sodium", "sat_fat", "trans_fat", "cholesterol",
                "vitamin_a", "vitamin_c", "calcium", "iron", "potassium",
            ]
        }

    def _photo_candidate_rules(self) -> dict[str, Any]:
        return {
            "max_items": MAX_PHOTO_ITEMS,
            "database_candidates_are_reference_only": True,
            "prefer_database_when_match_is_strong": False,
            "compare_all_database_candidates_not_only_first": True,
            "database_missing_auto_fill_required": True,
            "must_not_return_zero_nutrition_except_near_zero_drinks": True,
            "serving_size_must_include_grams": True,
            "serving_size_grams_must_equal_visual_estimated_grams": True,
            "database_reasonableness_check_required": True,
            "visual_result_is_primary_evidence": True,
            "candidate_quality_fields": [
                "match_score",
                "quality_score",
                "quality_status",
                "quality_notes",
                "per_100g_nutrition",
            ],
            "reject_or_fix_candidate_when": [
                "category_or_cooking_method_mismatch",
                "fresh_food_matched_to_dried_or_packaged_food",
                "per_100g_nutrition_unreasonable_for_visual_food",
                "candidate_quality_status_review_without_strong_match",
            ],
            "candidate_selection_policy": [
                "do_not_default_to_first_candidate",
                "do_not_copy_database_without_common_sense_check",
                "prefer_visual_category_cooking_method_shape_match",
                "prefer_high_quality_score_and_match_score_after_visual_match",
                "avoid_outlier_per_100g_nutrition_when_multiple_candidates_disagree",
                "use_recipe_or_ai_fallback_when_all_candidates_mismatch",
            ],
            "low_calorie_liquid_guardrail": "plain tea, water, black coffee, clear soup/broth must stay near zero/low calories even if database candidates are high-calorie products",
        }

    def _build_photo_candidate_payload_item(self, item: dict[str, Any]) -> dict[str, Any]:
        candidates = self.food_db.find_nutrition_candidates(item["name"], limit=5)
        for candidate in candidates:
            candidate["estimated_total_nutrition"] = self._scale_candidate_nutrition(
                candidate,
                float(item.get("estimated_grams") or 0),
            )
            quality_score = self._safe_float(candidate.get("quality_score"))
            quality_status = str(candidate.get("quality_status") or "")
            candidate["candidate_review_hint"] = (
                "usable_if_visual_match"
                if quality_status == "ok" and quality_score >= 0.85
                else "needs_ai_reasonableness_check"
            )
        recipes = self.food_db.find_recipe_candidates(item["name"], limit=3)
        return {
            "visual_estimate": item,
            "nutrition_candidates": candidates,
            "recipe_candidates": recipes,
            "nutrition_candidate_count": len(candidates),
            "candidate_status": "database_candidates_found" if candidates else "database_missing_auto_fill_required",
        }

    def _build_photo_candidate_payload(self, visual_items: list[dict[str, Any]]) -> dict[str, Any]:
        payload_items = [
            self._build_photo_candidate_payload_item(item)
            for item in visual_items[:MAX_PHOTO_ITEMS]
        ]
        return {"items": payload_items, "rules": self._photo_candidate_rules()}

    async def _build_photo_candidate_payload_async(self, visual_items: list[dict[str, Any]]) -> dict[str, Any]:
        tasks = [
            asyncio.to_thread(self._build_photo_candidate_payload_item, item)
            for item in visual_items[:MAX_PHOTO_ITEMS]
        ]
        payload_items = await asyncio.gather(*tasks) if tasks else []
        return {"items": payload_items, "rules": self._photo_candidate_rules()}

    def _food_from_candidate(self, item: dict[str, Any], candidate: dict[str, Any]) -> Food:
        grams = float(item.get("estimated_grams") or 100)
        nutrition = self._scale_candidate_nutrition(candidate, grams)
        return Food(
            name=_display_food_name(str(candidate.get("name") or item.get("name") or "食物")),
            calories=max(1.0, nutrition["calories"]),
            protein=nutrition["protein"],
            carbs=nutrition["carbs"],
            fat=nutrition["fat"],
            fiber=nutrition["fiber"],
            sugar=nutrition["sugar"],
            added_sugar=nutrition["added_sugar"],
            sodium=nutrition["sodium"],
            sat_fat=nutrition["sat_fat"],
            trans_fat=nutrition["trans_fat"],
            cholesterol=nutrition["cholesterol"],
            vitamin_a=nutrition["vitamin_a"],
            vitamin_c=nutrition["vitamin_c"],
            calcium=nutrition["calcium"],
            iron=nutrition["iron"],
            potassium=nutrition["potassium"],
            serving_size=f"{grams:.0f}克",
            processing_level=self._normalize_processing(str(candidate.get("processing_level") or "whole")),
        )

    @staticmethod
    def _plain_low_calorie_liquid_profile(name: str) -> dict[str, float] | None:
        text = str(name or "")
        if not LOW_CALORIE_LIQUID_RE.search(text):
            return None
        if LOW_CALORIE_LIQUID_EXCLUDE_RE.search(text):
            return None
        if re.search(r"汤|清汤|汤水", text):
            return {"calories": 12, "protein": 0.5, "carbs": 1.0, "fat": 0.3, "fiber": 0, "sodium": 180}
        return {"calories": 1, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0, "sodium": 5}

    def _food_from_plain_low_calorie_liquid(self, item: dict[str, Any], display_name: str | None = None) -> Food:
        name = str(display_name or item.get("name") or "茶")
        grams = float(item.get("estimated_grams") or self._guess_item_weight(name) or 150)
        profile = self._plain_low_calorie_liquid_profile(name) or {"calories": 1, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0, "sodium": 5}
        ratio = max(0.0, grams) / 100.0
        return Food(
            name=_display_food_name(name),
            calories=round(profile["calories"] * ratio, 1),
            protein=round(profile["protein"] * ratio, 1),
            carbs=round(profile["carbs"] * ratio, 1),
            fat=round(profile["fat"] * ratio, 1),
            fiber=round(profile["fiber"] * ratio, 1),
            sugar=0,
            added_sugar=0,
            sodium=round(profile["sodium"] * ratio, 1),
            serving_size=f"{grams:.0f}克",
            processing_level=self._normalize_processing("whole"),
        )

    def _rough_food_from_estimate(self, item: dict[str, Any]) -> Food:
        name = str(item.get("name") or "食物")
        grams = float(item.get("estimated_grams") or self._guess_item_weight(name))
        method = str(item.get("cooking_method") or "")
        text = f"{name} {method}"
        plain_liquid = self._plain_low_calorie_liquid_profile(text)
        if plain_liquid:
            return self._food_from_plain_low_calorie_liquid(item, name)
        kcal_per_100 = 120.0
        protein_per_100 = 4.0
        carbs_per_100 = 12.0
        fat_per_100 = 4.0
        if re.search(r"米饭|饭|粥|面|粉|馒头|包子|饺子", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 130, 3, 26, 1
        if re.search(r"猪|五花|牛|羊|肉", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 240, 18, 2, 17
        if re.search(r"鸡|鸭|鱼|虾|海鲜", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 150, 20, 1, 7
        if re.search(r"蛋", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 140, 13, 1, 10
        if re.search(r"菜|蔬|青椒|西兰花|生菜|黄瓜|番茄", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 35, 2, 6, 0.5
        if re.search(r"汤", text):
            kcal_per_100, protein_per_100, carbs_per_100, fat_per_100 = 35, 2, 4, 1
        if re.search(r"炸|煎|油", text):
            kcal_per_100 += 80
            fat_per_100 += 8
        ratio = grams / 100.0
        return Food(
            name=_display_food_name(name),
            calories=round(kcal_per_100 * ratio, 1),
            protein=round(protein_per_100 * ratio, 1),
            carbs=round(carbs_per_100 * ratio, 1),
            fat=round(fat_per_100 * ratio, 1),
            fiber=round((2 if carbs_per_100 else 0) * ratio, 1),
            sugar=0,
            added_sugar=0,
            sodium=round(120 * ratio, 1),
            serving_size=f"{grams:.0f}克",
            processing_level=self._normalize_processing("processed" if "炸" in text else "whole"),
        )

    def _fallback_foods_from_payload(self, payload: dict[str, Any]) -> list[Food]:
        foods = []
        for payload_item in payload.get("items", []):
            item = payload_item.get("visual_estimate") or {}
            candidates = payload_item.get("nutrition_candidates") or []
            if self._plain_low_calorie_liquid_profile(str(item.get("name") or "")):
                foods.append(self._food_from_plain_low_calorie_liquid(item))
            elif candidates and not self._candidate_profile_outlier_reason(str(item.get("name") or ""), candidates[0]):
                foods.append(self._food_from_candidate(item, candidates[0]))
            else:
                foods.append(self._rough_food_from_estimate(item))
        return foods

    def _food_from_direct_profile(self, item: dict[str, Any], profile: dict[str, float]) -> Food:
        grams = float(item.get("estimated_grams") or self._guess_item_weight(str(item.get("name") or "食物")))
        ratio = max(0.0, grams) / 100.0
        return Food(
            name=_display_food_name(str(item.get("name") or "食物")),
            calories=round(profile["calories"] * ratio, 1),
            protein=round(profile["protein"] * ratio, 1),
            carbs=round(profile["carbs"] * ratio, 1),
            fat=round(profile["fat"] * ratio, 1),
            fiber=round(profile["fiber"] * ratio, 1),
            sugar=0,
            added_sugar=0,
            sodium=round(profile["sodium"] * ratio, 1),
            serving_size=f"{grams:.0f}克",
            processing_level=self._normalize_processing("processed"),
        )

    def _food_from_fast_db_item(self, item: dict[str, Any]) -> tuple[Food, dict[str, Any]]:
        candidates = []
        try:
            if hasattr(self.food_db, "find_nutrition_candidates_fast"):
                candidates = self.food_db.find_nutrition_candidates_fast(item["name"], limit=3)
            else:
                candidates = self.food_db.find_nutrition_candidates(item["name"], limit=3)
        except Exception:
            candidates = []

        best = candidates[0] if candidates else None
        if best and self._safe_float(best.get("quality_score")) >= 0.85 and self._safe_float(best.get("match_score")) >= 0.9:
            outlier_reason = self._candidate_profile_outlier_reason(item["name"], best)
            if outlier_reason:
                profile = self._direct_nutrition_profile(str(item.get("name") or ""))
                if profile:
                    return self._food_from_direct_profile(item, profile), {
                        "name": item["name"],
                        "estimated_grams": item.get("estimated_grams"),
                        "nutrition_source": "local_density_profile_db_outlier",
                        "candidate_count": len(candidates),
                        "top_candidate": best,
                        "db_reject_reason": outlier_reason,
                        "needs_ai_review": False,
                    }
            return self._food_from_candidate(item, best), {
                "name": item["name"],
                "estimated_grams": item.get("estimated_grams"),
                "nutrition_source": "database_exact_fast",
                "candidate_count": len(candidates),
                "top_candidate": best,
                "needs_ai_review": False,
            }

        profile = self._direct_nutrition_profile(str(item.get("name") or ""))
        if profile:
            return self._food_from_direct_profile(item, profile), {
                "name": item["name"],
                "estimated_grams": item.get("estimated_grams"),
                "nutrition_source": "local_density_profile",
                "candidate_count": len(candidates),
                "top_candidate": best,
                "needs_ai_review": False,
            }

        return self._rough_food_from_estimate(item), {
            "name": item["name"],
            "estimated_grams": item.get("estimated_grams"),
            "nutrition_source": "rough_estimate_no_fast_db_match",
            "candidate_count": len(candidates),
            "top_candidate": best,
            "needs_ai_review": True,
        }

    def _direct_food_to_visual_item(self, food: Food) -> dict[str, Any]:
        grams = self._extract_grams(food.serving_size)
        if grams <= 0:
            grams = self._guess_item_weight(food.name)
        return {
            "name": food.name,
            "estimated_grams": grams,
            "cooking_method": "",
            "is_mixed_dish": False,
            "visible_confidence": 0.75,
        }

    def _override_direct_food_with_database(self, food: Food) -> tuple[Food, dict[str, Any]]:
        item = self._direct_food_to_visual_item(food)
        candidates = []
        try:
            if hasattr(self.food_db, "find_nutrition_candidates_fast"):
                candidates = self.food_db.find_nutrition_candidates_fast(food.name, limit=3)
            else:
                candidates = self.food_db.find_nutrition_candidates(food.name, limit=3)
        except Exception:
            candidates = []

        best = candidates[0] if candidates else None
        strong_match = (
            best is not None
            and self._safe_float(best.get("quality_score")) >= 0.85
            and self._safe_float(best.get("match_score")) >= 0.9
        )
        if strong_match:
            outlier_reason = self._candidate_profile_outlier_reason(food.name, best)
            if outlier_reason:
                repaired = self._repair_direct_nutrition([food])[0]
                return repaired, {
                    "name": repaired.name,
                    "estimated_grams": item["estimated_grams"],
                    "nutrition_source": "local_density_profile_db_outlier",
                    "candidate_count": len(candidates),
                    "top_candidate": best,
                    "db_reject_reason": outlier_reason,
                    "model_original": {
                        "name": food.name,
                        "calories": food.calories,
                        "protein": food.protein,
                        "carbs": food.carbs,
                        "fat": food.fat,
                        "fiber": food.fiber,
                        "sodium": food.sodium,
                    },
                    "needs_ai_review": False,
                }
            db_food = self._food_from_candidate(item, best)
            return db_food, {
                "name": db_food.name,
                "estimated_grams": item["estimated_grams"],
                "nutrition_source": "database_strong_match",
                "candidate_count": len(candidates),
                "top_candidate": best,
                "model_original": {
                    "name": food.name,
                    "calories": food.calories,
                    "protein": food.protein,
                    "carbs": food.carbs,
                    "fat": food.fat,
                    "fiber": food.fiber,
                    "sodium": food.sodium,
                },
                "needs_ai_review": False,
            }

        repaired = self._repair_direct_nutrition([food])[0]
        return repaired, {
            "name": repaired.name,
            "estimated_grams": item["estimated_grams"],
            "nutrition_source": "vision_model_direct",
            "candidate_count": len(candidates),
            "top_candidate": best,
            "needs_ai_review": False if self._direct_nutrition_profile(repaired.name) else not bool(candidates),
        }

    @staticmethod
    def _format_grams(grams: float) -> str:
        return f"{round(max(1.0, grams))}克"

    @staticmethod
    def _candidate_profile_outlier_reason(name: str, candidate: dict[str, Any] | None) -> str:
        if not candidate:
            return ""
        plain_liquid_profile = DescribeMealService._plain_low_calorie_liquid_profile(name)
        profile = DescribeMealService._direct_nutrition_profile(name)
        if plain_liquid_profile:
            profile = plain_liquid_profile
        if not profile:
            return ""
        per_100g = candidate.get("per_100g_nutrition") or {}
        try:
            candidate_kcal = float(per_100g.get("calories", 0) or 0)
        except (TypeError, ValueError):
            candidate_kcal = 0.0
        if candidate_kcal <= 0:
            return "database_candidate_missing_calories"
        expected_kcal = float(profile.get("calories") or 0)
        if expected_kcal <= 0:
            return ""
        lower = expected_kcal * 0.55
        upper = expected_kcal * 1.45
        if candidate_kcal < lower or candidate_kcal > upper:
            return (
                f"database_per_100g_calories_outlier:"
                f"{candidate_kcal:.1f}_vs_expected_{expected_kcal:.1f}"
            )
        return ""

    @staticmethod
    def _set_food_nutrition_from_profile(food: Food, profile: dict[str, float], grams: float) -> None:
        ratio = max(0.0, grams) / 100.0
        food.calories = round(profile["calories"] * ratio, 1)
        food.protein = round(profile["protein"] * ratio, 1)
        food.carbs = round(profile["carbs"] * ratio, 1)
        food.fat = round(profile["fat"] * ratio, 1)
        food.fiber = round(profile["fiber"] * ratio, 1)
        food.sodium = round(profile["sodium"] * ratio, 1)
        food.serving_size = DescribeMealService._format_grams(grams)

    @staticmethod
    def _scale_food_nutrition(food: Food, scale: float) -> None:
        if not (scale > 0) or abs(scale - 1.0) < 0.001:
            return
        for field in [
            "calories", "protein", "carbs", "fat", "fiber", "sugar",
            "added_sugar", "sodium", "sat_fat", "trans_fat", "cholesterol",
            "vitamin_a", "vitamin_c", "calcium", "iron", "potassium",
        ]:
            value = getattr(food, field, 0) or 0
            setattr(food, field, round(max(0.0, float(value) * scale), 3))

    @staticmethod
    def _photo_duplicate_group(name: str, meta: dict[str, Any] | None = None) -> tuple[str, str, str] | None:
        text = f"{name or ''} {(meta or {}).get('cooking_method') or ''} {(meta or {}).get('visible_desc') or ''}"
        for pattern, group_key, display_name, profile_name in PHOTO_DUPLICATE_GROUPS:
            if pattern.search(text):
                return group_key, display_name, profile_name
        return None

    @staticmethod
    def _merge_unique_text(*values: str) -> str:
        parts: list[str] = []
        for value in values:
            for part in re.split(r"[;；、,，]+", str(value or "")):
                clean = part.strip()
                if clean and clean not in parts:
                    parts.append(clean)
        return "；".join(parts)

    def _merge_food_into(self, target: Food, source: Food, group: tuple[str, str, str] | None = None) -> None:
        target_grams = self._extract_grams(target.serving_size)
        source_grams = self._extract_grams(source.serving_size)
        total_grams = target_grams + source_grams
        for field in [
            "calories", "protein", "carbs", "fat", "fiber", "sugar",
            "added_sugar", "sodium", "sat_fat", "trans_fat", "cholesterol",
            "vitamin_a", "vitamin_c", "calcium", "iron", "potassium",
        ]:
            setattr(
                target,
                field,
                round(float(getattr(target, field, 0) or 0) + float(getattr(source, field, 0) or 0), 3),
            )
        if total_grams > 0:
            target.serving_size = self._format_grams(total_grams)
        target.quantity_description = self._merge_unique_text(
            target.quantity_description,
            source.quantity_description,
        )
        if (
            target.quantity_unit
            and source.quantity_unit
            and target.quantity_unit == source.quantity_unit
            and target.quantity_count is not None
            and source.quantity_count is not None
        ):
            target.quantity_count = round(float(target.quantity_count) + float(source.quantity_count), 2)
        if group:
            _, display_name, profile_name = group
            target.name = display_name
            profile = self._direct_nutrition_profile(profile_name)
            if profile and total_grams > 0:
                self._set_food_nutrition_from_profile(target, profile, total_grams)

    def _dedupe_photo_foods_with_metadata(
        self,
        foods: list[Food],
        metadata_items: list[dict[str, Any]] | None = None,
    ) -> tuple[list[Food], list[dict[str, Any]]]:
        if not foods:
            return foods, metadata_items or []
        metadata_items = list(metadata_items or [])
        merged_foods: list[Food] = []
        merged_meta: list[dict[str, Any]] = []
        group_to_index: dict[str, int] = {}

        for index, food in enumerate(foods[:MAX_PHOTO_ITEMS]):
            meta = dict(metadata_items[index]) if index < len(metadata_items) and isinstance(metadata_items[index], dict) else {}
            group = self._photo_duplicate_group(food.name, meta)
            group_key = group[0] if group else f"unique:{index}:{self._photo_match_key(food.name)}"

            if group_key not in group_to_index:
                group_to_index[group_key] = len(merged_foods)
                merged_foods.append(food)
                merged_meta.append(meta)
                continue

            target_index = group_to_index[group_key]
            target_food = merged_foods[target_index]
            target_meta = merged_meta[target_index]
            self._merge_food_into(target_food, food, group)

            merged_from = target_meta.get("merged_from")
            if not isinstance(merged_from, list):
                merged_from = [target_meta.get("name") or target_food.name]
            merged_from.append(meta.get("name") or food.name)
            target_meta["merged_from"] = list(dict.fromkeys([str(x) for x in merged_from if x]))
            target_meta["name"] = target_food.name
            target_meta["estimated_grams"] = self._extract_grams(target_food.serving_size)
            target_meta["quantity"] = self._merge_unique_text(target_meta.get("quantity", ""), meta.get("quantity", ""))
            target_meta["visible_desc"] = self._merge_unique_text(target_meta.get("visible_desc", ""), meta.get("visible_desc", ""))
            if target_meta.get("nutrition_source") != meta.get("nutrition_source") and meta.get("nutrition_source"):
                target_meta["nutrition_source"] = self._merge_unique_text(
                    str(target_meta.get("nutrition_source") or ""),
                    str(meta.get("nutrition_source") or ""),
                )
            target_meta["dedupe_reason"] = "same_food_category_merged"

        return merged_foods, merged_meta

    def _apply_visual_weights(self, foods: list[Food], payload: dict[str, Any]) -> list[Food]:
        """Keep final serving sizes tied to pass-1 visual gram estimates."""
        payload_items = payload.get("items", [])
        for index, food in enumerate(foods):
            if index >= len(payload_items):
                break
            visual = (payload_items[index] or {}).get("visual_estimate") or {}
            visual_grams = self._safe_float(visual.get("estimated_grams"))
            if visual_grams <= 0:
                continue
            reviewed_grams = self._extract_grams(food.serving_size)
            if reviewed_grams > 0 and abs(reviewed_grams - visual_grams) > 1:
                self._scale_food_nutrition(food, visual_grams / reviewed_grams)
            food.serving_size = self._format_grams(visual_grams)
        return foods

    def _attach_visual_quantity(self, foods: list[Food], payload: dict[str, Any]) -> list[Food]:
        payload_items = payload.get("items", [])
        for index, food in enumerate(foods):
            if index >= len(payload_items):
                break
            visual = (payload_items[index] or {}).get("visual_estimate") or {}
            quantity_detail = visual.get("quantity_detail") if isinstance(visual.get("quantity_detail"), dict) else {}
            quantity_count = self._safe_float(quantity_detail.get("count"), 0)
            quantity_unit = str(quantity_detail.get("unit") or visual.get("unit") or "").strip()
            quantity_description = str(quantity_detail.get("description") or visual.get("quantity") or "").strip()
            food.quantity_count = quantity_count if quantity_count > 0 else None
            food.quantity_unit = quantity_unit
            food.quantity_description = quantity_description
        return foods

    @staticmethod
    def _looks_like_fresh_photo_food(name: str) -> bool:
        return bool(FRESH_PHOTO_FOOD_RE.search(name or "")) and not bool(DRY_OR_CONDENSED_FOOD_RE.search(name or ""))

    @staticmethod
    def _photo_match_key(name: str) -> str:
        text = _display_food_name(str(name or "")).lower()
        text = re.sub(r"[\\s,，、。.;；:：()（）\\[\\]【】/\\\\-]+", "", text)
        text = re.sub(r"^(油炸|炸制|炸|烤|煎|炒|蒸|煮|生)", "", text)
        text = re.sub(r"(约|大约|少量|一份|一盘|一碗|一个|一块|一根|一片)", "", text)
        return text

    def _food_matches_visual_item(self, food: Food, visual: dict[str, Any]) -> bool:
        visual_key = self._photo_match_key(str(visual.get("name") or ""))
        food_key = self._photo_match_key(food.name)
        if not visual_key or not food_key:
            return False
        if visual_key == food_key:
            return True
        if len(visual_key) >= 2 and len(food_key) >= 2 and (visual_key in food_key or food_key in visual_key):
            return True
        return False

    def _fallback_food_from_payload_item(self, payload_item: dict[str, Any]) -> Food:
        visual = payload_item.get("visual_estimate") or {}
        candidates = payload_item.get("nutrition_candidates") or []
        visual_name = str(visual.get("name") or "")
        if self._plain_low_calorie_liquid_profile(visual_name):
            return self._food_from_plain_low_calorie_liquid(visual)
        if candidates and not self._candidate_profile_outlier_reason(visual_name, candidates[0]):
            return self._food_from_candidate(visual, candidates[0])
        return self._rough_food_from_estimate(visual)

    def _reconcile_photo_foods_with_payload(self, foods: list[Food], payload: dict[str, Any]) -> list[Food]:
        """Keep pass-2 review from dropping foods seen in pass-1 vision."""
        payload_items = payload.get("items", [])
        if not payload_items:
            return foods[:MAX_PHOTO_ITEMS]

        ordered: list[Food] = []
        used: set[int] = set()
        for payload_item in payload_items[:MAX_PHOTO_ITEMS]:
            visual = (payload_item or {}).get("visual_estimate") or {}
            match_index = None
            for index, food in enumerate(foods):
                if index in used:
                    continue
                if self._food_matches_visual_item(food, visual):
                    match_index = index
                    break
            if match_index is not None:
                used.add(match_index)
                ordered.append(foods[match_index])
            else:
                ordered.append(self._fallback_food_from_payload_item(payload_item or {}))

        for index, food in enumerate(foods):
            if len(ordered) >= MAX_PHOTO_ITEMS:
                break
            if index not in used:
                ordered.append(food)
        return ordered[:MAX_PHOTO_ITEMS]

    def _photo_food_needs_repair(self, food: Food, visual: dict[str, Any]) -> bool:
        grams = self._extract_grams(food.serving_size)
        if grams <= 0:
            grams = self._safe_float(visual.get("estimated_grams"), 100)
        calories = float(food.calories or 0)
        protein = float(food.protein or 0)
        carbs = float(food.carbs or 0)
        fat = float(food.fat or 0)
        fiber = float(food.fiber or 0)
        if calories <= 0 and protein <= 0 and carbs <= 0 and fat <= 0:
            return True
        if grams <= 0:
            return True
        per_100_cal = calories / max(0.01, grams / 100.0)
        if per_100_cal > 950 or protein < 0 or carbs < 0 or fat < 0:
            return True
        per_100_protein = protein / max(0.01, grams / 100.0)
        per_100_carbs = carbs / max(0.01, grams / 100.0)
        per_100_fat = fat / max(0.01, grams / 100.0)
        per_100_fiber = fiber / max(0.01, grams / 100.0)
        visual_name = str(visual.get("name") or food.name)
        if self._plain_low_calorie_liquid_profile(visual_name):
            if per_100_cal > 30 or per_100_protein > 3 or per_100_carbs > 5 or per_100_fat > 2:
                return True
        if per_100_protein > 100 or per_100_carbs > 100 or per_100_fat > 100 or per_100_fiber > 80:
            return True
        macro_energy = per_100_protein * 4 + per_100_carbs * 4 + per_100_fat * 9
        if per_100_cal > 15 and macro_energy > 15:
            ratio = per_100_cal / macro_energy
            if ratio < 0.35 or ratio > 2.8:
                return True
        if self._looks_like_fresh_photo_food(visual_name):
            if per_100_cal > 120 or per_100_protein > 12 or per_100_carbs > 30 or per_100_fat > 8:
                return True
        return False

    def _repair_photo_foods(self, foods: list[Food], payload: dict[str, Any]) -> list[Food]:
        repaired: list[Food] = []
        payload_items = payload.get("items", [])
        for index, food in enumerate(foods):
            payload_item = payload_items[index] if index < len(payload_items) else {}
            visual = (payload_item or {}).get("visual_estimate") or {}
            if not self._photo_food_needs_repair(food, visual):
                repaired.append(food)
                continue
            candidates = (payload_item or {}).get("nutrition_candidates") or []
            visual_name = str(visual.get("name") or food.name)
            if self._plain_low_calorie_liquid_profile(visual_name):
                fixed = self._food_from_plain_low_calorie_liquid(visual, food.name or visual_name)
            elif candidates and not self._candidate_profile_outlier_reason(visual_name, candidates[0]):
                fixed = self._food_from_candidate(visual, candidates[0])
                fixed.name = food.name or fixed.name
            else:
                fixed = self._rough_food_from_estimate(visual)
                fixed.name = food.name or fixed.name
            repaired.append(fixed)
        return self._apply_visual_weights(repaired, payload)

    def _repair_direct_nutrition(self, foods: list[Food]) -> list[Food]:
        """Cheap sanity repairs for one-pass model nutrition, without DB lookups."""
        repaired = []
        for food in foods:
            grams = self._extract_grams(food.serving_size)
            calories = float(food.calories or 0)
            protein = max(0.0, float(food.protein or 0))
            carbs = max(0.0, float(food.carbs or 0))
            fat = max(0.0, float(food.fat or 0))
            fiber = max(0.0, float(food.fiber or 0))
            sodium = max(0.0, float(food.sodium or 0))

            plain_liquid_profile = self._plain_low_calorie_liquid_profile(food.name)
            if plain_liquid_profile and grams > 0:
                self._set_food_nutrition_from_profile(food, plain_liquid_profile, grams)
                food.sugar = 0
                food.added_sugar = 0
                repaired.append(food)
                continue

            direct_profile = self._direct_nutrition_profile(food.name)
            if direct_profile and grams > 0:
                ratio = grams / 100.0
                food.calories = round(direct_profile["calories"] * ratio, 1)
                food.protein = round(direct_profile["protein"] * ratio, 1)
                food.carbs = round(direct_profile["carbs"] * ratio, 1)
                food.fat = round(direct_profile["fat"] * ratio, 1)
                food.fiber = round(direct_profile["fiber"] * ratio, 1)
                food.sodium = round(direct_profile["sodium"] * ratio, 1)
                repaired.append(food)
                continue

            macro_kcal = protein * 4 + carbs * 4 + fat * 9
            name = food.name or ""
            if re.search(r"油|黄油|奶油|脂肪|肥肉|五花", name) and calories > 20:
                fat = max(fat, min(max(grams, 0.0), calories / 9.0))
            elif calories > 20 and macro_kcal > 0 and macro_kcal < calories * 0.45:
                missing_fat = (calories - macro_kcal) / 9.0
                if missing_fat > 0 and grams > 0 and fat + missing_fat <= grams * 0.95:
                    fat += missing_fat
            elif calories <= 0 and macro_kcal > 0:
                calories = macro_kcal

            food.protein = round(protein, 1)
            food.carbs = round(carbs, 1)
            food.fat = round(fat, 1)
            food.fiber = round(min(fiber, max(0.0, grams)), 1) if grams > 0 else round(fiber, 1)
            food.sodium = round(sodium, 1)
            food.calories = round(max(0.0, calories), 1)
            repaired.append(food)
        return repaired

    @staticmethod
    def _direct_nutrition_profile(name: str) -> dict[str, float] | None:
        for pattern, profile in DIRECT_NUTRITION_PROFILES:
            if pattern.search(name or ""):
                return profile
        return None

    def _attach_metadata_defaults(self, foods: list[Food], payload: dict[str, Any]) -> dict[str, Any]:
        metadata_items = []
        for food, payload_item in zip(foods, payload.get("items", [])):
            visual = payload_item.get("visual_estimate") or {}
            candidates = payload_item.get("nutrition_candidates") or []
            metadata_items.append(
                {
                    "name": food.name,
                    "estimated_grams": visual.get("estimated_grams"),
                    "quantity": visual.get("quantity"),
                    "quantity_detail": visual.get("quantity_detail"),
                    "visible_confidence": visual.get("visible_confidence"),
                    "nutrition_source": "database_candidate" if candidates else "ai_or_rough_estimate",
                    "candidate_count": len(candidates),
                    "top_candidate": candidates[0] if candidates else None,
                }
            )
        return {"strategy": "vision_db_candidates_ai_review", "items": metadata_items}

    async def _review_photo_nutrition(self, payload: dict[str, Any]) -> tuple[list[Food], str, dict[str, Any]]:
        user_prompt = (
            "请复核以下一拍即算数据，并返回 food_photo_nutrition_review.txt 要求的严格 JSON。\n\n"
            f"{json.dumps(payload, ensure_ascii=False)}"
        )
        review_provider = self.nutrition_review_provider or self.provider
        response_text = await review_provider.raw_completion(
            PHOTO_NUTRITION_REVIEW_PROMPT,
            user_prompt,
            max_tokens=4096,
        )
        _debug_log(f"[DEBUG] nutrition review response ({len(response_text)} chars): {response_text[:300]}...")
        foods, description = self._parse_response(response_text)
        data = self._extract_json_data(response_text)
        metadata = data.get("estimation_metadata") if isinstance(data.get("estimation_metadata"), dict) else {}
        if foods:
            foods = self._reconcile_photo_foods_with_payload(foods, payload)
            foods = self._apply_visual_weights(foods, payload)
            foods = self._repair_photo_foods(foods, payload)
            metadata["review_provider"] = str(getattr(review_provider, "model", None) or getattr(review_provider, "PROVIDER_LABEL", "") or type(review_provider).__name__)
            return foods[:MAX_PHOTO_ITEMS], description, metadata
        return [], description, metadata

    def _stream_candidate_summary(self, payload: dict[str, Any]) -> list[dict[str, Any]]:
        summary: list[dict[str, Any]] = []
        for payload_item in payload.get("items", []):
            visual = payload_item.get("visual_estimate") or {}
            candidates = payload_item.get("nutrition_candidates") or []
            summary.append(
                {
                    "name": visual.get("name"),
                    "estimated_grams": visual.get("estimated_grams"),
                    "quantity": visual.get("quantity"),
                    "cooking_method": visual.get("cooking_method"),
                    "confidence": visual.get("visible_confidence") or visual.get("confidence"),
                    "candidate_count": len(candidates),
                    "candidates": [
                        {
                            "name": candidate.get("name"),
                            "source": candidate.get("source"),
                            "match_score": candidate.get("match_score"),
                            "quality_score": candidate.get("quality_score"),
                            "quality_status": candidate.get("quality_status"),
                            "per_100g_nutrition": candidate.get("per_100g_nutrition"),
                        }
                        for candidate in candidates[:5]
                    ],
                }
            )
        return summary

    def _photo_capture_context_prompt(self, capture_context: dict[str, Any] | None) -> str:
        if not capture_context:
            return ""
        depth = capture_context.get("depth_metadata") if isinstance(capture_context.get("depth_metadata"), dict) else {}
        capture = capture_context.get("capture_metadata") if isinstance(capture_context.get("capture_metadata"), dict) else {}
        has_reliable_depth = bool(capture.get("has_depth")) and bool(depth.get("available")) and bool(depth.get("valid_sample_count") or depth.get("foreground_sample_count"))
        parts = []
        if capture:
            parts.append(
                "拍摄来源: "
                + str(capture.get("source") or "unknown")
                + f"; has_depth={bool(capture.get('has_depth'))}"
            )
        if depth:
            volume_bits = []
            for key, label in [
                ("roi_mean_depth_m", "roi_mean_depth_m"),
                ("background_depth_m", "background_depth_m"),
                ("foreground_area_ratio", "foreground_area_ratio"),
                ("mean_foreground_height_m", "mean_food_height_m"),
                ("max_foreground_height_m", "max_food_height_m"),
                ("relative_volume_proxy", "relative_volume_proxy"),
                ("volume_method", "volume_method"),
            ]:
                value = depth.get(key)
                if value is not None:
                    volume_bits.append(f"{label}={value}")
            parts.append(
                "深度传感器摘要: "
                + f"available={bool(depth.get('available'))}, "
                + f"mean_depth_m={depth.get('mean_depth_m')}, "
                + f"min_depth_m={depth.get('min_depth_m')}, "
                + f"max_depth_m={depth.get('max_depth_m')}, "
                + f"valid_samples={depth.get('valid_sample_count')}"
                + (", " + ", ".join(volume_bits) if volume_bits else "")
            )
        if not parts:
            return ""
        depth_rule = (
            "如果 foreground_area_ratio、mean_food_height_m、relative_volume_proxy 可用，优先用它校准份量大小："
            "前景面积更大或食物高度更高时，不要低估克重；但不能因此识别图片中不可见食物。"
            if has_reliable_depth
            else (
                "当前没有可靠 depth/体积数据，必须走单目图片估重 fallback："
                "1) 用餐盘/碗/杯/餐盒/蛋挞托/筷子/勺子等可见参照物估尺度；"
                "2) 用食物在容器中的2D面积占比和堆叠高度外观估可食体积；"
                "3) 对可数食物先数数量，再乘常见单个重量并结合图片大小修正；"
                "4) 对米饭、面、汤、沙拉等用碗/盘占比和常见份量模板估重；"
                "5) estimated_grams 必须和 quantity/notes 可解释一致，禁止默认100克或频繁输出50/100/150/200/250占位数；"
                "6) 看不清或缺少尺度参照时降低置信度，并在依据里说明。"
            )
        )
        return (
            "\n\n额外拍摄/深度/体积信息（只能作为份量和距离参考，不能替代图片可见内容）："
            + "；".join(parts)
            + "。"
            + depth_rule
        )

    async def analyze_image_stages(self, image_base64: str, capture_context: dict[str, Any] | None = None):
        """Yield staged photo-analysis events for streaming UIs."""
        image_base64 = self._compress_image_base64(image_base64)
        context_prompt = self._photo_capture_context_prompt(capture_context)
        mode = os.getenv("PHOTO_ANALYSIS_MODE", "two_pass").strip().lower()
        if mode in {"direct", "direct_nutrition", "fast", "single_pass"}:
            yield {"stage": "vision_started", "message": "正在直接识别食物、克重和营养"}
            foods, description, metadata = await self._analyze_image_direct_nutrition(image_base64, context_prompt=context_prompt)
            if not foods:
                yield {"stage": "error", "message": description or "没有识别到可保存的食物"}
                return
            yield {
                "stage": "final",
                "foods": [food.model_dump(mode="json") for food in foods[:MAX_PHOTO_ITEMS]],
                "description": description,
                "estimation_metadata": metadata,
            }
            return

        yield {"stage": "vision_started", "message": "正在识别可见食物和估重"}

        try:
            detection_text = await self.provider.analyze_image_with_prompt(
                image_base64,
                PHOTO_DETECTION_PROMPT,
                PHOTO_DETECTION_USER_PROMPT + context_prompt,
                max_tokens=4096,
            )
        except Exception as exc:
            yield {"stage": "error", "message": self._image_provider_error_message(exc)}
            return
        visual_items, detection_description = self._parse_visual_estimates(detection_text)
        if not visual_items:
            yield {"stage": "error", "message": "没有识别到可保存的食物"}
            return

        yield {
            "stage": "vision_items",
            "description": detection_description,
            "items": visual_items,
        }

        limited_visual_items = visual_items[:MAX_PHOTO_ITEMS]
        payload_items: list[dict[str, Any] | None] = [None] * len(limited_visual_items)

        async def build_payload_item(index: int, item: dict[str, Any]) -> tuple[int, dict[str, Any]]:
            return index, await asyncio.to_thread(self._build_photo_candidate_payload_item, item)

        candidate_tasks = [
            asyncio.create_task(build_payload_item(index, item))
            for index, item in enumerate(limited_visual_items)
        ]
        completed = 0
        for task in asyncio.as_completed(candidate_tasks):
            index, payload_item = await task
            payload_items[index] = payload_item
            completed += 1
            single_summary = self._stream_candidate_summary({"items": [payload_item]})
            yield {
                "stage": "database_candidate",
                "item": single_summary[0] if single_summary else {},
                "completed": completed,
                "total": len(candidate_tasks),
            }

        payload = {
            "items": [item for item in payload_items if item is not None],
            "rules": self._photo_candidate_rules(),
        }
        yield {
            "stage": "database_candidates",
            "items": self._stream_candidate_summary(payload),
        }

        yield {
            "stage": "nutrition_review_started",
            "message": "正在用数据库候选和 DeepSeek 复核营养",
        }
        try:
            foods, desc, metadata = await self._review_photo_nutrition(payload)
        except Exception as review_error:
            _debug_log(f"[DEBUG] streaming nutrition review failed: {type(review_error).__name__}: {review_error!r}")
            foods, desc, metadata = [], "", {}

        if not foods:
            foods = self._fallback_foods_from_payload(payload)
            desc = detection_description or "已根据图片识别和数据库候选估算营养。"
            metadata = self._attach_metadata_defaults(foods, payload)
        else:
            foods = self._reconcile_photo_foods_with_payload(foods, payload)
            foods = self._apply_visual_weights(foods, payload)
            foods = self._repair_photo_foods(foods, payload)
            default_metadata = self._attach_metadata_defaults(foods, payload)
            if not metadata:
                metadata = default_metadata
            elif not isinstance(metadata.get("items"), list):
                metadata = {**default_metadata, **metadata}

        foods = self._attach_visual_quantity(foods, payload)
        metadata_items = metadata.get("items") if isinstance(metadata.get("items"), list) else []
        foods, metadata_items = self._dedupe_photo_foods_with_metadata(foods, metadata_items)
        metadata["items"] = metadata_items
        metadata.setdefault("strategy", "vision_db_candidates_deepseek_review")

        yield {
            "stage": "final",
            "foods": [food.model_dump(mode="json") for food in foods[:MAX_PHOTO_ITEMS]],
            "description": desc or detection_description,
            "estimation_metadata": metadata,
        }

    @staticmethod
    def _cloud_float(value: Any, default: float = 0.0) -> float:
        try:
            return float(value)
        except Exception:
            return default

    def _cloud_food_from_item(self, item: dict[str, Any]) -> tuple[Food, dict[str, Any]]:
        name = str(item.get("name_zh") or item.get("name_en") or "食物").strip()
        food_key = str(item.get("food_key") or item.get("nutrition_key") or "").strip()
        category = str(item.get("category") or "").strip()
        volume_ml = max(1.0, self._cloud_float(item.get("volume_ml"), 1.0))
        weight_pack = estimate_weight_from_volume(
            food_key,
            volume_ml,
            density_hint=item.get("density_hint") if isinstance(item.get("density_hint"), dict) else None,
            category=category,
            name=name,
        )
        grams = self._cloud_float(item.get("estimated_grams"), 0.0) or self._cloud_float(weight_pack.get("estimated_grams"), 0.0)

        direct = item.get("direct_nutrition") if isinstance(item.get("direct_nutrition"), dict) else {}
        if direct and any(self._cloud_float(value, 0.0) > 0 for value in direct.values()):
            nutrition = {
                "calories": round(self._cloud_float(direct.get("calories"), 0.0), 1),
                "protein_g": round(self._cloud_float(direct.get("protein_g"), 0.0), 1),
                "carbs_g": round(self._cloud_float(direct.get("carbs_g"), 0.0), 1),
                "fat_g": round(self._cloud_float(direct.get("fat_g"), 0.0), 1),
                "fiber_g": round(self._cloud_float(direct.get("fiber_g"), 0.0), 1),
                "sodium_mg": round(self._cloud_float(direct.get("sodium_mg"), 0.0), 1),
            }
            nutrition_source = "cloud_direct_nutrition"
        else:
            nutrition_pack = calculate_item_nutrition(
                food_key,
                grams,
                bool(item.get("mixed_dish")),
                nutrition_per_100g=item.get("nutrition_per_100g") if isinstance(item.get("nutrition_per_100g"), dict) else None,
            )
            nutrition = nutrition_pack.get("total", {})
            nutrition_source = "density_volume_nutrition"

        grams_label = round(max(0.0, grams), 1)
        food = Food(
            name=name,
            calories=round(self._cloud_float(nutrition.get("calories"), 0.0), 1),
            protein=round(self._cloud_float(nutrition.get("protein_g"), 0.0), 1),
            carbs=round(self._cloud_float(nutrition.get("carbs_g"), 0.0), 1),
            fat=round(self._cloud_float(nutrition.get("fat_g"), 0.0), 1),
            fiber=round(self._cloud_float(nutrition.get("fiber_g"), 0.0), 1),
            sugar=0.0,
            sodium=round(self._cloud_float(nutrition.get("sodium_mg"), 0.0), 1),
            serving_size=f"{grams_label:g}g",
            quantity_count=grams_label,
            quantity_unit="g",
            quantity_description=f"{round(volume_ml, 1):g}ml / {grams_label:g}g",
        )
        metadata = {
            "name": name,
            "food_key": food_key,
            "category": category,
            "estimated_volume_ml": round(volume_ml, 1),
            "estimated_grams": grams_label,
            "estimated_grams_min": weight_pack.get("estimated_grams_min"),
            "estimated_grams_max": weight_pack.get("estimated_grams_max"),
            "density_g_per_ml": weight_pack.get("density_g_per_ml"),
            "density_source": weight_pack.get("density_source"),
            "nutrition_source": nutrition_source,
            "volume_method": item.get("volume_method"),
            "detector": item.get("detector"),
            "detector_phrase": item.get("detector_phrase"),
            "detector_score": item.get("detector_score"),
            "bbox": item.get("bbox"),
            "segmentation_model": item.get("segmentation_model"),
            "mask_area_pixels": item.get("mask_area_pixels"),
            "mask_confidence": item.get("mask_confidence"),
            "fallback": item.get("fallback"),
            "fallback_reason": item.get("fallback_reason"),
            "needs_user_check": item.get("needs_user_check") or [],
        }
        return food, metadata

    async def _analyze_image_cloud_depth(
        self,
        image_base64: str,
        capture_context: dict[str, Any] | None = None,
    ) -> tuple[list[Food], str, dict[str, Any]]:
        client = DepthCloudPipelineClient()
        capture_context = capture_context or {}
        depth_metadata = capture_context.get("depth_metadata") if isinstance(capture_context.get("depth_metadata"), dict) else {}
        capture_metadata = capture_context.get("capture_metadata") if isinstance(capture_context.get("capture_metadata"), dict) else {}
        metadata = {
            "depth_metadata": depth_metadata,
            "capture_metadata": capture_metadata,
        }
        raw = await asyncio.to_thread(
            client.analyze_image_base64,
            image_base64,
            metadata=metadata,
            user_hint=str(capture_metadata.get("user_hint") or ""),
            container_hint=str(capture_metadata.get("container_hint") or ""),
            meal_type=str(capture_metadata.get("meal_type") or ""),
        )
        items = raw.get("normalized_items") if isinstance(raw.get("normalized_items"), list) else []
        foods: list[Food] = []
        metadata_items: list[dict[str, Any]] = []
        for item in items[:MAX_PHOTO_ITEMS]:
            if not isinstance(item, dict):
                continue
            food, item_metadata = self._cloud_food_from_item(item)
            foods.append(food)
            metadata_items.append(item_metadata)

        description = f"云端 Food-GR1 depth pipeline 已识别 {len(foods)} 项食物。"
        return foods, description, {
            "strategy": "cloud_foodgr1_depth_pipeline",
            "mode": raw.get("mode"),
            "status": raw.get("status"),
            "items": metadata_items,
            "timings": raw.get("timings"),
            "detections_count": len(raw.get("detections") or []),
            "segmentations_count": len(raw.get("segmentations") or []),
        }

    async def _analyze_image(
        self,
        image_base64: str,
        capture_context: dict[str, Any] | None = None,
    ) -> tuple[list[Food], str, dict[str, Any]]:
        """Two-pass photo analysis: vision estimates weight, DB candidates calibrate nutrition, AI reviews."""
        image_base64 = self._compress_image_base64(image_base64)
        context_prompt = self._photo_capture_context_prompt(capture_context)

        mode = os.getenv("PHOTO_ANALYSIS_MODE", "two_pass").strip().lower()
        if mode in {"cloud_depth", "depth_pipeline", "foodgr1_depth", "metric3d_depth"}:
            try:
                return await self._analyze_image_cloud_depth(image_base64, capture_context=capture_context)
            except Exception as cloud_error:
                _debug_log(f"[DEBUG] cloud depth pipeline failed: {type(cloud_error).__name__}: {cloud_error!r}")
                fallback_to_llm = os.getenv("PHOTO_CLOUD_DEPTH_FALLBACK_TO_LLM", "false").strip().lower() in {"1", "true", "yes", "on"}
                if not fallback_to_llm:
                    return [], f"云端 Food-GR1 depth pipeline 调用失败：{cloud_error}", {
                        "strategy": "cloud_depth_pipeline_failed",
                        "items": [],
                        "error_type": type(cloud_error).__name__,
                        "error_message": str(cloud_error)[:500],
                    }

        if mode in {"direct_db", "model_db", "hybrid_direct_db", "direct_nutrition_db"}:
            return await self._analyze_image_direct_db(image_base64, context_prompt=context_prompt)
        if mode in {"fast_db", "vision_db_fast", "fast_database"}:
            return await self._analyze_image_fast_db(image_base64, context_prompt=context_prompt)
        if mode in {"direct", "direct_nutrition", "fast", "single_pass"}:
            return await self._analyze_image_direct_nutrition(image_base64, context_prompt=context_prompt)

        try:
            detection_text = await self.provider.analyze_image_with_prompt(
                image_base64,
                PHOTO_DETECTION_PROMPT,
                PHOTO_DETECTION_USER_PROMPT + context_prompt,
                max_tokens=4096,
            )
            _debug_log(f"[DEBUG] vision estimate response ({len(detection_text)} chars): {detection_text[:300]}...")
            visual_items, detection_description = self._parse_visual_estimates(detection_text)
            if not visual_items:
                _debug_log(f"[DEBUG] Vision estimate returned 0 items. Response was: {detection_text[:500]}")
                legacy_text = await self.provider.analyze_image(image_base64)
                foods, desc = self._parse_response(legacy_text)
                if foods:
                    metadata = {"strategy": "legacy_single_pass_fallback", "items": []}
                    return foods[:MAX_PHOTO_ITEMS], desc, metadata
                return [], "没有识别到食物", {"strategy": "vision_detection_failed", "items": []}

            payload = await self._build_photo_candidate_payload_async(visual_items)
            try:
                foods, desc, metadata = await self._review_photo_nutrition(payload)
            except Exception as review_error:
                _debug_log(f"[DEBUG] nutrition review failed: {type(review_error).__name__}: {review_error!r}")
                foods, desc, metadata = [], "", {}

            if not foods:
                foods = self._fallback_foods_from_payload(payload)
                desc = detection_description or "已根据图片识别和数据库候选估算营养。"
                metadata = self._attach_metadata_defaults(foods, payload)
            else:
                foods = self._reconcile_photo_foods_with_payload(foods, payload)
                foods = self._apply_visual_weights(foods, payload)
                foods = self._repair_photo_foods(foods, payload)
                default_metadata = self._attach_metadata_defaults(foods, payload)
                if not metadata:
                    metadata = default_metadata
                elif not isinstance(metadata.get("items"), list):
                    metadata = {**default_metadata, **metadata}

            foods = self._attach_visual_quantity(foods, payload)
            metadata_items = metadata.get("items") if isinstance(metadata.get("items"), list) else []
            foods, metadata_items = self._dedupe_photo_foods_with_metadata(foods, metadata_items)
            metadata["items"] = metadata_items
            return foods[:MAX_PHOTO_ITEMS], desc or detection_description, metadata
        except Exception as e:
            _debug_exception()
            message = self._image_provider_error_message(e)
            strategy = "image_not_supported" if "does not support image" in str(e).lower() else "image_provider_failed"
            return [], message, {
                "strategy": strategy,
                "items": [],
                "error_type": type(e).__name__,
                "error_message": str(e)[:500],
            }

    async def _analyze_image_direct_db(
        self,
        image_base64: str,
        context_prompt: str = "",
    ) -> tuple[list[Food], str, dict[str, Any]]:
        """One model pass returns nutrition; strong DB matches override model nutrition."""
        try:
            response_text = await self.provider.analyze_image_with_prompt(
                image_base64,
                PHOTO_DIRECT_NUTRITION_PROMPT,
                PHOTO_DIRECT_NUTRITION_USER_PROMPT + context_prompt,
                max_tokens=_env_int("PHOTO_DIRECT_MAX_TOKENS", 1024, 512, 2048),
            )
            _debug_log(f"[DEBUG] direct db response ({len(response_text)} chars): {response_text[:300]}...")
            response_data = self._extract_json_data(response_text)
            direct_items = self._parse_direct_nutrition_items(response_text)
            model_foods, description = self._parse_response(response_text)
            if not model_foods:
                _debug_log(f"[DEBUG] Direct DB mode returned 0 foods. Response was: {response_text[:500]}")
                return [], "没有识别到可保存的食物", {"strategy": "direct_db_detection_failed", "items": []}

            matched = await asyncio.gather(
                *[
                    asyncio.to_thread(self._override_direct_food_with_database, food)
                    for food in model_foods[:MAX_PHOTO_ITEMS]
                ]
            )
            foods = [food for food, _ in matched]
            metadata_items = [meta for _, meta in matched]
            for index, meta in enumerate(metadata_items):
                if index < len(direct_items):
                    meta.update({
                        "quantity": direct_items[index].get("quantity") or "",
                        "cooking_method": direct_items[index].get("cooking_method") or "",
                        "visible_desc": direct_items[index].get("visible_desc") or "",
                        "model_confidence": direct_items[index].get("model_confidence"),
                        "model_direct_nutrition": direct_items[index].get("model_direct_nutrition") or {},
                    })
                    if direct_items[index].get("model_reason"):
                        meta["model_reason"] = direct_items[index]["model_reason"]

            foods, metadata_items = self._dedupe_photo_foods_with_metadata(foods, metadata_items)
            metadata = {
                "strategy": "direct_model_db_override",
                "title": str(response_data.get("title") or response_data.get("meal_title") or "").strip(),
                "model_description": str(response_data.get("d") or response_data.get("description") or "").strip(),
                "items": metadata_items,
                "database_override_count": sum(1 for item in metadata_items if item.get("nutrition_source") == "database_strong_match"),
                "needs_ai_review": any(item.get("needs_ai_review") for item in metadata_items),
            }
            return foods[:MAX_PHOTO_ITEMS], description or "已根据图片直接估算，并用数据库强匹配校准营养。", metadata
        except Exception as e:
            _debug_exception()
            message = self._image_provider_error_message(e)
            strategy = "image_not_supported" if "does not support image" in str(e).lower() else "image_provider_failed"
            return [], message, {
                "strategy": strategy,
                "items": [],
                "error_type": type(e).__name__,
                "error_message": str(e)[:500],
            }

    async def _analyze_image_fast_db(
        self,
        image_base64: str,
        context_prompt: str = "",
    ) -> tuple[list[Food], str, dict[str, Any]]:
        """Fast path: one vision pass for names/grams, then indexed DB nutrition by grams."""
        try:
            detection_text = await self.provider.analyze_image_with_prompt(
                image_base64,
                PHOTO_FAST_DETECTION_PROMPT,
                PHOTO_FAST_DETECTION_USER_PROMPT + context_prompt,
                max_tokens=768,
            )
            _debug_log(f"[DEBUG] fast detection response ({len(detection_text)} chars): {detection_text[:300]}...")
            visual_items, detection_description = self._parse_visual_estimates(detection_text)
            if not visual_items:
                _debug_log(f"[DEBUG] Fast detection returned 0 items. Response was: {detection_text[:500]}")
                return [], "没有识别到可保存的食物", {"strategy": "fast_db_detection_failed", "items": []}

            matched = await asyncio.gather(
                *[
                    asyncio.to_thread(self._food_from_fast_db_item, item)
                    for item in visual_items[:MAX_PHOTO_ITEMS]
                ]
            )
            foods = [food for food, _ in matched]
            metadata_items = [meta for _, meta in matched]

            foods = self._attach_visual_quantity(foods, {"items": [{"visual_estimate": item} for item in visual_items]})
            foods, metadata_items = self._dedupe_photo_foods_with_metadata(foods, metadata_items)
            metadata = {
                "strategy": "vision_fast_db_nutrition",
                "items": metadata_items,
                "needs_ai_review": any(item.get("needs_ai_review") for item in metadata_items),
            }
            return foods[:MAX_PHOTO_ITEMS], detection_description or "已根据图片估重并用数据库快速换算营养。", metadata
        except Exception as e:
            _debug_exception()
            message = self._image_provider_error_message(e)
            strategy = "image_not_supported" if "does not support image" in str(e).lower() else "image_provider_failed"
            return [], message, {
                "strategy": strategy,
                "items": [],
                "error_type": type(e).__name__,
                "error_message": str(e)[:500],
            }

    async def _analyze_image_direct_nutrition(
        self,
        image_base64: str,
        context_prompt: str = "",
    ) -> tuple[list[Food], str, dict[str, Any]]:
        """Single-pass photo analysis: the vision model returns weight and core nutrition directly."""
        cache_key = self._photo_cache_key(image_base64, context_prompt)
        cached = self._get_cached_photo_result(cache_key)
        if cached is not None:
            return cached
        try:
            response_text = await self.provider.analyze_image_with_prompt(
                image_base64,
                PHOTO_DIRECT_NUTRITION_PROMPT,
                PHOTO_DIRECT_NUTRITION_USER_PROMPT + context_prompt,
                max_tokens=_env_int("PHOTO_DIRECT_MAX_TOKENS", 1024, 512, 2048),
            )
            _debug_log(f"[DEBUG] direct nutrition response ({len(response_text)} chars): {response_text[:300]}...")
            direct_items = self._parse_direct_nutrition_items(response_text)
            foods, description = self._parse_response(response_text)
            if not foods:
                _debug_log(f"[DEBUG] Direct nutrition returned 0 foods. Response was: {response_text[:500]}")
                return [], "没有识别到可保存的食物", {"strategy": "direct_nutrition_failed", "items": []}
            foods = self._repair_direct_nutrition(foods[:MAX_PHOTO_ITEMS])
            metadata_items = [
                {
                    "name": food.name,
                    "estimated_grams": self._extract_grams(food.serving_size),
                    "quantity": direct_items[index].get("quantity") if index < len(direct_items) else "",
                    "cooking_method": direct_items[index].get("cooking_method") if index < len(direct_items) else "",
                    "visible_desc": direct_items[index].get("visible_desc") if index < len(direct_items) else "",
                    "model_confidence": direct_items[index].get("model_confidence") if index < len(direct_items) else None,
                    "model_direct_nutrition": direct_items[index].get("model_direct_nutrition") if index < len(direct_items) else {},
                    "nutrition_source": "vision_model_direct",
                }
                for index, food in enumerate(foods)
            ]
            foods, metadata_items = self._dedupe_photo_foods_with_metadata(foods, metadata_items)
            metadata = {
                "strategy": "direct_image_nutrition",
                "items": metadata_items,
                "cache_hit": False,
            }
            if context_prompt:
                metadata["capture_context_used"] = True
            final_description = description or "已根据图片直接估算克重和核心营养。"
            self._cache_photo_result(cache_key, foods, final_description, metadata)
            return foods, final_description, metadata
        except Exception as e:
            _debug_exception()
            message = self._image_provider_error_message(e)
            strategy = "image_not_supported" if "does not support image" in str(e).lower() else "image_provider_failed"
            return [], message, {
                "strategy": strategy,
                "items": [],
                "error_type": type(e).__name__,
                "error_message": str(e)[:500],
            }

    async def _analyze_text(self, text: str) -> tuple[list[Food], str]:
        """Analyze food from a text description using LLM provider."""
        try:
            response_text = await self.provider.analyze_text(text)
            foods, desc = self._parse_response(response_text)
            if foods:
                return foods, desc
            return self._mock_analyze(text)
        except Exception:
            return self._mock_analyze(text)

    def _mock_analyze(self, text: str) -> tuple[list[Food], str]:
        """Mock food analysis when Gemini API is unavailable.

        Uses keyword matching against the food database to generate
        realistic nutrition data without an API call.
        """
        import sqlite3

        text_lower = text.lower()
        food_names = []
        descriptions = []

        # Keyword-driven food detection
        mappings = [
            ("鸡胸肉", "Chicken breast, grilled, skinless"),
            ("鸡腿", "Chicken breast, grilled, skinless"),
            ("西兰花", "Broccoli, steamed"),
            ("糙米饭", "Brown rice, cooked"),
            ("糙米", "Brown rice, cooked"),
            ("白米饭", "White rice, cooked"),
            ("米饭", "White rice, cooked"),
            ("三文鱼", "Salmon, Atlantic, cooked"),
            ("鲑鱼", "Salmon, Atlantic, cooked"),
            ("牛排", "Beef steak, sirloin, grilled"),
            ("牛肉", "Beef steak, sirloin, grilled"),
            ("鸡蛋", "Egg, whole, large, boiled"),
            ("苹果", "Apple, raw, medium"),
            ("香蕉", "Banana, raw, medium"),
            ("酸奶", "Greek yogurt, plain, nonfat"),
            ("豆腐", "Tofu, firm, raw"),
            ("杏仁", "Almonds, raw"),
            ("薯片", "Potato chips, plain, salted"),
            ("可乐", "Coca-Cola, original"),
            ("可口可乐", "Coca-Cola, original"),
            ("披萨", "Pizza, cheese, regular crust"),
            ("方便面", "Instant ramen noodles, cooked"),
            ("泡面", "Instant ramen noodles, cooked"),
            ("全麦面包", "Whole wheat bread, slice"),
            ("面包", "Whole wheat bread, slice"),
            ("沙拉", "Mixed green salad, no dressing"),
            ("橙汁", "Orange juice, fresh squeezed"),
            ("橄榄油", "Olive oil, extra virgin"),
            ("cola", "Coca-Cola, original"),
            ("chicken breast", "Chicken breast, grilled, skinless"),
            ("broccoli", "Broccoli, steamed"),
            ("brown rice", "Brown rice, cooked"),
            ("white rice", "White rice, cooked"),
            ("salmon", "Salmon, Atlantic, cooked"),
            ("steak", "Beef steak, sirloin, grilled"),
            ("egg", "Egg, whole, large, boiled"),
            ("apple", "Apple, raw, medium"),
            ("banana", "Banana, raw, medium"),
            ("yogurt", "Greek yogurt, plain, nonfat"),
            ("tofu", "Tofu, firm, raw"),
            ("almonds", "Almonds, raw"),
            ("potato chip", "Potato chips, plain, salted"),
            ("chips", "Potato chips, plain, salted"),
            ("coke", "Coca-Cola, original"),
            ("coca cola", "Coca-Cola, original"),
            ("pizza", "Pizza, cheese, regular crust"),
            ("ramen", "Instant ramen noodles, cooked"),
            ("instant noodle", "Instant ramen noodles, cooked"),
            ("bread", "Whole wheat bread, slice"),
            ("salad", "Mixed green salad, no dressing"),
            ("orange juice", "Orange juice, fresh squeezed"),
            ("olive oil", "Olive oil, extra virgin"),
        ]

        for keyword, food_name in mappings:
            if keyword in text_lower:
                food_names.append(food_name)
            descriptions.append(food_name)

        if not food_names:
            food_names.append("Mixed green salad, no dressing")
            descriptions.append("未知餐食")

        # Direct SQLite lookup (sync, no event loop needed)
        foods = []
        conn = sqlite3.connect(str(self.food_db.db_path))
        conn.row_factory = sqlite3.Row
        for name in food_names:
            rows = conn.execute(
                "SELECT * FROM foods WHERE name LIKE ? LIMIT 1",
                (f"%{name}%",),
            ).fetchall()
            if rows:
                row = rows[0]
                f = self.food_db._row_to_food(row)
                f.id = f"{f.name[:8].replace(' ', '').lower()}_{len(foods)}"
                foods.append(f)
        conn.close()

        self._save_to_db(foods)

        desc_parts = list(dict.fromkeys([food.name for food in foods] or descriptions))  # deduplicate
        desc = f"识别到：{'、'.join(desc_parts)}"
        if any(f.processing_level.value in ("processed", "ultra_processed") for f in foods):
            desc += " 检测到部分加工食品。"

        return foods, desc

    async def _lookup_barcode(self, barcode: str) -> tuple[list[Food], str]:
        """Look up locally first, then cache an Open Food Facts result."""
        raw_barcode = str(barcode or "").strip()
        if not re.fullmatch(r"\d{8,14}", raw_barcode):
            raise ValueError("条形码应为 8–14 位数字")
        clean_barcode = raw_barcode
        food = await self.food_db.lookup_barcode(clean_barcode)
        if food:
            return [food], f"已找到：{food.name}"
        try:
            food = await self.open_food_facts.lookup(clean_barcode)
        except Exception as exc:
            _debug_log(f"[DEBUG] Open Food Facts lookup failed: {type(exc).__name__}: {exc}")
            food = None
        if food:
            await self.food_db.cache_barcode_food(food, clean_barcode, "open_food_facts")
            return [food], f"已找到：{food.name}（Open Food Facts）"
        return [], f"没有找到条形码 {clean_barcode or barcode} 对应的食品，请扫营养表或手动搜索。"

    async def _analyze_barcode_image(self, image_base64: str) -> tuple[list[Food], str]:
        """Use LLM vision to read barcode number from photo, then look up in DB."""
        if not self.provider:
            return [], "条形码识别暂不可用，未配置视觉模型。"

        barcode_prompt = """Read the barcode number from this product packaging photo.
Return ONLY the barcode digits. If no barcode is visible, return "NO_BARCODE".
No other text."""

        try:
            response_text = await self.provider.raw_completion(
                barcode_prompt, "", max_tokens=64
            )
        except Exception:
            # Try analyze_text as fallback - some providers route through different paths
            from io import BytesIO
            import base64
            img_bytes = base64.b64decode(image_base64)
            try:
                response_text = await self.provider._call(
                    barcode_prompt, image_bytes=img_bytes, max_tokens=64
                )
            except Exception:
                return [], "没有读到条形码，请重新拍摄或手动输入。"

        barcode = response_text.strip()
        if not barcode or "NO_BARCODE" in barcode:
            return [], "图片里没有检测到条形码。"

        # Look up in database
        return await self._lookup_barcode(barcode)

    @staticmethod
    def _normalize_processing(level: str) -> str:
        """Map non-standard processing levels (including Chinese) to valid enum values."""
        level = (level or "").lower().strip()
        # Chinese
        if "超加工" in level or "ultra" in level or "highly" in level:
            return "ultra_processed"
        if "轻加工" in level or "最小加工" in level or "minimally" in level or "light" in level:
            return "minimally_processed"
        if "加工" in level or "moderate" in level or "processed" in level:
            return "processed"
        if "天然" in level or "全食物" in level or level == "whole":
            return "whole"
        return "whole"

    @staticmethod
    def _safe_float(val, default=0.0) -> float:
        """Convert LLM response value to float, handling '未知', 'N/A', etc."""
        if val is None:
            return default
        if isinstance(val, (int, float)):
            return float(val)
        if isinstance(val, str):
            val = val.strip()
            if val in ("未知", "N/A", "NA", "unknown", "null", "", "-", "—"):
                return default
            try:
                return float(val)
            except ValueError:
                return default
        return default

    def _parse_response(self, text: str) -> tuple[list[Food], str]:
        """Parse LLM's JSON response into Food objects.

        Handles truncated JSON by salvaging complete food entries.
        """
        if not text:
            return [], "没有识别到食物"

        # strip markdown code blocks if present
        text = text.strip()
        answer_match = re.search(r"<answer>\s*(.*?)\s*</answer>", text, re.DOTALL | re.IGNORECASE)
        if answer_match:
            text = answer_match.group(1).strip()
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL | re.IGNORECASE).strip()
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)

        data = None
        # Try full parse first
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            # Try extracting JSON object
            match = re.search(r"\{.*\}", text, re.DOTALL)
            if match:
                try:
                    data = json.loads(match.group())
                except json.JSONDecodeError:
                    # Try to salvage: extract complete food entries from truncated JSON
                    food_entries = re.findall(r'\{\s*"(?:name|n|name_zh)":\s*"([^"]+)"[^}]*?\}', text, re.DOTALL)
                    if food_entries:
                        # At minimum, extract food names
                        data = {
                            "foods": [{"name": n} for n in food_entries],
                            "description": "已识别部分内容",
                        }
                    else:
                        return [], "营养数据解析失败"
            else:
                return [], "营养数据解析失败"

        def first_value(*values):
            for value in values:
                if value is not None and value != "":
                    return value
            return None

        foods = []
        for item in data.get("foods", []):
            if not isinstance(item, dict):
                continue
            nutrition = item.get("nutrition") if isinstance(item.get("nutrition"), dict) else {}
            name = (
                item.get("name")
                or item.get("n")
                or item.get("final_name_zh")
                or item.get("name_zh")
                or item.get("food_name")
                or "未知食物"
            )
            serving_grams = self._safe_float(
                first_value(
                    item.get("serving_size_grams"),
                    item.get("estimated_grams"),
                    item.get("g"),
                    item.get("grams"),
                    item.get("pass1_estimated_grams"),
                )
            )
            serving_size = f"{round(serving_grams)}克" if serving_grams > 0 else str(item.get("serving_size") or "100克")
            method_hint = " ".join(
                str(value or "")
                for value in [
                    item.get("category"),
                    item.get("source_type"),
                    item.get("source_name"),
                    item.get("calculation_basis"),
                    item.get("source_reason"),
                ]
            )
            processing_level = item.get("processing_level") or item.get("pl")
            if not processing_level:
                processing_level = "processed" if re.search(r"炸|油炸|薯条|烤肠|蛋挞|芝士条|包装|加工", f"{name} {method_hint}") else "whole"
            food = Food(
                name=_display_food_name(str(name)),
                calories=self._safe_float(first_value(item.get("calories"), item.get("calories_kcal"), item.get("kcal"), nutrition.get("calories_kcal"), nutrition.get("calories"))),
                protein=self._safe_float(first_value(item.get("protein"), item.get("protein_g"), item.get("p"), nutrition.get("protein_g"), nutrition.get("protein"))),
                carbs=self._safe_float(first_value(item.get("carbs"), item.get("carbohydrate"), item.get("carbohydrate_g"), item.get("c"), nutrition.get("carbohydrate_g"), nutrition.get("carbs_g"), nutrition.get("carbs"))),
                fat=self._safe_float(first_value(item.get("fat"), item.get("fat_g"), item.get("f"), nutrition.get("fat_g"), nutrition.get("fat"))),
                fiber=self._safe_float(first_value(item.get("fiber"), item.get("fiber_g"), item.get("fi"), nutrition.get("fiber_g"), nutrition.get("fiber"))),
                sugar=self._safe_float(first_value(item.get("sugar"), item.get("sugar_g"), nutrition.get("sugar_g"), nutrition.get("sugar"))),
                sodium=self._safe_float(first_value(item.get("sodium"), item.get("sodium_mg"), item.get("na"), nutrition.get("sodium_mg"), nutrition.get("sodium"))),
                serving_size=_display_serving_size(serving_size),
                processing_level=self._normalize_processing(str(processing_level or "whole")),
                added_sugar=self._safe_float(first_value(item.get("added_sugar"), item.get("added_sugar_g"), nutrition.get("added_sugar_g"), nutrition.get("added_sugar"))),
                sat_fat=self._safe_float(first_value(item.get("sat_fat"), item.get("sat_fat_g"), nutrition.get("sat_fat_g"), nutrition.get("sat_fat"))),
                trans_fat=self._safe_float(first_value(item.get("trans_fat"), item.get("trans_fat_g"), nutrition.get("trans_fat_g"), nutrition.get("trans_fat"))),
                cholesterol=self._safe_float(first_value(item.get("cholesterol"), item.get("cholesterol_mg"), nutrition.get("cholesterol_mg"), nutrition.get("cholesterol"))),
                vitamin_a=self._safe_float(first_value(item.get("vitamin_a"), nutrition.get("vitamin_a"))),
                vitamin_c=self._safe_float(first_value(item.get("vitamin_c"), nutrition.get("vitamin_c"))),
                calcium=self._safe_float(first_value(item.get("calcium"), nutrition.get("calcium"))),
                iron=self._safe_float(first_value(item.get("iron"), nutrition.get("iron"))),
                potassium=self._safe_float(first_value(item.get("potassium"), nutrition.get("potassium"))),
            )
            # Accept foods: either has nutrition OR has serving_size (will be enriched later)
            has_nutrition = food.calories > 0 or food.protein > 0
            has_weight = self._extract_grams(food.serving_size) > 0
            if food.name and (has_nutrition or has_weight):
                foods.append(food)

        description = data.get("title", "") or data.get("meal_title", "") or data.get("description", "") or data.get("d", "")
        if not description and isinstance(data.get("estimation_metadata"), dict):
            description = str(data["estimation_metadata"].get("notes") or "")

        # edge case handling (matching Cal AI strings)
        if not foods:
            return [], "没有识别到食物"

        processed_count = sum(
            1 for f in foods
            if f.processing_level.value in ("processed", "ultra_processed")
        )
        if processed_count >= 2:
            if description:
                description += " "
            description += "检测到多种加工食品，包装食品建议用标签扫描。"

        return foods, description
