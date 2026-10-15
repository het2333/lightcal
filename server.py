"""Cal AI Reproduction — FastAPI backend server.

All /v6/ endpoints matching the Cal AI IPA's API structure.

Run:
  python server.py
  uvicorn server:app --reload
"""

import asyncio
import os
import base64
import hashlib
import html
import json
import math
import re
import time
from contextlib import asynccontextmanager, suppress
from datetime import date, datetime, timedelta
from typing import Optional
from uuid import uuid4

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from models.food import Food, DescribeMealRequest, DescribeMealResponse, ScanSource
from models.health import HealthScore
from services.describe_meal import DescribeMealService
from services.health_scorer import HealthScorer
from services.food_database import FoodDatabase
from services.auto_complete import AutoCompleteService
from services.llm_providers import create_provider
from services.recommendation_service import RecommendationService
from services.decision_service import DecisionService
from services.exercise_catalog import (
    DEFAULT_BODY_WEIGHT_KG,
    INTENSITY_LABELS,
    estimate_exercise_calories,
    get_exercise_catalog,
    normalize_intensity,
)
from engine import parse, evaluate, create_context
from engine.builtins import BUILTINS

load_dotenv()

# ── Service initialization ─────────────────────────────────────────

from services.tracking_service import TrackingService
from services.depth_meal_service import DepthMealService

food_db = FoodDatabase()
health_scorer = HealthScorer()
auto_complete = AutoCompleteService(food_db)
tracking = TrackingService()
depth_meal_service = DepthMealService()
decision_service = DecisionService(tracking=tracking)

try:
    llm_provider = create_provider()
    print(f"[Server] LLM provider: {type(llm_provider).__name__}")
except RuntimeError as e:
    print(f"[Server] WARNING: {e}")
    print("[Server] Running in mock-only mode (no LLM provider configured)")
    llm_provider = None

describe_meal = DescribeMealService(provider=llm_provider, food_db=food_db)
recommendation_service = RecommendationService(
    food_db=food_db,
    tracking=tracking,
    llm_provider=llm_provider,
    decision_service=decision_service,
)

_FOOD_STREAK_CACHE = {"value": None, "at": 0.0}
_FOOD_STREAK_CACHE_TTL_SECONDS = 30.0


def _env_bool(name: str, default: bool = True) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off", "disabled"}


def _env_float(name: str, default: float, minimum: float = 0.0) -> float:
    try:
        value = float(os.getenv(name, str(default)) or default)
    except (TypeError, ValueError):
        value = default
    return max(minimum, value)


def _tiny_warmup_jpeg_base64() -> str:
    from io import BytesIO
    from PIL import Image

    buffer = BytesIO()
    Image.new("RGB", (32, 32), (245, 245, 245)).save(buffer, format="JPEG", quality=70)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


async def _warm_photo_model_once(reason: str) -> None:
    if not describe_meal or not getattr(describe_meal, "provider", None):
        return

    analyze = getattr(describe_meal.provider, "analyze_image_with_prompt", None)
    if not callable(analyze):
        return

    try:
        await analyze(
            _tiny_warmup_jpeg_base64(),
            "只返回 JSON。",
            '返回 {"foods":[]}，不要解释。',
            max_tokens=16,
        )
        print(f"[Server] photo model warmup ok ({reason})")
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        print(f"[Server] photo model warmup skipped ({reason}): {type(exc).__name__}: {str(exc)[:180]}")


async def _photo_model_keepalive_loop() -> None:
    await asyncio.sleep(_env_float("PHOTO_MODEL_WARMUP_DELAY_SECONDS", 2.0, 0.0))
    await _warm_photo_model_once("startup")

    interval = _env_float("PHOTO_MODEL_KEEPALIVE_INTERVAL_SECONDS", 300.0, 0.0)
    if interval <= 0:
        return

    while True:
        await asyncio.sleep(interval)
        await _warm_photo_model_once("keepalive")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown."""
    try:
        yield
    finally:
        pass


app = FastAPI(
    title="Cal AI Reproduction",
    description="Reproduction of Cal AI's core nutrition analysis pipeline",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Static files ──────────────────────────────────────────────────


def _configured_static_dir() -> str:
    configured = os.getenv("CAL_STATIC_DIR", "").strip()
    path = configured or os.path.join(os.path.dirname(__file__), "static")
    return os.path.abspath(os.path.expanduser(path))


static_dir = _configured_static_dir()
os.makedirs(static_dir, exist_ok=True)
app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.get("/")
async def root():
    return {"status": "ok", "version": "0.1.0", "docs": "/docs"}


def _api_success(data: dict | list | None = None, **fields):
    """Return the Cal AI 26.27.0-style API envelope while keeping legacy top-level fields."""
    if data is None:
        data = dict(fields)
    body = {
        "success": True,
        "status": "ok",
        "data": data,
        "remoteConfigExperiment": None,
        "statsigExperiment": None,
    }
    body.update(fields)
    return body


def _empty_describe_meal_payload(reason: str = "", text: str | None = None) -> dict:
    return {
        "foods": [],
        "health_score": None,
        "description": text or "",
        "decision": None,
        "estimation_metadata": {
            "source": "describeMeal.compat",
            "reason": reason,
        },
    }

# ── Helper models ──────────────────────────────────────────────────

class HealthScoreRequest(BaseModel):
    """Request body for /v6/health-score."""
    food_name: str
    processing_level: str = "whole"
    total_carbs: float = 0
    fiber: float = 0
    added_sugar: float = 0


class RuleEvalRequest(BaseModel):
    """Request body for rule evaluation."""
    expression: str
    daily_stats: Optional[dict] = None
    goal: Optional[dict] = None
    streak_days: int = 0


class FoodAddRequest(BaseModel):
    """Request body for /v6/foodDatabase/add."""
    name: str
    calories: float = 0
    protein: float = 0
    carbs: float = 0
    fat: float = 0
    fats: Optional[float] = None
    fiber: float = 0
    sugar: float = 0
    ethanol: float = 0
    servings: float = 1
    ingredients: Optional[list[str]] = None
    added_sugar: float = 0
    sodium: float = 0
    sat_fat: float = 0
    trans_fat: float = 0
    cholesterol: float = 0
    vitamin_a: float = 0
    vitamin_c: float = 0
    calcium: float = 0
    iron: float = 0
    potassium: float = 0
    magnesium: float = 0
    zinc: float = 0
    folate: float = 0
    vitamin_d: float = 0
    vitamin_b12: float = 0
    vitamin_e: float = 0
    vitamin_k: float = 0
    omega_3: float = 0
    monounsaturated_fat: float = 0
    polyunsaturated_fat: float = 0
    serving_size: str = "100g"
    grams_per_unit: float = 100
    barcode: str = ""
    nutrition_source: str = "user"
    processing_level: str = "whole"


class RecipeSearchRequest(BaseModel):
    """Request body for /v6/recipes/search."""
    query: str
    max_calories: Optional[float] = None
    meal_type: Optional[str] = None


class MealCaptureCreateRequest(BaseModel):
    """Request body for third-stage RGB + depth capture creation."""
    platform: str = "ios"
    device_model: str = ""
    depth_source: str = "ios_lidar_scene_depth"
    meal_type: str = ""
    container_hint: str | None = None


class MealCaptureAnalyzeRequest(BaseModel):
    """Request body for starting third-stage RGB + depth meal analysis."""
    user_hint: str = ""
    container_hint: str | None = None
    meal_type: str = ""


class MealItemCorrectionRequest(BaseModel):
    """Request body for editable third-stage meal item corrections."""
    name_zh: str | None = None
    estimated_grams: float | None = None
    eaten_ratio: float | None = None
    oil_level: str | None = None
    ingredient_ratios: dict | None = None


class MealConfirmRequest(BaseModel):
    """Request body for confirming a third-stage meal draft."""
    confirmed: bool = True


# ── /v1 RGB + Depth meal analysis (third-stage experimental pipeline) ──

@app.get("/v1/health")
async def v1_health_check_endpoint():
    """Health check for the iOS RGB + Depth capture pipeline."""
    return {
        "status": "ok",
        "version": "0.1.0",
        "features": ["meal_captures", "depth_analysis"],
        "depth_pipeline": depth_meal_service.pipeline_status(),
    }


@app.post("/v1/meal-captures")
async def create_meal_capture_endpoint(request: MealCaptureCreateRequest):
    """Create an RGB/depth capture bundle upload task."""
    return depth_meal_service.create_capture("me", request.model_dump())


@app.post("/v1/meal-captures/{capture_id}/analyze")
async def analyze_meal_capture_endpoint(capture_id: str, request: MealCaptureAnalyzeRequest):
    """Start the third-stage RGB + depth analysis job."""
    try:
        return depth_meal_service.analyze_capture(capture_id, "me", request.model_dump())
    except KeyError:
        raise HTTPException(status_code=404, detail="没有找到这次深度拍摄任务，请重新拍摄。")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"深度餐食分析失败：{exc}")


@app.put("/v1/meal-captures/{capture_id}/files/{kind}")
async def upload_meal_capture_file_endpoint(capture_id: str, kind: str, request: Request):
    """Upload one raw file from an RGB/depth capture bundle."""
    try:
        body = await request.body()
        return depth_meal_service.save_capture_file(capture_id, kind, body)
    except KeyError:
        raise HTTPException(status_code=404, detail="没有找到这次深度拍摄任务，请重新拍摄。")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"深度拍摄文件上传失败：{exc}")


@app.get("/v1/meal-analysis-jobs/{job_id}")
async def get_meal_analysis_job_endpoint(job_id: str):
    """Read third-stage analysis job status and result."""
    job = depth_meal_service.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="没有找到这次分析任务，请重新拍摄。")
    return job


@app.get("/v1/meals/{meal_id}")
async def get_depth_meal_endpoint(meal_id: str):
    """Read a third-stage meal draft/result."""
    meal = depth_meal_service.get_meal(meal_id)
    if not meal:
        raise HTTPException(status_code=404, detail="没有找到这次餐食结果。")
    return meal


@app.patch("/v1/meals/{meal_id}/items/{item_id}")
async def patch_depth_meal_item_endpoint(meal_id: str, item_id: str, request: MealItemCorrectionRequest):
    """Apply user corrections and recalculate item, meal total, and daily intake."""
    payload = {k: v for k, v in request.model_dump().items() if v is not None}
    try:
        return depth_meal_service.patch_item("me", meal_id, item_id, payload)
    except KeyError:
        raise HTTPException(status_code=404, detail="没有找到这项食物。")
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"餐食修正失败：{exc}")


@app.post("/v1/meals/{meal_id}/confirm")
async def confirm_depth_meal_endpoint(meal_id: str, request: MealConfirmRequest):
    """Confirm a third-stage meal draft and update daily intake."""
    if not request.confirmed:
        raise HTTPException(status_code=400, detail="当前只支持确认保存餐食。")
    try:
        return depth_meal_service.confirm_meal("me", meal_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="没有找到这次餐食结果。")


class FoodLogRequest(BaseModel):
    """Request body for saving analyzed or searched foods to daily history."""
    foods: list[Food]
    date: str | None = None
    meal_category: str = ""
    image_base64: str | None = None
    group_title: str = ""
    request_id: str | None = None


class SavedMealRequest(BaseModel):
    """Request body for creating a reusable saved meal."""
    title: str = ""
    foods: list[Food]
    source: str = "user"
    meal_category: str = ""
    image_url: str = ""
    note: str | None = None
    instructions: list[str] | None = None
    favorite: bool | None = None


class SavedMealLogRequest(BaseModel):
    date: str | None = None
    meal_category: str = ""
    portion_multiplier: float = 1.0


class SavedFoodRequest(BaseModel):
    """Request body for creating a reusable saved food."""
    food: Food
    source: str = "user"


class SavedFoodLogRequest(BaseModel):
    date: str | None = None
    meal_category: str = ""
    portion_multiplier: float = 1.0


class FoodLogDeleteRequest(BaseModel):
    """Request body for deleting one or more persisted food log rows."""
    ids: list[int] = []
    upload_group_id: str | None = None
    date: str | None = None


class FoodLogPortionRequest(BaseModel):
    """Request body for adjusting one persisted food log row by portion ratio."""
    consumed_ratio: float = 1
    date: str | None = None


class FoodLogMoveRequest(BaseModel):
    """Request body for moving one persisted food log row to another meal slot."""
    meal_category: str
    date: str | None = None


class DiaryNoteRequest(BaseModel):
    """Request body for saving a daily food diary note."""
    date: str | None = None
    note: str = ""


class DiaryCompleteRequest(BaseModel):
    """Request body for completing a daily food diary."""
    date: str | None = None


class FoodLogLeftoverRequest(BaseModel):
    """Request body for adjusting a saved meal from an after-meal leftovers photo."""
    upload_group_id: str
    image_base64: str
    date: str | None = None
    description: str = ""


class FoodLogLeftoverApplyItem(BaseModel):
    """Confirmed per-food leftover percentage for a saved meal row."""
    id: str | int
    name: str = ""
    remaining_percent: float = 0
    confidence: float = 0
    reason: str = ""


class FoodLogLeftoverApplyRequest(BaseModel):
    """Request body for applying user-confirmed leftover percentages."""
    upload_group_id: str
    image_base64: str | None = None
    date: str | None = None
    items: list[FoodLogLeftoverApplyItem]


class CommunityPostFromMealRequest(BaseModel):
    """Request body for publishing an analyzed meal to community."""
    upload_group_id: str
    user: str = "me"
    visibility: str = "friends"
    caption: str = ""
    tags: list[str] = []


class CommunityDailyCheckinRequest(BaseModel):
    """Request body for publishing today's status check-in."""
    user: str = "me"
    visibility: str = "friends"
    date: str | None = None
    caption: str = ""
    challenge_id: str = ""


class CommunityReactionRequest(BaseModel):
    user: str = "me"
    reaction: str = "like"


class CommunityCommentRequest(BaseModel):
    user: str = "me"
    body: str


class CommunityReportRequest(BaseModel):
    user: str = "me"
    reason: str = "内容不适合"


class CommunityLogSameMealRequest(BaseModel):
    user: str = "me"
    date: str | None = None
    meal_category: str = ""


class FastingPreferencesRequest(BaseModel):
    enabled: bool = False
    method: str = "16:8"
    fasting_hours: float = 16
    eating_hours: float = 8
    eating_window_start: str = "12:00"
    reminders_enabled: bool = True
    timezone: str = "local"


class FastingStartRequest(BaseModel):
    method: str | None = None
    fasting_hours: float | None = None
    start_at: str | None = None


class FastingEndRequest(BaseModel):
    ended_at: str | None = None
    notes: str = ""


class FastingManualRequest(BaseModel):
    method: str | None = None
    fasting_hours: float | None = None
    start_at: str
    ended_at: str
    notes: str = ""


class DecisionScoreRequest(BaseModel):
    """Request body for nutrition decision scoring."""
    foods: list[Food] = []
    nutrition: dict | None = None
    names: list[str] = []
    source: str = "meal"
    event_type: str = "today_fit"
    date: str | None = None
    persist: bool = True


NUTRITION_FIELDS = [
    "calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium",
    "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
    "calcium", "iron", "potassium", "added_sugar", "magnesium", "zinc",
    "folate", "vitamin_d", "vitamin_b12", "vitamin_e", "vitamin_k",
    "omega_3", "monounsaturated_fat", "polyunsaturated_fat",
]


def _ensure_food_log_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS food_log_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            food_name TEXT, calories REAL, protein REAL, carbs REAL, fat REAL,
            fiber REAL, sugar REAL, sodium REAL, sat_fat REAL DEFAULT 0,
            trans_fat REAL DEFAULT 0, cholesterol REAL DEFAULT 0,
            vitamin_a REAL DEFAULT 0, vitamin_c REAL DEFAULT 0,
            calcium REAL DEFAULT 0, iron REAL DEFAULT 0, potassium REAL DEFAULT 0,
            magnesium REAL DEFAULT 0, zinc REAL DEFAULT 0, folate REAL DEFAULT 0,
            vitamin_d REAL DEFAULT 0, vitamin_b12 REAL DEFAULT 0,
            vitamin_e REAL DEFAULT 0, vitamin_k REAL DEFAULT 0,
            omega_3 REAL DEFAULT 0, monounsaturated_fat REAL DEFAULT 0,
            polyunsaturated_fat REAL DEFAULT 0,
            serving_size TEXT, processing_level TEXT, date TEXT DEFAULT '',
            meal_category TEXT DEFAULT '',
            upload_group_id TEXT DEFAULT '',
            upload_group_title TEXT DEFAULT '',
            image_url TEXT DEFAULT '',
            logged_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(food_log_history)").fetchall()]
    migrations = {
        "date": "TEXT DEFAULT ''",
        "meal_category": "TEXT DEFAULT ''",
        "upload_group_id": "TEXT DEFAULT ''",
        "upload_group_title": "TEXT DEFAULT ''",
        "image_url": "TEXT DEFAULT ''",
        "sat_fat": "REAL DEFAULT 0",
        "trans_fat": "REAL DEFAULT 0",
        "cholesterol": "REAL DEFAULT 0",
        "vitamin_a": "REAL DEFAULT 0",
        "vitamin_c": "REAL DEFAULT 0",
        "calcium": "REAL DEFAULT 0",
        "iron": "REAL DEFAULT 0",
        "potassium": "REAL DEFAULT 0",
        "magnesium": "REAL DEFAULT 0",
        "zinc": "REAL DEFAULT 0",
        "folate": "REAL DEFAULT 0",
        "vitamin_d": "REAL DEFAULT 0",
        "vitamin_b12": "REAL DEFAULT 0",
        "vitamin_e": "REAL DEFAULT 0",
        "vitamin_k": "REAL DEFAULT 0",
        "omega_3": "REAL DEFAULT 0",
        "monounsaturated_fat": "REAL DEFAULT 0",
        "polyunsaturated_fat": "REAL DEFAULT 0",
        "added_sugar": "REAL DEFAULT 0",
        "grams_per_unit": "REAL DEFAULT 100",
        "barcode": "TEXT DEFAULT ''",
        "nutrition_source": "TEXT DEFAULT ''",
        "original_nutrition_json": "TEXT DEFAULT ''",
        "leftover_nutrition_json": "TEXT DEFAULT ''",
        "leftover_image_url": "TEXT DEFAULT ''",
        "leftover_logged_at": "TEXT DEFAULT ''",
        "leftover_calories": "REAL DEFAULT 0",
        "consumed_ratio": "REAL DEFAULT 1",
        "quantity_count": "REAL DEFAULT NULL",
        "quantity_unit": "TEXT DEFAULT ''",
        "quantity_description": "TEXT DEFAULT ''",
    }
    for col, spec in migrations.items():
        if col not in cols:
            try:
                conn.execute(f"ALTER TABLE food_log_history ADD COLUMN {col} {spec}")
            except Exception:
                pass


def _ensure_food_log_idempotency_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS food_log_idempotency (
            idempotency_key TEXT PRIMARY KEY,
            upload_group_id TEXT NOT NULL,
            request_fingerprint TEXT DEFAULT '',
            response_json TEXT DEFAULT '',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cols = {row[1] for row in conn.execute("PRAGMA table_info(food_log_idempotency)").fetchall()}
    if "request_fingerprint" not in cols:
        conn.execute(
            "ALTER TABLE food_log_idempotency ADD COLUMN request_fingerprint TEXT DEFAULT ''"
        )


def _logged_foods_for_day(day: str) -> list[Food]:
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE date = ? ORDER BY logged_at DESC LIMIT 200",
            (day,),
        ).fetchall()
    foods = []
    for r in rows:
        data = dict(r)
        foods.append(Food(
            id=str(data.get("id", "")),
            name=data.get("food_name", ""),
            date=data.get("date") or day,
            **{field: data.get(field) or 0 for field in NUTRITION_FIELDS},
            serving_size=data.get("serving_size") or "100g",
            quantity_count=data.get("quantity_count"),
            quantity_unit=data.get("quantity_unit") or "",
            quantity_description=data.get("quantity_description") or "",
            grams_per_unit=data.get("grams_per_unit") or 100,
            barcode=data.get("barcode") or "",
            nutrition_source=data.get("nutrition_source") or "",
            processing_level=data.get("processing_level") or "whole",
        ))
    return foods


def _calculate_food_streak() -> int:
    now = time.monotonic()
    cached_value = _FOOD_STREAK_CACHE.get("value")
    if cached_value is not None and now - float(_FOOD_STREAK_CACHE.get("at") or 0) < _FOOD_STREAK_CACHE_TTL_SECONDS:
        return int(cached_value)

    from datetime import date as _date, timedelta as _td
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT DISTINCT date FROM food_log_history WHERE date != '' ORDER BY date DESC LIMIT 365"
        ).fetchall()
    logged_dates = {r["date"] for r in rows}
    today = _date.today()
    streak = 0
    d = today
    while d.isoformat() in logged_dates:
        streak += 1
        d = d - _td(days=1)
    if streak == 0 and (today - _td(days=1)).isoformat() in logged_dates:
        d = today - _td(days=1)
        while d.isoformat() in logged_dates:
            streak += 1
            d = d - _td(days=1)
    _FOOD_STREAK_CACHE["value"] = streak
    _FOOD_STREAK_CACHE["at"] = now
    return streak


def _daily_summary_for_day(day: str):
    foods = _logged_foods_for_day(day)
    summary = tracking.get_daily_summary(day, foods=foods)
    summary.streak_days = _calculate_food_streak()
    return summary


def _score_status(score: float) -> str:
    if score >= 78:
        return "green"
    if score >= 55:
        return "yellow"
    return "red"


def _serving_grams(value: str | None) -> float:
    match = re.search(r"(\d+(?:\.\d+)?)\s*(?:g|克)", str(value or ""), re.IGNORECASE)
    return float(match.group(1)) if match else 0.0


def _food_day_stats(foods: list[Food]) -> dict:
    vegetable_tokens = ("菜", "蔬", "青椒", "西兰花", "生菜", "黄瓜", "番茄", "菠菜", "芹", "白菜", "冬瓜", "胡萝卜", "蘑菇", "菌")
    stats = {
        "food_items": len(foods),
        "vegetable_items": 0,
        "vegetable_grams": 0.0,
        "processed_items": 0,
        "ultra_processed_items": 0,
    }
    for food in foods:
        name = str(food.name or "")
        grams = _serving_grams(getattr(food, "serving_size", ""))
        level = food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level or "")
        if any(token in name for token in vegetable_tokens):
            stats["vegetable_items"] += 1
            stats["vegetable_grams"] += grams or 80
        if level == "ultra_processed":
            stats["ultra_processed_items"] += 1
        if level in {"processed", "ultra_processed"}:
            stats["processed_items"] += 1
    return stats


def _logged_meal_category_count(day: str) -> int:
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            """SELECT DISTINCT meal_category
               FROM food_log_history
               WHERE date = ?
                 AND COALESCE(meal_category, '') != ''""",
            (day,),
        ).fetchall()
    return len({(row["meal_category"] or "").strip().lower() for row in rows if (row["meal_category"] or "").strip()})


def _score_dimension(
    id_: str,
    label: str,
    score: float,
    value: float,
    goal: float,
    unit: str,
    message: str,
    suggestion: str,
    weight: int,
) -> dict:
    rounded = max(0, min(100, round(score)))
    return {
        "id": id_,
        "label": label,
        "value": round(value, 1),
        "goal": round(goal, 1),
        "unit": unit,
        "ratio": round(float(value or 0) / max(1.0, float(goal or 1)), 3),
        "status": _score_status(rounded),
        "score": rounded,
        "weight": weight,
        "message": message,
        "suggestion": suggestion,
    }


def _latest_fasting_day_score(day: str, fasting_status: dict) -> tuple[int, str, str]:
    active = fasting_status.get("active_session")
    if active:
        progress = float(active.get("progress_pct") or 0)
        return round(55 + min(100, progress) * 0.45), "断食进行中", "按当前节奏继续，注意补水。"
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        row = conn.execute(
            """SELECT * FROM fasting_sessions
               WHERE substr(COALESCE(ended_at, target_end_at, start_at), 1, 10) = ?
               ORDER BY COALESCE(ended_at, target_end_at, start_at) DESC LIMIT 1""",
            (day,),
        ).fetchone()
    if row and row["status"] == "completed":
        return 100, "今日断食已完成", "明天继续保持这个节奏。"
    if row and row["status"] == "ended_early":
        return 65, "今天提前结束", "下一次可以选择更容易坚持的窗口。"
    if fasting_status.get("enabled") or fasting_status.get("preferences", {}).get("enabled"):
        return 55, "已开启断食计划", "今天还没有完成记录，可以从下一餐后开始。"
    return 70, "未开启断食", "如果适合你，可以尝试 12-14 小时轻断食。"


def _daily_nutrition_score(day: str) -> dict:
    summary = _daily_summary_for_day(day)
    foods = _logged_foods_for_day(day)
    food_stats = _food_day_stats(foods)
    fasting_status = _get_fasting_status()
    sleep = tracking.get_sleep_summary(day)
    active_challenges = [item for item in tracking.get_challenges() if item.get("status") == "active"]

    def ratio(value: float, goal: float) -> float:
        return float(value or 0) / max(1.0, float(goal or 1))

    def positive_item(key: str, label: str, value: float, goal: float, unit: str, weight: int, suggestion: str) -> dict:
        pct = ratio(value, goal)
        if pct >= 0.85:
            status, score, message = "green", 100, "接近或达到目标"
        elif pct >= 0.55:
            status, score, message = "yellow", round(65 + (pct - 0.55) / 0.30 * 20), "还可以再补一点"
        else:
            status, score, message = "red", round(35 + pct / 0.55 * 25), "明显不足"
        return {
            "id": key,
            "label": label,
            "value": round(value, 1),
            "goal": round(goal, 1),
            "unit": unit,
            "ratio": round(pct, 3),
            "status": status,
            "score": max(0, min(100, score)),
            "weight": weight,
            "message": message,
            "suggestion": suggestion,
        }

    def upper_limit_item(key: str, label: str, value: float, goal: float, unit: str, weight: int, suggestion: str) -> dict:
        pct = ratio(value, goal)
        if pct <= 0.8:
            status, score, message = "green", 100, "控制得不错"
        elif pct <= 1.0:
            status, score, message = "yellow", round(100 - (pct - 0.8) / 0.2 * 25), "接近上限"
        elif pct <= 1.25:
            status, score, message = "yellow", round(70 - (pct - 1.0) / 0.25 * 20), "已经超出目标"
        else:
            status, score, message = "red", max(20, round(50 - min(0.7, pct - 1.25) / 0.7 * 30)), "超出较多"
        return {
            "id": key,
            "label": label,
            "value": round(value, 1),
            "goal": round(goal, 1),
            "unit": unit,
            "ratio": round(pct, 3),
            "status": status,
            "score": max(0, min(100, score)),
            "weight": weight,
            "message": message,
            "suggestion": suggestion,
        }

    def range_item(key: str, label: str, value: float, goal: float, unit: str, weight: int, suggestion: str) -> dict:
        pct = ratio(value, goal)
        if 0.75 <= pct <= 1.05:
            status, score, message = "green", 100, "落在理想区间"
        elif 0.55 <= pct <= 1.18:
            status, score, message = "yellow", 72, "略偏离目标"
        else:
            status, score, message = "red", 45, "偏离目标较多"
        return {
            "id": key,
            "label": label,
            "value": round(value, 1),
            "goal": round(goal, 1),
            "unit": unit,
            "ratio": round(pct, 3),
            "status": status,
            "score": score,
            "weight": weight,
            "message": message,
            "suggestion": suggestion,
        }

    nutrition_items = [
        range_item("calories", "热量", summary.calories_consumed, summary.calories_goal, "kcal", 20, "下一餐按剩余热量安排份量。"),
        positive_item("protein", "蛋白质", summary.protein, summary.protein_goal, "g", 20, "优先选鸡蛋、鱼虾、鸡胸肉、豆腐或酸奶。"),
        positive_item("fiber", "膳食纤维", summary.fiber, summary.fiber_goal, "g", 18, "加一份绿叶菜、豆类、燕麦或水果。"),
        upper_limit_item("sugar", "糖", summary.sugar, summary.sugar_goal, "g", 16, "把饮料和甜点换成无糖茶、水或原味酸奶。"),
        upper_limit_item("sodium", "钠", summary.sodium, summary.sodium_goal, "mg", 14, "下一餐少酱料、少汤底、少腌制品。"),
        range_item("fat", "脂肪", summary.fat, summary.fat_goal, "g", 12, "少油烹饪，脂肪优先来自坚果、鱼和橄榄油。"),
    ]

    nutrition_base = sum(item["score"] * item["weight"] for item in nutrition_items) / max(1, sum(item["weight"] for item in nutrition_items))
    vegetable_score = min(100, max(45, food_stats["vegetable_grams"] / 300 * 100)) if foods else 40
    processed_ratio = food_stats["processed_items"] / max(1, food_stats["food_items"])
    processing_score = max(30, 100 - processed_ratio * 55 - food_stats["ultra_processed_items"] * 12) if foods else 45
    diet_score = round(nutrition_base * 0.72 + vegetable_score * 0.16 + processing_score * 0.12)

    hydration_ratio = ratio(summary.hydration_effective_ml, summary.hydration_goal_ml)
    hydration_score = min(100, max(35, hydration_ratio * 100))
    fasting_score, fasting_message, fasting_suggestion = _latest_fasting_day_score(day, fasting_status)
    steps_score = min(100, ratio(summary.steps, summary.steps_goal) * 100)
    exercise_score = 100 if summary.calories_burned >= 250 else 70 if summary.calories_burned > 0 else 45
    movement_score = round(steps_score * 0.7 + exercise_score * 0.3)
    if sleep["logs_count"]:
        duration_score = min(100, sleep["duration_hours"] / max(1, sleep["goal_hours"]) * 100)
        quality_score = min(100, max(20, sleep["quality"] / 5 * 100))
        sleep_score = round(duration_score * 0.7 + quality_score * 0.3)
        sleep_message = f"昨晚睡眠 {sleep['duration_hours']:.1f} 小时"
        sleep_suggestion = "保持规律睡眠时间，训练日尤其注意恢复。"
    else:
        sleep_score = 45
        sleep_message = "还没有记录昨晚睡眠"
        sleep_suggestion = "补一条睡眠记录，今日状态分会更准确。"
    logged_any = bool(foods or summary.drink_count or summary.steps or sleep["logs_count"])
    active_challenge_bonus = 15 if active_challenges else 0
    streak_bonus = min(35, summary.streak_days * 5)
    consistency_score = min(100, (65 if logged_any else 30) + active_challenge_bonus + streak_bonus)

    dimensions = [
        _score_dimension("diet", "饮食", diet_score, summary.calories_consumed, summary.calories_goal, "kcal", "热量、蛋白、蔬菜和加工食品一起评估", "下一餐优先高蛋白、够蔬菜、少油少加工。", 35),
        _score_dimension("hydration", "饮水", hydration_score, summary.hydration_effective_ml, summary.hydration_goal_ml, "ml", "按有效补水量计算", "每次补 250ml，优先水、茶或无糖饮品。", 15),
        _score_dimension("fasting", "断食", fasting_score, fasting_score, 100, "分", fasting_message, fasting_suggestion, 15),
        _score_dimension("movement", "运动", movement_score, summary.steps, summary.steps_goal, "步", "步数和运动消耗一起计算", "饭后走 10 分钟，状态分会更稳。", 15),
        _score_dimension("sleep", "睡眠", sleep_score, sleep["duration_hours"], sleep["goal_hours"], "小时", sleep_message, sleep_suggestion, 15),
        _score_dimension("consistency", "连续性", consistency_score, summary.streak_days, 7, "天", "记录、挑战和连续天数一起计算", "每天至少完成一次拍照或饮水打卡。", 5),
    ]

    score = round(sum(item["score"] * item["weight"] for item in dimensions) / max(1, sum(item["weight"] for item in dimensions)))
    weak = [item for item in dimensions if item["status"] != "green"]
    adjustments = [item["suggestion"] for item in weak[:3]]
    if not adjustments:
        adjustments = ["保持当前节奏，下一餐继续优先高蛋白和高纤维。"]
    status = _score_status(score)
    highlights = [
        f"饮食 {dimensions[0]['score']} 分",
        f"饮水 {dimensions[1]['score']} 分",
        f"睡眠 {dimensions[4]['score']} 分",
    ]
    if active_challenges:
        highlights.append(f"正在参与 {len(active_challenges)} 个挑战")
    headline = (
        "今天状态很稳，继续保持。"
        if status == "green"
        else "今天有几项需要微调。"
        if status == "yellow"
        else "今天状态偏离较多，先补最容易的一项。"
    )
    return {
        "date": day,
        "score_type": "daily_status_score",
        "score": score,
        "status": status,
        "headline": headline,
        "items": dimensions,
        "nutrition_items": nutrition_items,
        "dimensions": dimensions,
        "highlights": highlights[:4],
        "next_actions": adjustments,
        "adjustments": adjustments,
        "sleep": sleep,
        "food_stats": food_stats,
        "active_challenges": active_challenges[:3],
        "summary": summary.model_dump(),
    }


def _decision_context_for_day(day: str) -> dict:
    summary = _daily_summary_for_day(day)
    fasting_status = _get_fasting_status()
    fasting_history = _get_fasting_history(30)
    preferences = tracking.get_user_preferences()
    return decision_service.build_context(
        summary=summary,
        fasting_status=fasting_status,
        preferences=preferences,
        history=fasting_history,
    )


def _score_decision_payload(request: DecisionScoreRequest) -> dict:
    day = request.date or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(day)
    fasting_status = _get_fasting_status()
    preferences = tracking.get_user_preferences()
    event_type = request.event_type or "today_fit"
    source = request.source or "meal"
    if request.foods:
        return decision_service.score_foods(
            request.foods,
            summary=summary,
            fasting_status=fasting_status,
            preferences=preferences,
            source=source,
            event_type=event_type,
            persist=request.persist,
        )
    if request.nutrition:
        return decision_service.score_nutrition_dict(
            request.nutrition,
            summary=summary,
            fasting_status=fasting_status,
            preferences=preferences,
            source=source,
            event_type=event_type,
            names=request.names,
            persist=request.persist,
        )
    raise HTTPException(status_code=400, detail="foods or nutrition is required")


def _source_for_decision(source: ScanSource | str) -> str:
    value = source.value if hasattr(source, "value") else str(source)
    if value in ("barcode_scan", "barcode_camera"):
        return "barcode"
    if value == "label_scan":
        return "label"
    if value in ("manually", "database"):
        return "search"
    return "meal"


def _event_type_for_decision(source: ScanSource | str) -> str:
    value = source.value if hasattr(source, "value") else str(source)
    if value in ("barcode_scan", "barcode_camera", "label_scan"):
        return "product_score"
    return "meal_score"


def _save_upload_image(image_base64: str | None, group_id: str) -> str:
    if not image_base64:
        return ""
    try:
        payload = image_base64.split(",", 1)[1] if "," in image_base64 else image_base64
        image_bytes = base64.b64decode(payload)
    except Exception:
        return ""
    uploads_dir = os.path.join(static_dir, "uploads")
    os.makedirs(uploads_dir, exist_ok=True)
    safe_group = "".join(ch if ch.isalnum() or ch in {"_", "-"} else "_" for ch in group_id)
    filename = f"{safe_group}.jpg"
    with open(os.path.join(uploads_dir, filename), "wb") as f:
        f.write(image_bytes)
    return f"/static/uploads/{filename}"


def _remove_unused_upload_images(conn, image_urls: list[str]) -> None:
    for image_url in {url for url in image_urls if url}:
        if not image_url.startswith("/static/uploads/"):
            continue
        still_used = conn.execute(
            "SELECT 1 FROM food_log_history WHERE image_url = ? OR leftover_image_url = ? LIMIT 1",
            (image_url, image_url),
        ).fetchone()
        if still_used:
            continue
        path = os.path.join(static_dir, "uploads", os.path.basename(image_url))
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


def _delete_foods_from_log(ids: list[int], upload_group_id: str | None = None) -> tuple[int, str]:
    clean_ids = sorted({int(value) for value in ids if int(value) > 0})
    clauses = []
    params: list[object] = []
    if clean_ids:
        clauses.append(f"id IN ({','.join('?' for _ in clean_ids)})")
        params.extend(clean_ids)
    if upload_group_id:
        clauses.append("upload_group_id = ?")
        params.append(upload_group_id)
    if not clauses:
        raise HTTPException(status_code=400, detail="No food log ids provided")

    where = " OR ".join(clauses)
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            f"SELECT id, date, upload_group_id, image_url, leftover_image_url FROM food_log_history WHERE {where}",
            params,
        ).fetchall()
        if not rows:
            return 0, __import__("datetime").date.today().isoformat()

        row_ids = [int(row["id"]) for row in rows]
        day = next((row["date"] for row in rows if row["date"]), __import__("datetime").date.today().isoformat())
        placeholders = ",".join("?" for _ in row_ids)
        conn.execute(f"DELETE FROM food_log_history WHERE id IN ({placeholders})", row_ids)
        _ensure_food_log_idempotency_table(conn)
        affected_groups = {str(row["upload_group_id"] or "") for row in rows if row["upload_group_id"]}
        for group_id in affected_groups:
            still_used = conn.execute(
                "SELECT 1 FROM food_log_history WHERE upload_group_id = ? LIMIT 1",
                (group_id,),
            ).fetchone()
            if not still_used:
                conn.execute(
                    "DELETE FROM food_log_idempotency WHERE upload_group_id = ?",
                    (group_id,),
                )
        _remove_unused_upload_images(
            conn,
            [row["image_url"] for row in rows] + [row["leftover_image_url"] for row in rows],
        )
        conn.commit()
        return len(row_ids), day


def _adjust_food_log_portion(log_id: int, consumed_ratio: float, day: str | None = None) -> dict:
    if log_id <= 0:
        raise HTTPException(status_code=400, detail="food log id is required")
    if float(consumed_ratio) <= 0:
        deleted, log_day = _delete_foods_from_log([log_id])
        if not deleted:
            raise HTTPException(status_code=404, detail="找不到这条食物记录")
        final_day = day or log_day
        return {
            "status": "ok",
            "date": final_day,
            "adjusted": 0,
            "removed": 1,
            "food": None,
            "daily_summary": _daily_summary_for_day(final_day).model_dump(),
        }
    ratio = round(_clamp_float(consumed_ratio, 0.05, 20.0), 4)

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        row = conn.execute("SELECT * FROM food_log_history WHERE id = ?", (log_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="找不到这条食物记录")

        original = _nutrition_from_row(row)
        original_json = row["original_nutrition_json"] or json.dumps(original, ensure_ascii=False)
        adjusted = {
            field: round(float(original.get(field, 0) or 0) * ratio, 3)
            for field in NUTRITION_FIELDS
        }
        conn.execute(
            f"""UPDATE food_log_history
                SET {", ".join(f"{field} = ?" for field in NUTRITION_FIELDS)},
                    original_nutrition_json = ?,
                    consumed_ratio = ?,
                    leftover_calories = CASE WHEN ? <= 1 THEN ? ELSE 0 END
                WHERE id = ?""",
            (
                *[adjusted[field] for field in NUTRITION_FIELDS],
                original_json,
                ratio,
                ratio,
                round(max(0, float(original.get("calories", 0) or 0) - adjusted["calories"]), 3),
                log_id,
            ),
        )
        updated = conn.execute("SELECT * FROM food_log_history WHERE id = ?", (log_id,)).fetchone()
        conn.commit()

    log_day = day or row["date"] or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(log_day)
    return {
        "status": "ok",
        "date": log_day,
        "adjusted": 1,
        "food": _food_log_row_payload(updated),
        "daily_summary": summary.model_dump(),
    }


def _move_food_log_meal_category(log_id: int, meal_category: str, day: str | None = None) -> dict:
    if log_id <= 0:
        raise HTTPException(status_code=400, detail="food log id is required")

    clean_category = (meal_category or "").strip().lower()
    allowed = {"breakfast", "lunch", "dinner", "snack"}
    if clean_category not in allowed:
        raise HTTPException(status_code=400, detail="meal_category must be breakfast, lunch, dinner, or snack")

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        row = conn.execute("SELECT * FROM food_log_history WHERE id = ?", (log_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="找不到这条食物记录")

        conn.execute(
            "UPDATE food_log_history SET meal_category = ? WHERE id = ?",
            (clean_category, log_id),
        )
        updated = conn.execute("SELECT * FROM food_log_history WHERE id = ?", (log_id,)).fetchone()
        conn.commit()

    log_day = day or row["date"] or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(log_day)
    return {
        "status": "ok",
        "date": log_day,
        "moved": 1,
        "food": _food_log_row_payload(updated),
        "daily_summary": summary.model_dump(),
    }


def _nutrition_from_food(food: Food) -> dict[str, float]:
    return {field: float(getattr(food, field, 0) or 0) for field in NUTRITION_FIELDS}


def _nutrition_from_row(row) -> dict[str, float]:
    data = dict(row)
    original_json = data.get("original_nutrition_json") or ""
    if original_json:
        try:
            original = json.loads(original_json)
        except (TypeError, json.JSONDecodeError):
            original = data
    else:
        original = data
    return {field: float(original.get(field, 0) or 0) for field in NUTRITION_FIELDS}


def _food_log_row_payload(row) -> dict:
    data = dict(row)
    for image_field in ("image_url", "leftover_image_url"):
        image_url = str(data.get(image_field) or "").strip()
        if image_url.startswith("/static/"):
            image_path = os.path.join(static_dir, image_url.removeprefix("/static/"))
            if not os.path.isfile(image_path):
                data[image_field] = ""
    original = _nutrition_from_row(row)
    original_calories = float(original.get("calories", 0) or data.get("calories", 0) or 0)
    current_calories = float(data.get("calories", 0) or 0)
    ratio = data.get("consumed_ratio")
    if ratio in (None, ""):
        ratio = current_calories / original_calories if original_calories > 0 else 1
    try:
        ratio = float(ratio)
    except (TypeError, ValueError):
        ratio = 1
    data["original_calories"] = round(original_calories, 3)
    data["consumed_ratio"] = round(max(0, ratio), 4)
    data["adjusted_by_leftovers"] = 1 if float(data.get("leftover_calories", 0) or 0) > 0 else 0
    return data


def _sum_nutrition(items: list[dict[str, float]]) -> dict[str, float]:
    return {
        field: round(sum(float(item.get(field, 0) or 0) for item in items), 3)
        for field in NUTRITION_FIELDS
    }


def _subtract_nutrition(base: dict[str, float], deduction: dict[str, float]) -> dict[str, float]:
    if not deduction.get("calories"):
        return dict(base)
    scale = 1.0
    if base.get("calories", 0) > 0 and deduction["calories"] > base["calories"]:
        scale = base["calories"] / deduction["calories"]
    return {
        field: round(max(0, float(base.get(field, 0) or 0) - float(deduction.get(field, 0) or 0) * scale), 3)
        for field in NUTRITION_FIELDS
    }


def _normalize_food_name(value: str) -> str:
    return re.sub(r"[\s,，、。()（）\[\]【】_\-]+", "", str(value or "").lower())


def _leftover_match_score(leftover_name: str, original_name: str) -> float:
    leftover = _normalize_food_name(leftover_name)
    original = _normalize_food_name(original_name)
    if not leftover or not original:
        return 0
    if leftover == original:
        return 1
    if leftover in original or original in leftover:
        return 0.82

    leftover_tokens = set(re.findall(r"[a-z0-9]+|[\u4e00-\u9fff]", leftover))
    original_tokens = set(re.findall(r"[a-z0-9]+|[\u4e00-\u9fff]", original))
    if not leftover_tokens or not original_tokens:
        return 0
    return len(leftover_tokens & original_tokens) / max(len(leftover_tokens), len(original_tokens))


def _clamp_float(value, min_value: float, max_value: float) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        numeric = min_value
    return max(min_value, min(max_value, numeric))


def _original_food_items_from_rows(rows) -> list[dict]:
    items = []
    for row in rows:
        nutrition = _nutrition_from_row(row)
        items.append({
            "id": str(row["id"]),
            "name": row["food_name"] or "",
            "serving_size": row["serving_size"] or "",
            **{field: round(nutrition[field], 3) for field in NUTRITION_FIELDS},
        })
    return items


def _image_url_to_base64(image_url: str | None) -> str | None:
    if not image_url or not image_url.startswith("/static/"):
        return None
    path = os.path.join(static_dir, image_url.removeprefix("/static/"))
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as f:
            return base64.b64encode(f.read()).decode()
    except OSError:
        return None


def _compare_original_image_for_leftovers_enabled() -> bool:
    return os.getenv("LEFTOVER_COMPARE_ORIGINAL_IMAGE", "false").strip().lower() in {"1", "true", "yes", "on"}


def _parse_leftover_percentage_response(text: str, original_items: list[dict]) -> list[dict]:
    if not text:
        return []
    text = re.sub(r"^```(?:json)?\s*", "", text.strip())
    text = re.sub(r"\s*```$", "", text)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", text)
        if not match:
            return []
        try:
            data = json.loads(match.group())
        except json.JSONDecodeError:
            return []

    original_by_id = {str(item["id"]): item for item in original_items}
    used_ids: set[str] = set()
    parsed = []
    for raw in data.get("items", []):
        raw_id = str(raw.get("id", "")).strip()
        matched = original_by_id.get(raw_id)
        if not matched:
            best_score = 0
            for item in original_items:
                if str(item["id"]) in used_ids:
                    continue
                score = _leftover_match_score(str(raw.get("name", "")), item["name"])
                if score > best_score:
                    best_score = score
                    matched = item
            if best_score < 0.45:
                matched = None
        if not matched:
            continue

        confidence = _clamp_float(raw.get("confidence", 0.55), 0, 100)
        if confidence > 1:
            confidence = confidence / 100
        item_id = str(matched["id"])
        used_ids.add(item_id)
        parsed.append({
            "id": item_id,
            "name": matched["name"],
            "remaining_percent": round(_clamp_float(raw.get("remaining_percent", 0), 0, 100), 1),
            "confidence": round(_clamp_float(confidence, 0, 1), 2),
            "reason": str(raw.get("reason", ""))[:120],
            "original_calories": round(float(matched.get("calories", 0) or 0), 1),
        })

    for item in original_items:
        item_id = str(item["id"])
        if item_id not in used_ids:
            parsed.append({
                "id": item_id,
                "name": item["name"],
                "remaining_percent": 0,
                "confidence": 0.45,
                "reason": "剩余图中未明确看到",
                "original_calories": round(float(item.get("calories", 0) or 0), 1),
            })
    return parsed


def _fallback_percentages_from_leftover_foods(original_items: list[dict], leftover_foods: list[Food]) -> list[dict]:
    remaining_by_id = {str(item["id"]): 0.0 for item in original_items}
    for food in leftover_foods:
        best_item = None
        best_score = 0.0
        for item in original_items:
            score = _leftover_match_score(food.name, item["name"])
            if score > best_score:
                best_score = score
                best_item = item
        if not best_item or best_score < 0.45:
            continue
        item_id = str(best_item["id"])
        original_cal = float(best_item.get("calories", 0) or 0)
        if original_cal > 0:
            remaining_by_id[item_id] += min(100, (float(food.calories or 0) / original_cal) * 100)

    return [
        {
            "id": str(item["id"]),
            "name": item["name"],
            "remaining_percent": round(min(100, remaining_by_id[str(item["id"])]), 1),
            "confidence": 0.5,
            "reason": "按剩余照片营养估算",
            "original_calories": round(float(item.get("calories", 0) or 0), 1),
        }
        for item in original_items
    ]


async def _estimate_leftover_percentages(
    upload_group_id: str,
    image_base64: str,
    day: str | None = None,
    description: str = "",
) -> dict:
    if not upload_group_id:
        raise HTTPException(status_code=400, detail="upload_group_id is required")

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE upload_group_id = ? ORDER BY id",
            (upload_group_id,),
        ).fetchall()
    if not rows:
        raise HTTPException(status_code=404, detail="找不到这次上传的餐食记录")

    original_items = _original_food_items_from_rows(rows)
    original_total = _sum_nutrition([{field: item[field] for field in NUTRITION_FIELDS} for item in original_items])
    original_image_base64 = None
    if _compare_original_image_for_leftovers_enabled():
        original_image_base64 = _image_url_to_base64(next((row["image_url"] for row in rows if row["image_url"]), ""))

    items: list[dict] = []
    notes = ""
    if describe_meal and getattr(describe_meal, "provider", None):
        try:
            raw_text = await describe_meal.provider.analyze_leftover_percentages(
                original_items,
                image_base64,
                original_image_base64,
                description,
            )
            items = _parse_leftover_percentage_response(raw_text, original_items)
        except Exception as e:
            notes = f"比例估算不可用，已使用营养识别兜底：{e}"

    if not items:
        leftover_foods = await _analyze_leftover_foods(image_base64)
        items = _fallback_percentages_from_leftover_foods(original_items, leftover_foods)
        if not notes:
            notes = "已使用剩余食物营养识别兜底"

    estimated_leftover_calories = round(sum(
        float(item.get("original_calories", 0) or 0) * float(item.get("remaining_percent", 0) or 0) / 100
        for item in items
    ), 1)
    return {
        "status": "needs_confirmation",
        "date": day or next((row["date"] for row in rows if row["date"]), __import__("datetime").date.today().isoformat()),
        "upload_group_id": upload_group_id,
        "original_calories": round(original_total["calories"], 1),
        "estimated_leftover_calories": estimated_leftover_calories,
        "estimated_consumed_calories": round(max(0, original_total["calories"] - estimated_leftover_calories), 1),
        "items": items,
        "notes": notes,
    }


def _apply_leftover_percentages_to_log(
    upload_group_id: str,
    items: list[FoodLogLeftoverApplyItem | dict],
    image_base64: str | None = None,
    day: str | None = None,
) -> dict:
    if not upload_group_id:
        raise HTTPException(status_code=400, detail="upload_group_id is required")

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE upload_group_id = ? ORDER BY id",
            (upload_group_id,),
        ).fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="找不到这次上传的餐食记录")

        normalized_items = []
        for item in items:
            payload = item.model_dump() if hasattr(item, "model_dump") else dict(item)
            confidence = _clamp_float(payload.get("confidence", 0), 0, 100)
            if confidence > 1:
                confidence = confidence / 100
            normalized_items.append({
                "id": str(payload.get("id", "")),
                "name": str(payload.get("name", "")),
                "remaining_percent": round(_clamp_float(payload.get("remaining_percent", 0), 0, 100), 1),
                "confidence": round(_clamp_float(confidence, 0, 1), 2),
                "reason": str(payload.get("reason", ""))[:120],
            })

        item_by_id = {item["id"]: item for item in normalized_items if item["id"]}
        original_by_id = {int(row["id"]): _nutrition_from_row(row) for row in rows}
        consumed_by_id: dict[int, dict[str, float]] = {}
        leftover_by_id: dict[int, dict[str, float]] = {}
        resolved_items = []

        for row in rows:
            row_id = int(row["id"])
            item = item_by_id.get(str(row_id))
            if not item:
                item = next(
                    (candidate for candidate in normalized_items if _leftover_match_score(candidate["name"], row["food_name"] or "") >= 0.45),
                    {"id": str(row_id), "name": row["food_name"] or "", "remaining_percent": 0, "confidence": 0, "reason": ""},
                )
            pct = _clamp_float(item.get("remaining_percent", 0), 0, 100)
            original = original_by_id[row_id]
            consumed_by_id[row_id] = {
                field: round(original[field] * (1 - pct / 100), 3)
                for field in NUTRITION_FIELDS
            }
            leftover_by_id[row_id] = {
                field: round(original[field] * (pct / 100), 3)
                for field in NUTRITION_FIELDS
            }
            resolved_items.append({
                **item,
                "id": str(row_id),
                "name": row["food_name"] or item.get("name", ""),
                "original_calories": round(original["calories"], 1),
                "leftover_calories": round(leftover_by_id[row_id]["calories"], 1),
                "consumed_calories": round(consumed_by_id[row_id]["calories"], 1),
            })

        original_total = _sum_nutrition(list(original_by_id.values()))
        leftover_total = _sum_nutrition(list(leftover_by_id.values()))
        consumed_total = _sum_nutrition(list(consumed_by_id.values()))
        consumed_ratio = consumed_total["calories"] / original_total["calories"] if original_total["calories"] > 0 else 1
        consumed_ratio = round(max(0, min(1, consumed_ratio)), 4)
        leftover_image_url = _save_upload_image(image_base64, f"{upload_group_id}_leftover") if image_base64 else ""
        leftover_json = json.dumps(
            {
                "method": "remaining_percent",
                "items": resolved_items,
                "total": leftover_total,
            },
            ensure_ascii=False,
        )

        for row in rows:
            row_id = int(row["id"])
            original_json = row["original_nutrition_json"] or json.dumps(original_by_id[row_id], ensure_ascii=False)
            consumed = consumed_by_id[row_id]
            conn.execute(
                f"""UPDATE food_log_history
                    SET {", ".join(f"{field} = ?" for field in NUTRITION_FIELDS)},
                        original_nutrition_json = ?,
                        leftover_nutrition_json = ?,
                        leftover_image_url = COALESCE(NULLIF(?, ''), leftover_image_url),
                        leftover_logged_at = CURRENT_TIMESTAMP,
                        leftover_calories = ?,
                        consumed_ratio = ?
                    WHERE id = ?""",
                (
                    *[round(consumed[field], 3) for field in NUTRITION_FIELDS],
                    original_json,
                    leftover_json,
                    leftover_image_url,
                    round(leftover_by_id[row_id]["calories"], 3),
                    consumed_ratio,
                    row_id,
                ),
            )
        conn.commit()

    log_day = day or next((row["date"] for row in rows if row["date"]), __import__("datetime").date.today().isoformat())
    summary = _daily_summary_for_day(log_day)
    return {
        "status": "ok",
        "date": log_day,
        "upload_group_id": upload_group_id,
        "original_calories": round(original_total["calories"], 1),
        "leftover_calories": round(leftover_total["calories"], 1),
        "applied_leftover_calories": round(leftover_total["calories"], 1),
        "consumed_calories": round(consumed_total["calories"], 1),
        "consumed_ratio": consumed_ratio,
        "items": resolved_items,
        "daily_summary": summary.model_dump(),
    }


def _apply_leftovers_to_log(
    upload_group_id: str,
    leftover_foods: list[Food],
    image_base64: str,
    day: str | None = None,
) -> dict:
    if not upload_group_id:
        raise HTTPException(status_code=400, detail="upload_group_id is required")
    if not leftover_foods:
        raise HTTPException(status_code=400, detail="没有识别到剩余食物，请重新拍摄剩余部分")

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE upload_group_id = ? ORDER BY id",
            (upload_group_id,),
        ).fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="找不到这次上传的餐食记录")

        log_day = day or next((row["date"] for row in rows if row["date"]), __import__("datetime").date.today().isoformat())
        original_by_id = {int(row["id"]): _nutrition_from_row(row) for row in rows}
        consumed_by_id = {row_id: dict(nutrition) for row_id, nutrition in original_by_id.items()}
        row_names = {int(row["id"]): row["food_name"] or "" for row in rows}
        unmatched_leftovers: list[dict[str, float]] = []

        for food in leftover_foods:
            leftover_nutrition = _nutrition_from_food(food)
            best_row_id = None
            best_score = 0.0
            for row_id, row_name in row_names.items():
                score = _leftover_match_score(food.name, row_name)
                if score > best_score:
                    best_score = score
                    best_row_id = row_id

            if best_row_id is not None and best_score >= 0.45:
                consumed_by_id[best_row_id] = _subtract_nutrition(consumed_by_id[best_row_id], leftover_nutrition)
            else:
                unmatched_leftovers.append(leftover_nutrition)

        unmatched_total = _sum_nutrition(unmatched_leftovers)
        if unmatched_total["calories"] > 0:
            remaining_total_calories = sum(item["calories"] for item in consumed_by_id.values())
            cap_ratio = min(1.0, remaining_total_calories / unmatched_total["calories"]) if unmatched_total["calories"] else 1.0
            if remaining_total_calories > 0:
                for row_id, nutrition in list(consumed_by_id.items()):
                    share = nutrition["calories"] / remaining_total_calories
                    proportional_deduction = {
                        field: unmatched_total[field] * cap_ratio * share
                        for field in NUTRITION_FIELDS
                    }
                    consumed_by_id[row_id] = _subtract_nutrition(nutrition, proportional_deduction)

        original_total = _sum_nutrition(list(original_by_id.values()))
        leftover_total = _sum_nutrition([_nutrition_from_food(food) for food in leftover_foods])
        consumed_total = _sum_nutrition(list(consumed_by_id.values()))
        consumed_ratio = consumed_total["calories"] / original_total["calories"] if original_total["calories"] > 0 else 1
        consumed_ratio = round(max(0, min(1, consumed_ratio)), 4)
        leftover_image_url = _save_upload_image(image_base64, f"{upload_group_id}_leftover")
        leftover_json = json.dumps(
            {
                "foods": [food.model_dump(mode="json") for food in leftover_foods],
                "total": leftover_total,
            },
            ensure_ascii=False,
        )

        for row in rows:
            row_id = int(row["id"])
            original_json = row["original_nutrition_json"] or json.dumps(original_by_id[row_id], ensure_ascii=False)
            consumed = consumed_by_id[row_id]
            conn.execute(
                f"""UPDATE food_log_history
                    SET {", ".join(f"{field} = ?" for field in NUTRITION_FIELDS)},
                        original_nutrition_json = ?,
                        leftover_nutrition_json = ?,
                        leftover_image_url = ?,
                        leftover_logged_at = CURRENT_TIMESTAMP,
                        leftover_calories = ?,
                        consumed_ratio = ?
                    WHERE id = ?""",
                (
                    *[round(consumed[field], 3) for field in NUTRITION_FIELDS],
                    original_json,
                    leftover_json,
                    leftover_image_url,
                    round(leftover_total["calories"], 3),
                    consumed_ratio,
                    row_id,
                ),
            )
        conn.commit()

    summary = _daily_summary_for_day(log_day)
    return {
        "status": "ok",
        "date": log_day,
        "upload_group_id": upload_group_id,
        "original_calories": round(original_total["calories"], 1),
        "leftover_calories": round(leftover_total["calories"], 1),
        "applied_leftover_calories": round(max(0, original_total["calories"] - consumed_total["calories"]), 1),
        "consumed_calories": round(consumed_total["calories"], 1),
        "consumed_ratio": consumed_ratio,
        "leftover_foods": [food.model_dump(mode="json") for food in leftover_foods],
        "daily_summary": summary.model_dump(),
    }


async def _analyze_leftover_foods(image_base64: str) -> list[Food]:
    if describe_meal is None:
        raise HTTPException(
            status_code=503,
            detail="暂未配置文本/条码识别模型，请在 .env 中设置 ZHIPU_API_KEY、DEEPSEEK_API_KEY 或 GEMINI_API_KEY。",
        )
    result = await describe_meal.analyze(
        DescribeMealRequest(source=ScanSource.image_scan, image_base64=image_base64)
    )
    return result.foods


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _parse_iso_datetime(value: str | None) -> datetime:
    if not value:
        return datetime.now().astimezone()
    text = str(value).replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        parsed = datetime.now().astimezone()
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed


def _fasting_default_preferences() -> dict:
    return {
        "enabled": False,
        "method": "16:8",
        "fasting_hours": 16,
        "eating_hours": 8,
        "eating_window_start": "12:00",
        "reminders_enabled": True,
        "timezone": "local",
    }


def _normalize_fasting_preferences(data: dict | FastingPreferencesRequest | None) -> dict:
    raw = data.model_dump() if hasattr(data, "model_dump") else dict(data or {})
    prefs = {**_fasting_default_preferences(), **raw}
    method = str(prefs.get("method") or "16:8")
    match = re.match(r"^\s*(\d+(?:\.\d+)?)\s*[:/]\s*(\d+(?:\.\d+)?)\s*$", method)
    raw_fasting = float(raw.get("fasting_hours") or 16)
    raw_eating = float(raw.get("eating_hours") or 8)
    raw_uses_request_defaults = raw_fasting == 16 and raw_eating == 8
    method_is_default = method.strip().replace("/", ":") == "16:8"
    if match and ("fasting_hours" not in raw or "eating_hours" not in raw or (not method_is_default and raw_uses_request_defaults)):
        prefs["fasting_hours"] = float(match.group(1))
        prefs["eating_hours"] = float(match.group(2))
    prefs["fasting_hours"] = round(max(1, min(72, float(prefs.get("fasting_hours") or 16))), 1)
    prefs["eating_hours"] = round(max(1, min(23, float(prefs.get("eating_hours") or max(1, 24 - prefs["fasting_hours"])))), 1)
    prefs["method"] = f"{prefs['fasting_hours']:g}:{prefs['eating_hours']:g}"
    if not re.match(r"^\d{2}:\d{2}$", str(prefs.get("eating_window_start", ""))):
        prefs["eating_window_start"] = "12:00"
    prefs["enabled"] = bool(prefs.get("enabled"))
    prefs["reminders_enabled"] = bool(prefs.get("reminders_enabled"))
    prefs["timezone"] = str(prefs.get("timezone") or "local")
    return prefs


def _ensure_fasting_tables(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS fasting_preferences (
            id TEXT PRIMARY KEY DEFAULT 'default',
            data_json TEXT NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS fasting_sessions (
            id TEXT PRIMARY KEY,
            method TEXT DEFAULT '16:8',
            fasting_hours REAL DEFAULT 16,
            start_at TEXT NOT NULL,
            target_end_at TEXT NOT NULL,
            ended_at TEXT,
            status TEXT DEFAULT 'active',
            notes TEXT DEFAULT '',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_fasting_sessions_status ON fasting_sessions(status);
        CREATE INDEX IF NOT EXISTS idx_fasting_sessions_start ON fasting_sessions(start_at);
    """)


def _get_fasting_preferences() -> dict:
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        row = conn.execute("SELECT data_json FROM fasting_preferences WHERE id = 'default'").fetchone()
    if not row:
        return _fasting_default_preferences()
    try:
        saved = json.loads(row["data_json"])
    except Exception:
        saved = {}
    return _normalize_fasting_preferences(saved)


def _save_fasting_preferences(req: FastingPreferencesRequest) -> dict:
    prefs = _normalize_fasting_preferences(req)
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        conn.execute(
            """INSERT INTO fasting_preferences (id, data_json, updated_at)
               VALUES ('default', ?, CURRENT_TIMESTAMP)
               ON CONFLICT(id) DO UPDATE SET
               data_json = excluded.data_json,
               updated_at = CURRENT_TIMESTAMP""",
            (json.dumps(prefs, ensure_ascii=False),),
        )
        conn.commit()
    return prefs


FASTING_STAGE_DEFINITIONS = [
    {
        "id": "blood_sugar_rises",
        "label": "血糖上升",
        "starts_at_hours": 0,
        "ends_at_hours": 3,
        "description": "身体开始消化上一餐并分泌胰岛素，血糖水平会上升。",
        "advice": "刚开始断食，先保持补水并让身体进入节奏。",
        "color": "#007aff",
    },
    {
        "id": "blood_sugar_drops",
        "label": "血糖下降",
        "starts_at_hours": 3,
        "ends_at_hours": 9,
        "description": "消化接近完成，细胞正在吸收并使用来自食物的能量。",
        "advice": "继续喝水，避免含糖饮品打断断食。",
        "color": "#ff9500",
    },
    {
        "id": "blood_sugar_stabilizes",
        "label": "血糖稳定",
        "starts_at_hours": 9,
        "ends_at_hours": 11,
        "description": "胰岛素影响减弱，身体开始调用此前储存的能量。",
        "advice": "饥饿感可能波动，先观察身体感受。",
        "color": "#34c759",
    },
    {
        "id": "fat_burning",
        "label": "脂肪燃烧",
        "starts_at_hours": 11,
        "ends_at_hours": 14,
        "description": "身体开始更多使用储存脂肪作为能量来源。",
        "advice": "继续补水，轻活动可以帮助保持状态。",
        "color": "#ff3b30",
    },
    {
        "id": "ketosis",
        "label": "酮体开始",
        "starts_at_hours": 14,
        "ends_at_hours": 16,
        "description": "脂肪代谢会产生酮体，身体开始把它作为能量来源之一。",
        "advice": "保持温和节奏，不要在明显不适时硬撑。",
        "color": "#5856d6",
    },
    {
        "id": "autophagy",
        "label": "细胞自噬",
        "starts_at_hours": 16,
        "ends_at_hours": None,
        "description": "受损细胞开始更新与回收，身体进入更深层的修复节奏。",
        "advice": "这属于进阶阶段，不建议没有经验时硬撑。",
        "color": "#111827",
    },
]


def _stage_window_label(stage: dict) -> str:
    start = f"{stage['starts_at_hours']:g}"
    end = stage.get("ends_at_hours")
    if end is None:
        return f"{start}+ 小时"
    return f"{start}-{end:g} 小时"


def _stage_display(stage: dict) -> dict:
    return {
        **stage,
        "window_label": _stage_window_label(stage),
    }


def _fasting_stage_for_elapsed(elapsed_seconds: int, target_seconds: int | None = None) -> dict:
    elapsed_hours = max(0, elapsed_seconds) / 3600
    current = FASTING_STAGE_DEFINITIONS[-1]
    for stage in FASTING_STAGE_DEFINITIONS:
        stage_end = stage.get("ends_at_hours")
        if elapsed_hours >= stage["starts_at_hours"] and (stage_end is None or elapsed_hours < stage_end):
            current = stage
            break

    current_index = FASTING_STAGE_DEFINITIONS.index(current)
    next_stage = FASTING_STAGE_DEFINITIONS[current_index + 1] if current_index + 1 < len(FASTING_STAGE_DEFINITIONS) else None
    stage_start_seconds = int(current["starts_at_hours"] * 3600)
    if current.get("ends_at_hours") is None:
        stage_end_seconds = max(target_seconds or 0, stage_start_seconds + 4 * 3600)
    else:
        stage_end_seconds = int(current["ends_at_hours"] * 3600)
    stage_seconds = max(1, stage_end_seconds - stage_start_seconds)
    progress_pct = round(min(100, max(0, (elapsed_seconds - stage_start_seconds) / stage_seconds * 100)), 1)
    return {
        **_stage_display(current),
        "progress_pct": progress_pct,
        "next_label": next_stage["label"] if next_stage else "",
        "next_in_seconds": max(0, int(next_stage["starts_at_hours"] * 3600) - elapsed_seconds) if next_stage else 0,
    }


def _fasting_stage_plan(current_stage_id: str | None = None) -> list[dict]:
    return [
        {
            **_stage_display(stage),
            "active": stage["id"] == current_stage_id,
        }
        for stage in FASTING_STAGE_DEFINITIONS
    ]


def _row_to_fasting_session(row) -> dict:
    data = dict(row)
    start = _parse_iso_datetime(data.get("start_at"))
    target = _parse_iso_datetime(data.get("target_end_at"))
    ended = _parse_iso_datetime(data.get("ended_at")) if data.get("ended_at") else None
    now = datetime.now().astimezone()
    current_end = ended or now
    elapsed_seconds = max(0, int((current_end - start).total_seconds()))
    target_seconds = max(1, int((target - start).total_seconds()))
    remaining_seconds = max(0, int((target - now).total_seconds())) if data.get("status") == "active" else 0
    completed = elapsed_seconds >= target_seconds
    stage = _fasting_stage_for_elapsed(elapsed_seconds, target_seconds)
    return {
        "id": data.get("id"),
        "method": data.get("method") or "16:8",
        "fasting_hours": float(data.get("fasting_hours") or 16),
        "start_at": data.get("start_at"),
        "target_end_at": data.get("target_end_at"),
        "ended_at": data.get("ended_at") or "",
        "status": data.get("status") or "active",
        "notes": data.get("notes") or "",
        "elapsed_seconds": elapsed_seconds,
        "remaining_seconds": remaining_seconds,
        "target_seconds": target_seconds,
        "progress_pct": round(min(100, elapsed_seconds / target_seconds * 100), 1),
        "completed": completed,
        "stage": stage,
    }


def _get_active_fasting_session(conn=None) -> dict | None:
    owns_conn = conn is None
    if owns_conn:
        conn = tracking._get_conn()
    try:
        _ensure_fasting_tables(conn)
        row = conn.execute(
            "SELECT * FROM fasting_sessions WHERE status = 'active' ORDER BY start_at DESC LIMIT 1"
        ).fetchone()
        return _row_to_fasting_session(row) if row else None
    finally:
        if owns_conn:
            conn.close()


def _get_fasting_status() -> dict:
    prefs = _get_fasting_preferences()
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        active = _get_active_fasting_session(conn)
        recent = conn.execute(
            "SELECT * FROM fasting_sessions ORDER BY start_at DESC LIMIT 7"
        ).fetchall()
    current_stage = active.get("stage") if active else None
    return {
        "preferences": prefs,
        "active_session": active,
        "enabled": bool(prefs.get("enabled")),
        "is_fasting": bool(active),
        "current_stage": current_stage,
        "stage_plan": _fasting_stage_plan(current_stage.get("id") if current_stage else None),
        "recent_sessions": [_row_to_fasting_session(row) for row in recent],
    }


def _start_fasting_session(req: FastingStartRequest) -> dict:
    prefs = _get_fasting_preferences()
    method = req.method or prefs["method"]
    method_defaults = _normalize_fasting_preferences({"method": method})
    normalized_input = {**prefs, "method": method}
    if req.method:
        normalized_input["eating_hours"] = method_defaults["eating_hours"]
    if req.fasting_hours is not None:
        normalized_input["fasting_hours"] = req.fasting_hours
        if not req.method:
            normalized_input["eating_hours"] = max(1, 24 - float(req.fasting_hours))
    else:
        normalized_input["fasting_hours"] = method_defaults["fasting_hours"]
    normalized = _normalize_fasting_preferences(normalized_input)
    start = _parse_iso_datetime(req.start_at)
    target = start + timedelta(hours=float(normalized["fasting_hours"]))
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        active = _get_active_fasting_session(conn)
        if active:
            recent = conn.execute(
                "SELECT * FROM fasting_sessions ORDER BY start_at DESC LIMIT 7"
            ).fetchall()
            return {
                "status": "already_active",
                "preferences": prefs,
                "active_session": active,
                "enabled": bool(prefs.get("enabled")),
                "is_fasting": True,
                "current_stage": active.get("stage"),
                "stage_plan": _fasting_stage_plan(active.get("stage", {}).get("id")),
                "recent_sessions": [_row_to_fasting_session(row) for row in recent],
            }
        session_id = uuid4().hex[:12]
        conn.execute(
            """INSERT INTO fasting_sessions
               (id, method, fasting_hours, start_at, target_end_at, status)
               VALUES (?, ?, ?, ?, ?, 'active')""",
            (session_id, normalized["method"], normalized["fasting_hours"], start.isoformat(timespec="seconds"), target.isoformat(timespec="seconds")),
        )
        conn.commit()
    if not prefs.get("enabled") or prefs.get("method") != normalized["method"]:
        _save_fasting_preferences(FastingPreferencesRequest(**{**prefs, **normalized, "enabled": True}))
    return _get_fasting_status()


def _end_fasting_session(req: FastingEndRequest) -> dict:
    ended = _parse_iso_datetime(req.ended_at)
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        active = _get_active_fasting_session(conn)
        if not active:
            raise HTTPException(status_code=404, detail="没有正在进行的断食")
        start = _parse_iso_datetime(active["start_at"])
        target = _parse_iso_datetime(active["target_end_at"])
        status = "completed" if ended >= target else "ended_early"
        conn.execute(
            "UPDATE fasting_sessions SET ended_at = ?, status = ?, notes = ? WHERE id = ?",
            (ended.isoformat(timespec="seconds"), status, req.notes, active["id"]),
        )
        conn.commit()
    return _get_fasting_status()


def _cancel_fasting_session() -> dict:
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        active = _get_active_fasting_session(conn)
        if not active:
            raise HTTPException(status_code=404, detail="没有正在进行的断食")
        conn.execute(
            "UPDATE fasting_sessions SET ended_at = ?, status = 'canceled', notes = ? WHERE id = ?",
            (_now_iso(), "用户取消", active["id"]),
        )
        conn.commit()
    return _get_fasting_status()


def _add_manual_fasting_session(req: FastingManualRequest) -> dict:
    start = _parse_iso_datetime(req.start_at)
    ended = _parse_iso_datetime(req.ended_at)
    now = datetime.now().astimezone()
    if ended <= start:
        raise HTTPException(status_code=400, detail="结束时间必须晚于开始时间")
    if ended > now + timedelta(minutes=1):
        raise HTTPException(status_code=400, detail="补记断食不能晚于当前时间")

    duration_hours = round((ended - start).total_seconds() / 3600, 1)
    if req.fasting_hours is not None:
        fasting_hours = round(max(1, min(72, float(req.fasting_hours))), 1)
        method_defaults = _normalize_fasting_preferences({"method": req.method or f"{fasting_hours:g}:{max(1, 24 - fasting_hours):g}"})
        eating_hours = method_defaults["eating_hours"] if req.method else max(1, min(23, round(24 - fasting_hours, 1)))
        normalized = _normalize_fasting_preferences({
            "method": req.method or f"{fasting_hours:g}:{eating_hours:g}",
            "fasting_hours": fasting_hours,
            "eating_hours": eating_hours,
        })
    elif req.method:
        normalized = _normalize_fasting_preferences({"method": req.method})
    else:
        fasting_hours = max(1, min(72, duration_hours))
        eating_hours = max(1, min(23, round(24 - min(23, fasting_hours), 1)))
        normalized = _normalize_fasting_preferences({
            "method": f"{fasting_hours:g}:{eating_hours:g}",
            "fasting_hours": fasting_hours,
            "eating_hours": eating_hours,
        })

    target = start + timedelta(hours=float(normalized["fasting_hours"]))
    status = "completed" if ended >= target else "ended_early"
    session_id = uuid4().hex[:12]

    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        active = _get_active_fasting_session(conn)
        if active:
            active_start = _parse_iso_datetime(active["start_at"])
            active_end = _parse_iso_datetime(active["ended_at"]) if active.get("ended_at") else now
            if start < active_end and ended > active_start:
                raise HTTPException(status_code=400, detail="补记时间与正在进行的断食重叠")
        conn.execute(
            """INSERT INTO fasting_sessions
               (id, method, fasting_hours, start_at, target_end_at, ended_at, status, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                session_id,
                normalized["method"],
                normalized["fasting_hours"],
                start.isoformat(timespec="seconds"),
                target.isoformat(timespec="seconds"),
                ended.isoformat(timespec="seconds"),
                status,
                req.notes,
            ),
        )
        conn.commit()

    return _get_fasting_history(30)


def _get_fasting_history(days: int = 30) -> dict:
    since = (datetime.now().astimezone() - timedelta(days=max(1, min(365, days)))).isoformat(timespec="seconds")
    with tracking._get_conn() as conn:
        _ensure_fasting_tables(conn)
        rows = conn.execute(
            "SELECT * FROM fasting_sessions WHERE start_at >= ? ORDER BY start_at DESC LIMIT 100",
            (since,),
        ).fetchall()
    sessions = [_row_to_fasting_session(row) for row in rows]
    completed = [s for s in sessions if s["status"] == "completed"]
    completed_dates = sorted({
        _parse_iso_datetime(s["start_at"]).date()
        for s in completed
        if s.get("start_at")
    })
    completed_date_set = set(completed_dates)
    today = datetime.now().astimezone().date()
    streak_anchor = today if today in completed_date_set else today - timedelta(days=1)
    current_streak = 0
    cursor = streak_anchor
    while cursor in completed_date_set:
        current_streak += 1
        cursor -= timedelta(days=1)

    longest_streak = 0
    running_streak = 0
    previous_date = None
    for day in completed_dates:
        if previous_date is not None and day == previous_date + timedelta(days=1):
            running_streak += 1
        else:
            running_streak = 1
        longest_streak = max(longest_streak, running_streak)
        previous_date = day

    week_start = today - timedelta(days=today.weekday())
    week_completed_dates = [
        day.isoformat()
        for day in completed_dates
        if week_start <= day <= today
    ]
    return {
        "sessions": sessions,
        "summary": {
            "total_sessions": len(sessions),
            "completed_sessions": len(completed),
            "completion_rate": round(len(completed) / max(1, len(sessions)) * 100),
            "average_hours": round(sum(s["elapsed_seconds"] for s in sessions) / max(1, len(sessions)) / 3600, 1),
            "current_streak": current_streak,
            "longest_streak": longest_streak,
            "week_completed_days": len(week_completed_dates),
            "week_completed_dates": week_completed_dates,
        },
    }


def _save_foods_to_log_result(
    foods: list[Food],
    day: str,
    meal_category: str = "",
    upload_group_id: str | None = None,
    image_base64: str | None = None,
    group_title: str = "",
    idempotency_key: str | None = None,
    request_fingerprint: str = "",
) -> tuple[list[dict], bool]:
    saved = []
    for index, food in enumerate(foods, start=1):
        ratio = float(food.consumed_ratio or 0)
        if not math.isfinite(ratio) or not 0 <= ratio <= 1:
            raise HTTPException(status_code=400, detail=f"第 {index} 项食物的食用比例必须在 0–1 之间")
    foods = [food for food in foods if float(food.consumed_ratio or 0) > 0]
    if not foods:
        return saved, False
    for index, food in enumerate(foods, start=1):
        name = str(food.name or "").strip()
        if not name:
            raise HTTPException(status_code=400, detail=f"第 {index} 项食物缺少名称")
        for field in NUTRITION_FIELDS:
            value = float(getattr(food, field, 0) or 0)
            if not math.isfinite(value) or value < 0:
                raise HTTPException(status_code=400, detail=f"{name}的{field}不能小于 0")
    group_id = upload_group_id or f"upload_{uuid4().hex}"
    image_url = _save_upload_image(image_base64, group_id)
    clean_group_title = str(group_title or "").strip()[:80]
    total_protein = 0.0
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        if idempotency_key:
            _ensure_food_log_idempotency_table(conn)
            conn.execute("BEGIN IMMEDIATE")
            existing = conn.execute(
                """SELECT request_fingerprint, response_json
                   FROM food_log_idempotency WHERE idempotency_key = ?""",
                (idempotency_key,),
            ).fetchone()
            if existing:
                previous_fingerprint = str(existing["request_fingerprint"] or "")
                if request_fingerprint and previous_fingerprint and request_fingerprint != previous_fingerprint:
                    conn.rollback()
                    raise HTTPException(status_code=409, detail="这个记录请求编号已用于其他餐食，请重新提交。")
                try:
                    previous = json.loads(existing["response_json"] or "[]")
                except (TypeError, json.JSONDecodeError):
                    previous = []
                conn.commit()
                return previous if isinstance(previous, list) else [], True
            conn.execute(
                """INSERT INTO food_log_idempotency
                   (idempotency_key, upload_group_id, request_fingerprint)
                   VALUES (?, ?, ?)""",
                (idempotency_key, group_id, request_fingerprint),
            )
        for food in foods:
            total_protein += float(food.protein or 0)
            columns = [
                "food_name", *NUTRITION_FIELDS, "serving_size", "grams_per_unit",
                "processing_level", "quantity_count", "quantity_unit",
                "quantity_description", "barcode", "nutrition_source",
                "original_nutrition_json", "consumed_ratio", "date", "meal_category",
                "upload_group_id", "upload_group_title", "image_url",
            ]
            nutrition = _nutrition_from_food(food)
            consumed_ratio = max(0.0, min(1.0, float(food.consumed_ratio or 0)))
            original_nutrition = (
                {field: round(value / consumed_ratio, 6) for field, value in nutrition.items()}
                if 0 < consumed_ratio < 1
                else nutrition
            )
            values = [
                food.name,
                *[nutrition[field] for field in NUTRITION_FIELDS],
                food.serving_size,
                max(0.1, float(food.grams_per_unit or 100)),
                food.processing_level.value if hasattr(food.processing_level, "value") else food.processing_level,
                food.quantity_count,
                food.quantity_unit,
                food.quantity_description,
                food.barcode,
                food.nutrition_source,
                json.dumps(original_nutrition, ensure_ascii=False),
                consumed_ratio,
                day,
                meal_category,
                group_id,
                clean_group_title,
                image_url,
            ]
            placeholders = ",".join(["?"] * len(columns))
            conn.execute(
                f"INSERT INTO food_log_history ({','.join(columns)}) VALUES ({placeholders})",
                values,
            )
            saved.append({
                "name": food.name,
                **{field: round(float(getattr(food, field, 0) or 0), 3) for field in NUTRITION_FIELDS},
                "serving_size": food.serving_size,
                "grams_per_unit": food.grams_per_unit,
                "processing_level": food.processing_level.value if hasattr(food.processing_level, "value") else food.processing_level,
                "quantity_count": food.quantity_count,
                "quantity_unit": food.quantity_unit,
                "quantity_description": food.quantity_description,
                "barcode": food.barcode,
                "nutrition_source": food.nutrition_source,
                "consumed_ratio": consumed_ratio,
                "upload_group_id": group_id,
                "upload_group_title": clean_group_title,
                "image_url": image_url,
            })
        if idempotency_key:
            conn.execute(
                "UPDATE food_log_idempotency SET response_json = ? WHERE idempotency_key = ?",
                (json.dumps(saved, ensure_ascii=False), idempotency_key),
            )
        conn.commit()
    if foods:
        try:
            tracking.add_habit_event(
                day,
                "food",
                meal_category or "",
                total_protein,
                {"upload_group_id": group_id, "foods": [food.name for food in foods]},
            )
        except Exception:
            pass
    return saved, False


def _save_foods_to_log(
    foods: list[Food],
    day: str,
    meal_category: str = "",
    upload_group_id: str | None = None,
    image_base64: str | None = None,
    group_title: str = "",
) -> list[dict]:
    saved, _ = _save_foods_to_log_result(
        foods,
        day,
        meal_category,
        upload_group_id,
        image_base64,
        group_title,
    )
    return saved


def _food_from_log_row(row) -> Food:
    data = dict(row)
    return Food(
        id=str(data.get("id", "")),
        name=data.get("food_name", "") or data.get("name", ""),
        date=data.get("date") or date.today().isoformat(),
        **{field: data.get(field) or 0 for field in NUTRITION_FIELDS},
        serving_size=data.get("serving_size") or "100克",
        quantity_count=data.get("quantity_count"),
        quantity_unit=data.get("quantity_unit") or "",
        quantity_description=data.get("quantity_description") or "",
        grams_per_unit=data.get("grams_per_unit") or 100,
        barcode=data.get("barcode") or "",
        nutrition_source=data.get("nutrition_source") or "",
        processing_level=data.get("processing_level") or "whole",
    )


def _food_to_snapshot(food: Food) -> dict:
    return {
        "name": food.name,
        **_nutrition_from_food(food),
        "serving_size": food.serving_size or "100克",
        "quantity_count": food.quantity_count,
        "quantity_unit": food.quantity_unit or "",
        "quantity_description": food.quantity_description or "",
        "grams_per_unit": float(food.grams_per_unit or 100),
        "barcode": food.barcode or "",
        "nutrition_source": food.nutrition_source or "",
        "processing_level": food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level or "whole"),
    }


def _food_from_snapshot(item: dict) -> Food:
    return Food(
        name=str(item.get("name") or "同款餐食"),
        **{field: float(item.get(field) or 0) for field in NUTRITION_FIELDS},
        serving_size=str(item.get("serving_size") or "100克"),
        quantity_count=item.get("quantity_count"),
        quantity_unit=str(item.get("quantity_unit") or ""),
        quantity_description=str(item.get("quantity_description") or ""),
        grams_per_unit=float(item.get("grams_per_unit") or 100),
        barcode=str(item.get("barcode") or ""),
        nutrition_source=str(item.get("nutrition_source") or ""),
        processing_level=str(item.get("processing_level") or "whole"),
    )


def _json_list(value: str | None) -> list:
    try:
        data = json.loads(value or "[]")
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _json_object(value: str | None) -> dict:
    try:
        data = json.loads(value or "{}")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _ensure_community_tables(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS community_posts (
            id TEXT PRIMARY KEY,
            author TEXT NOT NULL,
            visibility TEXT DEFAULT 'friends',
            title TEXT NOT NULL,
            body TEXT DEFAULT '',
            image_url TEXT DEFAULT '',
            meal_log_group_id TEXT DEFAULT '',
            date TEXT DEFAULT '',
            calories REAL DEFAULT 0,
            protein REAL DEFAULT 0,
            carbs REAL DEFAULT 0,
            fat REAL DEFAULT 0,
            health_label TEXT DEFAULT '',
            ai_note TEXT DEFAULT '',
            tags_json TEXT DEFAULT '[]',
            foods_json TEXT DEFAULT '[]',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS community_reactions (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            user TEXT NOT NULL,
            reaction TEXT DEFAULT 'like',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(post_id, user, reaction)
        );
        CREATE TABLE IF NOT EXISTS community_comments (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            user TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS community_reports (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            user TEXT NOT NULL,
            reason TEXT DEFAULT '',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(post_id, user)
        );
        CREATE TABLE IF NOT EXISTS community_bookmarks (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL,
            user TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(post_id, user)
        );
    """)
    existing = {row[1] for row in conn.execute("PRAGMA table_info(community_posts)").fetchall()}
    for name, definition in {
        "post_type": "TEXT DEFAULT 'meal'",
        "status_score": "REAL DEFAULT 0",
        "checkin_date": "TEXT DEFAULT ''",
        "challenge_id": "TEXT DEFAULT ''",
        "payload_json": "TEXT DEFAULT '{}'",
    }.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE community_posts ADD COLUMN {name} {definition}")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_community_posts_type_date ON community_posts(post_type, created_at)")


def _community_title(names: list[str]) -> str:
    clean = [name for name in names if name]
    if not clean:
        return "今日餐食"
    if len(clean) <= 3:
        return "、".join(clean)
    return f"{'、'.join(clean[:3])}等 {len(clean)} 项"


def _community_tags(names: list[str], calories: float, protein: float, fat: float, requested: list[str] | None = None) -> list[str]:
    text = " ".join(names)
    tags = []
    for tag in requested or []:
        clean = str(tag).strip().lstrip("#")
        if clean:
            tags.append(clean[:12])
    if calories <= 450:
        tags.append("轻卡")
    if protein >= 25:
        tags.append("高蛋白")
    if fat <= 12 and calories <= 550:
        tags.append("少油")
    if re.search(r"鸡|蛋|牛|鱼|虾|豆腐|豆|奶|瘦肉", text):
        tags.append("优质蛋白")
    if re.search(r"米饭|面|粉|粥|馒头|包子|饺子|土豆|红薯", text):
        tags.append("主食搭配")
    if re.search(r"菜|蔬|青椒|西兰花|生菜|黄瓜|番茄|菠菜|芹", text):
        tags.append("蔬菜补充")
    if re.search(r"炒|煎|炸|红烧|麻辣|火锅", text):
        tags.append("中式家常")
    unique = []
    for tag in tags:
        if tag and tag not in unique:
            unique.append(tag)
    return unique[:6]


def _community_health_label(calories: float, protein: float, fat: float) -> str:
    if protein >= 30 and calories <= 700:
        return "高蛋白友好"
    if calories <= 450 and fat <= 15:
        return "适合控卡"
    if fat >= 35 or calories >= 850:
        return "注意油脂"
    return "家常均衡"


def _community_ai_note(calories: float, protein: float, carbs: float, fat: float) -> str:
    if protein >= 30 and calories <= 700:
        return "蛋白质比较扎实，适合当作减脂期的一餐参考。"
    if calories <= 450 and fat <= 15:
        return "整体热量不高，适合想吃清爽一点的时候参考。"
    if fat >= 35 or calories >= 850:
        return "这餐能量偏高，记录同款时可以少油或减少主食比例。"
    if carbs >= 90 and protein < 20:
        return "主食占比偏高，搭配鸡蛋、豆腐或瘦肉会更稳。"
    return "这一餐搭配比较日常，可以按自己的剩余热量调整份量。"


def _community_post_by_id(conn, post_id: str):
    _ensure_community_tables(conn)
    return conn.execute("SELECT * FROM community_posts WHERE id = ?", (post_id,)).fetchone()


def _serialize_community_post(conn, row, user: str = "me") -> dict:
    post = dict(row)
    post_id = post["id"]
    reactions = conn.execute(
        "SELECT reaction, COUNT(*) AS c FROM community_reactions WHERE post_id = ? GROUP BY reaction",
        (post_id,),
    ).fetchall()
    active = conn.execute(
        "SELECT reaction FROM community_reactions WHERE post_id = ? AND user = ?",
        (post_id, user),
    ).fetchall()
    comments_count = conn.execute(
        "SELECT COUNT(*) AS c FROM community_comments WHERE post_id = ?",
        (post_id,),
    ).fetchone()["c"]
    bookmarks_count = conn.execute(
        "SELECT COUNT(*) AS c FROM community_bookmarks WHERE post_id = ?",
        (post_id,),
    ).fetchone()["c"]
    bookmarked = conn.execute(
        "SELECT 1 FROM community_bookmarks WHERE post_id = ? AND user = ? LIMIT 1",
        (post_id, user),
    ).fetchone() is not None
    recent_comments = conn.execute(
        "SELECT id, user, body, created_at FROM community_comments WHERE post_id = ? ORDER BY created_at DESC LIMIT 2",
        (post_id,),
    ).fetchall()
    return {
        "id": post_id,
        "author": post["author"],
        "author_name": "我" if post["author"] == user else post["author"],
        "avatar_initial": ("我" if post["author"] == user else post["author"] or "?")[:1].upper(),
        "visibility": post["visibility"],
        "post_type": post.get("post_type") or "meal",
        "title": post["title"],
        "body": post["body"] or "",
        "image_url": post["image_url"] or "",
        "meal_log_group_id": post["meal_log_group_id"] or "",
        "date": post["date"] or "",
        "checkin_date": post.get("checkin_date") or post["date"] or "",
        "challenge_id": post.get("challenge_id") or "",
        "status_score": round(float(post.get("status_score") or 0)),
        "payload": _json_object(post.get("payload_json")),
        "calories": round(float(post["calories"] or 0)),
        "protein": round(float(post["protein"] or 0), 1),
        "carbs": round(float(post["carbs"] or 0), 1),
        "fat": round(float(post["fat"] or 0), 1),
        "health_label": post["health_label"] or "",
        "ai_note": post["ai_note"] or "",
        "tags": _json_list(post["tags_json"]),
        "foods": _json_list(post["foods_json"]),
        "created_at": post["created_at"],
        "reactions": {r["reaction"]: r["c"] for r in reactions},
        "active_reactions": [r["reaction"] for r in active],
        "comments_count": comments_count,
        "recent_comments": [dict(r) for r in recent_comments],
        "bookmarks_count": bookmarks_count,
        "bookmarked": bookmarked,
    }


# ── /v6/describeMeal ───────────────────────────────────────────────

def _sse_payload(payload: dict) -> str:
    event_name = str(payload.get("stage") or "message")
    data = json.dumps(payload, ensure_ascii=False, default=str)
    return f"event: {event_name}\ndata: {data}\n\n"


@app.post("/v6/describeMeal")
async def describe_meal_endpoint(request: DescribeMealRequest):
    """Analyze food from image, text, or barcode.

    Supports:
      - image_scan: send image_base64 for vision analysis
      - manually: send text description
      - barcode_scan: send barcode number
    """
    if request.source == ScanSource.barcode_scan:
        barcode = str(request.barcode or "").strip()
        if not re.fullmatch(r"\d{8,14}", barcode):
            raise HTTPException(status_code=400, detail="条形码应为 8–14 位数字")
    if describe_meal is None:
        payload = _empty_describe_meal_payload("no_model", request.text)
        return DescribeMealResponse(**payload)
    try:
        result = await describe_meal.analyze(request)
        decision = None
        if result.foods:
            day = __import__("datetime").date.today().isoformat()
            decision = decision_service.score_foods(
                result.foods,
                summary=_daily_summary_for_day(day),
                fasting_status=_get_fasting_status(),
                preferences=tracking.get_user_preferences(),
                source=_source_for_decision(request.source),
                event_type=_event_type_for_decision(request.source),
                persist=False,
            )
        return result.model_copy(update={"decision": decision})
    except ValueError as e:
        payload = _empty_describe_meal_payload(str(e), request.text)
        return DescribeMealResponse(**payload)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"餐食分析失败：{e}")


@app.post("/v6/describeMeal/stream")
async def describe_meal_stream_endpoint(request: DescribeMealRequest):
    """Stream staged analysis events so the UI can show food names before final nutrition."""
    if describe_meal is None:
        raise HTTPException(
            status_code=503,
            detail="暂未配置文本/条码识别模型，请在 .env 中设置 ZHIPU_API_KEY、DEEPSEEK_API_KEY 或 GEMINI_API_KEY。",
        )

    async def event_stream():
        try:
            is_image_request = request.source in {
                ScanSource.image_scan,
                ScanSource.describe_meal,
                ScanSource.library,
                ScanSource.label_scan,
            }
            if is_image_request and request.image_base64:
                async for event in describe_meal.analyze_image_stages(
                    request.image_base64,
                    capture_context={
                        "depth_metadata": request.depth_metadata or {},
                        "capture_metadata": request.capture_metadata or {},
                    },
                ):
                    if event.get("stage") == "final":
                        foods = [Food(**item) for item in event.get("foods", [])]
                        decision = None
                        if foods:
                            day = date.today().isoformat()
                            decision = decision_service.score_foods(
                                foods,
                                summary=_daily_summary_for_day(day),
                                fasting_status=_get_fasting_status(),
                                preferences=tracking.get_user_preferences(),
                                source=_source_for_decision(request.source),
                                event_type=_event_type_for_decision(request.source),
                                persist=False,
                            )
                        event["decision"] = decision
                    yield _sse_payload(event)
                return

            result = await describe_meal.analyze(request)
            decision = None
            if result.foods:
                day = date.today().isoformat()
                decision = decision_service.score_foods(
                    result.foods,
                    summary=_daily_summary_for_day(day),
                    fasting_status=_get_fasting_status(),
                    preferences=tracking.get_user_preferences(),
                    source=_source_for_decision(request.source),
                    event_type=_event_type_for_decision(request.source),
                    persist=False,
                )
            final_event = result.model_copy(update={"decision": decision}).model_dump(mode="json")
            final_event["stage"] = "final"
            yield _sse_payload(final_event)
        except ValueError as exc:
            yield _sse_payload({"stage": "error", "message": str(exc)})
        except Exception as exc:
            yield _sse_payload({"stage": "error", "message": f"餐食分析失败：{exc}"})

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.api_route("/v6/describeMeal/autoComplete", methods=["GET", "POST"])
async def auto_complete_endpoint(request: Request, q: str = "", query: str = ""):
    """Search foods by name — returns simplified results."""
    payload = await _compat_request_payload(request)
    search_query = query or q or str(payload.get("query") or payload.get("q") or "")
    results = await auto_complete.search(search_query) if search_query else []
    data = {"results": results, "suggestions": results, "query": search_query}
    return _api_success(data, **data)


@app.api_route("/v6/describeMeal/autoComplete/suggestions", methods=["GET", "POST"])
async def suggestions_endpoint(request: Request, q: str = "", query: str = ""):
    """Return food name suggestions for auto-complete."""
    payload = await _compat_request_payload(request)
    search_query = query or q or str(payload.get("query") or payload.get("q") or "")
    suggestions = await auto_complete.suggest(search_query) if search_query else []
    data = {"suggestions": suggestions, "results": suggestions, "query": search_query}
    return _api_success(data, **data)


# ── /v6/fixFood / /v6/reportFood / /v6/voteFood (Cal AI flywheel) ─

class FixFoodAPIRequest(BaseModel):
    food_id: str
    original_name: str = ""
    corrected_name: str | None = None
    corrected_calories: float | None = None
    corrected_protein: float | None = None
    corrected_carbs: float | None = None
    corrected_fat: float | None = None
    corrected_fiber: float | None = None
    corrected_sugar: float | None = None
    corrected_sodium: float | None = None
    corrected_serving_size: str | None = None
    corrected_processing_level: str | None = None
    note: str = ""


class ReportFoodAPIRequest(BaseModel):
    food_id: str
    food_name: str = ""
    reason: str = "wrong_nutrition"
    detail: str = ""


class VoteFoodAPIRequest(BaseModel):
    food_id: str
    food_name: str = ""
    vote: str = "accurate"  # accurate | inaccurate | helpful


@app.post("/v6/fixFood")
async def fix_food_endpoint(request: FixFoodAPIRequest):
    """User corrects nutrition data for a food."""
    corrections = {}
    for field in ["corrected_name", "corrected_calories", "corrected_protein",
                  "corrected_carbs", "corrected_fat", "corrected_fiber",
                  "corrected_sugar", "corrected_sodium",
                  "corrected_serving_size", "corrected_processing_level"]:
        val = getattr(request, field, None)
        if val is not None:
            corrections[field] = val
    result = food_db.fix_food(request.food_id, corrections, request.note)
    return result


@app.post("/v6/reportFood")
async def report_food_endpoint(request: ReportFoodAPIRequest):
    """Report a food with incorrect data."""
    return food_db.report_food(request.food_id, request.reason, request.detail)


@app.post("/v6/voteFood")
async def vote_food_endpoint(request: VoteFoodAPIRequest):
    """Vote on food data accuracy."""
    return food_db.vote_food(request.food_id, request.vote)


@app.get("/v6/foodConfidence")
async def food_confidence_endpoint(food_id: str | None = None):
    """Get confidence data for foods."""
    return {"confidence": food_db.get_confidence(food_id)}


# ── /v6/health-score ──────────────────────────────────────────────

def _floatish(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _health_score_payload(request: HealthScoreRequest) -> dict:
    score = HealthScore.calculate(
        food_name=request.food_name,
        processing_level=request.processing_level,
        total_carbs=request.total_carbs,
        fiber=request.fiber,
        added_sugar=request.added_sugar,
    )
    payload = score.model_dump(mode="json")
    payload["score"] = payload.get("total")
    total = _floatish(payload.get("score"))
    payload["band"] = "excellent" if total >= 8 else "good" if total >= 6 else "fair" if total >= 4 else "poor"
    return payload


def _health_score_ipa_payload(values: dict) -> dict:
    consumed = {
        "caloriesConsumed": _floatish(values.get("caloriesConsumed", values.get("calories_consumed"))),
        "carbsConsumed": _floatish(values.get("carbsConsumed", values.get("carbs_consumed"))),
        "proteinConsumed": _floatish(values.get("proteinConsumed", values.get("protein_consumed"))),
        "fatsConsumed": _floatish(values.get("fatsConsumed", values.get("fats_consumed", values.get("fatConsumed")))),
        "sugarConsumed": _floatish(values.get("sugarConsumed", values.get("sugar_consumed"))),
        "fiberConsumed": _floatish(values.get("fiberConsumed", values.get("fiber_consumed"))),
        "sodiumConsumed": _floatish(values.get("sodiumConsumed", values.get("sodium_consumed"))),
    }
    goals = {
        "caloriesGoal": _floatish(values.get("caloriesGoal", values.get("calories_goal")), 2000),
        "carbsGoal": _floatish(values.get("carbsGoal", values.get("carbs_goal")), 250),
        "proteinGoal": _floatish(values.get("proteinGoal", values.get("protein_goal")), 120),
        "fatsGoal": _floatish(values.get("fatsGoal", values.get("fats_goal", values.get("fatGoal"))), 70),
        "sugarGoal": _floatish(values.get("sugarGoal", values.get("sugar_goal")), 50),
        "fiberGoal": _floatish(values.get("fiberGoal", values.get("fiber_goal")), 30),
        "sodiumGoal": _floatish(values.get("sodiumGoal", values.get("sodium_goal")), 2300),
    }
    calorie_ratio = consumed["caloriesConsumed"] / goals["caloriesGoal"] if goals["caloriesGoal"] else 0
    protein_ratio = consumed["proteinConsumed"] / goals["proteinGoal"] if goals["proteinGoal"] else 0
    fiber_ratio = consumed["fiberConsumed"] / goals["fiberGoal"] if goals["fiberGoal"] else 0
    sodium_ratio = consumed["sodiumConsumed"] / goals["sodiumGoal"] if goals["sodiumGoal"] else 0
    score = max(0, min(100, round(
        72
        + min(protein_ratio, 1.2) * 10
        + min(fiber_ratio, 1.2) * 8
        - max(calorie_ratio - 1.0, 0) * 20
        - max(sodium_ratio - 1.0, 0) * 10
    )))
    band = "excellent" if score >= 85 else "good" if score >= 70 else "fair" if score >= 50 else "poor"
    return {
        **consumed,
        **goals,
        "goal": values.get("goal") or goals,
        "averageHealthScore": score,
        "score": score,
        "band": band,
    }


@app.get("/v6/health-score")
async def health_score_get_endpoint(
    food_name: str = "",
    processing_level: str = "whole",
    total_carbs: float = 0,
    fiber: float = 0,
    added_sugar: float = 0,
    caloriesConsumed: float = 0,
    carbsConsumed: float = 0,
    proteinConsumed: float = 0,
    fatsConsumed: float = 0,
    sugarConsumed: float = 0,
    fiberConsumed: float = 0,
    sodiumConsumed: float = 0,
    caloriesGoal: float = 2000,
    carbsGoal: float = 250,
    proteinGoal: float = 120,
    fatsGoal: float = 70,
    sugarGoal: float = 50,
    fiberGoal: float = 30,
    sodiumGoal: float = 2300,
):
    """Calculate health score via query params for IPA clients that use GET."""
    values = {
        "caloriesConsumed": caloriesConsumed,
        "carbsConsumed": carbsConsumed,
        "proteinConsumed": proteinConsumed,
        "fatsConsumed": fatsConsumed,
        "sugarConsumed": sugarConsumed,
        "fiberConsumed": fiberConsumed,
        "sodiumConsumed": sodiumConsumed,
        "caloriesGoal": caloriesGoal,
        "carbsGoal": carbsGoal,
        "proteinGoal": proteinGoal,
        "fatsGoal": fatsGoal,
        "sugarGoal": sugarGoal,
        "fiberGoal": fiberGoal,
        "sodiumGoal": sodiumGoal,
    }
    payload = (
        _health_score_ipa_payload(values)
        if any(values[key] for key in ("caloriesConsumed", "carbsConsumed", "proteinConsumed", "fatsConsumed", "sugarConsumed", "fiberConsumed", "sodiumConsumed"))
        else _health_score_payload(HealthScoreRequest(
            food_name=food_name,
            processing_level=processing_level,
            total_carbs=total_carbs,
            fiber=fiber,
            added_sugar=added_sugar,
        ))
    )
    return _api_success(payload, **payload)


@app.post("/v6/health-score")
async def health_score_endpoint(request: Request):
    """Calculate health score (0-10) for a food based on its nutrition profile."""
    values = await _compat_request_payload(request)
    if any(key in values for key in ("caloriesConsumed", "calories_consumed", "carbsConsumed", "proteinConsumed", "fatsConsumed", "sugarConsumed", "fiberConsumed", "sodiumConsumed")):
        payload = _health_score_ipa_payload(values)
    else:
        payload = _health_score_payload(HealthScoreRequest(**values))
    return _api_success(payload, **payload)


@app.get("/v6/health-score-description")
async def health_score_description_endpoint():
    """Return the explanation of how health scores are calculated."""
    description = health_scorer.describe()
    return _api_success({"description": description}, description=description)


# ── /v6/foodDatabase ──────────────────────────────────────────────

@app.post("/v6/foodDatabase/add")
async def food_database_add_endpoint(request: FoodAddRequest):
    """Add a food to the database."""
    food = Food(
        name=request.name,
        calories=request.calories,
        protein=request.protein,
        carbs=request.carbs,
        fat=request.fat if request.fats is None else request.fats,
        fiber=request.fiber,
        sugar=request.sugar,
        added_sugar=request.added_sugar,
        sodium=request.sodium,
        sat_fat=request.sat_fat,
        trans_fat=request.trans_fat,
        cholesterol=request.cholesterol,
        vitamin_a=request.vitamin_a,
        vitamin_c=request.vitamin_c,
        calcium=request.calcium,
        iron=request.iron,
        potassium=request.potassium,
        magnesium=request.magnesium,
        zinc=request.zinc,
        folate=request.folate,
        vitamin_d=request.vitamin_d,
        vitamin_b12=request.vitamin_b12,
        vitamin_e=request.vitamin_e,
        vitamin_k=request.vitamin_k,
        omega_3=request.omega_3,
        monounsaturated_fat=request.monounsaturated_fat,
        polyunsaturated_fat=request.polyunsaturated_fat,
        serving_size=request.serving_size,
        grams_per_unit=request.grams_per_unit,
        barcode=request.barcode,
        nutrition_source=request.nutrition_source,
        processing_level=request.processing_level,
    )
    saved = await food_db.add(food)
    payload = saved.model_dump(mode="json") if hasattr(saved, "model_dump") else dict(saved)
    payload["fats"] = payload.get("fat", request.fat if request.fats is None else request.fats)
    payload["ethanol"] = request.ethanol
    payload["servings"] = request.servings
    payload["ingredients"] = request.ingredients or []
    return _api_success(payload, **payload)


@app.get("/v6/foodDatabase/search")
async def food_database_search_endpoint(q: str = Query(..., min_length=1)):
    """Search the food database."""
    foods = await food_db.search(q)
    return {"foods": foods, "query": q}


# ── /v6/recipes ───────────────────────────────────────────────────

async def _recipe_search_response(query: str):
    foods = await food_db.search(query, limit=5)
    recipes = [
        {
            "id": f"food-{idx}",
            "name": f.name,
            "title": f.name,
            "calories": f.calories,
            "protein": f.protein,
            "carbs": f.carbs,
            "fat": f.fat,
            "imageUrl": "",
            "tags": [],
        }
        for idx, f in enumerate(foods, start=1)
    ]
    data = {"recipes": recipes, "query": query, "nextCursor": None, "hasMore": False}
    return {
        "success": True,
        "status": "ok",
        "data": data,
        "remoteConfigExperiment": None,
        "statsigExperiment": None,
        "recipes": [
            {
                "name": f.name,
                "calories": f.calories,
                "protein": f.protein,
                "carbs": f.carbs,
                "fat": f.fat,
            }
            for f in foods
        ],
        "query": query,
    }


@app.get("/v6/recipes/search")
async def recipes_search_get_endpoint(q: str = "", query: str = ""):
    """Search recipes using the query shape observed in Cal AI 26.27.0."""
    return await _recipe_search_response(query or q)


@app.post("/v6/recipes/search")
async def recipes_search_endpoint(request: RecipeSearchRequest):
    """Search recipes using the body shape observed in Cal AI 26.27.0."""
    return await _recipe_search_response(request.query)


# ── /v6/rules/eval ────────────────────────────────────────────────

@app.post("/v6/rules/eval")
async def rule_eval_endpoint(request: RuleEvalRequest):
    """Evaluate a CEL expression against a nutrition context.

    This exposes the CEL rule engine that Cal AI uses for
    badge unlocking, goal checking, and nutrition validation.
    """
    from models.rules import DailyStats, Goal

    stats = DailyStats(**(request.daily_stats or {}))
    goal = Goal(**(request.goal or {}))

    ctx = create_context(
        daily_stats=stats,
        goal=goal,
        streak_days=request.streak_days,
    )

    try:
        ast = parse(request.expression)
        result = evaluate(ast, ctx)
        return {
            "expression": request.expression,
            "result": bool(result) if isinstance(result, (bool, int)) else result,
            "context": {
                "today": ctx.variables.get("today", {}),
                "goal": ctx.variables.get("goal", {}),
            },
        }
    except SyntaxError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except NameError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"规则评估失败：{e}")


# ── /v6/recipe (LLM-powered builder) ─────────────────────────────

class BuildRecipeRequest(BaseModel):
    ingredients: str  # e.g. "鸡胸肉200g, 西兰花100g, 橄榄油15ml, 蒜2瓣"
    servings: int = 1
    recipe_name: str = ""


class IngredientRecipeRequest(BaseModel):
    ingredients: str | None = None
    image_base64: str | None = None
    servings: int = 1
    limit: int = 3
    use_ai: bool = True
    date: str | None = None


class IngredientRecipeLogRequest(BaseModel):
    portion_multiplier: float = 1
    serving_size_label: str | None = None
    meal_category: str | None = "dinner"
    date: str | None = None


class IngredientRecipeUpdateRequest(BaseModel):
    recipe: dict


class IngredientRecipeCreateRequest(BaseModel):
    recipe: dict
    date: str | None = None
    source: str = "manual"


@app.post("/v6/recipe/build")
async def build_recipe_endpoint(request: BuildRecipeRequest):
    """Analyze ingredients and return per-serving nutrition + cooking instructions."""
    if describe_meal is None or describe_meal.provider is None:
        raise HTTPException(status_code=503, detail="暂未配置菜谱生成模型，请先配置 LLM API Key。")

    prompt = f"""分析以下食材组合，计算每份的营养数据，并给出简要做法。

食材: {request.ingredients}
份数: {request.servings}份

返回JSON:
{{"recipe_name":"菜名","servings":{request.servings},"total_calories":0,"calories_per_serving":0,"protein_per_serving":0,"carbs_per_serving":0,"fat_per_serving":0,"fiber":0,"sodium":0,"cooking_time":"30分钟","instructions":["步骤1","步骤2"],"ingredients_breakdown":[{{"name":"鸡胸肉","amount":"200g","calories":330,"protein":62}}]}}"""

    try:
        response_text = await describe_meal.provider.raw_completion(
            "你是营养师和厨师。返回JSON。", prompt, max_tokens=1536)
        import json, re
        return json.loads(re.sub(r'```(?:json)?\s*', '', response_text.strip()).strip())
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"菜谱生成失败：{e}")


def _split_ingredient_text(text: str | None) -> list[str]:
    if not text:
        return []
    normalized = re.sub(r"[，、；;\n]+", ",", text)
    items = []
    for item in normalized.split(","):
        value = re.sub(r"\s+", " ", item).strip()
        if value:
            items.append(value[:40])
    return items[:12]


def _ingredient_search_key(ingredient: str) -> str:
    value = re.sub(r"\([^)]*\)|（[^）]*）", "", ingredient)
    value = re.sub(r"\d+(\.\d+)?\s*(g|克|kg|千克|ml|毫升|个|颗|根|片|块|只|条|碗|杯|勺|汤匙|茶匙|份|朵|包|袋|cup|cups|bowl|bowls|piece|pieces|pcs|slice|slices|serving|servings|oz|lb|斤|两)", "", value, flags=re.I)
    value = re.sub(r"\d+(\.\d+)?", "", value)
    return value.strip(" ,，、+-") or ingredient.strip()


def _unit_for_food_name(name: str) -> str:
    lower = name.lower()
    if any(term in lower for term in ["banana", "cucumber", "carrot", "corn", "香蕉", "黄瓜", "胡萝卜", "玉米"]):
        return "根"
    if any(term in lower for term in ["bread", "toast", "slice", "面包", "吐司", "培根"]):
        return "片"
    if any(term in lower for term in ["egg", "apple", "orange", "tomato", "potato", "onion", "鸡蛋", "蛋", "苹果", "橙", "番茄", "土豆", "洋葱"]):
        return "个"
    if any(term in lower for term in ["broccoli", "cauliflower", "西兰花", "菜花"]):
        return "朵"
    if any(term in lower for term in ["rice", "noodle", "oat", "quinoa", "soup", "米饭", "饭", "面", "燕麦", "藜麦", "汤"]):
        return "碗"
    if any(term in lower for term in ["milk", "yogurt", "juice", "豆浆", "牛奶", "酸奶", "果汁"]):
        return "杯"
    if any(term in lower for term in ["oil", "sauce", "dressing", "油", "酱", "醋"]):
        return "汤匙"
    if any(term in lower for term in ["chicken wing", "wing", "shrimp", "dumpling", "鸡翅", "虾", "饺子"]):
        return "只"
    if any(term in lower for term in ["chicken", "beef", "pork", "fish", "tofu", "steak", "鸡", "牛", "猪", "鱼", "豆腐", "肉"]):
        return "块"
    return "份"


def _normalize_count_text(value: str) -> str:
    value = str(value).strip()
    mapping = {"半": "半", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9", "十": "10"}
    return mapping.get(value, value)


def _extract_amount_hint(text: str | None, food_name: str = "", from_photo: bool = False) -> str:
    if not text:
        return f"图片中的{food_name}" if from_photo and food_name else ""
    raw = str(text)
    unit = _unit_for_food_name(food_name or raw)
    cn = re.search(r"(半|一|二|两|三|四|五|六|七|八|九|十|\d+(?:\.\d+)?)\s*(个|颗|根|片|块|只|条|碗|杯|勺|汤匙|茶匙|份|朵|包|袋)", raw)
    if cn:
        hint = f"{_normalize_count_text(cn.group(1))}{cn.group(2)}"
        return f"图片中的{hint}" if from_photo else hint
    en = re.search(r"(\d+(?:\.\d+)?)\s*(wings?|pieces?|pcs|slices?|cups?|bowls?|servings?)", raw, re.I)
    if en:
        unit_map = {
            "wing": "只", "wings": "只",
            "piece": unit if unit != "份" else "块", "pieces": unit if unit != "份" else "块", "pcs": unit if unit != "份" else "块",
            "slice": "片", "slices": "片",
            "cup": "杯", "cups": "杯",
            "bowl": "碗", "bowls": "碗",
            "serving": "份", "servings": "份",
        }
        hint = f"{en.group(1)}{unit_map.get(en.group(2).lower(), unit)}"
        return f"图片中的{hint}" if from_photo else hint
    if re.search(r"\b1\s*serving\b|1\s*份|一份", raw, re.I):
        return "图片中的1份" if from_photo else "1份"
    return f"图片中的{food_name}" if from_photo and food_name else ""


def _is_blocked_ingredient(name: str, preferences: dict) -> bool:
    lower = name.lower()
    blocked = []
    for key in ["allergies", "avoid_ingredients"]:
        blocked.extend(str(v).strip().lower() for v in preferences.get(key, []) if str(v).strip())
    if any(term and term in lower for term in blocked):
        return True
    diet_type = str(preferences.get("diet_type") or "balanced")
    if diet_type in ("vegetarian", "vegan") and any(term in lower for term in recommendation_service.MEAT_KEYWORDS):
        return True
    if diet_type == "vegan" and any(term in lower for term in ["蛋", "奶", "egg", "milk", "yogurt"]):
        return True
    return False


RECIPE_NAME_ALIASES = [
    ("chicken breast", "鸡胸肉"),
    ("chicken", "鸡肉"),
    ("beef", "牛肉"),
    ("pork", "猪肉"),
    ("salmon", "三文鱼"),
    ("shrimp", "虾仁"),
    ("fish", "鱼肉"),
    ("tofu", "豆腐"),
    ("egg", "鸡蛋"),
    ("broccoli", "西兰花"),
    ("cauliflower", "花椰菜"),
    ("spinach", "菠菜"),
    ("lettuce", "生菜"),
    ("tomato", "番茄"),
    ("cucumber", "黄瓜"),
    ("carrot", "胡萝卜"),
    ("mushroom", "蘑菇"),
    ("white rice", "米饭"),
    ("brown rice", "糙米饭"),
    ("rice", "米饭"),
    ("noodle", "面条"),
    ("oat", "燕麦"),
    ("potato", "土豆"),
    ("sweet potato", "红薯"),
    ("corn", "玉米"),
    ("milk", "牛奶"),
    ("yogurt", "酸奶"),
    ("banana", "香蕉"),
    ("apple", "苹果"),
    ("orange", "橙子"),
]


def _clean_recipe_food_name(name: str, fallback: str = "") -> str:
    raw = str(name or "").strip()
    fallback_key = _ingredient_search_key(fallback).strip()
    if fallback_key:
        fallback_lower = fallback_key.lower()
        for token, zh in RECIPE_NAME_ALIASES:
            if token in fallback_lower or fallback_lower in token or zh in fallback_key:
                return zh
        return fallback_key[:18]
    lower = raw.lower()
    for token, zh in RECIPE_NAME_ALIASES:
        if token in lower:
            return zh
    value = re.sub(r"[\"]([^\"\"]+)[\"]", "", raw)
    value = re.sub(r"\([^)]*\)|（[^）]*）", "", value)
    value = re.sub(r"\b\d+(\.\d+)?\s*(g|kg|ml|oz|lb|cal|kcal|serving|servings)\b", "", value, flags=re.I)
    value = re.split(r"[,，;/｜|&+]", value)[0]
    value = re.sub(r"\s+", "", value)
    zh = "".join(ch for ch in value if "\u4e00" <= ch <= "\u9fff")
    if zh:
        return zh[:18]
    for token, zh_name in RECIPE_NAME_ALIASES:
        if token in lower:
            return zh_name
    return (raw[:18] or "食材")


def _recipe_food_match_score(food: Food, key: str) -> float:
    name = str(food.name or "")
    lower = name.lower()
    key_lower = key.lower()
    clean = _clean_recipe_food_name(name, key)
    score = 0.0
    if key and key in name:
        score += 8
    if key_lower and key_lower in lower:
        score += 8
    if clean and clean in name:
        score += 2
    for token, zh in RECIPE_NAME_ALIASES:
        if (key_lower in token or token in key_lower or key in zh or zh in key) and token in lower:
            score += 6
    if re.search(r"[\"&]|slap|mama|brand|sauce|seasoning|mix|packet|cajun|bbq", lower):
        score -= 5
    if len(name) > 28:
        score -= min(6, (len(name) - 28) / 6)
    processing = food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level or "")
    if processing in ("whole", "minimally_processed"):
        score += 1.5
    if food.calories <= 0:
        score -= 4
    return score


def _display_recipe_food(food: Food | None, fallback: str = "") -> Food | None:
    if not food:
        return None
    clean = _clean_recipe_food_name(food.name, fallback)
    return food.model_copy(update={"name": clean})


async def _recognize_ingredients(request: IngredientRecipeRequest) -> tuple[list[str], str, str, dict[str, str]]:
    ingredients = _split_ingredient_text(request.ingredients)
    amount_hints: dict[str, str] = {}
    for ingredient in ingredients:
        key = _ingredient_search_key(ingredient).lower()
        hint = _extract_amount_hint(ingredient)
        if key and hint:
            amount_hints[key] = hint
    source = "text" if ingredients else "rules"
    message = ""
    if request.image_base64:
        message = "旧图片识别链路已移除，已使用文字食材和基础模板。"

    unique = []
    seen = set()
    for item in ingredients:
        key = _ingredient_search_key(item).lower()
        if key and key not in seen:
            seen.add(key)
            unique.append(item)
    return unique[:12], source, message, amount_hints


async def _match_recipe_foods(ingredients: list[str], preferences: dict) -> tuple[list[Food], list[str]]:
    matched: list[Food] = []
    missing: list[str] = []
    seen = set()
    for ingredient in ingredients:
        key = _ingredient_search_key(ingredient)
        if not key:
            continue
        if _is_blocked_ingredient(key, preferences):
            missing.append(f"{key}（已按饮食偏好跳过）")
            continue
        foods = await food_db.search(key, limit=5)
        foods = [food for food in foods if not _is_blocked_ingredient(food.name, preferences)]
        if foods:
            ranked = sorted(foods, key=lambda food: _recipe_food_match_score(food, key), reverse=True)
            food = _display_recipe_food(ranked[0], key)
            seen_key = _ingredient_search_key(food.name).lower() if food else ""
            if food and seen_key and seen_key not in seen:
                seen.add(seen_key)
                matched.append(food)
        else:
            missing.append(ingredient)

    if matched:
        return matched, missing[:6]

    candidates = recommendation_service._filter_candidates(
        recommendation_service._load_food_candidates(),
        preferences,
    )
    return candidates[:30], missing[:6]


def _amount_hint_for_food(food_name: str, amount_hints: dict[str, str]) -> str:
    key = _ingredient_search_key(food_name).lower()
    if key in amount_hints:
        return amount_hints[key]
    lower = food_name.lower()
    for hint_key, hint in amount_hints.items():
        if hint_key and (hint_key in lower or lower in hint_key):
            return hint
    return ""


def _format_display_amount(name: str, grams: float, hint: str = "") -> str:
    grams_text = f"约{round(grams)}g"
    if hint:
        return f"{hint}（{grams_text}）"
    return _human_amount_label(name, grams)


def _recipe_food_item(food: Food, grams: float, amount_hints: dict[str, str] | None = None) -> dict:
    ratio = grams / 100
    processing = food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level)
    hint = _amount_hint_for_food(food.name, amount_hints or {})
    return {
        "id": uuid4().hex[:12],
        "name": food.name,
        "amount": f"{round(grams)}g",
        "display_amount": _format_display_amount(food.name, grams, hint),
        "calories": round(food.calories * ratio, 1),
        "protein": round(food.protein * ratio, 1),
        "carbs": round(food.carbs * ratio, 1),
        "fat": round(food.fat * ratio, 1),
        "fiber": round(food.fiber * ratio, 1),
        "sugar": round(food.sugar * ratio, 1),
        "sodium": round(food.sodium * ratio, 1),
        "added_sugar": round(food.added_sugar * ratio, 1),
        "sat_fat": round(food.sat_fat * ratio, 1),
        "trans_fat": round(food.trans_fat * ratio, 1),
        "cholesterol": round(food.cholesterol * ratio, 1),
        "vitamin_a": round(food.vitamin_a * ratio, 1),
        "vitamin_c": round(food.vitamin_c * ratio, 1),
        "calcium": round(food.calcium * ratio, 1),
        "iron": round(food.iron * ratio, 1),
        "potassium": round(food.potassium * ratio, 1),
        "serving_size": f"{round(grams)}g",
        "processing_level": processing,
    }


def _sum_recipe_items(items: list[dict], servings: int) -> dict:
    servings = max(1, min(8, int(servings or 1)))
    totals = {}
    for field in [
        "calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium",
        "added_sugar", "sat_fat", "trans_fat", "cholesterol", "vitamin_a",
        "vitamin_c", "calcium", "iron", "potassium",
    ]:
        totals[field] = round(sum(float(item.get(field) or 0) for item in items) / servings, 1)
    totals["calories"] = round(totals["calories"])
    totals["sodium"] = round(totals["sodium"])
    return totals


def _pick_recipe_food(foods: list[Food], keywords: list[str], fallback_index: int = 0) -> Food | None:
    matches = [food for food in foods if any(term.lower() in food.name.lower() for term in keywords)]
    pool = matches or foods
    if not pool:
        return None
    return pool[fallback_index % len(pool)]


def _pick_recipe_food_strict(foods: list[Food], keywords: list[str], fallback_index: int = 0) -> Food | None:
    matches = [food for food in foods if any(term.lower() in food.name.lower() for term in keywords)]
    if not matches:
        return None
    return matches[fallback_index % len(matches)]


def _dedupe_recipe_foods(foods: list[Food | None], grams: list[int]) -> tuple[list[Food], list[int]]:
    unique_foods: list[Food] = []
    unique_grams: list[int] = []
    seen: set[str] = set()
    for food, gram in zip(foods, grams):
        if not food:
            continue
        key = _ingredient_search_key(food.name).lower()
        if not key or key in seen:
            continue
        seen.add(key)
        unique_foods.append(food)
        unique_grams.append(gram)
    return unique_foods, unique_grams


def _human_amount_label(name: str, grams: float) -> str:
    """Translate grams into concrete kitchen units while keeping grams as a reference."""
    lower = name.lower()
    grams = max(1, float(grams or 0))

    def count_label(base: float, unit: str) -> str:
        count = max(0.5, round((grams / base) * 2) / 2)
        if count == 0.5:
            return f"半{unit}"
        if count == 1:
            return f"1{unit}"
        if count == 1.5:
            return f"1{unit}半"
        if float(count).is_integer():
            return f"{int(count)}{unit}"
        return f"{count:g}{unit}"

    if any(term in lower for term in ["rice", "米饭", "brown rice", "quinoa", "藜麦", "oat", "燕麦", "noodle", "面", "pasta", "soup", "汤"]):
        human = count_label(140, "碗")
    elif any(term in lower for term in ["bread", "toast", "slice", "面包", "吐司"]):
        human = count_label(35, "片")
    elif any(term in lower for term in ["egg", "鸡蛋", "蛋"]):
        human = count_label(50, "个")
    elif any(term in lower for term in ["banana", "cucumber", "carrot", "corn", "香蕉", "黄瓜", "胡萝卜", "玉米"]):
        human = count_label(120, "根")
    elif any(term in lower for term in ["milk", "yogurt", "奶", "酸奶", "豆浆"]):
        human = count_label(240, "杯")
    elif any(term in lower for term in ["oil", "sauce", "dressing", "油", "酱", "醋"]):
        human = count_label(14, "汤匙")
    elif any(term in lower for term in ["almond", "nut", "peanut", "cashew", "坚果", "花生", "杏仁", "腰果"]):
        human = count_label(30, "小袋")
    elif any(term in lower for term in ["apple", "banana", "orange", "berry", "fruit", "苹果", "香蕉", "橙", "水果", "莓"]):
        human = count_label(150, "个")
    elif any(term in lower for term in ["broccoli", "cauliflower", "西兰花", "菜花"]):
        human = count_label(25, "朵")
    elif any(term in lower for term in [
        "broccoli", "salad", "green", "lettuce", "spinach", "vegetable",
        "西兰花", "青菜", "生菜", "菠菜", "蔬菜", "沙拉", "黄瓜", "番茄",
    ]):
        human = count_label(100, "份")
    elif any(term in lower for term in [
        "chicken", "beef", "pork", "fish", "shrimp", "tofu", "turkey",
        "鸡", "牛", "猪", "鱼", "虾", "豆腐", "肉",
    ]):
        human = count_label(90, "块")
    else:
        human = count_label(100, "份")
    return f"约{human}（{round(grams)}g）"


def _compose_recipe(title: str, foods: list[Food], grams: list[int], servings: int, reason: str, instructions: list[str], prep: int, source: str, missing: list[str], amount_hints: dict[str, str] | None = None) -> dict:
    items = [_recipe_food_item(food, grams[idx], amount_hints) for idx, food in enumerate(foods) if food]
    totals = _sum_recipe_items(items, servings)
    recipe = {
        "id": uuid4().hex[:12],
        "title": title,
        "servings": max(1, min(8, int(servings or 1))),
        "serving_size_label": "1份",
        "calories": totals["calories"],
        "protein": totals["protein"],
        "carbs": totals["carbs"],
        "fat": totals["fat"],
        "fiber": totals["fiber"],
        "sodium": totals["sodium"],
        "sugar": totals["sugar"],
        "prep_time_minutes": prep,
        "active_time_minutes": prep,
        "inactive_time_minutes": 0,
        "reason": reason,
        "instructions": instructions,
        "ingredients_breakdown": items,
        "missing_ingredients": missing,
        "source": source,
        "tags": ["AI生成"],
        "meal_types": [],
    }
    return recipe


def _build_rule_recipes(foods: list[Food], ingredients: list[str], preferences: dict, summary, limit: int, servings: int, missing: list[str], amount_hints: dict[str, str] | None = None) -> list[dict]:
    candidates = [food for food in foods if not _is_blocked_ingredient(food.name, preferences)]
    if not candidates:
        candidates = recommendation_service._filter_candidates(recommendation_service._load_food_candidates(), preferences)
    protein = _pick_recipe_food_strict(candidates, recommendation_service.PROTEIN_KEYWORDS, 0)
    carb = _pick_recipe_food_strict(candidates, recommendation_service.CARB_KEYWORDS, 0)
    veg = _pick_recipe_food_strict(candidates, recommendation_service.VEGETABLE_KEYWORDS, 0)
    fruit = _pick_recipe_food_strict(candidates, recommendation_service.FRUIT_KEYWORDS, 0)
    first = _pick_recipe_food(candidates, [], 0)
    second = _pick_recipe_food(candidates, [], 1)
    prep = max(8, min(60, int(preferences.get("prep_time_minutes") or 20)))
    ingredient_hint = "、".join([_ingredient_search_key(item) for item in ingredients[:3] if _ingredient_search_key(item)])
    base_reason = "根据你手头食材、今日剩余热量和饮食偏好生成。"
    if summary.protein_goal - summary.protein > 15:
        base_reason = "今天蛋白质还有缺口，优先做高蛋白搭配。"
    recipes = []
    if protein and carb and veg:
        recipe_foods, recipe_grams = _dedupe_recipe_foods([protein, carb, veg], [150, 130, 180])
        recipes.append(_compose_recipe(
            f"{protein.name}配{carb.name}与{veg.name}",
            recipe_foods,
            recipe_grams,
            servings,
            base_reason,
            ["主食提前加热或煮熟。", "蛋白食材少油煎熟，蔬菜快速翻炒。", "装盘后按口味加少量盐或黑胡椒。"],
            prep,
            "rules",
            missing,
            amount_hints,
        ))
    if protein and veg:
        recipe_foods, recipe_grams = _dedupe_recipe_foods([protein, veg, carb], [160, 220, 70])
        recipes.append(_compose_recipe(
            f"清炒{protein.name}和{veg.name}",
            recipe_foods,
            recipe_grams,
            servings,
            f"{ingredient_hint}适合做成清淡快手菜。" if ingredient_hint else base_reason,
            ["蛋白食材切块并简单调味。", "热锅少油，先煎蛋白再下蔬菜。", "出锅前补一点水焖 1 分钟，减少用油。"],
            min(prep, 20),
            "rules",
            missing,
            amount_hints,
        ))
    if protein and veg and fruit:
        recipe_foods, recipe_grams = _dedupe_recipe_foods([protein, veg, fruit], [130, 180, 100])
        recipes.append(_compose_recipe(
            f"{protein.name}{veg.name}轻食碗",
            recipe_foods,
            recipe_grams,
            servings,
            "更轻负担，适合今天热量已经接近目标时选择。",
            ["蛋白食材煎熟或水煮。", "蔬菜切小块，和水果或清爽配菜拌匀。", "用少量酸奶、柠檬汁或醋调味。"],
            15,
            "rules",
            missing,
            amount_hints,
        ))
    if not recipes and carb and veg:
        recipe_foods, recipe_grams = _dedupe_recipe_foods([veg, carb], [220, 150])
        recipes.append(_compose_recipe(
            f"{veg.name}{carb.name}轻食碗",
            recipe_foods,
            recipe_grams,
            servings,
            f"{ingredient_hint}已按饮食偏好做成主食蔬菜搭配。" if ingredient_hint else "按当前饮食偏好生成更清淡的主食蔬菜搭配。",
            ["主食提前加热。", "蔬菜焯水或少油快炒。", "装碗后用少量盐、醋或黑胡椒调味。"],
            min(prep, 18),
            "rules",
            missing,
            amount_hints,
        ))
    if not recipes and first:
        recipe_foods, recipe_grams = _dedupe_recipe_foods([first, second], [180, 120])
        title_names = "和".join(food.name for food in recipe_foods)
        recipes.append(_compose_recipe(
            f"{title_names}简餐",
            recipe_foods,
            recipe_grams,
            servings,
            "根据可用食材生成的基础记录菜谱。",
            ["食材按常规方式加热或简单烹调。", "少油少盐调味。", "按实际吃下份量记录。"],
            min(prep, 15),
            "rules",
            missing,
            amount_hints,
        ))
    unique = []
    seen = set()
    for recipe in recipes:
        if recipe["title"] not in seen:
            seen.add(recipe["title"])
            unique.append(recipe)
    return unique[:max(1, min(3, int(limit or 3)))]


async def _enhance_recipes_with_ai(recipes: list[dict], ingredients: list[str], preferences: dict) -> list[dict]:
    if not describe_meal or not describe_meal.provider or not recipes:
        return recipes
    compact = [
        {
            "id": recipe["id"],
            "title": recipe["title"],
            "reason": recipe["reason"],
            "instructions": recipe["instructions"],
            "calories": recipe["calories"],
            "protein": recipe["protein"],
            "carbs": recipe["carbs"],
            "fat": recipe["fat"],
        }
        for recipe in recipes
    ]
    prompt = f"""基于食材和用户偏好，润色菜谱标题、理由和三步做法。不要改变任何营养数字。
食材: {json.dumps(ingredients, ensure_ascii=False)}
偏好: {json.dumps(preferences, ensure_ascii=False)}
菜谱: {json.dumps(compact, ensure_ascii=False)}

只返回JSON: {{"items":[{{"id":"原id","title":"短标题","reason":"一句中文理由","instructions":["步骤1","步骤2","步骤3"]}}]}}"""
    try:
        text = await describe_meal.provider.raw_completion("你是营养师和家常菜厨师，只返回JSON。", prompt, max_tokens=1200)
        data = json.loads(re.sub(r'```(?:json)?\s*', '', text.strip()).strip())
        by_id = {item.get("id"): item for item in data.get("items", []) if isinstance(item, dict)}
        enhanced = []
        for recipe in recipes:
            item = by_id.get(recipe["id"])
            if item:
                next_recipe = dict(recipe)
                next_recipe["title"] = str(item.get("title") or recipe["title"])[:60]
                next_recipe["reason"] = str(item.get("reason") or recipe["reason"])[:180]
                instructions = item.get("instructions")
                if isinstance(instructions, list) and instructions:
                    next_recipe["instructions"] = [str(step)[:90] for step in instructions[:4]]
                enhanced.append(next_recipe)
            else:
                enhanced.append(recipe)
        return enhanced
    except Exception:
        return recipes


def _recipe_to_food(recipe: dict, multiplier: float, serving_size_label: str | None = None) -> Food:
    multiplier = max(0.05, min(20.0, float(multiplier or 1)))
    serving_label = str(recipe.get("serving_size_label") or recipe.get("serving_size") or "1份").strip() or "1份"
    selected_label = re.sub(r"\s+", " ", str(serving_size_label or "").strip())[:40]
    serving_size = selected_label if selected_label else (serving_label if abs(multiplier - 1.0) < 0.01 else f"{multiplier:g} × {serving_label}")
    _normalize_recipe_extended_nutrition(recipe)
    return Food(
        id=uuid4().hex[:12],
        name=recipe.get("title") or "自制菜谱",
        calories=round(float(recipe.get("calories") or 0) * multiplier, 1),
        protein=round(float(recipe.get("protein") or 0) * multiplier, 1),
        carbs=round(float(recipe.get("carbs") or 0) * multiplier, 1),
        fat=round(float(recipe.get("fat") or 0) * multiplier, 1),
        fiber=round(float(recipe.get("fiber") or 0) * multiplier, 1),
        sugar=round(float(recipe.get("sugar") or 0) * multiplier, 1),
        sodium=round(float(recipe.get("sodium") or 0) * multiplier, 1),
        added_sugar=round(float(recipe.get("added_sugar") or 0) * multiplier, 1),
        sat_fat=round(float(recipe.get("sat_fat") or recipe.get("saturated_fat") or 0) * multiplier, 1),
        trans_fat=round(float(recipe.get("trans_fat") or 0) * multiplier, 1),
        cholesterol=round(float(recipe.get("cholesterol") or 0) * multiplier, 1),
        vitamin_a=round(float(recipe.get("vitamin_a") or 0) * multiplier, 1),
        vitamin_c=round(float(recipe.get("vitamin_c") or 0) * multiplier, 1),
        calcium=round(float(recipe.get("calcium") or 0) * multiplier, 1),
        iron=round(float(recipe.get("iron") or 0) * multiplier, 1),
        potassium=round(float(recipe.get("potassium") or 0) * multiplier, 1),
        serving_size=serving_size,
        processing_level="whole",
    )


RECIPE_NUTRITION_ALIASES = {
    "calories": ("calories", "calories_per_serving", "energy"),
    "protein": ("protein", "protein_per_serving"),
    "carbs": ("carbs", "carbohydrates", "carbohydrate", "carbohydrates_per_serving", "carbs_per_serving"),
    "fat": ("fat", "fat_per_serving"),
    "fiber": ("fiber", "fiber_per_serving"),
    "sugar": ("sugar", "sugars", "sugar_per_serving"),
    "sodium": ("sodium", "sodium_mg", "sodium_per_serving"),
    "added_sugar": ("added_sugar", "added_sugars"),
    "sat_fat": ("sat_fat", "saturated_fat", "saturatedFat"),
    "trans_fat": ("trans_fat", "transFat"),
    "monounsaturated_fat": ("monounsaturated_fat", "monounsaturatedFat"),
    "polyunsaturated_fat": ("polyunsaturated_fat", "polyunsaturatedFat"),
    "cholesterol": ("cholesterol",),
    "vitamin_a": ("vitamin_a", "vitaminA"),
    "vitamin_c": ("vitamin_c", "vitaminC"),
    "calcium": ("calcium",),
    "iron": ("iron",),
    "potassium": ("potassium",),
}


def _recipe_numeric_value(value) -> float:
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        for key in ("value", "amount", "calories"):
            if key in value:
                return _recipe_numeric_value(value.get(key))
        return 0.0
    text = str(value)
    match = re.search(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
    return float(match.group()) if match else 0.0


def _recipe_clean_text(value, limit: int = 120) -> str:
    text = re.sub(r"\s+", " ", str(value or "").replace("\\n", "\n")).strip()
    return text[:limit]


def _recipe_lines_from_text(value, limit: int = 12) -> list[str]:
    if isinstance(value, list):
        lines = [_recipe_clean_text(item, 220) for item in value]
    else:
        text = str(value or "").replace("\\n", "\n")
        parts = re.split(r"\n\s*\n|\r\n\s*\r\n|\n", text)
        lines = [_recipe_clean_text(part, 220) for part in parts]
    return [line for line in lines if line][:limit]


def _recipe_serving_size_text(value) -> str:
    if not isinstance(value, dict):
        return ""
    amount = value.get("value") or value.get("amount") or value.get("quantity") or ""
    unit = _recipe_clean_text(value.get("unit") or value.get("label") or "", 24)
    amount_text = f"{float(amount):g}" if isinstance(amount, (int, float)) else _recipe_clean_text(amount, 24)
    return f"{amount_text} {unit}".strip()


def _normalize_recipe_tags(recipe: dict) -> list[str]:
    if "tags" not in recipe and "tag_list" not in recipe:
        return recipe.get("tags") if isinstance(recipe.get("tags"), list) else []
    raw_tags = recipe.get("tags") or recipe.get("tag_list") or []
    if isinstance(raw_tags, (str, dict)):
        raw_tags = [raw_tags]
    tags: list[str] = []
    seen: set[str] = set()
    if isinstance(raw_tags, list):
        for raw in raw_tags:
            if isinstance(raw, dict):
                value = raw.get("name") or raw.get("title") or raw.get("label") or raw.get("tag")
            else:
                value = raw
            tag = _recipe_clean_text(value, 40)
            key = tag.lower()
            if tag and key not in seen:
                seen.add(key)
                tags.append(tag)
    recipe["tags"] = tags[:12]
    return recipe["tags"]


def _normalize_recipe_ingredients_from_external_shape(recipe: dict) -> list[dict]:
    if isinstance(recipe.get("ingredients_breakdown"), list) and recipe.get("ingredients_breakdown"):
        return recipe["ingredients_breakdown"]
    raw_ingredients = recipe.get("ingredients") or recipe.get("ingredient_lines") or []
    if isinstance(raw_ingredients, (str, dict)):
        raw_ingredients = [raw_ingredients]
    items: list[dict] = []
    if not isinstance(raw_ingredients, list):
        recipe.setdefault("ingredients_breakdown", [])
        return recipe["ingredients_breakdown"]

    for index, raw in enumerate(raw_ingredients[:80]):
        if isinstance(raw, dict):
            food = raw.get("food") if isinstance(raw.get("food"), dict) else {}
            nutrition = food.get("nutritional_contents") if isinstance(food.get("nutritional_contents"), dict) else {}
            name = _recipe_clean_text(
                raw.get("name") or raw.get("description") or food.get("description") or food.get("name") or raw.get("raw_text") or f"配料{index + 1}",
                60,
            )
            raw_text = _recipe_clean_text(raw.get("raw_text") or raw.get("display_amount") or raw.get("amount") or "", 80)
            serving_size = raw.get("serving_size") if isinstance(raw.get("serving_size"), dict) else {}
            serving_text = _recipe_serving_size_text(serving_size)
            servings = _recipe_numeric_value(raw.get("servings") or raw.get("quantity") or 1) or 1.0
            multiplier = _recipe_numeric_value(serving_size.get("nutrition_multiplier") if isinstance(serving_size, dict) else None) or 1.0
            scale = max(0.01, servings * multiplier)
            amount = raw_text or serving_text or f"{servings:g}份"
            item = {
                "name": name,
                "amount": amount,
                "display_amount": raw_text or amount,
                "serving_size": serving_text or None,
                "calories": round(_recipe_numeric_value(nutrition.get("energy") or raw.get("calories")) * scale, 1),
                "protein": round(_recipe_numeric_value(nutrition.get("protein") or raw.get("protein")) * scale, 1),
                "carbs": round(_recipe_numeric_value(nutrition.get("carbohydrates") or nutrition.get("carbs") or raw.get("carbs")) * scale, 1),
                "fat": round(_recipe_numeric_value(nutrition.get("fat") or raw.get("fat")) * scale, 1),
                "sugar": round(_recipe_numeric_value(nutrition.get("sugar") or raw.get("sugar")) * scale, 1),
                "processing_level": "prepared",
            }
        else:
            amount = _recipe_clean_text(raw, 80)
            item = {
                "name": amount.split(",")[0].strip()[:60] or f"配料{index + 1}",
                "amount": amount,
                "display_amount": amount,
                "calories": 0,
                "protein": 0,
                "processing_level": "prepared",
            }
        items.append(item)

    recipe["ingredients_breakdown"] = items
    return items


def _normalize_recipe_external_shape(recipe: dict) -> dict:
    """Accept MyFitnessPal-style recipe payloads and normalize them into our schema."""
    if not isinstance(recipe, dict):
        return {}
    title = _recipe_clean_text(recipe.get("title") or recipe.get("name") or recipe.get("recipe_name"), 80)
    if title:
        recipe["title"] = title
    if "instructions" not in recipe or not recipe.get("instructions"):
        directions = recipe.get("directions") or recipe.get("method") or recipe.get("steps")
        lines = _recipe_lines_from_text(directions)
        if lines:
            recipe["instructions"] = lines
    _normalize_recipe_tags(recipe)
    _normalize_recipe_ingredients_from_external_shape(recipe)
    if "image_url" not in recipe and recipe.get("imageUrl"):
        recipe["image_url"] = recipe.get("imageUrl")
    if "source_url" not in recipe and recipe.get("sourceUrl"):
        recipe["source_url"] = recipe.get("sourceUrl")
    _normalize_recipe_extended_nutrition(recipe)
    return recipe


def _normalize_recipe_extended_nutrition(recipe: dict) -> dict:
    """Flatten MyFitnessPal-style nutritional_contents into our recipe keys."""
    if not isinstance(recipe, dict):
        return {}
    nested = recipe.get("nutritional_contents") if isinstance(recipe.get("nutritional_contents"), dict) else {}
    for target, aliases in RECIPE_NUTRITION_ALIASES.items():
        if recipe.get(target) not in (None, ""):
            recipe[target] = _recipe_numeric_value(recipe.get(target))
            continue
        for alias in aliases:
            if alias in recipe and recipe.get(alias) not in (None, ""):
                recipe[target] = _recipe_numeric_value(recipe.get(alias))
                break
            if alias in nested and nested.get(alias) not in (None, ""):
                recipe[target] = _recipe_numeric_value(nested.get(alias))
                break
    details = {}
    for key in RECIPE_NUTRITION_ALIASES:
        if recipe.get(key) not in (None, ""):
            details[key] = _recipe_numeric_value(recipe.get(key))
    if details:
        recipe["nutrition_details"] = details
    return recipe


def _merge_recipe_source_metadata(existing_recipe: dict | None, next_recipe: dict) -> dict:
    """Keep saved recipe source metadata when an update payload omits it."""
    if not existing_recipe:
        _normalize_recipe_external_shape(next_recipe)
        _normalize_recipe_extended_nutrition(next_recipe)
        _normalize_recipe_serving_sizes(next_recipe)
        return next_recipe
    merged = dict(next_recipe or {})
    _normalize_recipe_external_shape(existing_recipe)
    _normalize_recipe_external_shape(merged)
    _normalize_recipe_extended_nutrition(existing_recipe)
    _normalize_recipe_extended_nutrition(merged)
    _normalize_recipe_serving_sizes(existing_recipe)
    _normalize_recipe_serving_sizes(merged)
    for key in (
        "source_url", "image_url", "cooking_time", "active_time_minutes", "inactive_time_minutes",
        "serving_size_label", "serving_sizes", "nutrition_details", "added_sugar", "sat_fat", "trans_fat",
        "monounsaturated_fat", "polyunsaturated_fat", "cholesterol", "vitamin_a", "vitamin_c",
        "calcium", "iron", "potassium",
    ):
        existing_value = (existing_recipe or {}).get(key)
        if key not in merged and existing_value not in (None, ""):
            merged[key] = existing_value
    existing_tags = (existing_recipe or {}).get("tags")
    if "tags" not in merged and isinstance(existing_tags, list) and existing_tags:
        merged["tags"] = existing_tags
    existing_meal_types = (existing_recipe or {}).get("meal_types")
    if "meal_types" not in merged and isinstance(existing_meal_types, list) and existing_meal_types:
        merged["meal_types"] = existing_meal_types
    if "favorite" not in merged and isinstance(existing_recipe, dict) and "favorite" in existing_recipe:
        merged["favorite"] = bool(existing_recipe.get("favorite"))
    return merged


def _sanitize_recipe_serving_size_label(recipe: dict) -> str:
    label = str((recipe or {}).get("serving_size_label") or (recipe or {}).get("serving_size") or "").strip()
    label = re.sub(r"\s+", " ", label)[:40]
    if not label:
        label = "1份"
    recipe["serving_size_label"] = label
    _normalize_recipe_serving_sizes(recipe)
    return label


def _recipe_serving_size_label(value: float, unit: str, fallback_label: str) -> str:
    unit = re.sub(r"\s+", " ", str(unit or "").strip())[:16]
    if unit in {"", "份", "serving", "servings", "unit", "units"}:
        if abs(value - 0.5) < 0.01:
            return "半份"
        if abs(value - 1.0) < 0.01:
            return fallback_label
        return f"{value:g}份"
    return f"{value:g}{unit}"


def _normalize_recipe_serving_sizes(recipe: dict) -> list[dict]:
    """Normalize MyFitnessPal-style serving size options and add sane defaults."""
    if not isinstance(recipe, dict):
        return []
    fallback_label = str(recipe.get("serving_size_label") or recipe.get("serving_size") or "1份").strip() or "1份"
    raw_options = recipe.get("serving_sizes") or recipe.get("serving_size_options") or []
    if isinstance(raw_options, dict):
        raw_options = [raw_options]

    options: list[dict] = []
    seen: set[tuple[str, float]] = set()

    def add_option(value=1.0, unit="份", multiplier=None, label=None):
        try:
            clean_value = max(0.01, min(999.0, float(value or 1)))
        except Exception:
            clean_value = 1.0
        try:
            clean_multiplier = max(0.05, min(20.0, float(clean_value if multiplier is None else multiplier)))
        except Exception:
            clean_multiplier = clean_value
        clean_unit = re.sub(r"\s+", " ", str(unit or "份").strip())[:16] or "份"
        clean_label = re.sub(r"\s+", " ", str(label or "").strip())[:40]
        if not clean_label:
            clean_label = _recipe_serving_size_label(clean_value, clean_unit, fallback_label)
        key = (clean_label, round(clean_multiplier, 4))
        if key in seen:
            return
        seen.add(key)
        options.append({
            "value": round(clean_value, 3),
            "unit": clean_unit,
            "nutrition_multiplier": round(clean_multiplier, 4),
            "label": clean_label,
        })

    if isinstance(raw_options, list):
        for option in raw_options:
            if not isinstance(option, dict):
                continue
            add_option(
                value=option.get("value") or option.get("amount") or option.get("servings") or option.get("quantity") or 1,
                unit=option.get("unit") or option.get("label_unit") or option.get("name") or "份",
                multiplier=option.get("nutrition_multiplier") or option.get("multiplier") or option.get("portion_multiplier"),
                label=option.get("label") or option.get("description") or option.get("display_name"),
            )

    for value in (0.5, 1.0, 1.5, 2.0):
        add_option(value=value, unit="份", multiplier=value)

    recipe["serving_sizes"] = options[:8]
    recipe.pop("serving_size_options", None)
    return recipe["serving_sizes"]


def _sanitize_recipe_image_url(recipe: dict) -> str:
    raw = (recipe or {}).get("image_url") or (recipe or {}).get("imageUrl") or (recipe or {}).get("image") or ""
    if isinstance(raw, list):
        raw = next((item for item in raw if item), "")
    if isinstance(raw, dict):
        raw = raw.get("url") or raw.get("contentUrl") or raw.get("@id") or ""
    image_url = str(raw or "").strip()[:600]
    if image_url and not image_url.lower().startswith(("http://", "https://", "/static/")):
        image_url = ""
    if image_url:
        recipe["image_url"] = image_url
    else:
        recipe.pop("image_url", None)
    recipe.pop("imageUrl", None)
    return image_url


def _scaled_saved_meal_food(food: Food, multiplier: float) -> Food:
    multiplier = max(0.05, min(20.0, float(multiplier or 1)))
    serving_size = food.serving_size or "1份"
    if abs(multiplier - 1.0) >= 0.01:
        serving_size = f"{multiplier:g}份 · {serving_size}"
    return Food(
        id=food.id or uuid4().hex[:12],
        name=food.name,
        calories=round(float(food.calories or 0) * multiplier, 1),
        protein=round(float(food.protein or 0) * multiplier, 1),
        carbs=round(float(food.carbs or 0) * multiplier, 1),
        fat=round(float(food.fat or 0) * multiplier, 1),
        fiber=round(float(food.fiber or 0) * multiplier, 1),
        sugar=round(float(food.sugar or 0) * multiplier, 1),
        sodium=round(float(food.sodium or 0) * multiplier, 1),
        serving_size=serving_size,
        processing_level=food.processing_level,
        added_sugar=round(float(food.added_sugar or 0) * multiplier, 1),
        sat_fat=round(float(food.sat_fat or 0) * multiplier, 1),
        trans_fat=round(float(food.trans_fat or 0) * multiplier, 1),
        cholesterol=round(float(food.cholesterol or 0) * multiplier, 1),
        vitamin_a=round(float(food.vitamin_a or 0) * multiplier, 1),
        vitamin_c=round(float(food.vitamin_c or 0) * multiplier, 1),
        calcium=round(float(food.calcium or 0) * multiplier, 1),
        iron=round(float(food.iron or 0) * multiplier, 1),
        potassium=round(float(food.potassium or 0) * multiplier, 1),
    )


def _upsert_recipe_suggestion_by_title(recipe: dict, day: str, source: str) -> dict:
    _normalize_recipe_external_shape(recipe)
    title = str((recipe or {}).get("title") or "").strip()
    if not title:
        return recipe
    recipe["title"] = title
    recipe["source"] = source
    _sanitize_recipe_meal_types(recipe)
    _sanitize_recipe_serving_size_label(recipe)
    _sanitize_recipe_image_url(recipe)
    recipe.setdefault("prep_time_minutes", 0)
    recipe.setdefault("active_time_minutes", int(recipe.get("prep_time_minutes") or 0))
    recipe.setdefault("inactive_time_minutes", 0)
    existing = tracking.find_recipe_suggestion_event_by_title(title, exclude_id=str(recipe.get("id") or ""))
    if existing:
        existing_id = existing["id"]
        recipe = _merge_recipe_source_metadata(existing.get("recipe"), recipe)
        recipe["id"] = existing_id
        updated = tracking.update_recipe_suggestion_event(existing_id, recipe, day=day, source=source)
        if updated:
            return updated["recipe"]
    recipe_id = str(recipe.get("id") or f"recipe_{uuid4().hex[:16]}")
    recipe["id"] = recipe_id
    tracking.save_recipe_suggestion_event(recipe_id, day, source, recipe)
    return recipe


@app.post("/v6/recipes/from-ingredients")
async def recipes_from_ingredients_endpoint(request: IngredientRecipeRequest):
    """Build recordable recipe suggestions from text or photographed ingredients."""
    day = request.date or __import__("datetime").date.today().isoformat()
    preferences = tracking.get_user_preferences()
    summary = _daily_summary_for_day(day)
    ingredients, recognition_source, message, amount_hints = await _recognize_ingredients(request)
    matched_foods, missing = await _match_recipe_foods(ingredients, preferences)
    recipes = _build_rule_recipes(
        matched_foods,
        ingredients,
        preferences,
        summary,
        request.limit,
        request.servings,
        missing,
        amount_hints,
    )
    source = "rules"
    if request.use_ai:
        enhanced = await _enhance_recipes_with_ai(recipes, ingredients, preferences)
        if enhanced != recipes:
            source = "ai_enhanced"
            recipes = enhanced
    recipes = [
        _upsert_recipe_suggestion_by_title(recipe, day, source)
        for recipe in recipes
    ]
    return {
        "date": day,
        "summary": summary.model_dump(),
        "identified_ingredients": ingredients,
        "recognition_source": recognition_source,
        "message": message,
        "source": source,
        "recipes": recipes,
    }


@app.get("/v6/recipes/suggestions")
async def recipe_suggestions_endpoint(limit: int = 10, query: str = "", sort: str = "created", offset: int = 0, favorite: bool = False, imported: bool = False, meal_type: str = "", tag: str = ""):
    """List previously generated recordable recipes."""
    items = tracking.list_recipe_suggestion_events(limit, query=query, sort=sort, offset=offset, favorite=favorite, imported=imported, meal_type=meal_type, tag=tag)
    return {"recipes": items}


@app.post("/v6/recipes/suggestions")
async def create_recipe_suggestion_endpoint(request: IngredientRecipeCreateRequest):
    """Create a manually edited recordable recipe suggestion."""
    recipe = dict(request.recipe or {})
    _normalize_recipe_external_shape(recipe)
    title = str(recipe.get("title") or "").strip()
    if not title:
        raise HTTPException(status_code=400, detail="食谱名称不能为空。")
    recipe_id = str(recipe.get("id") or f"recipe_{uuid4().hex[:16]}")
    recipe["id"] = recipe_id
    recipe["title"] = title
    recipe["source"] = recipe.get("source") or request.source or "manual"
    _normalize_recipe_extended_nutrition(recipe)
    recipe.setdefault("servings", 1)
    recipe.setdefault("calories", 0)
    recipe.setdefault("protein", 0)
    recipe.setdefault("carbs", 0)
    recipe.setdefault("fat", 0)
    recipe.setdefault("fiber", 0)
    recipe.setdefault("sodium", 0)
    recipe.setdefault("sugar", 0)
    recipe.setdefault("prep_time_minutes", 0)
    recipe.setdefault("active_time_minutes", int(recipe.get("prep_time_minutes") or 0))
    recipe.setdefault("inactive_time_minutes", 0)
    recipe.setdefault("reason", "手动创建")
    recipe.setdefault("instructions", [])
    recipe.setdefault("ingredients_breakdown", [])
    recipe.setdefault("missing_ingredients", [])
    recipe.setdefault("tags", [])
    _sanitize_recipe_meal_types(recipe)
    _sanitize_recipe_serving_size_label(recipe)
    _sanitize_recipe_image_url(recipe)
    recipe.setdefault("favorite", False)
    day = request.date or __import__("datetime").date.today().isoformat()
    recipe = _upsert_recipe_suggestion_by_title(recipe, day, recipe["source"])
    recipe_id = recipe["id"]
    item = tracking.get_recipe_suggestion_event(recipe_id)
    return {"status": "ok", "recipe_id": recipe_id, "recipe": recipe, "item": item}


@app.delete("/v6/recipes/suggestions/{recipe_id}")
async def delete_recipe_suggestion_endpoint(recipe_id: str):
    """Remove a saved generated recipe from the user's recipe list."""
    deleted = tracking.delete_recipe_suggestion_event(recipe_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="没有找到这条食谱。")
    return {"status": "ok", "deleted": True, "recipe_id": recipe_id}


@app.post("/v6/recipes/suggestions/{recipe_id}/favorite")
async def toggle_recipe_favorite_endpoint(recipe_id: str):
    """Toggle a saved recipe favorite flag for the recipe library."""
    event = tracking.get_recipe_suggestion_event(recipe_id)
    if not event:
        raise HTTPException(status_code=404, detail="没有找到这条食谱。")
    recipe = dict(event["recipe"] or {})
    recipe["favorite"] = not bool(recipe.get("favorite"))
    updated = tracking.update_recipe_suggestion_event(recipe_id, recipe)
    if not updated:
        raise HTTPException(status_code=404, detail="没有找到这条食谱。")
    return {"status": "ok", "recipe_id": recipe_id, "recipe": updated["recipe"], "item": updated}


@app.put("/v6/recipes/suggestions/{recipe_id}")
async def update_recipe_suggestion_endpoint(recipe_id: str, request: IngredientRecipeUpdateRequest):
    """Update a saved generated recipe before it is logged again."""
    recipe = dict(request.recipe or {})
    _normalize_recipe_external_shape(recipe)
    title = str(recipe.get("title") or "").strip()
    if not title:
        raise HTTPException(status_code=400, detail="食谱名称不能为空。")
    existing_same_title = tracking.find_recipe_suggestion_event_by_title(title, exclude_id=recipe_id)
    target_id = existing_same_title["id"] if existing_same_title else recipe_id
    current_event = existing_same_title or tracking.get_recipe_suggestion_event(recipe_id)
    recipe = _merge_recipe_source_metadata((current_event or {}).get("recipe"), recipe)
    _sanitize_recipe_meal_types(recipe)
    _sanitize_recipe_serving_size_label(recipe)
    _sanitize_recipe_image_url(recipe)
    recipe["id"] = target_id
    if existing_same_title:
        tracking.delete_recipe_suggestion_event(recipe_id)
    updated = tracking.update_recipe_suggestion_event(target_id, recipe)
    if not updated:
        raise HTTPException(status_code=404, detail="没有找到这条食谱。")
    return {"status": "ok", "recipe_id": target_id, "recipe": updated["recipe"], "item": updated}


@app.post("/v6/recipes/{recipe_id}/log")
async def log_ingredient_recipe_endpoint(recipe_id: str, request: IngredientRecipeLogRequest):
    """Persist a generated recipe into the same daily food log used by scans/searches."""
    event = tracking.get_recipe_suggestion_event(recipe_id)
    if not event:
        raise HTTPException(status_code=404, detail="没有找到这条菜谱建议，请先重新生成菜谱。")
    day = request.date or event["date"]
    recipe = event["recipe"]
    food = _recipe_to_food(recipe, request.portion_multiplier, request.serving_size_label)
    saved = _save_foods_to_log([food], day, request.meal_category or "dinner")
    tracking.mark_recipe_suggestion_logged(recipe_id)
    summary = _daily_summary_for_day(day)
    return {
        "status": "ok",
        "date": day,
        "recipe_id": recipe_id,
        "saved": len(saved),
        "foods": saved,
        "summary": summary.model_dump(),
    }


# ── /v6/body-measurements ────────────────────────────────────────

class AddMeasurementRequest(BaseModel):
    date: str | None = None
    weight_kg: float | None = None
    waist_cm: float | None = None
    hips_cm: float | None = None
    chest_cm: float | None = None
    arm_cm: float | None = None
    thigh_cm: float | None = None
    body_fat_pct: float | None = None
    notes: str = ""


@app.post("/v6/body-measurements")
async def add_measurement_endpoint(request: AddMeasurementRequest):
    """Log body measurements."""
    measurements = {
        "weight_kg": (request.weight_kg, 25, 350),
        "waist_cm": (request.waist_cm, 20, 300),
        "hips_cm": (request.hips_cm, 20, 300),
        "chest_cm": (request.chest_cm, 20, 300),
        "arm_cm": (request.arm_cm, 5, 150),
        "thigh_cm": (request.thigh_cm, 10, 200),
        "body_fat_pct": (request.body_fat_pct, 1, 75),
    }
    if all(value is None for value, _, _ in measurements.values()):
        raise HTTPException(status_code=400, detail="请至少填写一项身体数据")
    for field, (value, low, high) in measurements.items():
        if value is not None and (not math.isfinite(value) or not low <= value <= high):
            raise HTTPException(status_code=400, detail=f"{field}超出合理范围")
    day = request.date or __import__("datetime").date.today().isoformat()
    tracking._init_measurements_table()
    with tracking._get_conn() as conn:
        conn.execute("""INSERT INTO body_measurements
            (date, weight_kg, waist_cm, hips_cm, chest_cm, arm_cm, thigh_cm, body_fat_pct, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (day, request.weight_kg, request.waist_cm, request.hips_cm,
             request.chest_cm, request.arm_cm, request.thigh_cm,
             request.body_fat_pct, request.notes))
        conn.commit()
    return {"status": "ok", "date": day}


@app.get("/v6/body-measurements")
async def get_measurements_endpoint(days: int = 90):
    """Get body measurement history."""
    tracking._init_measurements_table()
    since = (__import__("datetime").date.today() - __import__("datetime").timedelta(days=days)).isoformat()
    with tracking._get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM body_measurements WHERE date >= ? ORDER BY date", (since,)
        ).fetchall()
    return {"measurements": [dict(r) for r in rows]}


# ── /v6/frequent-foods ───────────────────────────────────────────

@app.get("/v6/frequent-foods")
async def frequent_foods_endpoint(limit: int = 12, meal_category: str = ""):
    """Get recently logged foods for quick-add."""
    clean_limit = max(1, min(50, int(limit or 12)))
    clean_meal_category = str(meal_category or "").strip()[:40]
    where_sql = "WHERE meal_category = ?" if clean_meal_category else ""
    params = [clean_meal_category] if clean_meal_category else []
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        try:
            rows = conn.execute(
                f"""SELECT
                       LOWER(TRIM(food_name)) as id,
                       food_name,
                       calories, protein, carbs, fat, fiber, sugar, sodium,
                       sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
                       calcium, iron, potassium, serving_size, processing_level,
                       meal_category,
                       COUNT(*) as log_count,
                       MAX(logged_at) as last_logged
                    FROM food_log_history
                    {where_sql}
                    GROUP BY LOWER(TRIM(food_name))
                    ORDER BY log_count DESC, last_logged DESC
                    LIMIT ?""",
                (*params, clean_limit),
            ).fetchall()
        except Exception:
            rows = conn.execute(
                f"""SELECT
                       LOWER(TRIM(food_name)) as id,
                       food_name,
                       calories, protein, carbs, fat, fiber, sugar, sodium,
                       serving_size, processing_level,
                       meal_category,
                       COUNT(*) as log_count,
                       MAX(logged_at) as last_logged
                    FROM food_log_history
                    {where_sql}
                    GROUP BY LOWER(TRIM(food_name))
                    ORDER BY log_count DESC, last_logged DESC
                    LIMIT ?""",
                (*params, clean_limit),
            ).fetchall()
    return {"foods": [dict(r) for r in rows]}


# ── /v6/exercise ─────────────────────────────────────────────────

class AddExerciseRequest(BaseModel):
    name: str
    duration_minutes: int
    intensity: str = "moderate"
    calories_burned: float = 0
    date: str | None = None
    notes: str = ""
    exercise_id: str | None = None
    body_weight_kg: float | None = None
    request_id: str | None = None


class EstimateExerciseRequest(BaseModel):
    exercise_id: str | None = None
    name: str = ""
    duration_minutes: int = 30
    intensity: str = "moderate"
    body_weight_kg: float | None = None


def _reserve_tracking_mutation(
    operation: str,
    request_id: str | None,
    payload: dict,
) -> tuple[str | None, bool]:
    clean_request_id = str(request_id or "").strip()
    if not clean_request_id:
        return None, False
    if len(clean_request_id) > 128:
        raise HTTPException(status_code=400, detail="记录请求编号过长")
    fingerprint = hashlib.sha256(
        json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    try:
        return tracking.reserve_mutation(operation, clean_request_id, fingerprint)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.get("/v6/exercise/catalog")
async def get_exercise_catalog_endpoint():
    """Get the exercise catalog used by the workout logger."""
    return {
        "exercises": get_exercise_catalog(),
        "intensities": INTENSITY_LABELS,
        "default_body_weight_kg": DEFAULT_BODY_WEIGHT_KG,
    }


@app.post("/v6/exercise/estimate")
async def estimate_exercise_endpoint(request: EstimateExerciseRequest):
    """Estimate exercise calories with MET values."""
    if request.duration_minutes <= 0 or request.duration_minutes > 1440:
        raise HTTPException(status_code=400, detail="运动时长必须在 1–1440 分钟之间")
    return estimate_exercise_calories(
        exercise_id=request.exercise_id,
        name=request.name,
        duration_minutes=request.duration_minutes,
        intensity=request.intensity,
        body_weight_kg=request.body_weight_kg,
    )


@app.post("/v6/exercise")
async def add_exercise_endpoint(request: AddExerciseRequest):
    """Log an exercise."""
    from models.tracking import Exercise
    if not str(request.name or "").strip():
        raise HTTPException(status_code=400, detail="请填写运动名称")
    if request.duration_minutes <= 0 or request.duration_minutes > 1440:
        raise HTTPException(status_code=400, detail="运动时长必须在 1–1440 分钟之间")
    if not math.isfinite(request.calories_burned) or request.calories_burned < 0:
        raise HTTPException(status_code=400, detail="手动消耗不能小于 0")
    estimate = estimate_exercise_calories(
        exercise_id=request.exercise_id,
        name=request.name,
        duration_minutes=request.duration_minutes,
        intensity=request.intensity,
        body_weight_kg=request.body_weight_kg,
    )
    day = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "exercise",
        request.request_id,
        {
            **request.model_dump(mode="json", exclude={"request_id", "date"}),
            "date": day,
        },
    )
    ex = Exercise(
        id=record_id or uuid4().hex[:12],
        name=request.name,
        duration_minutes=estimate["duration_minutes"],
        intensity=normalize_intensity(request.intensity),
        calories_burned=request.calories_burned if request.calories_burned > 0 else estimate["calories_burned"],
        date=day,
        notes=request.notes,
    )
    saved = tracking.add_exercise(ex)
    return {**saved.model_dump(), "already_logged": already_logged}


@app.get("/v6/exercise")
async def get_exercises_endpoint(date: str | None = None):
    """Get exercises for a day."""
    return {"exercises": tracking.get_exercises(date)}


# ── /v6/weight ───────────────────────────────────────────────────

class AddWeightRequest(BaseModel):
    weight_kg: float
    date: str | None = None
    notes: str = ""
    request_id: str | None = None


@app.post("/v6/weight")
async def add_weight_endpoint(request: AddWeightRequest):
    """Log weight."""
    from models.tracking import WeightLog
    if not math.isfinite(request.weight_kg) or not 25 <= request.weight_kg <= 350:
        raise HTTPException(status_code=400, detail="体重必须在 25–350 公斤之间")
    day = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "weight",
        request.request_id,
        {
            **request.model_dump(mode="json", exclude={"request_id", "date"}),
            "date": day,
        },
    )
    w = WeightLog(
        id=record_id or uuid4().hex[:12],
        weight_kg=request.weight_kg,
        date=day,
        notes=request.notes,
    )
    saved = tracking.add_weight(w)
    return {**saved.model_dump(), "already_logged": already_logged}


@app.get("/v6/weight")
async def get_weights_endpoint(days: int = 30):
    """Get weight history."""
    return {"weights": tracking.get_weights(days)}


# ── /v6/water ────────────────────────────────────────────────────

class AddWaterRequest(BaseModel):
    amount_ml: float
    date: str | None = None
    request_id: str | None = None


class HydrationLogRequest(BaseModel):
    drink_type: str = "water"
    amount_ml: float
    hydration_factor: float | None = None
    effective_ml: float | None = None
    caffeine_mg: float | None = None
    alcohol_g: float | None = None
    sugar_g: float | None = None
    calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    source: str = "manual"
    note: str = ""
    external_id: str = ""
    date: str | None = None
    logged_at: str | None = None
    request_id: str | None = None


class HydrationDeleteRequest(BaseModel):
    ids: list[str] = []
    date: str | None = None


class HydrationSettingsRequest(BaseModel):
    hydration_goal_ml: float


class SleepLogRequest(BaseModel):
    duration_hours: float
    quality: int = 3
    date: str | None = None
    start_at: str | None = None
    end_at: str | None = None
    note: str = ""
    source: str = "manual"
    request_id: str | None = None


class DrinkPresetRequest(BaseModel):
    id: str | None = None
    drink_type: str
    name: str
    default_amount_ml: float = 250
    hydration_factor: float = 1
    caffeine_mg: float = 0
    alcohol_g: float = 0
    sugar_g: float = 0
    calories: float = 0
    protein_g: float = 0
    carbs_g: float = 0
    fat_g: float = 0
    color: str = "#2f80ed"
    icon: str = "drop"
    custom: bool = True


class ChallengeRequest(BaseModel):
    id: str | None = None
    template_id: str | None = None
    title: str
    description: str = ""
    challenge_type: str = "hydration_goal"
    duration_days: int = 7
    target_value: float = 0
    reward_points: int | None = None


class VoiceLogParseRequest(BaseModel):
    text: str
    date: str | None = None


class VoiceLogApplyRequest(BaseModel):
    text: str = ""
    date: str | None = None
    meal_category: str = ""
    hydration: list[dict] = []
    foods: list[dict] = []
    request_id: str | None = None


class HealthImportRecord(BaseModel):
    external_id: str | None = None
    record_type: str
    value: float = 0
    unit: str = ""
    date: str | None = None
    source: str | None = None
    drink_type: str | None = None
    start_at: str | None = None
    logged_at: str | None = None
    metadata: dict | None = None


class HealthImportRequest(BaseModel):
    source: str = "healthkit"
    records: list[HealthImportRecord]


@app.post("/v6/water")
async def add_water_endpoint(request: AddWaterRequest):
    """Log water intake."""
    from models.tracking import WaterLog
    if not math.isfinite(request.amount_ml) or not 0 < request.amount_ml <= 10000:
        raise HTTPException(status_code=400, detail="饮水量必须在 1–10000 毫升之间")
    day = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "water",
        request.request_id,
        {"amount_ml": request.amount_ml, "date": day},
    )
    w = WaterLog(
        id=record_id or uuid4().hex[:12],
        amount_ml=request.amount_ml,
        date=day,
    )
    saved = tracking.add_water(w)
    return {**saved.model_dump(), "already_logged": already_logged}


@app.get("/v6/water")
async def get_water_endpoint(date: str | None = None):
    """Get water intake for a day."""
    return {"amount_ml": tracking.get_water(date)}


# ── /v6/hydration / drink presets / challenges ───────────────────

@app.get("/v6/hydration")
async def get_hydration_endpoint(date: str | None = None, days: int = 1):
    """Get drink logs for a day or date range."""
    return {"logs": tracking.get_hydration_logs(date, days=max(1, min(90, days)))}


@app.post("/v6/hydration")
async def add_hydration_endpoint(request: HydrationLogRequest):
    """Log any drink with effective hydration and nutrition metadata."""
    if not math.isfinite(request.amount_ml) or not 0 < request.amount_ml <= 10000:
        raise HTTPException(status_code=400, detail="饮品毫升数必须在 1–10000 之间")
    optional_nonnegative = {
        "effective_ml": request.effective_ml, "caffeine_mg": request.caffeine_mg,
        "alcohol_g": request.alcohol_g, "sugar_g": request.sugar_g,
        "calories": request.calories, "protein_g": request.protein_g,
        "carbs_g": request.carbs_g, "fat_g": request.fat_g,
    }
    for field, value in optional_nonnegative.items():
        if value is not None and (not math.isfinite(value) or value < 0):
            raise HTTPException(status_code=400, detail=f"{field}不能小于 0")
    if request.hydration_factor is not None and (
        not math.isfinite(request.hydration_factor) or not 0 <= request.hydration_factor <= 2
    ):
        raise HTTPException(status_code=400, detail="hydration_factor超出合理范围")
    payload = request.model_dump(exclude_none=True, exclude={"request_id"})
    payload["date"] = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "hydration", request.request_id, payload,
    )
    if record_id:
        payload["id"] = record_id
    saved = tracking.add_hydration(payload)
    return {**saved, "already_logged": already_logged}


@app.delete("/v6/hydration")
async def delete_hydration_endpoint(request: HydrationDeleteRequest):
    """Delete drink logs by id or date."""
    deleted = tracking.delete_hydration_logs(ids=request.ids, day=request.date)
    day = request.date or date.today().isoformat()
    return {"status": "ok", "deleted": deleted, "summary": tracking.get_hydration_summary(day)}


@app.get("/v6/hydration/summary")
async def hydration_summary_endpoint(date: str | None = None):
    """Get daily drink totals and effective hydration."""
    return tracking.get_hydration_summary(date)


@app.get("/v6/hydration/settings")
async def hydration_settings_endpoint():
    """Get hydration goal settings."""
    return tracking.get_hydration_settings()


@app.put("/v6/hydration/settings")
async def save_hydration_settings_endpoint(request: HydrationSettingsRequest):
    """Save hydration goal settings while preserving macro goals."""
    if not math.isfinite(request.hydration_goal_ml) or not 250 <= request.hydration_goal_ml <= 10000:
        raise HTTPException(status_code=400, detail="每日饮水目标必须在 250–10000 毫升之间")
    return tracking.save_hydration_settings(request.hydration_goal_ml)


@app.get("/v6/sleep")
async def get_sleep_endpoint(date: str | None = None):
    """Get sleep logs for a day."""
    return {"logs": tracking.get_sleep_logs(date)}


@app.post("/v6/sleep")
async def add_sleep_endpoint(request: SleepLogRequest):
    """Log sleep duration and subjective quality."""
    if not math.isfinite(request.duration_hours) or not 0 < request.duration_hours <= 24:
        raise HTTPException(status_code=400, detail="睡眠时长必须在 0–24 小时之间")
    if not 1 <= request.quality <= 5:
        raise HTTPException(status_code=400, detail="睡眠质量必须在 1–5 之间")
    payload = request.model_dump(exclude_none=True, exclude={"request_id"})
    payload["date"] = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "sleep", request.request_id, payload,
    )
    if record_id:
        payload["id"] = record_id
    return {
        "status": "ok",
        "already_logged": already_logged,
        "sleep": tracking.add_sleep(payload),
        "summary": tracking.get_sleep_summary(payload["date"]),
    }


@app.get("/v6/sleep/summary")
async def sleep_summary_endpoint(date: str | None = None):
    """Get daily sleep totals and score inputs."""
    return tracking.get_sleep_summary(date)


@app.get("/v6/drink-presets")
async def get_drink_presets_endpoint():
    """Get built-in and custom drink presets."""
    return {"presets": tracking.get_drink_presets()}


@app.post("/v6/drink-presets")
async def add_drink_preset_endpoint(request: DrinkPresetRequest):
    """Create or update a custom drink preset."""
    return tracking.add_drink_preset(request.model_dump())


@app.get("/v6/challenges")
async def get_challenges_endpoint():
    """List challenge templates and joined challenge progress."""
    return {"challenges": tracking.get_challenges()}


@app.post("/v6/challenges")
async def create_challenge_endpoint(request: ChallengeRequest):
    """Create a custom habit challenge."""
    return tracking.create_challenge(request.model_dump(exclude_none=True))


@app.post("/v6/challenges/{challenge_id}/join")
async def join_challenge_endpoint(challenge_id: str):
    """Join a challenge and start its date window today."""
    challenge = tracking.join_challenge(challenge_id)
    if not challenge:
        raise HTTPException(status_code=404, detail="没有找到这个挑战。")
    return challenge


@app.post("/v6/challenges/{challenge_id}/refresh")
async def refresh_challenge_endpoint(challenge_id: str):
    """Recalculate a challenge from logged habits and drinks."""
    challenge = tracking.refresh_challenge(challenge_id)
    if not challenge:
        raise HTTPException(status_code=404, detail="没有找到这个挑战。")
    return challenge


VOICE_DRINK_KEYWORDS = [
    ("energy_drink", ["能量饮料", "energy drink", "red bull", "红牛"]),
    ("latte", ["拿铁", "latte"]),
    ("milk_tea", ["奶茶", "milk tea"]),
    ("coffee", ["咖啡", "coffee", "美式"]),
    ("tea", ["茶", "tea"]),
    ("milk", ["牛奶", "milk"]),
    ("juice", ["果汁", "juice"]),
    ("alcohol", ["啤酒", "红酒", "白酒", "酒", "wine", "beer"]),
    ("water", ["喝水", "水", "白水", "water"]),
]

VOICE_DEFAULT_AMOUNTS = {
    "water": 250,
    "coffee": 240,
    "latte": 350,
    "milk_tea": 350,
    "tea": 240,
    "milk": 240,
    "juice": 240,
    "energy_drink": 250,
    "alcohol": 150,
}

VOICE_FOOD_ESTIMATES = {
    "米饭": {"name": "米饭", "calories": 210, "protein": 4, "carbs": 46, "fat": 1, "fiber": 1, "sugar": 0, "sodium": 5, "serving_size": "1 bowl"},
    "鸡胸肉": {"name": "鸡胸肉", "calories": 240, "protein": 42, "carbs": 0, "fat": 6, "fiber": 0, "sugar": 0, "sodium": 180, "serving_size": "150g"},
    "鸡蛋": {"name": "鸡蛋", "calories": 78, "protein": 6, "carbs": 0.6, "fat": 5, "fiber": 0, "sugar": 0.4, "sodium": 62, "serving_size": "1 egg"},
    "燕麦": {"name": "燕麦", "calories": 150, "protein": 5, "carbs": 27, "fat": 3, "fiber": 4, "sugar": 1, "sodium": 2, "serving_size": "40g"},
    "香蕉": {"name": "香蕉", "calories": 105, "protein": 1.3, "carbs": 27, "fat": 0.4, "fiber": 3, "sugar": 14, "sodium": 1, "serving_size": "1 medium"},
}


def _strip_json_response(text: str) -> dict | None:
    try:
        cleaned = re.sub(r"```(?:json)?\s*", "", text.strip()).replace("```", "").strip()
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start >= 0 and end > start:
            cleaned = cleaned[start:end + 1]
        return json.loads(cleaned)
    except Exception:
        return None


def _voice_amount_ml(segment: str, drink_type: str) -> float:
    match = re.search(r"(\d+(?:\.\d+)?)\s*(ml|毫升|mL|ML|l|L|升)?", segment)
    if match:
        value = float(match.group(1))
        unit = (match.group(2) or "ml").lower()
        return value * 1000 if unit in {"l", "升"} else value
    if "半杯" in segment:
        return 125
    if "一瓶" in segment or "1瓶" in segment:
        return 500
    if "一罐" in segment or "1罐" in segment:
        return 330
    if "一杯" in segment or "1杯" in segment:
        return VOICE_DEFAULT_AMOUNTS.get(drink_type, 250)
    return VOICE_DEFAULT_AMOUNTS.get(drink_type, 250)


def _voice_drink_segment(text: str, drink_type: str) -> str:
    keywords = next((values for kind, values in VOICE_DRINK_KEYWORDS if kind == drink_type), [])
    segments = [value.strip() for value in re.split(r"[，,。.;；、\n]", text) if value.strip()]
    return next(
        (segment for segment in segments if any(keyword.lower() in segment.lower() for keyword in keywords)),
        "",
    )


def _rules_voice_parse(text: str, day: str) -> dict:
    normalized = text.strip()
    hydration_candidates = []
    seen_drinks = set()
    segments = [s for s in re.split(r"[，,。.;；、\n]", normalized) if s.strip()] or [normalized]
    for segment in segments:
        lowered = segment.lower()
        for drink_type, keywords in VOICE_DRINK_KEYWORDS:
            if any(keyword.lower() in lowered for keyword in keywords):
                key = f"{drink_type}:{segment}"
                if key in seen_drinks:
                    continue
                seen_drinks.add(key)
                hydration_candidates.append({
                    "drink_type": drink_type,
                    "amount_ml": _voice_amount_ml(segment, drink_type),
                    "source": "voice",
                    "date": day,
                    "note": segment.strip(),
                })
                break

    food_candidates = []
    for keyword, estimate in VOICE_FOOD_ESTIMATES.items():
        if keyword in normalized:
            item = dict(estimate)
            if keyword == "米饭" and ("半碗" in normalized or "半份" in normalized):
                for field in ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"]:
                    item[field] = round(float(item[field]) * 0.5, 2)
                item["serving_size"] = "1/2 bowl"
            item["date"] = day
            food_candidates.append(item)

    if not food_candidates:
        match = re.search(r"(?:吃了|吃|早餐|午餐|晚餐)(.+)", normalized)
        if match:
            name = re.split(r"[，,。.;；、]", match.group(1).strip())[0].strip()
            for _, keywords in VOICE_DRINK_KEYWORDS:
                for keyword in keywords:
                    name = name.replace(keyword, "")
            name = name.strip()
            if name:
                food_candidates.append({
                    "name": name,
                    "date": day,
                    "calories": 0,
                    "protein": 0,
                    "carbs": 0,
                    "fat": 0,
                    "fiber": 0,
                    "sugar": 0,
                    "sodium": 0,
                    "serving_size": "voice estimate",
                    "processing_level": "whole",
                })

    meal_category = ""
    if "早餐" in normalized:
        meal_category = "breakfast"
    elif "午餐" in normalized:
        meal_category = "lunch"
    elif "晚餐" in normalized:
        meal_category = "dinner"
    elif "加餐" in normalized or "零食" in normalized:
        meal_category = "snack"

    confidence = 0.78 if hydration_candidates or food_candidates else 0.35
    return {
        "raw_text": text,
        "date": day,
        "source": "rules",
        "confidence": confidence,
        "meal_category": meal_category,
        "hydration": hydration_candidates,
        "foods": food_candidates,
    }


def _voice_chinese_count(value: str) -> int | None:
    value = value.strip()
    if value.isdigit():
        return max(1, min(20, int(value)))
    numbers = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
               "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}
    return numbers.get(value)


def _normalize_voice_parse(parsed: dict, text: str, day: str) -> dict:
    parsed.setdefault("raw_text", text)
    parsed.setdefault("date", day)
    parsed.setdefault("hydration", [])
    parsed.setdefault("foods", [])
    parsed.setdefault("meal_category", "")
    parsed.setdefault("confidence", 0.7)

    for item in parsed["hydration"]:
        drink_type = str(item.get("drink_type") or "water").strip().lower().replace(" ", "_")
        if drink_type == "milktea":
            drink_type = "milk_tea"
        source_segment = str(item.get("note") or "").strip() or _voice_drink_segment(text, drink_type)
        amount_ml = _voice_amount_ml(source_segment, drink_type) if source_segment else float(
            item.get("amount_ml") or VOICE_DEFAULT_AMOUNTS.get(drink_type, 250)
        )
        amount_ml = max(0, amount_ml)
        item["drink_type"] = drink_type
        item["amount_ml"] = amount_ml
        item.setdefault("date", day)
        item.setdefault("source", "voice")
        preset = tracking._preset_for_type(drink_type) or {}
        scale = amount_ml / max(float(preset.get("default_amount_ml") or amount_ml or 1), 1)
        for field in ("calories", "protein_g", "carbs_g", "fat_g", "sugar_g"):
            item[field] = round(float(preset.get(field) or 0) * scale, 2)

    egg_match = re.search(r"([一二两三四五六七八九十\d]+)\s*(?:个|只|枚)?\s*鸡蛋", text)
    egg_count = _voice_chinese_count(egg_match.group(1)) if egg_match else None
    for item in parsed["foods"]:
        item.setdefault("date", day)
        if egg_count and "鸡蛋" in str(item.get("name") or ""):
            estimate = VOICE_FOOD_ESTIMATES["鸡蛋"]
            for field in ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"):
                item[field] = round(float(estimate[field]) * egg_count, 2)
            item["serving_size"] = f"{egg_count}个"
    return parsed


async def _parse_voice_log(text: str, day: str) -> dict:
    if llm_provider:
        prompt = f"""
Parse this food/drink voice note into JSON only.
Schema:
{{
  "confidence": 0.0,
  "meal_category": "breakfast|lunch|dinner|snack|",
  "hydration": [{{"drink_type":"water|coffee|latte|tea|milk|milk_tea|juice|energy_drink|alcohol","amount_ml":250,"note":""}}],
  "foods": [{{"name":"","calories":0,"protein":0,"carbs":0,"fat":0,"fiber":0,"sugar":0,"sodium":0,"serving_size":""}}]
}}
Date: {day}
Voice note: {text}
"""
        try:
            raw = await llm_provider.raw_completion("You parse nutrition voice logs into strict JSON.", prompt, max_tokens=900)
            parsed = _strip_json_response(raw)
            if parsed:
                parsed.setdefault("source", "llm")
                return _normalize_voice_parse(parsed, text, day)
        except Exception:
            pass
    return _normalize_voice_parse(_rules_voice_parse(text, day), text, day)


def _food_from_candidate(candidate: dict, day: str) -> Food:
    return Food(
        name=candidate.get("name") or "Voice food",
        date=candidate.get("date") or day,
        calories=float(candidate.get("calories") or 0),
        protein=float(candidate.get("protein") or 0),
        carbs=float(candidate.get("carbs") or 0),
        fat=float(candidate.get("fat") or 0),
        fiber=float(candidate.get("fiber") or 0),
        sugar=float(candidate.get("sugar") or 0),
        sodium=float(candidate.get("sodium") or 0),
        serving_size=candidate.get("serving_size") or "voice estimate",
        processing_level=candidate.get("processing_level") or "whole",
        added_sugar=float(candidate.get("added_sugar") or 0),
        sat_fat=float(candidate.get("sat_fat") or 0),
        trans_fat=float(candidate.get("trans_fat") or 0),
        cholesterol=float(candidate.get("cholesterol") or 0),
        vitamin_a=float(candidate.get("vitamin_a") or 0),
        vitamin_c=float(candidate.get("vitamin_c") or 0),
        calcium=float(candidate.get("calcium") or 0),
        iron=float(candidate.get("iron") or 0),
        potassium=float(candidate.get("potassium") or 0),
    )


@app.post("/v6/voice-log/parse")
async def parse_voice_log_endpoint(request: VoiceLogParseRequest):
    """Parse voice transcript into confirmable food and drink candidates."""
    day = request.date or date.today().isoformat()
    return await _parse_voice_log(request.text, day)


@app.post("/v6/voice-log/apply")
async def apply_voice_log_endpoint(request: VoiceLogApplyRequest):
    """Apply user-confirmed voice log candidates to food and drink history."""
    day = request.date or date.today().isoformat()
    hydration_items = request.hydration
    food_items = request.foods
    meal_category = request.meal_category
    if request.text and not (hydration_items or food_items):
        parsed = await _parse_voice_log(request.text, day)
        hydration_items = parsed.get("hydration", [])
        food_items = parsed.get("foods", [])
        meal_category = meal_category or parsed.get("meal_category", "")

    # Validate the complete edited batch before writing anything. Otherwise an
    # invalid drink could be silently dropped after valid foods were persisted.
    for index, item in enumerate(hydration_items, start=1):
        try:
            amount_ml = float(item.get("amount_ml"))
        except (TypeError, ValueError):
            amount_ml = float("nan")
        if not math.isfinite(amount_ml) or amount_ml <= 0:
            raise HTTPException(status_code=400, detail=f"第 {index} 项饮品的毫升数必须大于 0")

    for index, item in enumerate(food_items, start=1):
        name = str(item.get("name") or "").strip()
        if not name:
            raise HTTPException(status_code=400, detail=f"第 {index} 项食物缺少名称")
        for field in ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"):
            try:
                value = float(item.get(field) or 0)
            except (TypeError, ValueError):
                value = float("nan")
            if not math.isfinite(value) or value < 0:
                raise HTTPException(status_code=400, detail=f"{name}的{field}不能小于 0")

    mutation_payload = {
        "text": request.text,
        "date": day,
        "meal_category": meal_category or "",
        "hydration": hydration_items,
        "foods": food_items,
    }
    record_id, already_logged = _reserve_tracking_mutation(
        "voice_log", request.request_id, mutation_payload,
    )

    saved_hydration = []
    for index, item in enumerate(hydration_items, start=1):
        payload = dict(item)
        payload.setdefault("date", day)
        payload.setdefault("source", "voice")
        if record_id:
            payload["id"] = hashlib.sha256(f"{record_id}:hydration:{index}".encode("utf-8")).hexdigest()[:24]
        saved_hydration.append(tracking.add_hydration(payload))

    foods = [_food_from_candidate(item, day) for item in food_items]
    if foods:
        saved_foods, food_already_logged = _save_foods_to_log_result(
            foods,
            day,
            meal_category=meal_category or "",
            upload_group_id=f"voice_{record_id}" if record_id else None,
            idempotency_key=f"voice_log:{request.request_id}" if request.request_id else None,
            request_fingerprint=hashlib.sha256(
                json.dumps(mutation_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest(),
        )
        already_logged = already_logged or food_already_logged
    else:
        saved_foods = []
    return {
        "status": "ok",
        "date": day,
        "already_logged": already_logged,
        "hydration": saved_hydration,
        "foods": saved_foods,
        "daily_summary": _daily_summary_for_day(day).model_dump(),
    }


@app.post("/v6/health/import")
async def health_import_endpoint(request: HealthImportRequest):
    """Import HealthKit records with source/external_id de-duplication."""
    records = [r.model_dump(exclude_none=True) for r in request.records]
    return tracking.import_health_records(records, default_source=request.source)


# ── /v6/daily-summary ────────────────────────────────────────────

@app.get("/v6/daily-summary")
async def daily_summary_endpoint(date: str | None = None):
    """Get complete daily nutrition + exercise + weight summary."""
    day = date or __import__("datetime").date.today().isoformat()
    return _daily_summary_for_day(day)


@app.get("/v6/diary-note")
async def diary_note_endpoint(date: str | None = None):
    """Get the user's food diary note for a day."""
    day = date or __import__("datetime").date.today().isoformat()
    return tracking.get_diary_note(day)


@app.post("/v6/diary-note")
async def save_diary_note_endpoint(request: DiaryNoteRequest):
    """Save or clear the user's food diary note for a day."""
    day = request.date or __import__("datetime").date.today().isoformat()
    return tracking.save_diary_note(day, request.note)


@app.post("/v6/diary/complete")
async def complete_diary_endpoint(request: DiaryCompleteRequest):
    """Persist a completed daily food diary checkpoint and return projection copy."""
    day = request.date or __import__("datetime").date.today().isoformat()
    foods = _logged_foods_for_day(day)
    summary = tracking.get_daily_summary(day, foods=foods)
    event = tracking.complete_food_diary(
        day,
        summary,
        logged_meal_categories=_logged_meal_category_count(day),
    )
    projection = summary.weight_projection or "今日日记已完成。继续记录体重后，会显示 5 周趋势预测。"
    return {
        "status": "ok",
        "date": day,
        "message": "今日日记已完成。",
        "projection": projection,
        "summary": summary.model_dump(),
        "event": event,
    }


@app.get("/v6/nutrition-score/daily")
async def daily_nutrition_score_endpoint(date: str | None = None):
    """Score today's nutrition with red/yellow/green nutrient status."""
    day = date or __import__("datetime").date.today().isoformat()
    return _daily_nutrition_score(day)


# ── /v6/user-preferences / recommendations / coach ───────────────

class UserPreferencesRequest(BaseModel):
    diet_type: str | None = None
    allergies: list[str] | None = None
    avoid_ingredients: list[str] | None = None
    favorite_cuisines: list[str] | None = None
    budget_level: str | None = None
    prep_time_minutes: int | None = None
    include_imported_recipes_in_meal_plans: bool | None = None
    taste_tags: list[str] | None = None
    meal_names: dict[str, str] | None = None


class TodayRecommendationsRequest(BaseModel):
    meal_type: str | None = None
    limit: int = 3
    prep_time_minutes: int | None = None
    use_ai: bool = True
    date: str | None = None


class RecommendationLogRequest(BaseModel):
    portion_multiplier: float = 1
    meal_category: str | None = None
    date: str | None = None


class DeliveryDraftRequest(BaseModel):
    portion_multiplier: float = 1
    provider: str = "auto"
    date: str | None = None


class DeliveryRecommendationsRequest(BaseModel):
    tastes: list[str] = []
    meal_types: list[str] = []
    platform: str = "any"
    budget: str = "20-35 元"
    delivery_time: str = "45 分钟内"
    restrictions: list[str] = []
    variant: int = 0
    limit: int = 3
    date: str | None = None


class CoachChatRequest(BaseModel):
    message: str
    date: str | None = None
    meal_type: str | None = None


class CoachActionApplyRequest(BaseModel):
    action: dict
    date: str | None = None


@app.get("/v6/user-preferences")
async def get_user_preferences_endpoint():
    """Get persistent nutrition preference settings."""
    return tracking.get_user_preferences()


@app.put("/v6/user-preferences")
async def save_user_preferences_endpoint(request: UserPreferencesRequest):
    """Save persistent nutrition preference settings."""
    data = {k: v for k, v in request.model_dump().items() if v is not None}
    return tracking.save_user_preferences(data)


@app.get("/v6/fasting/preferences")
async def get_fasting_preferences_endpoint():
    """Get optional intermittent fasting settings."""
    return _get_fasting_preferences()


@app.put("/v6/fasting/preferences")
async def save_fasting_preferences_endpoint(request: FastingPreferencesRequest):
    """Save optional intermittent fasting settings."""
    return _save_fasting_preferences(request)


@app.get("/v6/fasting/status")
async def get_fasting_status_endpoint():
    """Get fasting preferences, active timer state, and recent sessions."""
    return _get_fasting_status()


@app.post("/v6/fasting/start")
async def start_fasting_endpoint(request: FastingStartRequest):
    """Start a fasting timer using the selected or saved method."""
    return _start_fasting_session(request)


@app.post("/v6/fasting/end")
async def end_fasting_endpoint(request: FastingEndRequest):
    """End the active fasting timer."""
    return _end_fasting_session(request)


@app.post("/v6/fasting/cancel")
async def cancel_fasting_endpoint():
    """Cancel the active fasting timer."""
    return _cancel_fasting_session()


@app.post("/v6/fasting/manual")
async def add_manual_fasting_endpoint(request: FastingManualRequest):
    """Add a completed or ended-early fasting session to history."""
    return _add_manual_fasting_session(request)


@app.get("/v6/fasting/history")
async def fasting_history_endpoint(days: int = 30):
    """Get fasting session history and summary."""
    return _get_fasting_history(days)


@app.get("/v6/decision/context")
async def decision_context_endpoint(date: str | None = None):
    """Get the unified eating decision context for today."""
    day = date or __import__("datetime").date.today().isoformat()
    return _decision_context_for_day(day)


@app.get("/v6/decision/events")
async def decision_events_endpoint(date: str | None = None, limit: int = 30):
    """List recent persisted decision scores."""
    day = date or __import__("datetime").date.today().isoformat()
    return {"events": tracking.list_decision_events(day, limit)}


@app.post("/v6/decision/score-meal")
async def decision_score_meal_endpoint(request: DecisionScoreRequest):
    """Score a meal or candidate meal against today's calorie/protein/fasting context."""
    if request.source == "meal":
        request.source = "candidate"
    if request.event_type == "today_fit":
        request.event_type = "today_fit"
    return _score_decision_payload(request)


@app.post("/v6/decision/score-product")
async def decision_score_product_endpoint(request: DecisionScoreRequest):
    """Score a packaged food or nutrition label in a Yuka-style decision format."""
    request.source = request.source or "product"
    if request.source in ("meal", "candidate"):
        request.source = "product"
    request.event_type = request.event_type or "product_score"
    if request.event_type == "today_fit":
        request.event_type = "product_score"
    return _score_decision_payload(request)


@app.post("/v6/decision/after-log")
async def decision_after_log_endpoint(request: DecisionScoreRequest):
    """Score a saved meal and return next-meal adjustment advice."""
    request.source = request.source or "meal"
    request.event_type = "after_log"
    return _score_decision_payload(request)


@app.post("/v6/recommendations/today")
async def today_recommendations_endpoint(request: TodayRecommendationsRequest):
    """Recommend what to eat next using real tracked data and food database nutrients."""
    day = request.date or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(day)
    return await recommendation_service.today(
        summary=summary,
        meal_type=request.meal_type,
        limit=request.limit,
        prep_time_minutes=request.prep_time_minutes,
        use_ai=request.use_ai,
    )


@app.post("/v6/recommendations/{recommendation_id}/log")
async def log_recommendation_endpoint(recommendation_id: str, request: RecommendationLogRequest):
    """Persist a recommendation into the same daily food log used by scans/searches."""
    event = tracking.get_recommendation_event(recommendation_id)
    if not event:
        raise HTTPException(status_code=404, detail="没有找到这条推荐，请先重新生成。")
    day = request.date or event["date"]
    recommendation = event["recommendation"]
    meal_category = request.meal_category or recommendation.get("meal_type", "")
    try:
        requested_multiplier = float(request.portion_multiplier or 1)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="份量倍数无效")
    if not math.isfinite(requested_multiplier):
        raise HTTPException(status_code=400, detail="份量倍数无效")
    portion_multiplier = max(0.5, min(2.0, requested_multiplier))
    identity = json.dumps(
        {
            "recommendation_id": recommendation_id,
            "date": day,
            "meal_category": meal_category,
            "portion_multiplier": round(portion_multiplier, 6),
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    group_id = f"recommendation_{digest[:24]}"
    foods = recommendation_service.scale_recommendation_foods(recommendation, portion_multiplier)
    saved, already_logged = _save_foods_to_log_result(
        foods,
        day,
        meal_category,
        upload_group_id=group_id,
        group_title=str(recommendation.get("title") or "推荐餐"),
        idempotency_key=f"recommendation:{digest}",
        request_fingerprint=digest,
    )
    tracking.mark_recommendation_logged(recommendation_id)
    summary = _daily_summary_for_day(day)
    decision = None
    if not already_logged:
        decision = decision_service.score_foods(
            foods,
            summary=summary,
            fasting_status=_get_fasting_status(),
            preferences=tracking.get_user_preferences(),
            source="recommendation",
            event_type="after_log",
            persist=True,
        )
    return {
        "status": "ok",
        "date": day,
        "recommendation_id": recommendation_id,
        "already_logged": already_logged,
        "saved": len(saved),
        "foods": saved,
        "summary": summary.model_dump(),
        "decision": decision,
    }


@app.post("/v6/recommendations/{recommendation_id}/delivery-draft")
async def create_delivery_draft_endpoint(recommendation_id: str, request: DeliveryDraftRequest):
    """Persist a delivery order draft derived from a nutrition recommendation."""
    event = tracking.get_recommendation_event(recommendation_id)
    if not event:
        raise HTTPException(status_code=404, detail="没有找到这条推荐，请先重新生成。")
    day = request.date or event["date"]
    recommendation = event["recommendation"]
    meal_type = recommendation.get("meal_type", "")
    draft = recommendation_service.build_delivery_draft(
        recommendation,
        portion_multiplier=request.portion_multiplier,
        provider=request.provider,
    )
    saved = tracking.save_delivery_order_draft(
        recommendation_id=recommendation_id,
        day=day,
        meal_type=meal_type,
        provider=request.provider,
        draft=draft,
    )
    return {"status": "ok", "date": day, "draft": saved}


@app.get("/v6/delivery/drafts")
async def delivery_drafts_endpoint(date: str | None = None, limit: int = 20):
    """List recent delivery order drafts."""
    return {"drafts": tracking.list_delivery_order_drafts(date, limit)}


@app.post("/v6/delivery/recommendations")
async def delivery_recommendations_endpoint(request: DeliveryRecommendationsRequest):
    """Recommend delivery meals after explicit taste, platform, budget, and restriction choices."""
    day = request.date or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(day)
    preferences = request.model_dump()
    return recommendation_service.delivery_recommendations(
        summary,
        preferences,
        max(1, min(request.limit, 6)),
        fasting_status=_get_fasting_status(),
    )


def _coach_date_range(message: str, fallback_day: str) -> tuple[date, date]:
    try:
        anchor = date.fromisoformat(fallback_day)
    except ValueError:
        anchor = date.today()
    explicit = [date.fromisoformat(value) for value in re.findall(r"\d{4}-\d{2}-\d{2}", message)]
    if len(explicit) >= 2:
        return min(explicit[0], explicit[1]), max(explicit[0], explicit[1])
    if len(explicit) == 1:
        return explicit[0], explicit[0]
    if "上周" in message:
        end = anchor - timedelta(days=anchor.weekday() + 1)
        return end - timedelta(days=6), end
    if "本周" in message or "这周" in message:
        return anchor - timedelta(days=anchor.weekday()), anchor
    if "前天" in message:
        target = anchor - timedelta(days=2)
        return target, target
    if "昨天" in message:
        target = anchor - timedelta(days=1)
        return target, target
    recent = re.search(r"最近\s*(\d{1,2})\s*天", message)
    if recent:
        days = max(1, min(31, int(recent.group(1))))
        return anchor - timedelta(days=days - 1), anchor
    return anchor, anchor


def _coach_tool_context(message: str, fallback_day: str) -> dict:
    start, end = _coach_date_range(message, fallback_day)
    if (end - start).days > 30:
        start = end - timedelta(days=30)
    lower = message.lower()
    wants_food = any(token in lower for token in ("吃", "饮食", "餐", "热量", "蛋白", "碳水", "脂肪", "营养"))
    wants_weight = any(token in lower for token in ("体重", "称重", "胖", "瘦"))
    wants_training = any(token in lower for token in ("训练", "运动", "步数", "跑步", "健身"))
    days = []
    cursor = start
    while cursor <= end:
        days.append(_daily_summary_for_day(cursor.isoformat()).model_dump())
        cursor += timedelta(days=1)

    context = {
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "daily_summaries": days,
        "tools_used": ["query_daily_nutrition"],
    }
    if wants_food:
        with food_db._get_conn() as conn:
            _ensure_food_log_table(conn)
            rows = conn.execute(
                """SELECT date, food_name, calories, protein, carbs, fat, serving_size, meal_category
                   FROM food_log_history
                   WHERE date >= ? AND date <= ?
                   ORDER BY date DESC, logged_at DESC LIMIT 160""",
                (start.isoformat(), end.isoformat()),
            ).fetchall()
        context["food_logs"] = [dict(row) for row in rows]
        context["tools_used"].append("query_food_logs")
    if wants_weight or wants_training:
        with tracking._get_conn() as conn:
            if wants_weight:
                rows = conn.execute(
                    "SELECT date, weight_kg, notes FROM weight_logs WHERE date >= ? AND date <= ? ORDER BY date",
                    (start.isoformat(), end.isoformat()),
                ).fetchall()
                context["weight_logs"] = [dict(row) for row in rows]
                context["tools_used"].append("query_weight_logs")
            if wants_training:
                exercises = conn.execute(
                    """SELECT date, name, duration_minutes, intensity, calories_burned
                       FROM exercises WHERE date >= ? AND date <= ? ORDER BY date""",
                    (start.isoformat(), end.isoformat()),
                ).fetchall()
                steps = conn.execute(
                    "SELECT date, steps, source FROM step_logs WHERE date >= ? AND date <= ? ORDER BY date",
                    (start.isoformat(), end.isoformat()),
                ).fetchall()
                context["training_logs"] = [dict(row) for row in exercises]
                context["step_logs"] = [dict(row) for row in steps]
                context["tools_used"].append("query_training_logs")
    return context


@app.post("/v6/coach/chat")
async def coach_chat_endpoint(request: CoachChatRequest):
    """Chat with a nutrition coach grounded in today's real tracking data."""
    if not request.message.strip():
        raise HTTPException(status_code=400, detail="message is required")
    day = request.date or __import__("datetime").date.today().isoformat()
    summary = _daily_summary_for_day(day)
    recs_payload = await recommendation_service.today(
        summary=summary,
        meal_type=request.meal_type,
        limit=3,
        use_ai=False,
    )
    recommendations = recs_payload.get("recommendations", [])
    tool_context = _coach_tool_context(request.message, day)
    tracking.save_coach_message(
        "user",
        request.message,
        {"meal_type": request.meal_type, "tool_query": {"start_date": tool_context["start_date"], "end_date": tool_context["end_date"]}},
        day,
    )
    coach = await recommendation_service.coach_reply(
        request.message,
        summary,
        recommendations,
        tool_context=tool_context,
    )
    tracking.save_coach_message(
        "assistant",
        coach["reply"],
        {"actions": coach.get("actions", []), "recommendations": recommendations, "source": coach.get("source")},
        day,
    )
    return {
        "reply": coach["reply"],
        "actions": coach.get("actions", []),
        "source": coach.get("source", "rules"),
        "tools_used": coach.get("tools_used", []),
        "summary": summary.model_dump(),
        "recommendations": recommendations,
        "messages": tracking.get_coach_messages(day),
    }


@app.post("/v6/coach/actions/apply")
async def apply_coach_action_endpoint(request: CoachActionApplyRequest):
    """Apply a structured coach action such as saving preferences or updated targets."""
    action = request.action or {}
    payload = action.get("payload") or {}
    action_type = action.get("type") or action.get("id") or ""
    day = request.date or __import__("datetime").date.today().isoformat()

    if action_type == "save_preferences":
        saved = tracking.save_user_preferences(payload)
        tracking.save_coach_message(
            "assistant",
            "已保存你的饮食偏好，后续推荐会优先参考它。",
            {"applied_action": action, "preferences": saved},
            day,
        )
        return {
            "status": "ok",
            "message": "已保存偏好",
            "preferences": saved,
            "daily_summary": _daily_summary_for_day(day).model_dump(),
        }

    if action_type == "set_macro_goals":
        allowed = {
            "daily_calories", "protein_g", "carbs_g", "fat_g", "fiber_g",
            "sugar_g", "sodium_mg", "water_ml",
        }
        goals = {key: payload.get(key) for key in allowed if payload.get(key) is not None}
        if not goals:
            raise HTTPException(status_code=400, detail="No macro goals in action payload")
        saved = tracking.save_macro_goals(goals)
        tracking.save_coach_message(
            "assistant",
            "已应用新的热量和宏量目标。",
            {"applied_action": action, "macro_goals": saved},
            day,
        )
        return {
            "status": "ok",
            "message": "已应用新的目标",
            "macro_goals": saved,
            "daily_summary": _daily_summary_for_day(day).model_dump(),
        }

    if action_type == "log_recommendation":
        recommendation_id = payload.get("recommendation_id")
        if not recommendation_id:
            raise HTTPException(status_code=400, detail="recommendation_id is required")
        result = await log_recommendation_endpoint(
            str(recommendation_id),
            RecommendationLogRequest(
                portion_multiplier=payload.get("portion_multiplier") or 1,
                meal_category=payload.get("meal_type") or None,
                date=day,
            ),
        )
        already_logged = bool(result.get("already_logged"))
        message = "这餐已经记录过了" if already_logged else "已记录推荐餐"
        tracking.save_coach_message(
            "assistant",
            message,
            {"applied_action": action, "foods": result.get("foods", []), "already_logged": already_logged},
            day,
        )
        return {
            "status": "ok",
            "message": message,
            "already_logged": already_logged,
            "foods": result.get("foods", []),
            "daily_summary": result.get("summary"),
        }

    raise HTTPException(status_code=400, detail=f"Unsupported coach action: {action_type}")


# ── /v6/insights (LLM-powered) ───────────────────────────────────

class GenerateInsightsRequest(BaseModel):
    days: int = 7


@app.post("/v6/insights/generate")
async def generate_insights_endpoint(request: GenerateInsightsRequest):
    """Generate personalized LLM insights from tracking data."""
    if describe_meal is None or describe_meal.provider is None:
        raise HTTPException(status_code=503, detail="暂未配置洞察生成模型，请先配置 LLM API Key。")

    # Gather data
    weights = tracking.get_weights(request.days)
    summary = tracking.get_daily_summary()

    weight_trend = ""
    if len(weights) >= 2:
        delta = weights[-1].weight_kg - weights[0].weight_kg
        direction = "下降" if delta < 0 else ("上升" if delta > 0 else "不变")
        weight_trend = f"体重{direction}了{abs(delta):.1f}kg"

    prompt = f"""你是MyFitnessPal的营养教练AI。基于用户过去{request.days}天的数据生成3条简短洞察。

今日数据:
- 已摄入: {summary.calories_consumed:.0f}kcal / 目标 {summary.calories_goal:.0f}kcal
- 蛋白质: {summary.protein:.0f}g / 目标 {summary.protein_goal:.0f}g
- 饮水: {summary.water_ml:.0f}ml / 目标 {summary.water_goal_ml:.0f}ml
- 运动消耗: {summary.calories_burned:.0f}kcal
{weight_trend}

返回JSON: {{"insights":[{{"title":"...","body":"...","type":"nutrition|exercise|weight|tip","icon":"🔥"}}]}}
每次返回3条。用中文。简洁有鼓励性。"""

    try:
        response_text = await describe_meal.provider.raw_completion(
            "你是MyFitnessPal的营养教练AI。返回JSON。",
            prompt, max_tokens=1024
        )
        import json, re
        text = re.sub(r'```(?:json)?\s*', '', response_text.strip()).strip()
        data = json.loads(text)
        for item in data.get("insights", []):
            from models.tracking import Insight
            tracking.add_insight(Insight(
                title=item.get("title", ""),
                body=item.get("body", ""),
                type=item.get("type", "general"),
                icon=item.get("icon", "💡"),
            ))
        return {"insights": data.get("insights", [])}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Insight generation failed: {e}")


@app.get("/v6/insights")
async def get_insights_endpoint(days: int = 7):
    """Get recent insights."""
    return {"insights": tracking.get_insights(days)}


# ── /v6/goal-plan ────────────────────────────────────────────────

from services.goal_planner import GoalPlan, ActivityLevel

class GoalPlanRequest(BaseModel):
    current_weight_kg: float
    goal_weight_kg: float
    height_cm: float = 170
    age: int = 30
    gender: str = "male"
    activity: str = "moderate"
    deficit_pct: float = 20


@app.post("/v6/goal-plan")
async def create_goal_plan_endpoint(request: GoalPlanRequest):
    """Create a weight goal plan with BMR, TDEE, timeline projection."""
    if not 25 <= request.current_weight_kg <= 350:
        raise HTTPException(status_code=400, detail="当前体重必须在 25–350 公斤之间")
    if not 25 <= request.goal_weight_kg <= 350:
        raise HTTPException(status_code=400, detail="目标体重必须在 25–350 公斤之间")
    if not 100 <= request.height_cm <= 250:
        raise HTTPException(status_code=400, detail="身高必须在 100–250 厘米之间")
    if not 13 <= request.age <= 120:
        raise HTTPException(status_code=400, detail="年龄必须在 13–120 岁之间")
    if request.gender not in {"male", "female"}:
        raise HTTPException(status_code=400, detail="性别参数无效")
    try:
        activity = ActivityLevel(request.activity)
    except ValueError:
        activity = ActivityLevel.moderate

    plan = GoalPlan(
        current_weight_kg=request.current_weight_kg,
        goal_weight_kg=request.goal_weight_kg,
        height_cm=request.height_cm,
        age=request.age,
        gender=request.gender,
        activity=activity,
        deficit_pct=request.deficit_pct,
    )
    result = plan.to_dict()

    # Get latest weight for progress
    weights = tracking.get_weights(30)
    if weights:
        progress = plan.progress_report(weights[-1].weight_kg)
        result["progress"] = progress

    # Save to tracking
    tracking.save_goal_plan(result)

    return result


@app.get("/v6/goal-plan")
async def get_goal_plan_endpoint():
    """Get the active goal plan."""
    plan = tracking.get_active_goal_plan()
    return plan


# ── /v6/meal-plan (LLM-powered) ──────────────────────────────────

class GenerateMealPlanRequest(BaseModel):
    daily_calories: float = 2000
    days: int = 1
    preferences: str = ""
    protein_pct: float = 30   # % of calories
    carbs_pct: float = 40
    fat_pct: float = 30
    goal_type: str = "fat_loss"
    meals_per_day: int = 3
    prep_time_minutes: int = 20
    diet_preferences: list[str] = []
    avoid_ingredients: list[str] = []


def _meal_plan_slots(meals_per_day: int) -> list[tuple[str, str, float]]:
    count = max(2, min(5, int(meals_per_day or 3)))
    if count == 2:
        return [("lunch", "午餐", 0.48), ("dinner", "晚餐", 0.52)]
    if count == 3:
        return [("breakfast", "早餐", 0.25), ("lunch", "午餐", 0.36), ("dinner", "晚餐", 0.39)]
    if count == 4:
        return [("breakfast", "早餐", 0.22), ("lunch", "午餐", 0.34), ("snack", "加餐", 0.12), ("dinner", "晚餐", 0.32)]
    return [("breakfast", "早餐", 0.20), ("snack", "上午加餐", 0.10), ("lunch", "午餐", 0.30), ("snack", "下午加餐", 0.10), ("dinner", "晚餐", 0.30)]


def _fallback_plan_meal(meal_type: str, meal_label: str, target: int, ratio: float, protein_g: int, carbs_g: int, fat_g: int) -> dict:
    templates = {
        "breakfast": ("燕麦酸奶鸡蛋碗", ["燕麦 45g", "原味酸奶 180g", "鸡蛋 1个", "蓝莓 80g"]),
        "lunch": ("鸡胸糙米蔬菜碗", ["鸡胸肉 150g", "糙米饭 140g", "西兰花 180g", "橄榄油 5g"]),
        "dinner": ("鱼肉豆腐蔬菜餐", ["鱼肉 150g", "豆腐 120g", "绿叶菜 220g", "红薯 120g"]),
        "snack": ("高蛋白加餐", ["原味酸奶 180g", "香蕉 1根", "坚果 10g"]),
    }
    title, ingredients = templates.get(meal_type, templates["lunch"])
    return {
        "meal_type": meal_type,
        "label": meal_label,
        "name": f"{meal_label}: {title}",
        "calories": target,
        "protein": round(protein_g * ratio),
        "carbs": round(carbs_g * ratio),
        "fat": round(fat_g * ratio),
        "fiber": round(6 * ratio * 3, 1),
        "sugar": round(12 * ratio * 3, 1),
        "sodium": round(520 * ratio * 3),
        "prep_time_minutes": 20,
        "ingredients": ingredients,
        "reason": "基于规则生成的均衡备选。",
        "source": "rules_fallback",
    }


def _recipe_plan_ingredients(recipe: dict) -> list[str]:
    ingredients = []
    for item in recipe.get("ingredients_breakdown") or []:
        name = str(item.get("name") or "").strip()
        amount = str(item.get("display_amount") or item.get("amount") or item.get("serving_size") or "").strip()
        if name:
            ingredients.append(f"{name} {amount}".strip())
    if not ingredients:
        ingredients = [str(item).strip() for item in recipe.get("missing_ingredients") or [] if str(item).strip()]
    return ingredients[:12]


MEAL_TYPE_ALIASES = {
    "breakfast": ("breakfast", "早餐", "早饭", "早", "morning"),
    "lunch": ("lunch", "午餐", "中餐", "午饭", "午"),
    "dinner": ("dinner", "晚餐", "晚饭", "正餐", "晚"),
    "snack": ("snack", "加餐", "零食", "点心", "下午茶", "snacks"),
}


def _normalize_recipe_meal_type(value: str) -> str | None:
    text = str(value or "").strip().lower()
    if not text:
        return None
    for key, aliases in MEAL_TYPE_ALIASES.items():
        if text == key or any(alias.lower() in text for alias in aliases):
            return key
    return None


def _recipe_meal_types(recipe: dict) -> list[str]:
    meal_types: list[str] = []
    for raw in recipe.get("meal_types") or []:
        normalized = _normalize_recipe_meal_type(str(raw))
        if normalized and normalized not in meal_types:
            meal_types.append(normalized)
    for raw in recipe.get("tags") or []:
        normalized = _normalize_recipe_meal_type(str(raw))
        if normalized and normalized not in meal_types:
            meal_types.append(normalized)
    return meal_types[:4]


def _sanitize_recipe_meal_types(recipe: dict) -> list[str]:
    meal_types = _recipe_meal_types(recipe)
    recipe["meal_types"] = meal_types
    return meal_types


def _imported_recipe_plan_candidates(preferences: dict) -> list[dict]:
    if not bool(preferences.get("include_imported_recipes_in_meal_plans", True)):
        return []
    events = tracking.list_recipe_suggestion_events(limit=100, imported=True)
    candidates = []
    for event in events:
        recipe = event.get("recipe") or {}
        title = str(recipe.get("title") or "").strip()
        if not title or _is_blocked_ingredient(title, preferences):
            continue
        ingredients = _recipe_plan_ingredients(recipe)
        if any(_is_blocked_ingredient(item, preferences) for item in ingredients):
            continue
        calories = float(recipe.get("calories") or 0)
        if calories <= 0:
            continue
        meal_types = _sanitize_recipe_meal_types(recipe)
        candidates.append({
            "id": event.get("id") or recipe.get("id") or "",
            "recipe": recipe,
            "ingredients": ingredients,
            "calories": calories,
            "meal_types": meal_types,
        })
    return candidates


def _pick_imported_recipe_for_meal(candidates: list[dict], meal_type: str, offset: int) -> dict | None:
    if not candidates:
        return None
    normalized = _normalize_recipe_meal_type(meal_type) or meal_type
    exact = [candidate for candidate in candidates if normalized in (candidate.get("meal_types") or [])]
    generic = [candidate for candidate in candidates if not (candidate.get("meal_types") or [])]
    pool = exact or generic
    if not pool:
        return None
    return pool[offset % len(pool)]


def _meal_from_imported_recipe(candidate: dict, meal_type: str, meal_label: str, target: int, prep_time: int) -> dict:
    recipe = candidate.get("recipe") or {}
    base_calories = max(1.0, float(candidate.get("calories") or recipe.get("calories") or 1))
    multiplier = max(0.35, min(2.5, target / base_calories))
    title = str(recipe.get("title") or "导入食谱").strip()
    source_url = str(recipe.get("source_url") or "").strip()
    reason = f"来自导入食谱，按本餐目标约 {multiplier:.1f} 份纳入计划。"
    if source_url:
        reason += " 已保留原食谱来源。"
    return {
        "meal_type": meal_type,
        "label": meal_label,
        "name": f"{meal_label}: {title}",
        "calories": round(float(recipe.get("calories") or 0) * multiplier),
        "protein": round(float(recipe.get("protein") or 0) * multiplier, 1),
        "carbs": round(float(recipe.get("carbs") or 0) * multiplier, 1),
        "fat": round(float(recipe.get("fat") or 0) * multiplier, 1),
        "fiber": round(float(recipe.get("fiber") or 0) * multiplier, 1),
        "sugar": round(float(recipe.get("sugar") or 0) * multiplier, 1),
        "sodium": round(float(recipe.get("sodium") or 0) * multiplier),
        "prep_time_minutes": min(prep_time, int(recipe.get("active_time_minutes") or recipe.get("prep_time_minutes") or prep_time)),
        "ingredients": candidate.get("ingredients") or [],
        "reason": reason,
        "source": "imported_recipe",
        "source_recipe_id": candidate.get("id") or recipe.get("id"),
        "source_url": source_url or None,
        "meal_types": candidate.get("meal_types") or _recipe_meal_types(recipe),
        "portion_multiplier": round(multiplier, 2),
    }


MEAL_PLAN_RECIPE_COLLECTIONS = [
    {
        "id": "high_protein",
        "title": "高蛋白食谱集合",
        "description": "优先展示蛋白质更高、适合正餐和训练日的已保存食谱。",
        "tag": "高蛋白",
        "aliases": ("高蛋白", "high protein", "protein"),
    },
    {
        "id": "low_carb",
        "title": "低碳食谱集合",
        "description": "优先展示碳水更低、适合控糖和轻断食窗口后的食谱。",
        "tag": "低碳",
        "aliases": ("低碳", "low carb", "low-carb"),
    },
    {
        "id": "under_500",
        "title": "500 千卡以内",
        "description": "适合想控制单餐热量时快速选择。",
        "tag": "低热量",
        "aliases": ("低热量", "low calorie", "under 500", "under 500 calories"),
    },
    {
        "id": "breakfast",
        "title": "早餐食谱",
        "description": "适合早晨快速记录或加入餐单。",
        "tag": "早餐",
        "aliases": ("早餐", "breakfast"),
    },
    {
        "id": "dinner",
        "title": "晚餐食谱",
        "description": "适合晚餐安排和一键生成餐单。",
        "tag": "晚餐",
        "aliases": ("晚餐", "dinner"),
    },
]


def _recipe_collection_summary(event: dict) -> dict:
    recipe = dict((event or {}).get("recipe") or {})
    _normalize_recipe_external_shape(recipe)
    recipe_id = str((event or {}).get("id") or recipe.get("id") or "")
    return {
        "id": recipe_id,
        "title": str(recipe.get("title") or "未命名食谱"),
        "calories": round(float(recipe.get("calories") or 0), 1),
        "protein": round(float(recipe.get("protein") or 0), 1),
        "carbs": round(float(recipe.get("carbs") or 0), 1),
        "fat": round(float(recipe.get("fat") or 0), 1),
        "servings": int(recipe.get("servings") or 1),
        "image_url": recipe.get("image_url") or None,
        "source_url": recipe.get("source_url") or None,
        "cooking_time": recipe.get("cooking_time") or None,
        "tags": recipe.get("tags") or [],
        "meal_types": _recipe_meal_types(recipe),
        "favorite": bool(recipe.get("favorite")),
        "imported": _is_imported_recipe_event({"recipe": recipe, "source": event.get("source")}),
    }


def _is_imported_recipe_event(event: dict) -> bool:
    recipe = (event or {}).get("recipe") or {}
    source = str((event or {}).get("source") or recipe.get("source") or "").strip()
    source_url = str(recipe.get("source_url") or "").strip()
    return source == "recipe_url_import" or bool(source_url)


def _recipe_matches_collection(recipe: dict, collection: dict) -> bool:
    tags = [str(tag or "").strip().lower() for tag in recipe.get("tags") or []]
    meal_types = [str(item or "").strip().lower() for item in _recipe_meal_types(recipe)]
    aliases = [str(item).strip().lower() for item in collection.get("aliases") or []]
    text = " ".join([str(recipe.get("title") or "").lower(), *tags, *meal_types])
    if any(alias and alias in text for alias in aliases):
        return True
    calories = float(recipe.get("calories") or 0)
    protein = float(recipe.get("protein") or 0)
    carbs = float(recipe.get("carbs") or 0)
    if collection["id"] == "high_protein":
        return protein >= 25 or (calories > 0 and protein * 4 / calories >= 0.25)
    if collection["id"] == "low_carb":
        return carbs <= 35 or (calories > 0 and carbs * 4 / calories <= 0.30)
    if collection["id"] == "under_500":
        return 0 < calories <= 500
    return False


def _meal_plan_recipe_collections(limit: int = 6) -> list[dict]:
    events = tracking.list_recipe_suggestion_events(limit=200, sort="created") if hasattr(tracking, "list_recipe_suggestion_events") else []
    collections = []
    for collection in MEAL_PLAN_RECIPE_COLLECTIONS:
        matched = []
        for event in events:
            recipe = dict((event or {}).get("recipe") or {})
            _normalize_recipe_external_shape(recipe)
            if not str(recipe.get("title") or "").strip():
                continue
            if _recipe_matches_collection(recipe, collection):
                matched.append({**_recipe_collection_summary({**event, "recipe": recipe}), "_score": 1 if bool(recipe.get("favorite")) else 0})
        if not matched:
            continue
        matched.sort(key=lambda item: (item.get("_score", 0), item.get("protein", 0), -item.get("calories", 0)), reverse=True)
        recipes = [{k: v for k, v in item.items() if k != "_score"} for item in matched[: max(1, min(12, limit))]]
        calories = [float(item.get("calories") or 0) for item in recipes if float(item.get("calories") or 0) > 0]
        collections.append({
            "id": collection["id"],
            "title": collection["title"],
            "description": collection["description"],
            "tag": collection["tag"],
            "calorie_range": f"{int(min(calories))}-{int(max(calories))} 千卡" if calories else "",
            "recipe_count": len(matched),
            "image_url": next((item.get("image_url") for item in recipes if item.get("image_url")), None),
            "recipes": recipes,
        })
    return collections


def _inject_imported_recipes_into_plan(data: dict, preferences: dict) -> dict:
    candidates = _imported_recipe_plan_candidates(preferences)
    if not candidates:
        data["imported_recipes_included"] = 0
        return data
    prep_time = max(5, min(120, int(preferences.get("prep_time_minutes") or data.get("prep_time_minutes") or 20)))
    included = 0
    meal_index = 0
    for day_item in data.get("days") or []:
        meals = day_item.get("meals") or []
        for index, meal in enumerate(meals):
            if meal_index % 3 == 1:
                target = int(float(meal.get("calories") or 0)) or int(float((data.get("daily_targets") or {}).get("calories") or 2000) / max(len(meals), 1))
                meal_type = str(meal.get("meal_type") or "")
                label = str(meal.get("label") or "")
                if not label:
                    name = str(meal.get("name") or "")
                    label = name.split(":", 1)[0].strip() if ":" in name else "餐次"
                if not meal_type:
                    meal_type = "snack" if "加餐" in label else ("breakfast" if "早" in label else ("lunch" if "午" in label else "dinner"))
                candidate = _pick_imported_recipe_for_meal(candidates, meal_type, meal_index)
                if candidate:
                    meals[index] = _meal_from_imported_recipe(
                        candidate,
                        meal_type,
                        label,
                        target,
                        prep_time,
                    )
                    included += 1
            meal_index += 1
    data["imported_recipes_included"] = included
    return data


def _ingredient_category(name: str) -> str:
    lower = name.lower()
    if any(key in lower for key in ["鸡", "牛", "鱼", "虾", "蛋", "豆腐", "酸奶", "yogurt", "egg", "chicken", "beef", "fish", "tofu"]):
        return "蛋白质"
    if any(key in lower for key in ["米", "饭", "面", "燕麦", "红薯", "土豆", "面包", "oat", "rice", "bread", "potato"]):
        return "主食"
    if any(key in lower for key in ["菜", "西兰花", "菠菜", "生菜", "番茄", "水果", "香蕉", "蓝莓", "苹果", "broccoli", "spinach", "banana", "apple"]):
        return "蔬菜水果"
    return "其他"


def _meal_plan_grocery_list(days_payload: list[dict]) -> list[dict]:
    buckets: dict[str, dict[str, float]] = {"蛋白质": {}, "主食": {}, "蔬菜水果": {}, "其他": {}}
    servings: dict[str, int] = {}
    for day_item in days_payload:
        for meal in day_item.get("meals", []):
            for raw in meal.get("ingredients", []):
                text = str(raw).strip()
                if not text:
                    continue
                match = re.search(r"(\d+(?:\.\d+)?)\s*(g|克)", text, re.IGNORECASE)
                name = re.sub(r"\s*\d+(?:\.\d+)?\s*(?:g|克|个|根|份|杯|碗).*", "", text, flags=re.IGNORECASE).strip() or text
                category = _ingredient_category(name)
                if match:
                    buckets[category][name] = buckets[category].get(name, 0) + float(match.group(1))
                else:
                    servings[name] = servings.get(name, 0) + 1
                    buckets[category].setdefault(name, 0)
    result = []
    for category, items in buckets.items():
        formatted = []
        for name, grams in sorted(items.items()):
            if grams > 0:
                formatted.append(f"{name} {round(grams)}g")
            else:
                count = servings.get(name, 1)
                formatted.append(f"{name} {count}份")
        if formatted:
            result.append({"category": category, "items": formatted})
    return result


def _rule_based_meal_plan(request: GenerateMealPlanRequest) -> dict:
    days_count = max(1, min(14, int(request.days or 1)))
    meals_per_day = max(2, min(5, int(request.meals_per_day or 3)))
    daily_calories = max(1000, min(4500, float(request.daily_calories or 2000)))
    if request.goal_type in {"gain", "muscle_gain", "增肌"}:
        daily_calories = round(daily_calories * 1.05 / 10) * 10
    elif request.goal_type in {"fat_loss", "lose", "减脂"}:
        daily_calories = round(daily_calories * 0.95 / 10) * 10
    protein_g = round(daily_calories * request.protein_pct / 100 / 4)
    carbs_g = round(daily_calories * request.carbs_pct / 100 / 4)
    fat_g = round(daily_calories * request.fat_pct / 100 / 9)

    preferences = tracking.get_user_preferences()
    taste_tags = list(preferences.get("taste_tags", []))
    if request.preferences:
        taste_tags.extend([item.strip() for item in re.split(r"[，,、/ ]+", request.preferences) if item.strip()])
    taste_tags.extend([item.strip() for item in request.diet_preferences if str(item).strip()])
    preferences["taste_tags"] = list(dict.fromkeys(taste_tags))[:20]
    preferences["avoid_ingredients"] = list(dict.fromkeys([*preferences.get("avoid_ingredients", []), *request.avoid_ingredients]))[:20]
    preferences["prep_time_minutes"] = max(5, min(120, int(request.prep_time_minutes or preferences.get("prep_time_minutes", 20))))
    imported_recipe_candidates = _imported_recipe_plan_candidates(preferences)

    candidates = recommendation_service._load_food_candidates()
    filtered = recommendation_service._filter_candidates(candidates, preferences) or candidates
    slots = _meal_plan_slots(meals_per_day)
    summary = _daily_summary_for_day(date.today().isoformat()).model_copy(update={
        "calories_consumed": 0,
        "calories_goal": daily_calories,
        "protein": 0,
        "protein_goal": protein_g,
        "carbs": 0,
        "carbs_goal": carbs_g,
        "fat": 0,
        "fat_goal": fat_g,
    })

    plan_days = []
    for day_index in range(days_count):
        meals = []
        for meal_index, (meal_type, meal_label, ratio_value) in enumerate(slots):
            target = round(daily_calories * ratio_value)
            remaining = {
                "calories": target,
                "protein": round(protein_g * ratio_value),
                "carbs": round(carbs_g * ratio_value),
                "fat": round(fat_g * ratio_value),
            }
            imported_index = day_index * meals_per_day + meal_index
            imported_candidate = _pick_imported_recipe_for_meal(imported_recipe_candidates, meal_type, imported_index) if imported_recipe_candidates and imported_index % 3 == 1 else None
            if imported_candidate:
                meal = _meal_from_imported_recipe(
                    imported_candidate,
                    meal_type,
                    meal_label,
                    target,
                    preferences["prep_time_minutes"],
                )
            else:
                recs = recommendation_service._build_recommendations(
                    filtered,
                    summary,
                    remaining,
                    target,
                    meal_type,
                    preferences,
                    limit=6,
                ) if filtered else []
                rec = recs[(day_index + meal_index) % len(recs)] if recs else None
                if rec:
                    meal = {
                        "meal_type": meal_type,
                        "label": meal_label,
                        "name": rec["title"].replace("加餐:", f"{meal_label}:").replace("早餐:", f"{meal_label}:").replace("午餐:", f"{meal_label}:").replace("晚餐:", f"{meal_label}:"),
                        "calories": rec["calories"],
                        "protein": rec["protein"],
                        "carbs": rec["carbs"],
                        "fat": rec["fat"],
                        "fiber": rec.get("fiber", 0),
                        "sugar": rec.get("sugar", 0),
                        "sodium": rec.get("sodium", 0),
                        "prep_time_minutes": min(preferences["prep_time_minutes"], rec.get("prep_time_minutes", preferences["prep_time_minutes"])),
                        "ingredients": [f"{item.get('name', '')} {item.get('serving_size', '')}".strip() for item in rec.get("foods", [])],
                        "reason": rec.get("reason", ""),
                        "source": "rules",
                    }
                else:
                    meal = _fallback_plan_meal(meal_type, meal_label, target, ratio_value, protein_g, carbs_g, fat_g)
            meals.append(meal)
        plan_days.append({"day": f"第{day_index + 1}天", "meals": meals})

    data = {
        "plan_name": f"{round(daily_calories)}kcal {days_count}天{meals_per_day}餐计划",
        "source": "rules",
        "goal_type": request.goal_type,
        "meals_per_day": meals_per_day,
        "prep_time_minutes": preferences["prep_time_minutes"],
        "daily_targets": {
            "calories": round(daily_calories),
            "protein": protein_g,
            "carbs": carbs_g,
            "fat": fat_g,
        },
        "preferences": preferences,
        "imported_recipes_included": sum(
            1
            for day_item in plan_days
            for meal in day_item.get("meals", [])
            if meal.get("source") == "imported_recipe"
        ),
        "days": plan_days,
        "grocery_list": _meal_plan_grocery_list(plan_days),
    }
    return data


@app.post("/v6/meal-plan/generate")
async def generate_meal_plan_endpoint(request: GenerateMealPlanRequest):
    """Generate a meal plan with grocery list. Falls back to nutrition rules without an LLM."""
    prefs = request.preferences or "均衡饮食"
    plan_preferences = tracking.get_user_preferences()
    plan_preferences["prep_time_minutes"] = max(5, min(120, int(request.prep_time_minutes or plan_preferences.get("prep_time_minutes", 20))))
    plan_preferences["avoid_ingredients"] = list(dict.fromkeys([*plan_preferences.get("avoid_ingredients", []), *request.avoid_ingredients]))[:20]
    imported_recipe_count = len(_imported_recipe_plan_candidates(plan_preferences))
    imported_recipe_instruction = (
        f"用户允许导入食谱进入餐单；当前有 {imported_recipe_count} 个可用导入食谱，应混合部分导入食谱。"
        if plan_preferences.get("include_imported_recipes_in_meal_plans", True)
        else "用户关闭了导入食谱进入餐单，不要使用导入食谱。"
    )
    protein_g = round(request.daily_calories * request.protein_pct / 100 / 4)
    carbs_g = round(request.daily_calories * request.carbs_pct / 100 / 4)
    fat_g = round(request.daily_calories * request.fat_pct / 100 / 9)

    prompt = f"""你是专业营养师。生成{request.days}天餐谱。

每天目标: {request.daily_calories:.0f}kcal (蛋白质{protein_g}g, 碳水{carbs_g}g, 脂肪{fat_g}g)
偏好: {prefs}
目标: {request.goal_type}
每天{max(2, min(5, request.meals_per_day))}餐，烹饪时间约{request.prep_time_minutes}分钟。
忌口: {", ".join(request.avoid_ingredients) or "无"}
导入食谱设置: {imported_recipe_instruction}

返回JSON:
{{"plan_name":"餐谱名称","days":[
  {{"day":"第1天","meals":[
    {{"name":"早餐: xxx","calories":500,"protein":25,"carbs":55,"fat":18,"ingredients":["食材1 100g","食材2 50g"]}},
    {{"name":"午餐: xxx","calories":700,"protein":38,"carbs":67,"fat":22,"ingredients":["食材1 150g"]}},
    {{"name":"晚餐: xxx","calories":600,"protein":35,"carbs":58,"fat":18,"ingredients":["食材1 120g"]}}
  ]}}
],
"grocery_list":[
  {{"category":"蛋白质","items":["鸡胸肉 500g","鸡蛋 6个","三文鱼 300g"]}},
  {{"category":"主食","items":["糙米 400g","全麦面包 1袋"]}},
  {{"category":"蔬菜","items":["西兰花 300g","菠菜 200g"]}},
  {{"category":"其他","items":["橄榄油","盐","酱油"]}}
]}}
食材按类别分组。用中文。总热量≈{request.daily_calories:.0f}×{request.days}天。"""

    data = None
    if describe_meal is not None and describe_meal.provider is not None:
        try:
            response_text = await describe_meal.provider.raw_completion(
                "你是专业营养师。返回JSON格式的完整餐谱和购物清单。",
                prompt, max_tokens=3072
            )
            text = re.sub(r'```(?:json)?\s*', '', response_text.strip()).strip()
            data = json.loads(text)
            data.setdefault("source", "ai_enhanced")
            data.setdefault("goal_type", request.goal_type)
            data.setdefault("meals_per_day", max(2, min(5, request.meals_per_day)))
            data.setdefault("daily_targets", {
                "calories": round(request.daily_calories),
                "protein": protein_g,
                "carbs": carbs_g,
                "fat": fat_g,
            })
            if not data.get("grocery_list"):
                data["grocery_list"] = _meal_plan_grocery_list(data.get("days", []))
            if plan_preferences.get("include_imported_recipes_in_meal_plans", True):
                data = _inject_imported_recipes_into_plan(data, plan_preferences)
        except Exception:
            data = None

    if data is None:
        data = _rule_based_meal_plan(request)

    from models.tracking import MealPlan as MP
    target = data.get("daily_targets", {}).get("calories", request.daily_calories)
    plan = MP(name=data.get("plan_name", f"{request.daily_calories:.0f}kcal {request.days}天餐谱"),
              daily_calorie_target=target)
    tracking._save_meal_plan(plan, data)
    return data


@app.get("/v6/meal-plan/history")
async def meal_plan_history_endpoint():
    """Get saved meal plans."""
    return {"plans": tracking.get_meal_plans()}


@app.get("/v6/meal-plan/collections")
async def meal_plan_recipe_collections_endpoint(limit: int = 6):
    """Return MyFitnessPal-style recipe collections built from the user's saved recipes."""
    return {"collections": _meal_plan_recipe_collections(limit=limit)}


@app.delete("/v6/meal-plan/{plan_id}")
async def delete_meal_plan_endpoint(plan_id: str):
    """Delete a saved meal plan."""
    deleted = tracking.delete_meal_plan(plan_id) if hasattr(tracking, "delete_meal_plan") else False
    if not deleted:
        raise HTTPException(status_code=404, detail="餐单不存在")
    return {"deleted": True, "id": plan_id}


class GroceryCheckRequest(BaseModel):
    checked_items: list[str] = []


@app.post("/v6/meal-plan/{plan_id}/grocery-check")
async def meal_plan_grocery_check_endpoint(plan_id: str, request: GroceryCheckRequest):
    """Persist checked grocery items for a saved meal plan."""
    stored_plan = tracking.get_meal_plan(plan_id) if hasattr(tracking, "get_meal_plan") else None
    if not stored_plan:
        raise HTTPException(status_code=404, detail="餐单不存在")

    import json
    plan_data = json.loads(json.dumps(stored_plan, ensure_ascii=False))
    clean_items = []
    seen = set()
    for item in request.checked_items or []:
        text = str(item).strip()
        if text and text not in seen:
            clean_items.append(text)
            seen.add(text)
    plan_data["grocery_checked_items"] = clean_items
    updated = tracking.update_meal_plan(plan_id, plan_data)
    if not updated:
        raise HTTPException(status_code=404, detail="餐单不存在")
    return updated


class SwapMealRequest(BaseModel):
    current_meal: dict | None = None
    day: str | None = None
    daily_targets: dict | None = None
    preferences: str | None = None
    avoid_ingredients: list[str] | None = None


@app.post("/v6/meal-plan/{plan_id}/swap-meal")
async def swap_meal_endpoint(plan_id: str, request: SwapMealRequest | None = None):
    """Swap a meal in the plan with an LLM-generated alternative."""
    if describe_meal is None or describe_meal.provider is None:
        raise HTTPException(status_code=503, detail="暂未配置换餐模型，请先配置 LLM API Key。")

    payload = request or SwapMealRequest()
    current_meal = payload.current_meal or {}
    target_calories = current_meal.get("calories") or (payload.daily_targets or {}).get("calories")
    meal_type = current_meal.get("meal_type") or current_meal.get("label") or "餐次"
    avoid_text = "、".join(payload.avoid_ingredients or [])
    prompt = f"""请替换餐谱中的一餐，生成同餐次、同等热量区间、不同食材组合的新餐。
当前餐: {json.dumps(current_meal, ensure_ascii=False)}
日期/天: {payload.day or ""}
每日目标: {json.dumps(payload.daily_targets or {}, ensure_ascii=False)}
偏好: {payload.preferences or ""}
忌口: {avoid_text}
要求:
1. 新餐热量尽量接近 {target_calories or "当前餐"} 千卡。
2. meal_type 保持为 "{meal_type}"。
3. 使用中文食物名和食材。
4. 只返回 JSON，不要解释。
返回JSON: {{"meal_type":"{meal_type}","label":"替换餐","name":"新餐名","calories":500,"protein":25,"carbs":55,"fat":18,"fiber":5,"sugar":6,"sodium":500,"prep_time_minutes":20,"ingredients":["食材 100g"],"reason":"为什么适合替换","source":"ai_swap"}}"""

    try:
        response_text = await describe_meal.provider.raw_completion(
            "你是营养师。返回JSON。", prompt, max_tokens=512)
        import json, re
        text = re.sub(r'```(?:json)?\s*', '', response_text.strip()).strip()
        data = json.loads(text)
        data.setdefault("meal_type", current_meal.get("meal_type"))
        data.setdefault("label", current_meal.get("label") or "替换餐")
        data.setdefault("fiber", 0)
        data.setdefault("sugar", 0)
        data.setdefault("sodium", 0)
        data.setdefault("prep_time_minutes", current_meal.get("prep_time_minutes") or 20)
        data.setdefault("ingredients", [])
        data.setdefault("reason", "按当前餐次和热量目标替换")
        data.setdefault("source", "ai_swap")
        updated_plan = None
        stored_plan = tracking.get_meal_plan(plan_id) if hasattr(tracking, "get_meal_plan") else None
        if stored_plan:
            plan_data = json.loads(json.dumps(stored_plan, ensure_ascii=False))
            matched = False
            target_day = payload.day or ""

            def _same_meal(candidate: dict) -> bool:
                if not current_meal:
                    return False
                name_ok = (candidate.get("name") or "") == (current_meal.get("name") or "")
                type_ok = (candidate.get("meal_type") or "") == (current_meal.get("meal_type") or "")
                label_ok = (candidate.get("label") or "") == (current_meal.get("label") or "")
                return name_ok and (type_ok or label_ok or not (current_meal.get("meal_type") or current_meal.get("label")))

            for day in plan_data.get("days", []):
                if target_day and day.get("day") != target_day:
                    continue
                meals = day.get("meals") or []
                for index, meal in enumerate(meals):
                    if _same_meal(meal):
                        meals[index] = data
                        matched = True
                        break
                if matched:
                    break

            if matched:
                plan_data["grocery_list"] = _meal_plan_grocery_list(plan_data.get("days", []))
                updated_plan = tracking.update_meal_plan(plan_id, plan_data)

        return {"meal": data, "plan": updated_plan}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"换餐失败：{e}")


# ── /v6/steps ──────────────────────────────────────────────────────

class AddStepsRequest(BaseModel):
    steps: int
    date: str | None = None
    source: str = "manual"
    request_id: str | None = None


@app.post("/v6/steps")
async def add_steps_endpoint(request: AddStepsRequest):
    """Log step count."""
    day = request.date or date.today().isoformat()
    record_id, already_logged = _reserve_tracking_mutation(
        "steps",
        request.request_id,
        {"steps": request.steps, "date": day, "source": request.source},
    )
    result = tracking.add_steps(
        request.steps, day, request.source, step_id=record_id,
    )
    return {**result.model_dump(), "already_logged": already_logged}


@app.get("/v6/steps")
async def get_steps_endpoint(date: str | None = None):
    """Get steps for a day."""
    return {"steps": tracking.get_steps(date), "date": date or __import__("datetime").date.today().isoformat()}


@app.get("/v6/steps/history")
async def get_steps_history_endpoint(days: int = 30):
    """Get step history."""
    return {"steps": tracking.get_step_history(days)}


# ── /v6/friends ────────────────────────────────────────────────────

class FriendRequestReq(BaseModel):
    from_user: str
    to_user: str


class FriendActionReq(BaseModel):
    request_id: str


@app.post("/v6/friends/request")
async def send_friend_request_endpoint(request: FriendRequestReq):
    """Send a friend request."""
    return tracking.send_friend_request(request.from_user, request.to_user)


@app.post("/v6/friends/accept")
async def accept_friend_request_endpoint(request: FriendActionReq):
    """Accept a friend request."""
    return tracking.accept_friend_request(request.request_id)


@app.post("/v6/friends/reject")
async def reject_friend_request_endpoint(request: FriendActionReq):
    """Reject a friend request."""
    return tracking.reject_friend_request(request.request_id)


@app.delete("/v6/friends/{friendship_id}")
async def remove_friend_endpoint(friendship_id: str):
    """Remove a friend."""
    return tracking.remove_friend(friendship_id)


@app.get("/v6/friends")
async def get_friends_endpoint(user: str = Query(...)):
    """Get friends list."""
    return {"friends": tracking.get_friends(user)}


@app.get("/v6/friends/requests")
async def get_friend_requests_endpoint(user: str = Query(...)):
    """Get pending friend requests."""
    return {"requests": tracking.get_friend_requests(user)}


@app.get("/v6/friends/leaderboard")
async def get_leaderboard_endpoint(user: str = Query(...)):
    """Get friend leaderboard."""
    return {"leaderboard": tracking.get_leaderboard(user)}


# ── /v6/community ─────────────────────────────────────────────────

@app.get("/v6/community/feed")
async def get_community_feed_endpoint(
    tab: str = "friends",
    user: str = "me",
    limit: int = 20,
    cursor: str | None = None,
):
    """Return friends or public food-sharing feed."""
    limit = max(1, min(50, int(limit or 20)))
    tab = "discover" if tab == "discover" else "friends"
    with tracking._get_conn() as conn:
        _ensure_community_tables(conn)
        where = [
            "NOT EXISTS (SELECT 1 FROM community_reports r WHERE r.post_id = community_posts.id AND r.user = ?)",
            "(SELECT COUNT(*) FROM community_reports r2 WHERE r2.post_id = community_posts.id) < 3",
        ]
        params: list = [user]
        if cursor:
            where.append("created_at < ?")
            params.append(cursor)
        if tab == "discover":
            where.append("visibility = 'public'")
        else:
            friends = [item["friend"] for item in tracking.get_friends(user)]
            authors = [user] + [friend for friend in friends if friend]
            placeholders = ", ".join(["?"] * len(authors))
            where.append(f"author IN ({placeholders})")
            where.append("visibility IN ('friends', 'public')")
            params.extend(authors)
        rows = conn.execute(
            f"""
            SELECT *
            FROM community_posts
            WHERE {' AND '.join(where)}
            ORDER BY
                CASE WHEN ? = 'friends' AND post_type = 'daily_checkin' THEN 0 ELSE 1 END,
                created_at DESC
            LIMIT ?
            """,
            (*params, tab, limit + 1),
        ).fetchall()
        page = rows[:limit]
        next_cursor = page[-1]["created_at"] if len(rows) > limit and page else None
        return {
            "tab": tab,
            "posts": [_serialize_community_post(conn, row, user) for row in page],
            "next_cursor": next_cursor,
        }


@app.post("/v6/community/posts/from-meal-log")
async def create_community_post_from_meal_endpoint(request: CommunityPostFromMealRequest):
    """Publish a light meal card from a saved analyzed meal."""
    visibility = "public" if request.visibility == "public" else "friends"
    group_id = request.upload_group_id.strip()
    if not group_id:
        raise HTTPException(status_code=400, detail="upload_group_id is required")

    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE upload_group_id = ? ORDER BY id",
            (group_id,),
        ).fetchall()
    if not rows:
        raise HTTPException(status_code=404, detail="没有找到这次餐食记录。")

    foods = [_food_from_log_row(row) for row in rows]
    snapshots = [_food_to_snapshot(food) for food in foods]
    names = [food.name for food in foods]
    calories = sum(float(food.calories or 0) for food in foods)
    protein = sum(float(food.protein or 0) for food in foods)
    carbs = sum(float(food.carbs or 0) for food in foods)
    fat = sum(float(food.fat or 0) for food in foods)
    image_url = next((row["image_url"] for row in rows if row["image_url"]), "")
    day = rows[0]["date"] or date.today().isoformat()
    title = _community_title(names)
    tags = _community_tags(names, calories, protein, fat, request.tags)
    health_label = _community_health_label(calories, protein, fat)
    ai_note = _community_ai_note(calories, protein, carbs, fat)
    caption = request.caption.strip()[:280]

    with tracking._get_conn() as conn:
        _ensure_community_tables(conn)
        existing = conn.execute(
            "SELECT id FROM community_posts WHERE author = ? AND meal_log_group_id = ? LIMIT 1",
            (request.user, group_id),
        ).fetchone()
        if existing:
            post_id = existing["id"]
            conn.execute(
                """
                UPDATE community_posts
                SET visibility = ?, post_type = 'meal', title = ?, body = ?, image_url = ?, date = ?,
                    calories = ?, protein = ?, carbs = ?, fat = ?, health_label = ?,
                    ai_note = ?, tags_json = ?, foods_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                (
                    visibility, title, caption, image_url, day, calories, protein, carbs, fat,
                    health_label, ai_note, json.dumps(tags, ensure_ascii=False),
                    json.dumps(snapshots, ensure_ascii=False), post_id,
                ),
            )
        else:
            post_id = uuid4().hex[:12]
            conn.execute(
                """
                INSERT INTO community_posts
                    (id, author, visibility, post_type, title, body, image_url, meal_log_group_id, date,
                     calories, protein, carbs, fat, health_label, ai_note, tags_json, foods_json)
                VALUES (?, ?, ?, 'meal', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    post_id, request.user, visibility, title, caption, image_url, group_id, day,
                    calories, protein, carbs, fat, health_label, ai_note,
                    json.dumps(tags, ensure_ascii=False), json.dumps(snapshots, ensure_ascii=False),
                ),
            )
        conn.commit()
        row = _community_post_by_id(conn, post_id)
        return {"status": "ok", "post": _serialize_community_post(conn, row, request.user)}


@app.post("/v6/community/posts/daily-checkin")
async def create_daily_checkin_post_endpoint(request: CommunityDailyCheckinRequest):
    """Publish today's status-score check-in card."""
    day = request.date or date.today().isoformat()
    visibility = "public" if request.visibility == "public" else "friends"
    score = _daily_nutrition_score(day)
    summary = score.get("summary", {})
    active = score.get("active_challenges", [])
    title = f"今日状态分 {score['score']} 分"
    caption = request.caption.strip()[:280]
    body = caption or "完成今日健康打卡，继续把饮食、饮水、断食、运动和睡眠放在一个节奏里。"
    tags = ["今日打卡", score.get("status", "状态")]
    for item in score.get("highlights", [])[:3]:
        tags.append(str(item).replace(" ", ""))
    payload = {
        "score": score["score"],
        "status": score["status"],
        "headline": score["headline"],
        "dimensions": score.get("dimensions", []),
        "highlights": score.get("highlights", []),
        "next_actions": score.get("next_actions", []),
        "active_challenges": active,
    }
    health_label = "状态在线" if score["score"] >= 78 else "继续微调" if score["score"] >= 55 else "先补一项"
    ai_note = (score.get("next_actions") or ["今天先补最容易完成的一项。"])[0]
    with tracking._get_conn() as conn:
        _ensure_community_tables(conn)
        existing = conn.execute(
            "SELECT id FROM community_posts WHERE author = ? AND post_type = 'daily_checkin' AND checkin_date = ? LIMIT 1",
            (request.user, day),
        ).fetchone()
        if existing:
            post_id = existing["id"]
            conn.execute(
                """
                UPDATE community_posts
                SET visibility = ?, title = ?, body = ?, date = ?, checkin_date = ?,
                    challenge_id = ?, status_score = ?, calories = ?, protein = ?, carbs = ?, fat = ?,
                    health_label = ?, ai_note = ?, tags_json = ?, payload_json = ?,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                (
                    visibility, title, body, day, day, request.challenge_id, score["score"],
                    summary.get("calories_consumed", 0), summary.get("protein", 0),
                    summary.get("carbs", 0), summary.get("fat", 0), health_label, ai_note,
                    json.dumps(tags[:6], ensure_ascii=False), json.dumps(payload, ensure_ascii=False), post_id,
                ),
            )
        else:
            post_id = uuid4().hex[:12]
            conn.execute(
                """
                INSERT INTO community_posts
                    (id, author, visibility, post_type, title, body, date, checkin_date,
                     challenge_id, status_score, calories, protein, carbs, fat,
                     health_label, ai_note, tags_json, payload_json)
                VALUES (?, ?, ?, 'daily_checkin', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    post_id, request.user, visibility, title, body, day, day, request.challenge_id,
                    score["score"], summary.get("calories_consumed", 0), summary.get("protein", 0),
                    summary.get("carbs", 0), summary.get("fat", 0), health_label, ai_note,
                    json.dumps(tags[:6], ensure_ascii=False), json.dumps(payload, ensure_ascii=False),
                ),
            )
        conn.commit()
        row = _community_post_by_id(conn, post_id)
        return {"status": "ok", "post": _serialize_community_post(conn, row, request.user)}


@app.post("/v6/community/posts/{post_id}/reactions")
async def react_community_post_endpoint(post_id: str, request: CommunityReactionRequest):
    """Toggle a reaction on a community post."""
    reaction = request.reaction.strip() or "like"
    with tracking._get_conn() as conn:
        row = _community_post_by_id(conn, post_id)
        if not row:
            raise HTTPException(status_code=404, detail="没有找到这条动态。")
        existing = conn.execute(
            "SELECT id FROM community_reactions WHERE post_id = ? AND user = ? AND reaction = ?",
            (post_id, request.user, reaction),
        ).fetchone()
        if existing:
            conn.execute("DELETE FROM community_reactions WHERE id = ?", (existing["id"],))
        else:
            conn.execute(
                "INSERT OR IGNORE INTO community_reactions (id, post_id, user, reaction) VALUES (?, ?, ?, ?)",
                (uuid4().hex[:12], post_id, request.user, reaction),
            )
        conn.commit()
        row = _community_post_by_id(conn, post_id)
        return {"status": "ok", "post": _serialize_community_post(conn, row, request.user)}


@app.post("/v6/community/posts/{post_id}/comments")
async def comment_community_post_endpoint(post_id: str, request: CommunityCommentRequest):
    """Add a short comment to a community post."""
    body = request.body.strip()
    if not body:
        raise HTTPException(status_code=400, detail="Comment body is required")
    with tracking._get_conn() as conn:
        row = _community_post_by_id(conn, post_id)
        if not row:
            raise HTTPException(status_code=404, detail="没有找到这条动态。")
        comment_id = uuid4().hex[:12]
        conn.execute(
            "INSERT INTO community_comments (id, post_id, user, body) VALUES (?, ?, ?, ?)",
            (comment_id, post_id, request.user, body[:240]),
        )
        conn.commit()
        row = _community_post_by_id(conn, post_id)
        return {"status": "ok", "post": _serialize_community_post(conn, row, request.user)}


@app.post("/v6/community/posts/{post_id}/report")
async def report_community_post_endpoint(post_id: str, request: CommunityReportRequest):
    """Report or hide a community post for the current user."""
    with tracking._get_conn() as conn:
        row = _community_post_by_id(conn, post_id)
        if not row:
            raise HTTPException(status_code=404, detail="没有找到这条动态。")
        conn.execute(
            "INSERT OR IGNORE INTO community_reports (id, post_id, user, reason) VALUES (?, ?, ?, ?)",
            (uuid4().hex[:12], post_id, request.user, request.reason.strip()[:200]),
        )
        conn.commit()
    return {"status": "ok", "hidden": True}


@app.post("/v6/community/posts/{post_id}/bookmark")
async def bookmark_community_post_endpoint(post_id: str, request: CommunityReactionRequest):
    """Toggle a bookmark on a community post."""
    with tracking._get_conn() as conn:
        row = _community_post_by_id(conn, post_id)
        if not row:
            raise HTTPException(status_code=404, detail="没有找到这条动态。")
        existing = conn.execute(
            "SELECT id FROM community_bookmarks WHERE post_id = ? AND user = ?",
            (post_id, request.user),
        ).fetchone()
        if existing:
            conn.execute("DELETE FROM community_bookmarks WHERE id = ?", (existing["id"],))
        else:
            conn.execute(
                "INSERT OR IGNORE INTO community_bookmarks (id, post_id, user) VALUES (?, ?, ?)",
                (uuid4().hex[:12], post_id, request.user),
            )
        conn.commit()
        row = _community_post_by_id(conn, post_id)
        return {"status": "ok", "post": _serialize_community_post(conn, row, request.user)}


@app.post("/v6/community/posts/{post_id}/log-same-meal")
async def log_same_community_meal_endpoint(post_id: str, request: CommunityLogSameMealRequest):
    """Copy a shared meal snapshot into today's food log."""
    with tracking._get_conn() as conn:
        row = _community_post_by_id(conn, post_id)
        if not row:
            raise HTTPException(status_code=404, detail="没有找到这条动态。")
        foods_snapshot = _json_list(row["foods_json"])
    foods = [_food_from_snapshot(item) for item in foods_snapshot if isinstance(item, dict)]
    if not foods:
        raise HTTPException(status_code=400, detail="Post has no food snapshot")
    day = request.date or date.today().isoformat()
    saved = _save_foods_to_log(foods, day, request.meal_category)
    return {
        "status": "ok",
        "date": day,
        "saved": len(saved),
        "foods": saved,
        "daily_summary": _daily_summary_for_day(day).model_dump(),
    }


# ── /v6/reports ────────────────────────────────────────────────────

@app.get("/v6/reports/weekly")
async def weekly_report_endpoint(date_str: str | None = None):
    """Generate weekly nutrition report."""
    day = date_str or __import__("datetime").date.today().isoformat()
    dt = __import__("datetime").date.fromisoformat(day)
    start = (dt - __import__("datetime").timedelta(days=dt.weekday())).isoformat()
    end = (dt + __import__("datetime").timedelta(days=6 - dt.weekday())).isoformat()

    weights = tracking.get_weights(30)
    weights_in_week = [w for w in weights if start <= w.date <= end]
    steps_hist = tracking.get_step_history(30)
    steps_in_week = [s for s in steps_hist if start <= s["date"] <= end]

    return {
        "period": "weekly",
        "start": start,
        "end": end,
        "weight_change_kg": round(weights_in_week[-1].weight_kg - weights_in_week[0].weight_kg, 1) if len(weights_in_week) >= 2 else None,
        "total_steps": sum(s["steps"] for s in steps_in_week),
        "avg_steps_per_day": round(sum(s["steps"] for s in steps_in_week) / max(1, len(steps_in_week))),
        "days_tracked": len(steps_in_week),
    }


@app.get("/v6/reports/monthly")
async def monthly_report_endpoint(year: int | None = None, month: int | None = None):
    """Generate monthly nutrition report."""
    today = __import__("datetime").date.today()
    year = year or today.year
    month = month or today.month
    start = f"{year}-{month:02d}-01"
    if month == 12:
        end = f"{year}-12-31"
    else:
        import calendar
        end = f"{year}-{month:02d}-{calendar.monthrange(year, month)[1]}"

    weights = tracking.get_weights(365)
    weights_in_month = [w for w in weights if start <= w.date <= end]
    steps_hist = tracking.get_step_history(365)
    steps_in_month = [s for s in steps_hist if start <= s["date"] <= end]

    return {
        "period": "monthly",
        "year": year,
        "month": month,
        "start": start,
        "end": end,
        "weight_change_kg": round(weights_in_month[-1].weight_kg - weights_in_month[0].weight_kg, 1) if len(weights_in_month) >= 2 else None,
        "total_steps": sum(s["steps"] for s in steps_in_month),
        "avg_steps_per_day": round(sum(s["steps"] for s in steps_in_month) / max(1, len(steps_in_month))),
        "days_tracked": len(steps_in_month),
    }


# ── /v6/macro-goals ────────────────────────────────────────────────

class MacroGoalsRequest(BaseModel):
    daily_calories: float | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None
    fiber_g: float | None = None
    sugar_g: float | None = None
    sodium_mg: float | None = None
    water_ml: float | None = None
    meal_shares: dict[str, float] | None = None


@app.post("/v6/macro-goals")
async def save_macro_goals_endpoint(request: MacroGoalsRequest):
    """Save custom macro nutrient goals."""
    goals = {k: v for k, v in request.model_dump().items() if v is not None}
    numeric_limits = {
        "daily_calories": (1000, 6000), "protein_g": (0, 500),
        "carbs_g": (0, 1000), "fat_g": (0, 500), "fiber_g": (0, 200),
        "sugar_g": (0, 500), "sodium_mg": (0, 20000), "water_ml": (250, 10000),
    }
    for field, value in goals.items():
        if field == "meal_shares":
            continue
        low, high = numeric_limits[field]
        if not math.isfinite(value) or not low <= value <= high:
            raise HTTPException(status_code=400, detail=f"{field}超出合理范围")
    return tracking.save_macro_goals(goals)


@app.get("/v6/macro-goals")
async def get_macro_goals_endpoint():
    """Get custom macro nutrient goals."""
    goals = tracking.get_macro_goals()
    if not goals:
        return {"daily_calories": 2000, "protein_g": 50, "carbs_g": 250, "fat_g": 65, "fiber_g": 25, "sugar_g": 50, "sodium_mg": 2300, "water_ml": 2000, "meal_shares": {"breakfast": 0.25, "lunch": 0.35, "dinner": 0.30, "snack": 0.10}}
    return goals


# ── /v6/reminders ──────────────────────────────────────────────────

class ReminderItem(BaseModel):
    id: str | None = None
    meal_type: str = ""  # breakfast, lunch, dinner, snack, hydration, fasting, challenge
    time: str       # HH:MM
    enabled: bool = True
    category: str = "meal"
    title: str = ""
    target_id: str = ""
    days_of_week: str = ""
    interval_minutes: int = 60


class SaveRemindersRequest(BaseModel):
    reminders: list[ReminderItem]


@app.post("/v6/reminders")
async def save_reminders_endpoint(request: SaveRemindersRequest):
    """Save reminders for meals, hydration, fasting, logging, or challenges."""
    data = [
        {
            "id": r.id,
            "meal_type": r.meal_type,
            "time": r.time,
            "enabled": r.enabled,
            "category": r.category,
            "title": r.title,
            "target_id": r.target_id,
            "days_of_week": r.days_of_week,
            "interval_minutes": r.interval_minutes,
        }
        for r in request.reminders
    ]
    return {"reminders": tracking.save_reminders(data)}


@app.get("/v6/reminders")
async def get_reminders_endpoint():
    """Get saved reminders."""
    return {"reminders": tracking.get_reminders()}


# ── /v6/recipe/import (LLM-powered URL import) ────────────────────

class RecipeImportRequest(BaseModel):
    url: str


def _recipe_import_number(value) -> float:
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        for key in ("value", "amount", "calories"):
            if key in value:
                return _recipe_import_number(value.get(key))
        return 0.0
    text = str(value)
    match = re.search(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
    return float(match.group()) if match else 0.0


def _recipe_import_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return html.unescape(value).strip()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, dict):
        for key in ("text", "name", "description"):
            text = _recipe_import_text(value.get(key))
            if text:
                return text
    return ""


def _recipe_import_list(value) -> list:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _recipe_import_schema_types(node: dict) -> set[str]:
    raw = node.get("@type") or node.get("type") or ""
    values = raw if isinstance(raw, list) else [raw]
    return {str(value).lower() for value in values}


def _iter_recipe_jsonld_nodes(data):
    if isinstance(data, list):
        for item in data:
            yield from _iter_recipe_jsonld_nodes(item)
        return
    if not isinstance(data, dict):
        return
    yield data
    for key in ("@graph", "graph", "itemListElement"):
        nested = data.get(key)
        if nested is not None:
            yield from _iter_recipe_jsonld_nodes(nested)


def _recipe_import_instructions(value) -> list[str]:
    steps: list[str] = []
    for item in _recipe_import_list(value):
        if isinstance(item, dict):
            nested = item.get("itemListElement") or item.get("step")
            if nested is not None:
                steps.extend(_recipe_import_instructions(nested))
                continue
            text = _recipe_import_text(item)
        else:
            text = _recipe_import_text(item)
        if text:
            steps.append(re.sub(r"\s+", " ", text)[:220])
    return steps[:20]


def _recipe_import_duration_label(*values) -> str:
    for value in values:
        text = _recipe_import_text(value)
        if not text:
            continue
        iso = re.fullmatch(r"P(?:T)?(?:(\d+)H)?(?:(\d+)M)?", text, flags=re.I)
        if iso:
            minutes = int(iso.group(1) or 0) * 60 + int(iso.group(2) or 0)
            if minutes > 0:
                return f"{minutes}分钟"
        number = _recipe_import_number(text)
        if number > 0 and ("min" in text.lower() or "分钟" in text):
            return f"{int(round(number))}分钟"
        return text[:40]
    return ""


def _recipe_import_duration_minutes(value) -> int:
    text = _recipe_import_text(value)
    if not text:
        return 0
    iso = re.fullmatch(r"P(?:T)?(?:(\d+)H)?(?:(\d+)M)?", text, flags=re.I)
    if iso:
        return max(0, min(24 * 60, int(iso.group(1) or 0) * 60 + int(iso.group(2) or 0)))
    number = _recipe_import_number(text)
    if number <= 0:
        return 0
    lower = text.lower()
    if "hour" in lower or "小时" in text:
        return max(0, min(24 * 60, int(round(number * 60))))
    if "min" in lower or "分钟" in text:
        return max(0, min(24 * 60, int(round(number))))
    return 0


def _recipe_import_servings(value) -> int:
    values = _recipe_import_list(value)
    for item in values:
        number = _recipe_import_number(item)
        if number > 0:
            return max(1, min(48, int(round(number))))
    return 1


def _recipe_import_serving_size_label(*values) -> str:
    for value in values:
        text = _recipe_import_text(value)
        if not text:
            continue
        text = re.sub(r"\s+", " ", text).strip()
        text = re.sub(r"^\d+(?:\.\d+)?\s*", "", text).strip(" ：:-")
        replacements = {
            "servings": "份",
            "serving": "份",
            "portions": "份",
            "portion": "份",
            "bowls": "碗",
            "bowl": "碗",
            "cups": "杯",
            "cup": "杯",
            "pieces": "块",
            "piece": "块",
            "slices": "片",
            "slice": "片",
        }
        normalized = replacements.get(text.lower(), text)
        if normalized:
            if normalized in {"份", "碗", "杯", "块", "片"}:
                return f"1{normalized}"
            return normalized[:40]
    return "1份"


def _recipe_import_image_url(value) -> str:
    values = value if isinstance(value, list) else [value]
    for item in values:
        if isinstance(item, dict):
            candidate = item.get("url") or item.get("contentUrl") or item.get("@id")
        else:
            candidate = item
        text = str(candidate or "").strip()
        if text.lower().startswith(("http://", "https://")):
            return text[:600]
    return ""


def _extract_recipe_from_json_ld(page_text: str, source_url: str) -> dict | None:
    blocks = re.findall(
        r"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
        page_text or "",
        flags=re.I | re.S,
    )
    for block in blocks:
        raw = html.unescape(block).strip()
        raw = re.sub(r"^\s*<!--|-->\s*$", "", raw).strip()
        try:
            data = json.loads(raw)
        except Exception:
            continue
        for node in _iter_recipe_jsonld_nodes(data):
            if "recipe" not in _recipe_import_schema_types(node):
                continue
            ingredients = [
                _recipe_import_text(item)
                for item in _recipe_import_list(node.get("recipeIngredient"))
            ]
            ingredients = [item for item in ingredients if item][:80]
            title = _recipe_import_text(node.get("name"))
            if not title or not ingredients:
                continue
            nutrition = node.get("nutrition") if isinstance(node.get("nutrition"), dict) else {}
            prep_minutes = _recipe_import_duration_minutes(node.get("prepTime"))
            cook_minutes = _recipe_import_duration_minutes(node.get("cookTime"))
            total_minutes = _recipe_import_duration_minutes(node.get("totalTime"))
            inactive_minutes = cook_minutes
            if total_minutes > 0 and prep_minutes > 0:
                inactive_minutes = max(0, total_minutes - prep_minutes)
            return {
                "recipe_name": title[:100],
                "servings": _recipe_import_servings(node.get("recipeYield") or node.get("yield")),
                "serving_size_label": _recipe_import_serving_size_label(
                    nutrition.get("servingSize"),
                    node.get("recipeYield"),
                    node.get("yield"),
                ),
                "calories_per_serving": _recipe_import_number(nutrition.get("calories")),
                "protein_per_serving": _recipe_import_number(nutrition.get("proteinContent")),
                "carbs_per_serving": _recipe_import_number(nutrition.get("carbohydrateContent")),
                "fat_per_serving": _recipe_import_number(nutrition.get("fatContent")),
                "cooking_time": _recipe_import_duration_label(
                    node.get("totalTime"),
                    node.get("cookTime"),
                    node.get("prepTime"),
                ),
                "active_time_minutes": prep_minutes,
                "inactive_time_minutes": inactive_minutes,
                "ingredients": ingredients,
                "instructions": _recipe_import_instructions(node.get("recipeInstructions")),
                "source_url": source_url,
                "image_url": _recipe_import_image_url(node.get("image")),
                "import_source": "json_ld",
            }
    return None


def _recipe_import_plain_text(page_text: str) -> str:
    text = re.sub(r"<script[\s\S]*?</script>", " ", page_text or "", flags=re.I)
    text = re.sub(r"<style[\s\S]*?</style>", " ", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "\n", text)
    text = html.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()[:8000]


@app.post("/v6/recipe/import")
async def recipe_import_endpoint(request: RecipeImportRequest):
    """Import recipe from URL using structured Recipe metadata, then LLM fallback."""
    from urllib.parse import urlparse

    clean_url = (request.url or "").strip()
    parsed = urlparse(clean_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="请输入有效的 http/https 食谱链接。")

    # Fetch URL content
    import httpx
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            resp = await client.get(clean_url, headers={"User-Agent": "Mozilla/5.0"})
            resp.raise_for_status()
            page_text = resp.text
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"读取食谱链接失败：{e}")

    structured = _extract_recipe_from_json_ld(page_text, clean_url)
    if structured:
        return structured

    if describe_meal is None or describe_meal.provider is None:
        raise HTTPException(status_code=503, detail="网页未包含标准食谱结构，且暂未配置食谱导入模型。")

    plain_text = _recipe_import_plain_text(page_text)

    prompt = f"""从以下网页内容中提取食谱信息。返回JSON:

{plain_text}

返回JSON格式:
{{"recipe_name":"菜名","servings":4,"serving_size_label":"1份","calories_per_serving":0,"protein_per_serving":0,"carbs_per_serving":0,"fat_per_serving":0,"cooking_time":"30分钟","active_time_minutes":15,"inactive_time_minutes":15,"ingredients":["食材1 200g","食材2 100g"],"instructions":["步骤1","步骤2"],"source_url":"{clean_url}","image_url":"https://example.com/recipe.jpg"}}
如果无法识别食谱则返回{{"error":"无法识别食谱"}}"""

    try:
        response_text = await describe_meal.provider.raw_completion(
            "你是专业厨师和营养师。从网页文本中提取食谱。返回JSON。",
            prompt, max_tokens=1536)
        import json, re
        return json.loads(re.sub(r'```(?:json)?\s*', '', response_text.strip()).strip())
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"食谱导入失败：{e}")


# ── /v6/foods (cross-day food history) ────────────────────────────

def _food_to_saved_meal_payload(food: Food) -> dict:
    if hasattr(food, "model_dump"):
        data = food.model_dump()
    else:
        data = food.dict()
    processing = data.get("processing_level")
    if hasattr(processing, "value"):
        data["processing_level"] = processing.value
    return data


def _upsert_saved_meal_by_title(
    meal_id: str,
    title: str,
    foods: list[dict],
    source: str = "user",
    meal_category: str = "",
    image_url: str = "",
    note: str | None = None,
    instructions: list[str] | None = None,
    favorite: bool | None = None,
    allow_create: bool = True,
) -> dict:
    clean_title = str(title or "").strip() or "我的餐品"
    existing = tracking.find_saved_meal_event_by_title(clean_title, exclude_id=meal_id)
    if existing:
        updated = tracking.update_saved_meal_event(
            existing["id"],
            clean_title,
            foods,
            meal_category=meal_category or existing.get("meal_category") or "",
            image_url=image_url or existing.get("image_url") or "",
            note=note if note is not None else existing.get("note") or "",
            instructions=instructions if instructions is not None else existing.get("instructions") or [],
            favorite=favorite if favorite is not None else bool(existing.get("favorite")),
        )
        if meal_id != existing["id"]:
            tracking.delete_saved_meal_event(meal_id)
        return updated or existing
    current = tracking.get_saved_meal_event(meal_id)
    if current:
        return tracking.update_saved_meal_event(
            meal_id,
            clean_title,
            foods,
            meal_category=meal_category or current.get("meal_category") or "",
            image_url=image_url or current.get("image_url") or "",
            note=note if note is not None else current.get("note") or "",
            instructions=instructions if instructions is not None else current.get("instructions") or [],
            favorite=favorite if favorite is not None else bool(current.get("favorite")),
        ) or current
    if not allow_create:
        return {}
    return tracking.save_saved_meal_event(
        meal_id,
        clean_title,
        foods,
        source=source,
        meal_category=meal_category,
        image_url=image_url,
        note=note or "",
        instructions=instructions or [],
        favorite=bool(favorite),
    )


def _upsert_saved_food_by_name(
    food_id: str,
    food_payload: dict,
    source: str = "user",
    allow_create: bool = True,
) -> dict:
    clean_name = str((food_payload or {}).get("name") or "").strip() or "我的食物"
    existing = tracking.find_saved_food_event_by_name(clean_name, exclude_id=food_id)
    if existing:
        updated = tracking.update_saved_food_event(existing["id"], clean_name, food_payload)
        if food_id != existing["id"]:
            tracking.delete_saved_food_event(food_id)
        return updated or existing
    current = tracking.get_saved_food_event(food_id)
    if current:
        return tracking.update_saved_food_event(food_id, clean_name, food_payload) or current
    if not allow_create:
        return {}
    return tracking.save_saved_food_event(food_id, clean_name, food_payload, source=source)


@app.get("/v6/saved-meals")
async def saved_meals_endpoint(
    limit: int = 20,
    query: str = "",
    sort: str = "created",
    offset: int = 0,
    meal_category: str = "",
    favorite: bool = False,
):
    """List reusable saved meals."""
    return {
        "meals": tracking.list_saved_meal_events(
            limit,
            query=query,
            sort=sort,
            offset=offset,
            meal_category=meal_category,
            favorite=favorite,
        )
    }


@app.post("/v6/saved-meals")
async def create_saved_meal_endpoint(request: SavedMealRequest):
    """Save a reusable meal made of one or more food items."""
    if not request.foods:
        raise HTTPException(status_code=400, detail="餐品至少需要 1 个食物。")
    meal_id = f"meal_{uuid4().hex[:16]}"
    foods = [_food_to_saved_meal_payload(food) for food in request.foods]
    title = request.title.strip() or " + ".join(food.name for food in request.foods[:2])
    if len(request.foods) > 2:
        title = f"{title}等 {len(request.foods)} 项"
    meal = _upsert_saved_meal_by_title(
        meal_id,
        title,
        foods,
        source=request.source or "user",
        meal_category=request.meal_category or "",
        image_url=request.image_url or "",
        note=request.note if request.note is not None else None,
        instructions=request.instructions if request.instructions is not None else None,
        favorite=request.favorite,
        allow_create=True,
    )
    return {"status": "ok", "meal": meal}


@app.put("/v6/saved-meals/{meal_id}")
async def update_saved_meal_endpoint(meal_id: str, request: SavedMealRequest):
    """Update a reusable saved meal's title and food list."""
    if not request.foods:
        raise HTTPException(status_code=400, detail="餐品至少需要 1 个食物。")
    foods = [_food_to_saved_meal_payload(food) for food in request.foods]
    title = request.title.strip() or " + ".join(food.name for food in request.foods[:2])
    if len(request.foods) > 2:
        title = f"{title}等 {len(request.foods)} 项"
    meal = _upsert_saved_meal_by_title(
        meal_id,
        title,
        foods,
        source=request.source or "user",
        meal_category=request.meal_category or "",
        image_url=request.image_url or "",
        note=request.note if request.note is not None else None,
        instructions=request.instructions,
        favorite=request.favorite,
        allow_create=False,
    )
    if not meal:
        raise HTTPException(status_code=404, detail="没有找到这个餐品。")
    return {"status": "ok", "meal": meal}


@app.post("/v6/saved-meals/{meal_id}/favorite")
async def toggle_saved_meal_favorite_endpoint(meal_id: str):
    """Toggle a saved meal favorite flag for the meal library."""
    meal = tracking.get_saved_meal_event(meal_id)
    if not meal:
        raise HTTPException(status_code=404, detail="没有找到这个餐品。")
    updated = tracking.update_saved_meal_event(
        meal_id,
        meal.get("title") or "我的餐品",
        meal.get("foods") or [],
        meal_category=meal.get("meal_category") or "",
        image_url=meal.get("image_url") or "",
        note=meal.get("note") or "",
        instructions=meal.get("instructions") or [],
        favorite=not bool(meal.get("favorite")),
    )
    if not updated:
        raise HTTPException(status_code=404, detail="没有找到这个餐品。")
    return {"status": "ok", "meal_id": meal_id, "meal": updated}


@app.post("/v6/saved-meals/{meal_id}/log")
async def log_saved_meal_endpoint(meal_id: str, request: SavedMealLogRequest):
    """Copy a reusable saved meal into today's food log."""
    meal = tracking.get_saved_meal_event(meal_id)
    if not meal:
        raise HTTPException(status_code=404, detail="没有找到这个餐品。")
    multiplier = max(0.05, min(20.0, float(request.portion_multiplier or 1)))
    foods = [_scaled_saved_meal_food(Food(**food), multiplier) for food in meal.get("foods", [])]
    if not foods:
        raise HTTPException(status_code=400, detail="这个餐品没有可记录的食物。")
    day = request.date or __import__("datetime").date.today().isoformat()
    meal_category = request.meal_category or meal.get("meal_category") or ""
    saved = _save_foods_to_log(foods, day, meal_category=meal_category, group_title=meal.get("title") or "我的餐品")
    tracking.mark_saved_meal_logged(meal_id)
    summary = _daily_summary_for_day(day)
    return {
        "status": "ok",
        "date": day,
        "meal_id": meal_id,
        "saved": len(saved),
        "foods": saved,
        "daily_summary": summary.model_dump(),
    }


@app.delete("/v6/saved-meals/{meal_id}")
async def delete_saved_meal_endpoint(meal_id: str):
    deleted = tracking.delete_saved_meal_event(meal_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="没有找到这个餐品。")
    return {"status": "ok", "deleted": True, "meal_id": meal_id}


@app.get("/v6/saved-foods")
async def saved_foods_endpoint(limit: int = 50, query: str = "", sort: str = "created", offset: int = 0):
    """List reusable saved foods."""
    return {"foods": tracking.list_saved_food_events(limit, query=query, sort=sort, offset=offset)}


@app.post("/v6/saved-foods")
async def create_saved_food_endpoint(request: SavedFoodRequest):
    """Save one reusable food item from search or history."""
    food_id = f"food_{uuid4().hex[:16]}"
    food_payload = _food_to_saved_meal_payload(request.food)
    food = _upsert_saved_food_by_name(
        food_id,
        food_payload,
        source=request.source or "user",
        allow_create=True,
    )
    return {"status": "ok", "food": food}


@app.put("/v6/saved-foods/{food_id}")
async def update_saved_food_endpoint(food_id: str, request: SavedFoodRequest):
    """Update a reusable saved food item."""
    food_payload = _food_to_saved_meal_payload(request.food)
    food = _upsert_saved_food_by_name(
        food_id,
        food_payload,
        source=request.source or "user",
        allow_create=False,
    )
    if not food:
        raise HTTPException(status_code=404, detail="没有找到这个食物。")
    return {"status": "ok", "food": food}


@app.post("/v6/saved-foods/{food_id}/log")
async def log_saved_food_endpoint(food_id: str, request: SavedFoodLogRequest):
    """Copy a reusable saved food into today's food log."""
    saved_food = tracking.get_saved_food_event(food_id)
    if not saved_food:
        raise HTTPException(status_code=404, detail="没有找到这个食物。")
    food_payload = saved_food.get("food") or {}
    if not food_payload:
        raise HTTPException(status_code=400, detail="这个食物没有可记录的营养数据。")
    multiplier = max(0.05, min(20.0, float(request.portion_multiplier or 1)))
    food = _scaled_saved_meal_food(Food(**food_payload), multiplier)
    day = request.date or __import__("datetime").date.today().isoformat()
    saved = _save_foods_to_log(
        [food],
        day,
        meal_category=request.meal_category or "",
        group_title=saved_food.get("name") or food.name,
    )
    tracking.mark_saved_food_logged(food_id)
    summary = _daily_summary_for_day(day)
    return {
        "status": "ok",
        "date": day,
        "food_id": food_id,
        "saved": len(saved),
        "foods": saved,
        "daily_summary": summary.model_dump(),
    }


@app.delete("/v6/saved-foods/{food_id}")
async def delete_saved_food_endpoint(food_id: str):
    deleted = tracking.delete_saved_food_event(food_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="没有找到这个食物。")
    return {"status": "ok", "deleted": True, "food_id": food_id}


@app.post("/v6/food-log")
async def save_food_log_endpoint(request: FoodLogRequest):
    """Persist analyzed or searched foods into daily food history."""
    day = request.date or __import__("datetime").date.today().isoformat()
    for index, food in enumerate(request.foods, start=1):
        ratio = float(food.consumed_ratio or 0)
        if not math.isfinite(ratio) or not 0 <= ratio <= 1:
            raise HTTPException(status_code=400, detail=f"第 {index} 项食物的食用比例必须在 0–1 之间")
    consumed_foods = [food for food in request.foods if float(food.consumed_ratio or 0) > 0]
    if not consumed_foods:
        raise HTTPException(status_code=400, detail="没有实际吃下的食物，无需保存这餐")
    request_id = str(request.request_id or "").strip()
    if len(request_id) > 128:
        raise HTTPException(status_code=400, detail="记录请求编号过长")
    request_payload = request.model_dump(mode="json", exclude={"request_id"})
    request_fingerprint = hashlib.sha256(
        json.dumps(
            request_payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    group_id = None
    idempotency_key = None
    if request_id:
        request_digest = hashlib.sha256(request_id.encode("utf-8")).hexdigest()
        group_id = f"foodlog_{request_digest[:24]}"
        idempotency_key = f"food_log:{request_id}"
    saved, already_logged = _save_foods_to_log_result(
        consumed_foods,
        day,
        request.meal_category,
        upload_group_id=group_id,
        image_base64=request.image_base64,
        group_title=request.group_title,
        idempotency_key=idempotency_key,
        request_fingerprint=request_fingerprint,
    )
    summary = _daily_summary_for_day(day)
    decision = None
    if consumed_foods and not already_logged:
        decision = decision_service.score_foods(
            consumed_foods,
            summary=summary,
            fasting_status=_get_fasting_status(),
            preferences=tracking.get_user_preferences(),
            source="food_log",
            event_type="after_log",
            persist=True,
        )
    return {
        "status": "ok",
        "date": day,
        "already_logged": already_logged,
        "saved": len(saved),
        "foods": saved,
        "daily_summary": summary.model_dump(),
        "decision": decision,
    }


@app.post("/v6/food-log/leftovers")
async def adjust_food_log_for_leftovers_endpoint(request: FoodLogLeftoverRequest):
    """Adjust a saved meal by subtracting foods detected in an after-meal leftovers photo."""
    leftover_foods = await _analyze_leftover_foods(request.image_base64)
    return _apply_leftovers_to_log(
        request.upload_group_id,
        leftover_foods,
        request.image_base64,
        request.date,
    )


@app.post("/v6/food-log/leftovers/estimate")
async def estimate_food_log_leftovers_endpoint(request: FoodLogLeftoverRequest):
    """Estimate per-food remaining percentages from a leftovers photo before applying."""
    return await _estimate_leftover_percentages(
        request.upload_group_id,
        request.image_base64,
        request.date,
        request.description,
    )


@app.post("/v6/food-log/leftovers/apply")
async def apply_food_log_leftovers_endpoint(request: FoodLogLeftoverApplyRequest):
    """Apply user-confirmed per-food remaining percentages to a saved meal."""
    return _apply_leftover_percentages_to_log(
        request.upload_group_id,
        request.items,
        request.image_base64,
        request.date,
    )


@app.delete("/v6/food-log")
async def delete_food_log_endpoint(request: FoodLogDeleteRequest):
    """Delete persisted food log rows and return the refreshed day summary."""
    deleted, day = _delete_foods_from_log(request.ids, request.upload_group_id)
    summary = _daily_summary_for_day(request.date or day)
    return {
        "status": "ok",
        "date": request.date or day,
        "deleted": deleted,
        "daily_summary": summary.model_dump(),
    }


@app.post("/v6/food-log/delete")
async def delete_food_log_post_endpoint(request: FoodLogDeleteRequest):
    """Compatibility wrapper for clients that do not send bodies with DELETE."""
    return await delete_food_log_endpoint(request)


@app.post("/v6/food-log/{log_id}/portion")
async def adjust_food_log_portion_endpoint(log_id: int, request: FoodLogPortionRequest):
    """Adjust one persisted food row to a selected eaten portion ratio."""
    return _adjust_food_log_portion(log_id, request.consumed_ratio, request.date)


@app.post("/v6/food-log/{log_id}/move")
async def move_food_log_meal_category_endpoint(log_id: int, request: FoodLogMoveRequest):
    """Move one persisted food row to another meal category."""
    return _move_food_log_meal_category(log_id, request.meal_category, request.date)


@app.get("/v6/foods")
async def get_foods_endpoint(date: str | None = None, days: int = 1):
    """Get foods logged on specific date(s)."""
    day = date or __import__("datetime").date.today().isoformat()
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        if days > 1:
            from datetime import timedelta as _td
            start = (__import__("datetime").date.fromisoformat(day) - _td(days=days - 1)).isoformat()
            rows = conn.execute(
                "SELECT * FROM food_log_history WHERE date >= ? AND date <= ? ORDER BY date DESC, logged_at DESC LIMIT 200",
                (start, day)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM food_log_history WHERE date = ? ORDER BY logged_at DESC LIMIT 100", (day,)
            ).fetchall()
    return {"foods": [_food_log_row_payload(r) for r in rows], "date": day}


# ── /v6/streak ────────────────────────────────────────────────────

@app.get("/v6/streak")
async def get_streak_endpoint():
    """Calculate current streak of consecutive days with food logged."""
    today = __import__("datetime").date.today().isoformat()
    with food_db._get_conn() as conn:
        _ensure_food_log_table(conn)
        active = conn.execute(
            "SELECT 1 FROM food_log_history WHERE date = ? LIMIT 1", (today,)
        ).fetchone() is not None
    return {"streak_days": _calculate_food_streak(), "is_active_today": active}


# ── /v6/progress-photos ───────────────────────────────────────────

class ProgressPhotoRequest(BaseModel):
    image_base64: str
    date: str | None = None
    weight_kg: float | None = None
    notes: str = ""


@app.post("/v6/progress-photos")
async def add_progress_photo_endpoint(request: ProgressPhotoRequest):
    """Upload a progress photo."""
    day = request.date or __import__("datetime").date.today().isoformat()
    pid = __import__("uuid").uuid4().hex[:12]
    with tracking._get_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS progress_photos (
                id TEXT PRIMARY KEY, date TEXT, image_base64 TEXT,
                weight_kg REAL, notes TEXT DEFAULT '',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        conn.execute(
            "INSERT INTO progress_photos (id, date, image_base64, weight_kg, notes) VALUES (?, ?, ?, ?, ?)",
            (pid, day, request.image_base64, request.weight_kg, request.notes),
        )
        conn.commit()
    return {"id": pid, "date": day, "status": "ok"}


@app.get("/v6/progress-photos")
async def get_progress_photos_endpoint(limit: int = 20, include_images: bool = False):
    """Get progress photos history."""
    tracking._init_db()
    with tracking._get_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS progress_photos (
                id TEXT PRIMARY KEY, date TEXT, image_base64 TEXT,
                weight_kg REAL, notes TEXT DEFAULT '',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        columns = "id, date, weight_kg, notes, created_at"
        if include_images:
            columns += ", image_base64"
        rows = conn.execute(
            f"SELECT {columns} FROM progress_photos ORDER BY date DESC LIMIT ?",
            (limit,)
        ).fetchall()
    return {"photos": [dict(r) for r in rows]}


# ── /v6/copy-yesterday ────────────────────────────────────────────

@app.post("/v6/copy-yesterday")
async def copy_yesterday_endpoint():
    """Copy yesterday's foods to today."""
    from datetime import date as _d, timedelta as _td
    yesterday = (_d.today() - _td(days=1)).isoformat()
    with food_db._get_conn() as conn:
        rows = conn.execute(
            "SELECT * FROM food_log_history WHERE date = ? ORDER BY logged_at LIMIT 100", (yesterday,)
        ).fetchall()
    if not rows:
        raise HTTPException(status_code=404, detail="No foods logged yesterday")
    # Save copies for today
    today_str = _d.today().isoformat()
    copied = []
    for r in rows:
        food = _food_from_log_row(r)
        saved = _save_foods_to_log(
            [food],
            today_str,
            meal_category=r["meal_category"] or "",
            group_title=r["upload_group_title"] or food.name,
        )
        copied.append({"name": food.name, "calories": food.calories, "foods": saved})
    return {"status": "ok", "copied": len(copied), "foods": copied, "from": yesterday}


# ── Cal AI 26.27.0 IPA compatibility routes ───────────────────────

async def _compat_request_payload(request: Request) -> dict:
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    return payload if isinstance(payload, dict) else {"value": payload}


def _compat_response(route: str, payload: dict | None = None, **data):
    response_data = data.pop("data", None)
    if response_data is None:
        response_data = dict(data)
    body = {
        "status": "ok",
        "success": True,
        "route": route,
        "data": response_data,
        "remoteConfigExperiment": None,
        "statsigExperiment": None,
    }
    if payload:
        body["request"] = payload
    body.update(data)
    return body


async def _generic_compat_endpoint(request: Request):
    payload = await _compat_request_payload(request)
    path = request.url.path
    if path == "/v6/customer/marketingPreference":
        enabled = bool(payload.get("enabled", payload.get("marketingPreference", False)))
        data = {
            "marketingPreference": enabled,
            "marketing_preference": enabled,
            "emailMarketing": enabled,
            "pushMarketing": enabled,
            "enabled": enabled,
            "accepted": True,
        }
        return _compat_response(path, payload, data=data, **data)
    if path == "/v6/customExercise":
        exercise = {
            "id": payload.get("id") or uuid4().hex[:12],
            "name": payload.get("name") or payload.get("exercise") or "Exercise",
            "calories": float(payload.get("calories") or payload.get("calories_burned") or 0),
            "duration_minutes": payload.get("duration_minutes") or payload.get("durationMinutes"),
            "date": payload.get("date") or date.today().isoformat(),
        }
        return _compat_response(path, payload, data=exercise, exercise=exercise)
    if path == "/v6/log-conversion":
        data = {"logged": True, "conversionLogged": True, "transactionId": payload.get("transaction_id") or payload.get("transactionId") or ""}
        return _compat_response(path, payload, data=data, **data)
    if path == "/v6/queueLiveActivityRefresh":
        data = {"queued": True, "refreshQueued": True}
        return _compat_response(path, payload, data=data, **data)
    if path == "/v6/onboarding/generatePromoCode":
        code = payload.get("promoCode") or payload.get("promo_code") or f"CAL{uuid4().hex[:6].upper()}"
        data = {"promoCode": code, "promo_code": code, "code": code}
        return _compat_response(path, payload, data=data, **data)
    if path == "/v6/onboarding/linkPromoCode":
        data = {"linked": True, "promoCode": payload.get("promoCode") or payload.get("promo_code") or payload.get("code") or ""}
        return _compat_response(path, payload, data=data, **data)
    return _compat_response(path, payload)


async def _scan_image_stream_compat(request: Request):
    payload = await _compat_request_payload(request)
    image_base64 = (
        payload.get("image_base64")
        or payload.get("imageBase64")
        or payload.get("image")
        or payload.get("base64")
        or payload.get("photo")
    )
    meal_category = payload.get("meal_category") or payload.get("mealCategory")
    scan_request = DescribeMealRequest(
        source=ScanSource.image_scan,
        image_base64=image_base64,
        text=payload.get("text") or payload.get("description"),
        meal_category=meal_category,
        depth_metadata=payload.get("depth_metadata") or payload.get("depthMetadata"),
        capture_metadata=payload.get("capture_metadata") or payload.get("captureMetadata"),
    )
    if describe_meal is not None and image_base64:
        return await describe_meal_stream_endpoint(scan_request)

    async def event_stream():
        yield _sse_payload({"stage": "started", "message": "scan accepted"})
        yield _sse_payload({
            "stage": "final",
            "foods": [],
            "health_score": None,
            "description": "",
            "estimation_metadata": {
                "source": "scanImage.compat",
                "reason": "no_model_or_image",
            },
        })

    return StreamingResponse(event_stream(), media_type="text/event-stream")


async def _recipes_feed_compat(request: Request):
    payload = await _compat_request_payload(request)
    data = {
        "recipes": [],
        "items": [],
        "feed": [],
        "nextCursor": None,
        "next_cursor": None,
        "hasMore": False,
    }
    return _compat_response("/v6/recipes/feed", payload, data=data, **data)


async def _subscription_compat(request: Request):
    payload = await _compat_request_payload(request)
    now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    subscription = {
        "active": False,
        "isSubscribed": False,
        "isActive": False,
        "isCancelled": False,
        "isDuringTrial": False,
        "status": "none",
        "entitlements": [],
        "provider": "local",
        "platform": payload.get("platform") or "ios",
        "subscriptionId": payload.get("subscriptionId") or payload.get("subscription_id") or "",
        "subscription_id": payload.get("subscription_id") or payload.get("subscriptionId") or "",
        "productId": payload.get("productId") or payload.get("product_id") or "",
        "trial": False,
        "trialEnd": None,
        "price": 0,
        "currency": "USD",
        "currencySymbol": "$",
        "period": "unknown",
        "startedAt": None,
        "currentPeriodStart": None,
        "currentPeriodEnd": None,
        "cancelAt": None,
        "cancelAtPeriodEnd": False,
        "email": payload.get("email") or "",
        "managementUrl": "",
        "cancelUrl": "",
        "updatedAt": now,
    }
    return _compat_response(
        request.url.path,
        payload,
        data=subscription,
        subscription=subscription,
        isSubscribed=False,
        active=False,
    )


async def _customer_auth_compat(request: Request):
    payload = await _compat_request_payload(request)
    customer = {
        "id": payload.get("email") or payload.get("phone") or "local-user",
        "email": payload.get("email") or "",
        "phone": payload.get("phone") or "",
        "isNewUser": False,
        "is_new_user": False,
    }
    data = {
        "customer": customer,
        "user": customer,
        "token": "local-dev-token",
        "authToken": "local-dev-token",
        "codeSent": True,
        "sent": True,
    }
    return _compat_response(
        request.url.path,
        payload,
        data=data,
        **data,
    )


async def _customer_report_compat(request: Request):
    payload = await _compat_request_payload(request)
    report_id = payload.get("id") or payload.get("report_id") or payload.get("reportId") or uuid4().hex[:12]
    data = {
        "id": report_id,
        "report_id": report_id,
        "reportId": report_id,
        "reportStatus": "queued",
        "report_status": "queued",
        "url": "",
        "createdAt": datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }
    return _compat_response(request.url.path, payload, data=data, **data)


async def _referral_compat(request: Request):
    payload = await _compat_request_payload(request)
    code = payload.get("code") or payload.get("referralCode") or "CALAI"
    invite = ""  # No referral service is configured in the open-source app.
    data = {
        "code": code,
        "referral_code": code,
        "referralCode": code,
        "invite_link": invite,
        "inviteLink": invite,
        "referrals": [],
        "count": 0,
        "totalReferrals": 0,
        "total_referrals": 0,
        "payoutPending": False,
        "canCashOut": False,
        "payout_available": False,
        "payoutAvailable": False,
        "balance": 0,
        "pendingBalance": 0,
    }
    return _compat_response(
        request.url.path,
        payload,
        data=data,
        **data,
    )


async def _family_sharing_compat(request: Request):
    payload = await _compat_request_payload(request)
    user_id = payload.get("userId") or payload.get("user_id") or payload.get("requesterId") or "local-user"
    family_plan_id = payload.get("familyPlanId") or payload.get("family_plan_id") or ""
    invite_code = payload.get("inviteCode") or payload.get("invite_code") or ""
    app_account_token = payload.get("appAccountToken") or payload.get("app_account_token") or ""
    now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    social_profile = {
        "userId": user_id,
        "username": payload.get("username") or "local_user",
        "firstName": payload.get("firstName") or "",
        "lastName": payload.get("lastName") or "",
        "profileImageUrl": payload.get("profileImageUrl") or payload.get("avatar_url") or "",
        "fcmToken": payload.get("fcmToken") or "",
    }
    family_plan = {
        "familyPlanId": family_plan_id,
        "inviteCode": invite_code,
        "maxMembers": int(_floatish(payload.get("maxMembers"), 5)),
        "currentMemberCount": 0,
        "organizerId": payload.get("organizerId") or "",
        "organizerName": payload.get("organizerName") or "",
        "organizerUsername": payload.get("organizerUsername") or "",
        "organizerProfileImage": payload.get("organizerProfileImage") or "",
        "createdAt": now,
        "updatedAt": now,
        "isActive": False,
        "appAccountToken": app_account_token,
    }
    family = {
        "status": "inactive",
        "hasFamilyPlan": False,
        "familyPlan": family_plan,
        "members": [],
        "familyPlanId": family_plan_id,
        "inviteCode": invite_code,
        "invite_link": "",
        "inviteLink": "",
        "role": "participant",
        "socialProfile": social_profile,
    }
    return _compat_response(
        request.url.path,
        payload,
        data=family,
        family=family,
        familyPlan=family_plan,
        members=[],
        inviteLink="",
        familyPlanId=family_plan_id,
        appAccountToken=app_account_token,
        account_token=app_account_token,
        accountToken=app_account_token,
    )


async def _social_profile_compat(request: Request):
    payload = await _compat_request_payload(request)
    user_id = payload.get("userId") or payload.get("user_id") or payload.get("username") or "local-user"
    first_name = payload.get("firstName") or ""
    last_name = payload.get("lastName") or ""
    username = payload.get("username") or "local_user"
    profile_image_url = payload.get("profileImageUrl") or payload.get("profile_image_url") or payload.get("avatar_url") or ""
    profile = {
        "id": user_id,
        "userId": user_id,
        "username": username,
        "display_name": payload.get("display_name") or "Cal AI 用户",
        "displayName": payload.get("display_name") or "Cal AI 用户",
        "firstName": first_name,
        "lastName": last_name,
        "fullName": " ".join(part for part in (first_name, last_name) if part).strip(),
        "avatar_url": profile_image_url,
        "profileImageUrl": profile_image_url,
        "profileImageURL": profile_image_url,
        "profileImageBase64": "",
        "currentStreak": 0,
        "longestStreak": 0,
        "unlockedBadges": [],
    }
    return _compat_response(request.url.path, payload, data=profile, profile=profile, socialProfile=profile)


async def _social_collection_compat(request: Request):
    payload = await _compat_request_payload(request)
    now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    data = {
        "items": [],
        "groups": [],
        "notifications": [],
        "messages": [],
        "posts": [],
        "activity": [],
        "members": [],
        "recentPosts": [],
        "mutualGroups": [],
        "unread_count": 0,
        "unreadCount": 0,
        "count": 0,
        "totalCount": 0,
        "hasMore": False,
        "nextCursor": None,
        "lastUpdated": now,
        "memberCount": 0,
        "canNudge": False,
        "canRemove": False,
    }
    return _compat_response(
        request.url.path,
        payload,
        data=data,
        **data,
    )


async def _social_mutation_compat(request: Request):
    payload = await _compat_request_payload(request)
    item_id = payload.get("id") or payload.get("post_id") or payload.get("postId") or payload.get("group_id") or payload.get("groupId") or uuid4().hex[:12]
    data = {"id": item_id, "success": True, "deleted": "delete" in request.url.path, "updated": True}
    return _compat_response(
        request.url.path,
        payload,
        data=data,
        **data,
    )


async def _username_suggestions_compat(request: Request):
    payload = await _compat_request_payload(request)
    base = payload.get("username") or request.query_params.get("username") or "cal_user"
    safe = re.sub(r"[^A-Za-z0-9_]", "_", str(base)).strip("_") or "cal_user"
    data = {"valid": True, "available": True, "suggestions": [safe, f"{safe}_ai", f"{safe}_fit"]}
    return _compat_response(request.url.path, payload, data=data, **data)


async def _stripe_management_compat(request: Request):
    payload = await _compat_request_payload(request)
    path = request.url.path
    url = ""  # No subscription management service is configured.
    subscription = {
        "active": False,
        "isActive": False,
        "isCancelled": "cancel" in path,
        "isDuringTrial": False,
        "status": "cancelled" if "cancel" in path else "none",
        "subscriptionId": payload.get("subscriptionId") or payload.get("subscription_id") or "",
        "productId": payload.get("productId") or payload.get("product_id") or "",
        "platform": payload.get("platform") or "ios",
        "provider": payload.get("provider") or "stripe",
        "trial": False,
        "trialEnd": None,
        "price": 0,
        "currency": "USD",
        "currencySymbol": "$",
        "period": "unknown",
        "startedAt": None,
        "currentPeriodStart": None,
        "currentPeriodEnd": None,
        "cancelAt": None,
        "cancelAtPeriodEnd": False,
        "email": payload.get("email") or "",
    }
    data = {
        "url": url,
        "portal_url": url,
        "portalUrl": url,
        "managementPortalUrl": url,
        "subscription": subscription,
        "active": False,
        "isActive": False,
    }
    return _compat_response(
        path,
        payload,
        data=data,
        **data,
    )


_CUSTOMER_COMPAT_ROUTES = {
    "/v6/customer/sendCode": _customer_auth_compat,
    "/v6/customer/signIn": _customer_auth_compat,
    "/v6/customer/marketingPreference": _generic_compat_endpoint,
    "/v6/customer/report": _customer_report_compat,
    "/v6/customer/report/tune": _customer_report_compat,
    "/v6/customer/report/vote": _customer_report_compat,
}

_FAMILY_COMPAT_ROUTES = {
    "/v6/family-sharing/add-member": _family_sharing_compat,
    "/v6/family-sharing/create-family-plan": _family_sharing_compat,
    "/v6/family-sharing/get-app-account-token": _family_sharing_compat,
    "/v6/family-sharing/get-family-metadata": _family_sharing_compat,
    "/v6/family-sharing/get-family-status": _family_sharing_compat,
    "/v6/family-sharing/get-invite-link": _family_sharing_compat,
    "/v6/family-sharing/leave-family-plan": _family_sharing_compat,
    "/v6/family-sharing/reconcile-family-plan": _family_sharing_compat,
    "/v6/family-sharing/remove-member": _family_sharing_compat,
}

_SOCIAL_COLLECTION_ROUTES = {
    "/v6/social/all-groups-unread-activity",
    "/v6/social/get-social-profile",
    "/v6/social/group-leaderboard",
    "/v6/social/notifications",
    "/v6/social/notifications/unread-count",
    "/v6/social/notifications/unread-count-by-group",
    "/v6/social/user-violation-status",
}

_SOCIAL_MUTATION_ROUTES = {
    "/v6/social/add-reaction-to-chat-reply",
    "/v6/social/add-reaction-to-comment",
    "/v6/social/add-reaction-to-comment-reply",
    "/v6/social/add-reaction-to-message",
    "/v6/social/appeal",
    "/v6/social/create-chat-reply",
    "/v6/social/create-comment",
    "/v6/social/create-comment-reply",
    "/v6/social/create-group",
    "/v6/social/create-message",
    "/v6/social/create-post",
    "/v6/social/create-posts-to-multiple-groups",
    "/v6/social/create-social-profile",
    "/v6/social/delete-chat-reply",
    "/v6/social/delete-comment",
    "/v6/social/delete-comment-reply",
    "/v6/social/delete-group",
    "/v6/social/delete-message",
    "/v6/social/delete-post",
    "/v6/social/delete-post-by-food-id",
    "/v6/social/edit-group",
    "/v6/social/join-group",
    "/v6/social/kick-from-group",
    "/v6/social/leave-group",
    "/v6/social/mark-group-as-read",
    "/v6/social/notifications/delete",
    "/v6/social/notifications/read",
    "/v6/social/notifications/read-all",
    "/v6/social/nudge-user",
    "/v6/social/remove-reaction-from-chat-reply",
    "/v6/social/remove-reaction-from-comment",
    "/v6/social/remove-reaction-from-comment-reply",
    "/v6/social/remove-reaction-from-message",
    "/v6/social/report-message",
    "/v6/social/toggle-post-reaction",
    "/v6/social/update-post-by-food-id",
    "/v6/social/update-social-profile",
}

_STRIPE_COMPAT_ROUTES = {
    "/v6/stripe/cancel-subscription": _stripe_management_compat,
    "/v6/stripe/get-management-portal": _stripe_management_compat,
    "/v6/stripe/get-prelinked-sub-info": _subscription_compat,
    "/v6/stripe/get-web-sub-info": _subscription_compat,
    "/v6/stripe/link-subscription": _stripe_management_compat,
    "/v6/stripe/renew-subscription": _stripe_management_compat,
}


def _register_compat_route(path: str, endpoint, methods: list[str] | None = None):
    endpoint.__name__ = f"compat_{re.sub(r'[^0-9A-Za-z_]+', '_', path).strip('_')}"
    app.add_api_route(path, endpoint, methods=methods or ["GET", "POST"])


for _path, _endpoint in _CUSTOMER_COMPAT_ROUTES.items():
    _register_compat_route(_path, _endpoint, ["GET", "POST", "PUT", "PATCH"])

for _path, _endpoint in _FAMILY_COMPAT_ROUTES.items():
    _register_compat_route(_path, _endpoint, ["GET", "POST"])

for _path in _SOCIAL_COLLECTION_ROUTES:
    _endpoint = _social_profile_compat if _path == "/v6/social/get-social-profile" else _social_collection_compat
    _register_compat_route(_path, _endpoint, ["GET", "POST"])

for _path in _SOCIAL_MUTATION_ROUTES:
    _register_compat_route(_path, _social_mutation_compat, ["GET", "POST", "PUT", "PATCH", "DELETE"])

for _path, _endpoint in _STRIPE_COMPAT_ROUTES.items():
    _register_compat_route(_path, _endpoint, ["GET", "POST"])

_register_compat_route("/v6/customExercise", _generic_compat_endpoint, ["GET", "POST"])
_register_compat_route("/v6/getSubscription", _subscription_compat, ["GET", "POST"])
_register_compat_route("/v6/getReferralsData", _referral_compat, ["GET", "POST"])
_register_compat_route("/v6/log-conversion", _generic_compat_endpoint, ["POST"])
_register_compat_route("/v6/onboarding/generatePromoCode", _generic_compat_endpoint, ["POST"])
_register_compat_route("/v6/onboarding/linkPromoCode", _generic_compat_endpoint, ["POST"])
_register_compat_route("/v6/processReferral", _referral_compat, ["POST"])
_register_compat_route("/v6/queueLiveActivityRefresh", _generic_compat_endpoint, ["POST"])
_register_compat_route("/v6/recipes/feed", _recipes_feed_compat, ["GET", "POST"])
_register_compat_route("/v6/report/generate", _customer_report_compat, ["POST"])
_register_compat_route("/v6/requestReferralPayout", _referral_compat, ["POST"])
_register_compat_route("/v6/scanImage/stream", _scan_image_stream_compat, ["POST"])
_register_compat_route("/v6/scanImage/preview/stream", _scan_image_stream_compat, ["POST"])
_register_compat_route("/v6/social/username-suggestions", _username_suggestions_compat, ["GET", "POST"])
_register_compat_route("/v6/social/validate-username", _username_suggestions_compat, ["GET", "POST"])


@app.api_route("/v6/{compat_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def v6_compat_catch_all(compat_path: str, request: Request):
    """Last-resort compatibility response for dynamically composed Cal AI API paths."""
    payload = await _compat_request_payload(request)
    path = f"/v6/{compat_path}".rstrip("/")
    data = {
        "path": path,
        "items": [],
        "results": [],
        "notifications": [],
        "unreadCount": 0,
        "count": 0,
        "accepted": True,
    }
    return _compat_response(path, payload, data=data, **data)


# ── Health check ──────────────────────────────────────────────────

@app.get("/health")
async def health_check():
    return {"status": "ok", "version": "0.1.0"}


# ── Main ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=int(os.getenv("PORT", "8001")), reload=True)
