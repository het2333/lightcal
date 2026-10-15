"""Tracking service — exercise, weight, water, daily summaries.

Stores data in SQLite, served via API.
"""

import json
import hashlib
import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

from models.tracking import (
    Exercise, WeightLog, WaterLog, HydrationLog, DrinkPreset,
    DailySummary, MealPlan, Insight, StepLog,
)
from models.food import Food, Meal
from models.rules import Goal

DATA_DIR = Path(__file__).parent.parent / "data"
DB_PATH = DATA_DIR / "tracking.db"


DEFAULT_DRINK_PRESETS = [
    {"id": "water", "drink_type": "water", "name": "水", "default_amount_ml": 250, "hydration_factor": 1.0, "color": "#2f80ed", "icon": "drop"},
    {"id": "sparkling_water", "drink_type": "sparkling_water", "name": "气泡水", "default_amount_ml": 250, "hydration_factor": 1.0, "color": "#22a6f2", "icon": "bubbles"},
    {"id": "coffee", "drink_type": "coffee", "name": "咖啡", "default_amount_ml": 240, "hydration_factor": 0.85, "caffeine_mg": 95, "color": "#795548", "icon": "coffee"},
    {"id": "latte", "drink_type": "latte", "name": "拿铁", "default_amount_ml": 350, "hydration_factor": 0.75, "caffeine_mg": 75, "sugar_g": 8, "calories": 160, "protein_g": 8, "carbs_g": 18, "fat_g": 6, "color": "#a06a42", "icon": "coffee"},
    {"id": "tea", "drink_type": "tea", "name": "茶", "default_amount_ml": 240, "hydration_factor": 0.9, "caffeine_mg": 35, "color": "#2f9e44", "icon": "leaf"},
    {"id": "milk", "drink_type": "milk", "name": "牛奶", "default_amount_ml": 240, "hydration_factor": 0.9, "sugar_g": 12, "calories": 120, "protein_g": 8, "carbs_g": 12, "fat_g": 4.5, "color": "#8ecae6", "icon": "milk"},
    {"id": "milk_tea", "drink_type": "milk_tea", "name": "奶茶", "default_amount_ml": 350, "hydration_factor": 0.7, "caffeine_mg": 45, "sugar_g": 32, "calories": 230, "protein_g": 4, "carbs_g": 38, "fat_g": 7, "color": "#b7794f", "icon": "cup.and.saucer"},
    {"id": "juice", "drink_type": "juice", "name": "果汁", "default_amount_ml": 240, "hydration_factor": 0.8, "sugar_g": 22, "calories": 110, "protein_g": 1, "carbs_g": 26, "fat_g": 0.2, "color": "#ff9f1c", "icon": "citrus"},
    {"id": "energy_drink", "drink_type": "energy_drink", "name": "能量饮料", "default_amount_ml": 250, "hydration_factor": 0.65, "caffeine_mg": 80, "sugar_g": 27, "calories": 120, "protein_g": 0, "carbs_g": 29, "fat_g": 0, "color": "#f03e3e", "icon": "zap"},
    {"id": "alcohol", "drink_type": "alcohol", "name": "酒精饮品", "default_amount_ml": 150, "hydration_factor": 0.0, "alcohol_g": 14, "sugar_g": 2, "calories": 125, "protein_g": 0, "carbs_g": 3, "fat_g": 0, "color": "#9c36b5", "icon": "wine"},
]


DEFAULT_CHALLENGES = [
    {"id": "photo_checkin_7", "title": "7天拍照记录", "description": "每天至少拍照记录一餐，先把饮食看清楚。", "challenge_type": "food_photo_checkin", "duration_days": 7, "target_value": 1},
    {"id": "hydrate_5", "title": "5天饮水达标", "description": "连续 5 天达到有效饮水目标。", "challenge_type": "hydration_goal", "duration_days": 5, "target_value": 1},
    {"id": "daily_status_7", "title": "7天状态分 80+", "description": "连续 7 天把今日状态分保持在 80 分以上。", "challenge_type": "daily_status_score", "duration_days": 7, "target_value": 80},
    {"id": "sleep_7h_7", "title": "7天睡够7小时", "description": "连续 7 天记录睡眠，并达到至少 7 小时。", "challenge_type": "sleep_goal", "duration_days": 7, "target_value": 7},
    {"id": "steps_7", "title": "7天多走一点", "description": "连续 7 天步数达到目标。", "challenge_type": "steps_goal", "duration_days": 7, "target_value": 8000},
    {"id": "vegetable_7", "title": "一周蔬菜打卡", "description": "连续 7 天至少记录一份明显蔬菜。", "challenge_type": "vegetable_goal", "duration_days": 7, "target_value": 1},
    {"id": "low_processed_7", "title": "一周少油少加工", "description": "连续 7 天减少油炸、饮料和超加工食物。", "challenge_type": "low_processed_day", "duration_days": 7, "target_value": 1},
    {"id": "fasting_completed_5", "title": "5次轻断食完成", "description": "完成 5 天轻断食目标，建立稳定节奏。", "challenge_type": "fasting_completed", "duration_days": 7, "target_value": 1},
    {"id": "protein_breakfast_14", "title": "14天高蛋白早餐", "description": "早餐至少记录 20g 蛋白质。", "challenge_type": "protein_breakfast", "duration_days": 14, "target_value": 20},
]

CHALLENGE_ID_ALIASES = {
    "hydrate_7": "hydrate_5",
}


class TrackingService:
    """Manages exercise, weight, water, and daily summaries."""

    def __init__(self):
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row
        return conn

    def _init_measurements_table(self):
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS body_measurements (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date TEXT, weight_kg REAL, waist_cm REAL, hips_cm REAL,
                    chest_cm REAL, arm_cm REAL, thigh_cm REAL,
                    body_fat_pct REAL, notes TEXT DEFAULT ''
                )
            """)

    def _init_db(self):
        with self._get_conn() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS exercises (
                    id TEXT PRIMARY KEY, name TEXT, duration_minutes INTEGER,
                    intensity TEXT DEFAULT 'moderate', calories_burned REAL DEFAULT 0,
                    date TEXT, notes TEXT DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS weight_logs (
                    id TEXT PRIMARY KEY, weight_kg REAL, date TEXT, notes TEXT DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS water_logs (
                    id TEXT PRIMARY KEY, amount_ml REAL, date TEXT
                );
                CREATE TABLE IF NOT EXISTS hydration_logs (
                    id TEXT PRIMARY KEY,
                    drink_type TEXT DEFAULT 'water',
                    amount_ml REAL DEFAULT 0,
                    hydration_factor REAL DEFAULT 1,
                    effective_ml REAL DEFAULT 0,
                    caffeine_mg REAL DEFAULT 0,
                    alcohol_g REAL DEFAULT 0,
                    sugar_g REAL DEFAULT 0,
                    calories REAL DEFAULT 0,
                    protein_g REAL DEFAULT 0,
                    carbs_g REAL DEFAULT 0,
                    fat_g REAL DEFAULT 0,
                    source TEXT DEFAULT 'manual',
                    note TEXT DEFAULT '',
                    external_id TEXT DEFAULT '',
                    date TEXT DEFAULT '',
                    logged_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS drink_presets (
                    id TEXT PRIMARY KEY,
                    drink_type TEXT NOT NULL,
                    name TEXT NOT NULL,
                    default_amount_ml REAL DEFAULT 250,
                    hydration_factor REAL DEFAULT 1,
                    caffeine_mg REAL DEFAULT 0,
                    alcohol_g REAL DEFAULT 0,
                    sugar_g REAL DEFAULT 0,
                    calories REAL DEFAULT 0,
                    protein_g REAL DEFAULT 0,
                    carbs_g REAL DEFAULT 0,
                    fat_g REAL DEFAULT 0,
                    color TEXT DEFAULT '#2f80ed',
                    icon TEXT DEFAULT 'drop',
                    custom INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS insights (
                    id TEXT PRIMARY KEY, date TEXT, title TEXT, body TEXT,
                    type TEXT DEFAULT 'general', icon TEXT DEFAULT '💡'
                );
                CREATE TABLE IF NOT EXISTS diary_notes (
                    date TEXT PRIMARY KEY,
                    note TEXT DEFAULT '',
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS step_logs (
                    id TEXT PRIMARY KEY, date TEXT NOT NULL,
                    steps INTEGER DEFAULT 0, source TEXT DEFAULT 'manual',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS sleep_logs (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    duration_hours REAL DEFAULT 0,
                    quality INTEGER DEFAULT 3,
                    start_at TEXT DEFAULT '',
                    end_at TEXT DEFAULT '',
                    source TEXT DEFAULT 'manual',
                    note TEXT DEFAULT '',
                    external_id TEXT DEFAULT '',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS friend_requests (
                    id TEXT PRIMARY KEY, from_user TEXT NOT NULL,
                    to_user TEXT NOT NULL, status TEXT DEFAULT 'pending',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS friendships (
                    id TEXT PRIMARY KEY, user_a TEXT NOT NULL,
                    user_b TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS reminders (
                    id TEXT PRIMARY KEY, meal_type TEXT NOT NULL,
                    time TEXT NOT NULL, enabled INTEGER DEFAULT 1,
                    category TEXT DEFAULT 'meal', title TEXT DEFAULT '',
                    target_id TEXT DEFAULT '', days_of_week TEXT DEFAULT '',
                    interval_minutes INTEGER DEFAULT 60
                );
                CREATE TABLE IF NOT EXISTS challenges (
                    id TEXT PRIMARY KEY,
                    template_id TEXT DEFAULT '',
                    title TEXT NOT NULL,
                    description TEXT DEFAULT '',
                    challenge_type TEXT NOT NULL,
                    duration_days INTEGER DEFAULT 7,
                    target_value REAL DEFAULT 0,
                    start_date TEXT DEFAULT '',
                    end_date TEXT DEFAULT '',
                    status TEXT DEFAULT 'available',
                    reward_points INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS habit_events (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    source TEXT DEFAULT '',
                    amount REAL DEFAULT 0,
                    payload_json TEXT DEFAULT '{}',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS health_imports (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    record_type TEXT NOT NULL,
                    date TEXT DEFAULT '',
                    payload_json TEXT DEFAULT '{}',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(source, external_id)
                );
                CREATE TABLE IF NOT EXISTS api_mutation_idempotency (
                    idempotency_key TEXT PRIMARY KEY,
                    request_fingerprint TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS macro_goals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    daily_calories REAL,
                    protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
                    sugar_g REAL, sodium_mg REAL, water_ml REAL,
                    meal_shares_json TEXT DEFAULT '{}',
                    active INTEGER DEFAULT 1, created_at TEXT DEFAULT CURRENT_DATE
                );
                CREATE TABLE IF NOT EXISTS user_preferences (
                    id TEXT PRIMARY KEY DEFAULT 'default',
                    data_json TEXT NOT NULL,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS recommendation_events (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    meal_type TEXT DEFAULT '',
                    source TEXT DEFAULT 'rules',
                    recommendation_json TEXT NOT NULL,
                    logged INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    logged_at TEXT
                );
                CREATE TABLE IF NOT EXISTS delivery_order_drafts (
                    id TEXT PRIMARY KEY,
                    recommendation_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    meal_type TEXT DEFAULT '',
                    provider TEXT DEFAULT 'auto',
                    search_query TEXT DEFAULT '',
                    order_note TEXT DEFAULT '',
                    draft_json TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS coach_messages (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    payload_json TEXT DEFAULT '{}',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS decision_events (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    event_type TEXT DEFAULT 'meal_score',
                    source TEXT DEFAULT 'rules',
                    score INTEGER DEFAULT 0,
                    title TEXT DEFAULT '',
                    payload_json TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS recipe_suggestion_events (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    source TEXT DEFAULT 'rules',
                    recipe_json TEXT NOT NULL,
                    logged INTEGER DEFAULT 0,
                    logged_count INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    logged_at TEXT
                );
                CREATE TABLE IF NOT EXISTS saved_meal_events (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    source TEXT DEFAULT 'user',
                    meal_category TEXT DEFAULT '',
                    image_url TEXT DEFAULT '',
                    note TEXT DEFAULT '',
                    instructions_json TEXT DEFAULT '[]',
                    favorite INTEGER DEFAULT 0,
                    foods_json TEXT NOT NULL,
                    logged_count INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    logged_at TEXT
                );
                CREATE TABLE IF NOT EXISTS saved_food_events (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    source TEXT DEFAULT 'user',
                    food_json TEXT NOT NULL,
                    logged_count INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    logged_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_exercises_date ON exercises(date);
                CREATE INDEX IF NOT EXISTS idx_weight_date ON weight_logs(date);
                CREATE INDEX IF NOT EXISTS idx_water_date ON water_logs(date);
                CREATE INDEX IF NOT EXISTS idx_hydration_date ON hydration_logs(date);
                CREATE INDEX IF NOT EXISTS idx_hydration_external ON hydration_logs(source, external_id);
                CREATE INDEX IF NOT EXISTS idx_steps_date ON step_logs(date);
                CREATE INDEX IF NOT EXISTS idx_sleep_date ON sleep_logs(date);
                CREATE INDEX IF NOT EXISTS idx_sleep_external ON sleep_logs(source, external_id);
                CREATE INDEX IF NOT EXISTS idx_habit_events_date ON habit_events(date);
                CREATE INDEX IF NOT EXISTS idx_api_mutation_created ON api_mutation_idempotency(created_at);
                CREATE INDEX IF NOT EXISTS idx_challenges_status ON challenges(status);
                CREATE INDEX IF NOT EXISTS idx_recommendations_date ON recommendation_events(date);
                CREATE INDEX IF NOT EXISTS idx_delivery_order_drafts_date ON delivery_order_drafts(date);
                CREATE INDEX IF NOT EXISTS idx_recipe_suggestions_date ON recipe_suggestion_events(date);
                CREATE INDEX IF NOT EXISTS idx_saved_meals_created ON saved_meal_events(created_at);
                CREATE INDEX IF NOT EXISTS idx_saved_foods_created ON saved_food_events(created_at);
                CREATE INDEX IF NOT EXISTS idx_coach_messages_date ON coach_messages(date);
                CREATE INDEX IF NOT EXISTS idx_decision_events_date ON decision_events(date);
                CREATE INDEX IF NOT EXISTS idx_friend_requests_from ON friend_requests(from_user);
                CREATE INDEX IF NOT EXISTS idx_friend_requests_to ON friend_requests(to_user);
            """)
            self._ensure_columns(conn, "reminders", {
                "category": "TEXT DEFAULT 'meal'",
                "title": "TEXT DEFAULT ''",
                "target_id": "TEXT DEFAULT ''",
                "days_of_week": "TEXT DEFAULT ''",
                "interval_minutes": "INTEGER DEFAULT 60",
            })
            self._ensure_columns(conn, "macro_goals", {
                "daily_calories": "REAL",
                "meal_shares_json": "TEXT DEFAULT '{}'",
            })
            self._ensure_columns(conn, "recipe_suggestion_events", {
                "logged_count": "INTEGER DEFAULT 0",
            })
            self._ensure_columns(conn, "saved_meal_events", {
                "logged_count": "INTEGER DEFAULT 0",
                "note": "TEXT DEFAULT ''",
                "instructions_json": "TEXT DEFAULT '[]'",
                "favorite": "INTEGER DEFAULT 0",
            })
            self._ensure_columns(conn, "saved_food_events", {
                "logged_count": "INTEGER DEFAULT 0",
            })
            self._ensure_columns(conn, "hydration_logs", {
                "protein_g": "REAL DEFAULT 0",
                "carbs_g": "REAL DEFAULT 0",
                "fat_g": "REAL DEFAULT 0",
            })
            self._ensure_columns(conn, "drink_presets", {
                "protein_g": "REAL DEFAULT 0",
                "carbs_g": "REAL DEFAULT 0",
                "fat_g": "REAL DEFAULT 0",
            })
            self._seed_drink_presets(conn)
            self._seed_challenges(conn)
        self.dedupe_recipe_suggestion_events_by_title()
        self.dedupe_saved_meal_events_by_title()
        self.dedupe_saved_food_events_by_name()

    @staticmethod
    def _ensure_columns(conn: sqlite3.Connection, table: str, columns: dict[str, str]):
        existing = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
        for name, definition in columns.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")

    def reserve_mutation(self, operation: str, request_id: str, request_fingerprint: str) -> tuple[str, bool]:
        """Reserve a stable record id for a retryable client mutation."""
        key = f"{operation}:{request_id}"
        record_id = hashlib.sha256(key.encode("utf-8")).hexdigest()[:24]
        with self._get_conn() as conn:
            conn.execute("BEGIN IMMEDIATE")
            existing = conn.execute(
                """SELECT request_fingerprint, record_id
                   FROM api_mutation_idempotency WHERE idempotency_key = ?""",
                (key,),
            ).fetchone()
            if existing:
                if str(existing["request_fingerprint"] or "") != request_fingerprint:
                    conn.rollback()
                    raise ValueError("这个记录请求编号已用于其他内容，请重新提交。")
                conn.commit()
                return str(existing["record_id"]), True
            conn.execute(
                """INSERT INTO api_mutation_idempotency
                   (idempotency_key, request_fingerprint, record_id)
                   VALUES (?, ?, ?)""",
                (key, request_fingerprint, record_id),
            )
            conn.commit()
        return record_id, False

    @staticmethod
    def _seed_drink_presets(conn: sqlite3.Connection):
        for preset in DEFAULT_DRINK_PRESETS:
            conn.execute(
                """INSERT INTO drink_presets
                   (id, drink_type, name, default_amount_ml, hydration_factor, caffeine_mg,
                    alcohol_g, sugar_g, calories, protein_g, carbs_g, fat_g, color, icon, custom)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                     drink_type = excluded.drink_type,
                     name = excluded.name,
                     default_amount_ml = excluded.default_amount_ml,
                     hydration_factor = excluded.hydration_factor,
                     caffeine_mg = excluded.caffeine_mg,
                     alcohol_g = excluded.alcohol_g,
                     sugar_g = excluded.sugar_g,
                     calories = excluded.calories,
                     protein_g = excluded.protein_g,
                     carbs_g = excluded.carbs_g,
                     fat_g = excluded.fat_g,
                     color = excluded.color,
                     icon = excluded.icon,
                     custom = excluded.custom""",
                (
                    preset["id"], preset["drink_type"], preset["name"],
                    preset.get("default_amount_ml", 250), preset.get("hydration_factor", 1),
                    preset.get("caffeine_mg", 0), preset.get("alcohol_g", 0),
                    preset.get("sugar_g", 0), preset.get("calories", 0),
                    preset.get("protein_g", 0), preset.get("carbs_g", 0), preset.get("fat_g", 0),
                    preset.get("color", "#2f80ed"), preset.get("icon", "drop"),
                    1 if preset.get("custom") else 0,
                ),
            )

    @staticmethod
    def _seed_challenges(conn: sqlite3.Connection):
        for challenge in DEFAULT_CHALLENGES:
            conn.execute(
                """INSERT INTO challenges
                   (id, template_id, title, description, challenge_type, duration_days,
                    target_value, status, reward_points)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'available', ?)
                   ON CONFLICT(id) DO UPDATE SET
                     template_id = excluded.template_id,
                     title = excluded.title,
                     description = excluded.description,
                     challenge_type = excluded.challenge_type,
                     duration_days = excluded.duration_days,
                     target_value = excluded.target_value,
                     reward_points = excluded.reward_points,
                     updated_at = CURRENT_TIMESTAMP
                   WHERE challenges.template_id IS NOT excluded.template_id
                      OR challenges.title IS NOT excluded.title
                      OR challenges.description IS NOT excluded.description
                      OR challenges.challenge_type IS NOT excluded.challenge_type
                      OR challenges.duration_days IS NOT excluded.duration_days
                      OR challenges.target_value IS NOT excluded.target_value
                      OR challenges.reward_points IS NOT excluded.reward_points""",
                (
                    challenge["id"], challenge["id"], challenge["title"],
                    challenge["description"], challenge["challenge_type"],
                    challenge["duration_days"], challenge["target_value"],
                    int(challenge["duration_days"]) * 10,
                ),
            )

    # ── Exercise ──────────────────────────────────────────────────

    def add_exercise(self, ex: Exercise) -> Exercise:
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR IGNORE INTO exercises
                   (id, name, duration_minutes, intensity, calories_burned, date, notes)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (ex.id, ex.name, ex.duration_minutes, ex.intensity.value,
                 ex.calories_burned, ex.date, ex.notes),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM exercises WHERE id = ?", (ex.id,)).fetchone()
        return Exercise(**dict(row)) if row else ex

    def get_exercises(self, day: str | None = None) -> list[Exercise]:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM exercises WHERE date = ? ORDER BY id DESC", (day,)
            ).fetchall()
        return [Exercise(**dict(r)) for r in rows]

    # ── Weight ────────────────────────────────────────────────────

    def add_weight(self, w: WeightLog) -> WeightLog:
        with self._get_conn() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO weight_logs (id, weight_kg, date, notes) VALUES (?, ?, ?, ?)",
                (w.id, w.weight_kg, w.date, w.notes),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM weight_logs WHERE id = ?", (w.id,)).fetchone()
        return WeightLog(**dict(row)) if row else w

    def get_weights(self, days: int = 30) -> list[WeightLog]:
        since = (date.today() - timedelta(days=days)).isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM weight_logs WHERE date >= ? ORDER BY date",
                (since,),
            ).fetchall()
        return [WeightLog(**dict(r)) for r in rows]

    # ── Water ─────────────────────────────────────────────────────

    def add_water(self, w: WaterLog) -> WaterLog:
        with self._get_conn() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO water_logs (id, amount_ml, date) VALUES (?, ?, ?)",
                (w.id, w.amount_ml, w.date),
            )
            conn.commit()
        self.add_hydration({
            "id": w.id,
            "drink_type": "water",
            "amount_ml": w.amount_ml,
            "hydration_factor": 1,
            "effective_ml": w.amount_ml,
            "source": "manual",
            "date": w.date,
        })
        return w

    def get_water(self, day: str | None = None) -> float:
        day = day or date.today().isoformat()
        hydration = self.get_hydration_summary(day)
        if hydration["drink_count"] > 0:
            return hydration["hydration_effective_ml"]
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT COALESCE(SUM(amount_ml), 0) as total FROM water_logs WHERE date = ?",
                (day,),
            ).fetchone()
        return row["total"] if row else 0

    # ── Hydration / other drinks ───────────────────────────────────

    def get_drink_presets(self) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM drink_presets ORDER BY custom ASC, name COLLATE NOCASE ASC"
            ).fetchall()
        return [self._row_to_preset(r) for r in rows]

    def add_drink_preset(self, preset: dict) -> dict:
        preset_id = preset.get("id") or __import__("uuid").uuid4().hex[:12]
        drink_type = (preset.get("drink_type") or preset_id).strip().lower().replace(" ", "_")
        name = (preset.get("name") or drink_type.replace("_", " ").title()).strip()
        payload = {
            "id": preset_id,
            "drink_type": drink_type,
            "name": name,
            "default_amount_ml": float(preset.get("default_amount_ml") or 250),
            "hydration_factor": float(preset.get("hydration_factor") if preset.get("hydration_factor") is not None else 1),
            "caffeine_mg": float(preset.get("caffeine_mg") or 0),
            "alcohol_g": float(preset.get("alcohol_g") or 0),
            "sugar_g": float(preset.get("sugar_g") or 0),
            "calories": float(preset.get("calories") or 0),
            "protein_g": float(preset.get("protein_g") or 0),
            "carbs_g": float(preset.get("carbs_g") or 0),
            "fat_g": float(preset.get("fat_g") or 0),
            "color": preset.get("color") or "#2f80ed",
            "icon": preset.get("icon") or "drop",
            "custom": bool(preset.get("custom", True)),
        }
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO drink_presets
                   (id, drink_type, name, default_amount_ml, hydration_factor, caffeine_mg,
                    alcohol_g, sugar_g, calories, protein_g, carbs_g, fat_g, color, icon, custom)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    payload["id"], payload["drink_type"], payload["name"],
                    payload["default_amount_ml"], payload["hydration_factor"],
                    payload["caffeine_mg"], payload["alcohol_g"], payload["sugar_g"],
                    payload["calories"], payload["protein_g"], payload["carbs_g"], payload["fat_g"],
                    payload["color"], payload["icon"],
                    1 if payload["custom"] else 0,
                ),
            )
            conn.commit()
        return payload

    def _preset_for_type(self, drink_type: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM drink_presets WHERE drink_type = ? OR id = ? ORDER BY custom ASC LIMIT 1",
                (drink_type, drink_type),
            ).fetchone()
        return self._row_to_preset(row) if row else None

    @staticmethod
    def _row_to_preset(row) -> dict:
        return {
            "id": row["id"],
            "drink_type": row["drink_type"],
            "name": row["name"],
            "default_amount_ml": row["default_amount_ml"],
            "hydration_factor": row["hydration_factor"],
            "caffeine_mg": row["caffeine_mg"],
            "alcohol_g": row["alcohol_g"],
            "sugar_g": row["sugar_g"],
            "calories": row["calories"],
            "protein_g": row["protein_g"],
            "carbs_g": row["carbs_g"],
            "fat_g": row["fat_g"],
            "color": row["color"],
            "icon": row["icon"],
            "custom": bool(row["custom"]),
        }

    def add_hydration(self, data: dict) -> dict:
        drink_type = (data.get("drink_type") or "water").strip().lower().replace(" ", "_")
        amount_ml = max(0, float(data.get("amount_ml") or 0))
        day = data.get("date") or date.today().isoformat()
        source = data.get("source") or "manual"
        external_id = data.get("external_id") or ""
        explicit_id = str(data.get("id") or "").strip()
        if explicit_id:
            with self._get_conn() as conn:
                existing = conn.execute(
                    "SELECT * FROM hydration_logs WHERE id = ?", (explicit_id,),
                ).fetchone()
            if existing:
                return self._row_to_hydration(existing)
        if external_id:
            existing = self._get_hydration_by_external(source, external_id)
            if existing:
                return existing

        preset = self._preset_for_type(drink_type) or {}
        hydration_factor = float(data.get("hydration_factor") if data.get("hydration_factor") is not None else preset.get("hydration_factor", 1))
        scale = amount_ml / max(float(preset.get("default_amount_ml") or amount_ml or 1), 1)
        caffeine_mg = float(data.get("caffeine_mg") if data.get("caffeine_mg") is not None else float(preset.get("caffeine_mg") or 0) * scale)
        alcohol_g = float(data.get("alcohol_g") if data.get("alcohol_g") is not None else float(preset.get("alcohol_g") or 0) * scale)
        sugar_g = float(data.get("sugar_g") if data.get("sugar_g") is not None else float(preset.get("sugar_g") or 0) * scale)
        calories = float(data.get("calories") if data.get("calories") is not None else float(preset.get("calories") or 0) * scale)
        protein_g = float(data.get("protein_g") if data.get("protein_g") is not None else float(preset.get("protein_g") or 0) * scale)
        carbs_g = float(data.get("carbs_g") if data.get("carbs_g") is not None else float(preset.get("carbs_g") or 0) * scale)
        fat_g = float(data.get("fat_g") if data.get("fat_g") is not None else float(preset.get("fat_g") or 0) * scale)
        effective_ml = float(data.get("effective_ml") if data.get("effective_ml") is not None else amount_ml * hydration_factor)
        log_id = explicit_id or __import__("uuid").uuid4().hex[:12]
        logged_at = data.get("logged_at") or datetime.now().isoformat(timespec="seconds")
        payload = {
            "id": log_id,
            "drink_type": drink_type,
            "amount_ml": amount_ml,
            "hydration_factor": hydration_factor,
            "effective_ml": effective_ml,
            "caffeine_mg": caffeine_mg,
            "alcohol_g": alcohol_g,
            "sugar_g": sugar_g,
            "calories": calories,
            "protein_g": protein_g,
            "carbs_g": carbs_g,
            "fat_g": fat_g,
            "source": source,
            "note": data.get("note") or "",
            "external_id": external_id,
            "date": day,
            "logged_at": logged_at,
        }
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR IGNORE INTO hydration_logs
                   (id, drink_type, amount_ml, hydration_factor, effective_ml, caffeine_mg,
                    alcohol_g, sugar_g, calories, protein_g, carbs_g, fat_g,
                    source, note, external_id, date, logged_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    payload["id"], payload["drink_type"], payload["amount_ml"],
                    payload["hydration_factor"], payload["effective_ml"], payload["caffeine_mg"],
                    payload["alcohol_g"], payload["sugar_g"], payload["calories"],
                    payload["protein_g"], payload["carbs_g"], payload["fat_g"], payload["source"],
                    payload["note"], payload["external_id"], payload["date"], payload["logged_at"],
                ),
            )
            conn.execute(
                """INSERT INTO habit_events
                   (id, date, event_type, source, amount, payload_json)
                   VALUES (?, ?, 'hydration', ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                       date = excluded.date,
                       source = excluded.source,
                       amount = excluded.amount,
                       payload_json = excluded.payload_json""",
                (
                    f"hydration_{log_id}", day, source, effective_ml,
                    json.dumps({"drink_type": drink_type, "amount_ml": amount_ml}, ensure_ascii=False),
                ),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM hydration_logs WHERE id = ?", (log_id,),
            ).fetchone()
        return self._row_to_hydration(row) if row else payload

    def _get_hydration_by_external(self, source: str, external_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM hydration_logs WHERE source = ? AND external_id = ? LIMIT 1",
                (source, external_id),
            ).fetchone()
        return self._row_to_hydration(row) if row else None

    @staticmethod
    def _row_to_hydration(row) -> dict:
        return {
            "id": row["id"],
            "drink_type": row["drink_type"],
            "amount_ml": row["amount_ml"],
            "hydration_factor": row["hydration_factor"],
            "effective_ml": row["effective_ml"],
            "caffeine_mg": row["caffeine_mg"],
            "alcohol_g": row["alcohol_g"],
            "sugar_g": row["sugar_g"],
            "calories": row["calories"],
            "protein_g": row["protein_g"],
            "carbs_g": row["carbs_g"],
            "fat_g": row["fat_g"],
            "source": row["source"],
            "note": row["note"],
            "external_id": row["external_id"],
            "date": row["date"],
            "logged_at": row["logged_at"],
        }

    def get_hydration_logs(self, day: str | None = None, days: int = 1) -> list[dict]:
        day = day or date.today().isoformat()
        if days <= 1:
            query = "SELECT * FROM hydration_logs WHERE date = ? ORDER BY logged_at DESC, id DESC"
            params = (day,)
        else:
            since = (datetime.fromisoformat(day) - timedelta(days=days - 1)).date().isoformat()
            query = "SELECT * FROM hydration_logs WHERE date >= ? AND date <= ? ORDER BY date DESC, logged_at DESC"
            params = (since, day)
        with self._get_conn() as conn:
            rows = conn.execute(query, params).fetchall()
        return [self._row_to_hydration(r) for r in rows]

    def delete_hydration_logs(self, ids: list[str] | None = None, day: str | None = None) -> int:
        ids = [str(i) for i in (ids or []) if str(i)]
        with self._get_conn() as conn:
            if ids:
                placeholders = ",".join("?" for _ in ids)
                cur = conn.execute(f"DELETE FROM hydration_logs WHERE id IN ({placeholders})", ids)
            elif day:
                cur = conn.execute("DELETE FROM hydration_logs WHERE date = ?", (day,))
            else:
                return 0
            conn.commit()
            return cur.rowcount

    def get_hydration_summary(self, day: str | None = None) -> dict:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            row = conn.execute(
                """SELECT
                       COALESCE(SUM(amount_ml), 0) AS hydration_ml,
                       COALESCE(SUM(effective_ml), 0) AS hydration_effective_ml,
                       COALESCE(SUM(caffeine_mg), 0) AS caffeine_mg,
                       COALESCE(SUM(alcohol_g), 0) AS alcohol_g,
                       COALESCE(SUM(sugar_g), 0) AS sugar_g,
                       COALESCE(SUM(calories), 0) AS calories,
                       COALESCE(SUM(protein_g), 0) AS protein_g,
                       COALESCE(SUM(carbs_g), 0) AS carbs_g,
                       COALESCE(SUM(fat_g), 0) AS fat_g,
                       COUNT(*) AS drink_count
                   FROM hydration_logs WHERE date = ?""",
                (day,),
            ).fetchone()
        macro = self.get_macro_goals()
        goal = macro["water_ml"] if macro and macro.get("water_ml") else 2000
        return {
            "date": day,
            "hydration_ml": row["hydration_ml"] if row else 0,
            "hydration_effective_ml": row["hydration_effective_ml"] if row else 0,
            "hydration_goal_ml": goal,
            "caffeine_mg": row["caffeine_mg"] if row else 0,
            "alcohol_g": row["alcohol_g"] if row else 0,
            "sugar_g": row["sugar_g"] if row else 0,
            "calories": row["calories"] if row else 0,
            "protein_g": row["protein_g"] if row else 0,
            "carbs_g": row["carbs_g"] if row else 0,
            "fat_g": row["fat_g"] if row else 0,
            "drink_count": row["drink_count"] if row else 0,
        }

    def get_hydration_settings(self) -> dict:
        macro = self.get_macro_goals() or {}
        goal = macro.get("water_ml") or 2000
        return {
            "hydration_goal_ml": float(goal),
            "water_ml": float(goal),
        }

    def save_hydration_settings(self, hydration_goal_ml: float) -> dict:
        goal = max(500, min(6000, float(hydration_goal_ml or 2000)))
        existing = self.get_macro_goals() or {
            "daily_calories": 2000,
            "protein_g": 50,
            "carbs_g": 250,
            "fat_g": 65,
            "fiber_g": 25,
            "sugar_g": 50,
            "sodium_mg": 2300,
            "water_ml": 2000,
        }
        existing["water_ml"] = goal
        self.save_macro_goals(existing)
        return self.get_hydration_settings()

    # ── Habit events / challenges / health imports ─────────────────

    def add_habit_event(
        self,
        day: str,
        event_type: str,
        source: str = "",
        amount: float = 0,
        payload: dict | None = None,
    ) -> dict:
        event_id = __import__("uuid").uuid4().hex[:12]
        payload = payload or {}
        with self._get_conn() as conn:
            conn.execute(
                """INSERT INTO habit_events
                   (id, date, event_type, source, amount, payload_json)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (event_id, day, event_type, source or "", float(amount or 0), json.dumps(payload, ensure_ascii=False)),
            )
            conn.commit()
        return {
            "id": event_id,
            "date": day,
            "event_type": event_type,
            "source": source or "",
            "amount": float(amount or 0),
            "payload": payload,
        }

    def complete_food_diary(
        self,
        day: str | None,
        summary: DailySummary,
        logged_meal_categories: int = 0,
    ) -> dict:
        """Persist a MyFitnessPal-style daily diary completion checkpoint."""
        day = day or date.today().isoformat()
        event_id = f"diary_complete_{day}"
        created_at = datetime.now().isoformat(timespec="seconds")
        payload = {
            "calories_consumed": round(float(summary.calories_consumed), 1),
            "calories_goal": round(float(summary.calories_goal), 1),
            "protein": round(float(summary.protein), 1),
            "protein_goal": round(float(summary.protein_goal), 1),
            "carbs": round(float(summary.carbs), 1),
            "carbs_goal": round(float(summary.carbs_goal), 1),
            "fat": round(float(summary.fat), 1),
            "fat_goal": round(float(summary.fat_goal), 1),
            "weight_projection": summary.weight_projection,
            "logged_meal_categories": int(logged_meal_categories or 0),
        }
        with self._get_conn() as conn:
            conn.execute(
                """INSERT INTO habit_events
                   (id, date, event_type, source, amount, payload_json, created_at)
                   VALUES (?, ?, 'diary_complete', 'info_page', ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET
                       amount = excluded.amount,
                       payload_json = excluded.payload_json,
                       created_at = excluded.created_at""",
                (
                    event_id,
                    day,
                    float(summary.calories_consumed or 0),
                    json.dumps(payload, ensure_ascii=False),
                    created_at,
                ),
            )
            conn.commit()
        return {
            "id": event_id,
            "date": day,
            "event_type": "diary_complete",
            "source": "info_page",
            "amount": float(summary.calories_consumed or 0),
            "payload": payload,
            "created_at": created_at,
        }

    def _row_to_challenge(self, row) -> dict:
        return {
            "id": row["id"],
            "template_id": row["template_id"],
            "title": row["title"],
            "description": row["description"],
            "challenge_type": row["challenge_type"],
            "duration_days": row["duration_days"],
            "target_value": row["target_value"],
            "start_date": row["start_date"],
            "end_date": row["end_date"],
            "status": row["status"],
            "reward_points": row["reward_points"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def create_challenge(self, data: dict) -> dict:
        challenge_id = data.get("id") or __import__("uuid").uuid4().hex[:12]
        duration_days = max(1, int(data.get("duration_days") or 7))
        status = data.get("status") or "available"
        payload = {
            "id": challenge_id,
            "template_id": data.get("template_id") or challenge_id,
            "title": (data.get("title") or "Custom challenge").strip(),
            "description": data.get("description") or "",
            "challenge_type": (data.get("challenge_type") or "hydration_goal").strip(),
            "duration_days": duration_days,
            "target_value": float(data.get("target_value") or 0),
            "start_date": data.get("start_date") or "",
            "end_date": data.get("end_date") or "",
            "status": status,
            "reward_points": int(data.get("reward_points") or duration_days * 10),
        }
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO challenges
                   (id, template_id, title, description, challenge_type, duration_days,
                    target_value, start_date, end_date, status, reward_points, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)""",
                (
                    payload["id"], payload["template_id"], payload["title"],
                    payload["description"], payload["challenge_type"], payload["duration_days"],
                    payload["target_value"], payload["start_date"], payload["end_date"],
                    payload["status"], payload["reward_points"],
                ),
            )
            conn.commit()
        payload["progress"] = self._challenge_progress(payload)
        return payload

    def get_challenges(self) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM challenges
                   ORDER BY CASE status
                       WHEN 'active' THEN 0
                       WHEN 'available' THEN 1
                       WHEN 'completed' THEN 2
                       ELSE 3
                   END, created_at ASC"""
            ).fetchall()
        challenges = []
        for row in rows:
            item = self._row_to_challenge(row)
            item["progress"] = self._challenge_progress(item)
            challenges.append(item)
        return challenges

    def join_challenge(self, challenge_id: str) -> dict | None:
        challenge_id = CHALLENGE_ID_ALIASES.get(challenge_id, challenge_id)
        start = date.today()
        with self._get_conn() as conn:
            row = conn.execute("SELECT * FROM challenges WHERE id = ?", (challenge_id,)).fetchone()
            if not row:
                return None
            duration_days = max(1, int(row["duration_days"] or 7))
            end = start + timedelta(days=duration_days - 1)
            conn.execute(
                """UPDATE challenges
                   SET status = 'active', start_date = ?, end_date = ?, updated_at = CURRENT_TIMESTAMP
                   WHERE id = ?""",
                (start.isoformat(), end.isoformat(), challenge_id),
            )
            conn.commit()
        return self.refresh_challenge(challenge_id)

    def refresh_challenge(self, challenge_id: str) -> dict | None:
        challenge_id = CHALLENGE_ID_ALIASES.get(challenge_id, challenge_id)
        with self._get_conn() as conn:
            row = conn.execute("SELECT * FROM challenges WHERE id = ?", (challenge_id,)).fetchone()
            if not row:
                return None
            item = self._row_to_challenge(row)
            progress = self._challenge_progress(item)
            next_status = item["status"]
            if item["status"] == "active":
                if progress["completed"]:
                    next_status = "completed"
                elif item["end_date"] and date.today().isoformat() > item["end_date"]:
                    next_status = "expired"
            if next_status != item["status"]:
                conn.execute(
                    "UPDATE challenges SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                    (next_status, challenge_id),
                )
                conn.commit()
                item["status"] = next_status
            item["progress"] = progress
            return item

    def _challenge_progress(self, challenge: dict) -> dict:
        duration_days = max(1, int(challenge.get("duration_days") or 7))
        start_raw = challenge.get("start_date") or date.today().isoformat()
        try:
            start = date.fromisoformat(start_raw[:10])
        except Exception:
            start = date.today()
        end_raw = challenge.get("end_date") or (start + timedelta(days=duration_days - 1)).isoformat()
        try:
            end = date.fromisoformat(end_raw[:10])
        except Exception:
            end = start + timedelta(days=duration_days - 1)
        today = date.today()
        last_day = min(end, today)
        if challenge.get("status") == "available":
            last_day = start - timedelta(days=1)

        days = []
        completed_days = 0
        current_streak = 0
        challenge_type = challenge.get("challenge_type") or "hydration_goal"
        target = float(challenge.get("target_value") or 0)
        for offset in range(duration_days):
            day_date = start + timedelta(days=offset)
            day = day_date.isoformat()
            checked = day_date <= last_day
            success = False
            value = 0
            if checked:
                success, value = self._challenge_day_result(challenge_type, day, target)
                if success:
                    completed_days += 1
            if checked and day_date == today:
                current_streak = 1 if success else 0
                back = day_date - timedelta(days=1)
                while success and back >= start:
                    prev_success, _ = self._challenge_day_result(challenge_type, back.isoformat(), target)
                    if not prev_success:
                        break
                    current_streak += 1
                    back -= timedelta(days=1)
            days.append({"date": day, "checked": checked, "success": success, "value": value})

        percent = round(completed_days / duration_days * 100)
        return {
            "completed_days": completed_days,
            "duration_days": duration_days,
            "current_streak": current_streak,
            "percent": percent,
            "completed": completed_days >= duration_days,
            "days": days,
        }

    def _challenge_day_result(self, challenge_type: str, day: str, target: float) -> tuple[bool, float]:
        hydration = self.get_hydration_summary(day)
        if challenge_type == "hydration_goal":
            goal = hydration["hydration_goal_ml"] or 2000
            value = hydration["hydration_effective_ml"]
            return value >= goal, value
        if challenge_type == "sleep_goal":
            summary = self.get_sleep_summary(day)
            value = summary["duration_hours"]
            return summary["logs_count"] > 0 and value >= (target or summary["goal_hours"]), value
        if challenge_type == "steps_goal":
            value = self.get_steps(day)
            return value >= (target or 8000), value
        if challenge_type == "food_photo_checkin":
            with self._get_conn() as conn:
                row = conn.execute(
                    "SELECT COUNT(*) AS c FROM habit_events WHERE date = ? AND event_type = 'food'",
                    (day,),
                ).fetchone()
            value = row["c"] if row else 0
            return value >= max(1, target or 1), value
        if challenge_type in {"vegetable_goal", "low_processed_day", "daily_status_score"}:
            stats = self._food_log_stats(day)
            if challenge_type == "vegetable_goal":
                value = stats["vegetable_items"]
                return value >= max(1, target or 1), value
            if challenge_type == "low_processed_day":
                value = stats["processed_items"] + stats["ultra_processed_items"]
                return stats["food_items"] > 0 and value <= target, value
            score = self._simple_status_score(day, hydration=hydration, food_stats=stats)
            return score >= (target or 80), score
        if challenge_type == "fasting_completed":
            with self._get_conn() as conn:
                conn.execute(
                    """CREATE TABLE IF NOT EXISTS fasting_sessions (
                        id TEXT PRIMARY KEY, method TEXT, fasting_hours REAL,
                        start_at TEXT, target_end_at TEXT, ended_at TEXT,
                        status TEXT DEFAULT 'active', notes TEXT DEFAULT ''
                    )"""
                )
                row = conn.execute(
                    """SELECT COUNT(*) AS c FROM fasting_sessions
                       WHERE status = 'completed' AND substr(COALESCE(ended_at, target_end_at, start_at), 1, 10) = ?""",
                    (day,),
                ).fetchone()
            value = row["c"] if row else 0
            return value >= max(1, target or 1), value
        if challenge_type == "low_sugar_drinks":
            value = hydration.get("sugar_g", 0)
            return hydration["drink_count"] > 0 and value <= target, value
        if challenge_type == "no_sugary_drinks":
            with self._get_conn() as conn:
                row = conn.execute(
                    "SELECT COUNT(*) AS c FROM hydration_logs WHERE date = ? AND sugar_g > ?",
                    (day, target),
                ).fetchone()
            value = row["c"] if row else 0
            return hydration["drink_count"] > 0 and value == 0, value
        if challenge_type == "no_alcohol":
            value = hydration.get("alcohol_g", 0)
            return hydration["drink_count"] > 0 and value <= target, value
        if challenge_type == "protein_breakfast":
            with self._get_conn() as conn:
                row = conn.execute(
                    """SELECT COALESCE(SUM(amount), 0) AS protein
                       FROM habit_events
                       WHERE date = ? AND event_type = 'food' AND source = 'breakfast'""",
                    (day,),
                ).fetchone()
            value = row["protein"] if row else 0
            return value >= target, value
        return False, 0

    def _food_log_stats(self, day: str) -> dict:
        db_path = DATA_DIR / "foods.db"
        if not db_path.exists():
            return {"food_items": 0, "vegetable_items": 0, "processed_items": 0, "ultra_processed_items": 0}
        veg_pattern = ("菜", "蔬", "青椒", "西兰花", "生菜", "黄瓜", "番茄", "菠菜", "芹", "白菜", "冬瓜", "胡萝卜", "蘑菇", "菌")
        with sqlite3.connect(str(db_path)) as conn:
            conn.row_factory = sqlite3.Row
            try:
                rows = conn.execute(
                    "SELECT food_name, processing_level FROM food_log_history WHERE date = ?",
                    (day,),
                ).fetchall()
            except sqlite3.Error:
                rows = []
        stats = {"food_items": len(rows), "vegetable_items": 0, "processed_items": 0, "ultra_processed_items": 0}
        for row in rows:
            name = str(row["food_name"] or "")
            level = str(row["processing_level"] or "")
            if any(token in name for token in veg_pattern):
                stats["vegetable_items"] += 1
            if level == "ultra_processed":
                stats["ultra_processed_items"] += 1
            if level in {"processed", "ultra_processed"}:
                stats["processed_items"] += 1
        return stats

    def _simple_status_score(self, day: str, hydration: dict | None = None, food_stats: dict | None = None) -> int:
        hydration = hydration or self.get_hydration_summary(day)
        food_stats = food_stats or self._food_log_stats(day)
        water_score = min(100, hydration.get("hydration_effective_ml", 0) / max(1, hydration.get("hydration_goal_ml", 2000)) * 100)
        sleep = self.get_sleep_summary(day)
        sleep_score = min(100, sleep["duration_hours"] / max(1, sleep["goal_hours"]) * 100) if sleep["logs_count"] else 45
        steps_score = min(100, self.get_steps(day) / 8000 * 100)
        food_score = 100 if food_stats["food_items"] and food_stats["processed_items"] <= 1 else 65 if food_stats["food_items"] else 40
        return round(water_score * 0.25 + sleep_score * 0.25 + steps_score * 0.25 + food_score * 0.25)

    def import_health_records(self, records: list[dict], default_source: str = "healthkit") -> dict:
        imported: list[dict] = []
        skipped: list[dict] = []
        for record in records:
            source = record.get("source") or default_source or "healthkit"
            external_id = str(record.get("external_id") or "")
            if not external_id:
                external_id = f"{source}:{record.get('record_type', 'record')}:{record.get('date', '')}:{record.get('value', '')}"
            record_type = (record.get("record_type") or record.get("type") or "").strip().lower()
            day = record.get("date") or date.today().isoformat()
            with self._get_conn() as conn:
                existing = conn.execute(
                    "SELECT id FROM health_imports WHERE source = ? AND external_id = ?",
                    (source, external_id),
                ).fetchone()
                if existing:
                    skipped.append({"external_id": external_id, "reason": "duplicate"})
                    continue
                import_id = __import__("uuid").uuid4().hex[:12]
                conn.execute(
                    """INSERT INTO health_imports
                       (id, source, external_id, record_type, date, payload_json)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (import_id, source, external_id, record_type, day, json.dumps(record, ensure_ascii=False)),
                )
                conn.commit()

            value = float(record.get("value") or record.get("amount") or 0)
            unit = (record.get("unit") or "").lower()
            if record_type in {"water", "hydration", "dietary_water"}:
                amount_ml = value * 1000 if unit in {"l", "liter", "litre"} else value
                created = self.add_hydration({
                    "drink_type": record.get("drink_type") or "water",
                    "amount_ml": amount_ml,
                    "source": source,
                    "external_id": external_id,
                    "date": day,
                    "logged_at": record.get("logged_at") or record.get("start_at") or datetime.now().isoformat(timespec="seconds"),
                    "note": "Imported from HealthKit",
                })
                imported.append({"external_id": external_id, "record_type": record_type, "created": created})
            elif record_type in {"steps", "step_count"}:
                created = self.add_steps(int(value), day=day, source=source)
                imported.append({"external_id": external_id, "record_type": record_type, "created": created.model_dump()})
            elif record_type in {"sleep", "sleep_duration", "sleep_analysis", "asleep"}:
                duration_hours = value
                if unit in {"min", "minute", "minutes"}:
                    duration_hours = value / 60
                elif unit in {"sec", "second", "seconds"}:
                    duration_hours = value / 3600
                created = self.add_sleep({
                    "date": day,
                    "duration_hours": duration_hours,
                    "quality": int(record.get("quality") or 3),
                    "start_at": record.get("start_at") or "",
                    "end_at": record.get("end_at") or record.get("logged_at") or "",
                    "source": source,
                    "external_id": external_id,
                    "note": "Imported from HealthKit",
                })
                imported.append({"external_id": external_id, "record_type": record_type, "created": created})
            elif record_type in {"weight", "body_mass"}:
                weight_kg = value * 0.45359237 if unit in {"lb", "lbs", "pound", "pounds"} else value
                created = self.add_weight(WeightLog(weight_kg=weight_kg, date=day, notes=f"Imported from {source}:{external_id}"))
                imported.append({"external_id": external_id, "record_type": record_type, "created": created.model_dump()})
            elif record_type in {"active_energy", "active_energy_burned"}:
                created = self.add_habit_event(day, "active_energy", source, value, {"unit": unit, "external_id": external_id})
                imported.append({"external_id": external_id, "record_type": record_type, "created": created})
            else:
                created = self.add_habit_event(day, record_type or "health", source, value, {"unit": unit, "external_id": external_id})
                imported.append({"external_id": external_id, "record_type": record_type or "health", "created": created})
        return {"imported": imported, "skipped": skipped, "imported_count": len(imported), "skipped_count": len(skipped)}

    # ── Steps ────────────────────────────────────────────────────────

    def add_steps(
        self,
        steps: int,
        day: str | None = None,
        source: str = "manual",
        step_id: str | None = None,
    ) -> StepLog:
        day = day or date.today().isoformat()
        step_id = step_id or __import__("uuid").uuid4().hex[:12]
        with self._get_conn() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO step_logs (id, date, steps, source) VALUES (?, ?, ?, ?)",
                (step_id, day, steps, source),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM step_logs WHERE id = ?", (step_id,)).fetchone()
        return StepLog(**dict(row)) if row else StepLog(id=step_id, date=day, steps=steps, source=source)

    def get_steps(self, day: str | None = None) -> int:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT COALESCE(SUM(steps), 0) as total FROM step_logs WHERE date = ?", (day,)
            ).fetchone()
        return row["total"] if row else 0

    def get_step_history(self, days: int = 30) -> list[dict]:
        since = (date.today() - timedelta(days=days)).isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT date, SUM(steps) as steps FROM step_logs WHERE date >= ? GROUP BY date ORDER BY date",
                (since,),
            ).fetchall()
        return [{"date": r["date"], "steps": r["steps"]} for r in rows]

    # ── Sleep ───────────────────────────────────────────────────────

    def add_sleep(self, data: dict) -> dict:
        day = data.get("date") or date.today().isoformat()
        sleep_id = data.get("id") or __import__("uuid").uuid4().hex[:12]
        duration_hours = max(0.0, min(24.0, float(data.get("duration_hours") or data.get("hours") or 0)))
        quality = max(1, min(5, int(data.get("quality") or 3)))
        payload = {
            "id": sleep_id,
            "date": day,
            "duration_hours": duration_hours,
            "quality": quality,
            "start_at": data.get("start_at") or "",
            "end_at": data.get("end_at") or "",
            "source": data.get("source") or "manual",
            "note": data.get("note") or "",
            "external_id": data.get("external_id") or "",
        }
        with self._get_conn() as conn:
            existing = conn.execute(
                "SELECT * FROM sleep_logs WHERE id = ?", (payload["id"],),
            ).fetchone()
            if existing:
                result = dict(existing)
                result.pop("created_at", None)
                return result
            if payload["external_id"]:
                existing = conn.execute(
                    "SELECT id FROM sleep_logs WHERE source = ? AND external_id = ?",
                    (payload["source"], payload["external_id"]),
                ).fetchone()
                if existing:
                    payload["id"] = existing["id"]
            conn.execute(
                """INSERT OR IGNORE INTO sleep_logs
                   (id, date, duration_hours, quality, start_at, end_at, source, note, external_id)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    payload["id"], payload["date"], payload["duration_hours"], payload["quality"],
                    payload["start_at"], payload["end_at"], payload["source"], payload["note"], payload["external_id"],
                ),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM sleep_logs WHERE id = ?", (payload["id"],),
            ).fetchone()
        if row:
            result = dict(row)
            result.pop("created_at", None)
            return result
        return payload

    def get_sleep_logs(self, day: str | None = None) -> list[dict]:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM sleep_logs WHERE date = ? ORDER BY created_at DESC, id DESC",
                (day,),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_sleep_summary(self, day: str | None = None) -> dict:
        day = day or date.today().isoformat()
        logs = self.get_sleep_logs(day)
        duration = sum(float(item.get("duration_hours") or 0) for item in logs)
        quality = round(sum(float(item.get("quality") or 0) for item in logs) / len(logs), 1) if logs else 0
        goal = 7.5
        if not logs:
            status = "red"
            message = "还没有记录睡眠"
        elif duration >= goal * 0.9 and quality >= 3.5:
            status = "green"
            message = "睡眠达标"
        elif duration >= goal * 0.7:
            status = "yellow"
            message = "睡眠接近目标"
        else:
            status = "red"
            message = "睡眠不足"
        return {
            "date": day,
            "duration_hours": round(duration, 2),
            "goal_hours": goal,
            "quality": quality,
            "logs_count": len(logs),
            "status": status,
            "message": message,
            "logs": logs,
        }

    # ── Preferences ──────────────────────────────────────────────────

    @staticmethod
    def default_preferences() -> dict:
        return {
            "diet_type": "balanced",
            "allergies": [],
            "avoid_ingredients": [],
            "favorite_cuisines": ["中式", "家常"],
            "budget_level": "medium",
            "prep_time_minutes": 20,
            "include_imported_recipes_in_meal_plans": True,
            "taste_tags": ["清淡", "高蛋白"],
            "meal_names": {
                "breakfast": "早餐",
                "lunch": "午餐",
                "dinner": "晚餐",
                "snack": "加餐",
            },
        }

    def get_user_preferences(self) -> dict:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT data_json FROM user_preferences WHERE id = 'default'"
            ).fetchone()
        defaults = self.default_preferences()
        if not row:
            return defaults
        try:
            saved = json.loads(row["data_json"])
        except Exception:
            saved = {}
        merged = {**defaults, **saved}
        for key in ["allergies", "avoid_ingredients", "favorite_cuisines", "taste_tags"]:
            if not isinstance(merged.get(key), list):
                merged[key] = []
        if not isinstance(merged.get("meal_names"), dict):
            merged["meal_names"] = self.default_preferences()["meal_names"]
        return merged

    def save_user_preferences(self, preferences: dict) -> dict:
        merged = {**self.default_preferences(), **preferences}
        for key in ["allergies", "avoid_ingredients", "favorite_cuisines", "taste_tags"]:
            value = merged.get(key)
            if isinstance(value, str):
                merged[key] = [v.strip() for v in value.replace("，", ",").split(",") if v.strip()]
            elif not isinstance(value, list):
                merged[key] = []
        default_meal_names = self.default_preferences()["meal_names"]
        meal_names = merged.get("meal_names")
        if not isinstance(meal_names, dict):
            meal_names = default_meal_names
        cleaned_names = {}
        for key, fallback in default_meal_names.items():
            value = str(meal_names.get(key) or fallback).strip()
            cleaned_names[key] = value[:12] or fallback
        merged["meal_names"] = cleaned_names
        try:
            merged["prep_time_minutes"] = max(5, min(120, int(merged.get("prep_time_minutes") or 20)))
        except Exception:
            merged["prep_time_minutes"] = 20
        merged["include_imported_recipes_in_meal_plans"] = bool(merged.get("include_imported_recipes_in_meal_plans", True))
        with self._get_conn() as conn:
            conn.execute(
                """INSERT INTO user_preferences (id, data_json, updated_at)
                   VALUES ('default', ?, CURRENT_TIMESTAMP)
                   ON CONFLICT(id) DO UPDATE SET
                   data_json = excluded.data_json,
                   updated_at = CURRENT_TIMESTAMP""",
                (json.dumps(merged, ensure_ascii=False),),
            )
            conn.commit()
        return merged

    # ── Recommendation Events ───────────────────────────────────────

    @staticmethod
    def _recommendation_identity(recommendation: dict) -> str:
        """Return a stable identity while ignoring generated record IDs."""
        def strip_generated_ids(value):
            if isinstance(value, dict):
                return {
                    key: strip_generated_ids(item)
                    for key, item in value.items()
                    if key not in {"id", "recommendation_id"}
                }
            if isinstance(value, list):
                return [strip_generated_ids(item) for item in value]
            return value

        payload = strip_generated_ids(recommendation)
        return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    @classmethod
    def _stable_recommendation_id(
        cls,
        day: str,
        meal_type: str,
        source: str,
        recommendation: dict,
    ) -> str:
        identity = cls._recommendation_identity(recommendation)
        digest = hashlib.sha256(
            f"{day}|{meal_type}|{source}|{identity}".encode("utf-8")
        ).hexdigest()
        return digest[:12]

    @staticmethod
    def _assign_recommendation_ids(recommendation: dict, event_id: str) -> dict:
        normalized = {**recommendation, "id": event_id}
        if "recommendation_id" in normalized:
            normalized["recommendation_id"] = event_id
        foods = []
        for index, food in enumerate(normalized.get("foods") or []):
            item = dict(food)
            food_identity = json.dumps(
                {key: value for key, value in item.items() if key != "id"},
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            item["id"] = hashlib.sha256(
                f"{event_id}|{index}|{food_identity}".encode("utf-8")
            ).hexdigest()[:12]
            foods.append(item)
        if "foods" in normalized:
            normalized["foods"] = foods
        return normalized

    def save_recommendation_event(self, event_id: str, day: str, meal_type: str, source: str, recommendation: dict) -> dict:
        with self._get_conn() as conn:
            identity = self._recommendation_identity(recommendation)
            existing_rows = conn.execute(
                """SELECT * FROM recommendation_events
                   WHERE date = ? AND meal_type = ? AND source = ?
                   ORDER BY rowid DESC""",
                (day, meal_type, source),
            ).fetchall()
            for row in existing_rows:
                try:
                    saved = json.loads(row["recommendation_json"])
                except (TypeError, json.JSONDecodeError):
                    continue
                if self._recommendation_identity(saved) == identity:
                    return saved

            stable_id = self._stable_recommendation_id(day, meal_type, source, recommendation)
            normalized = self._assign_recommendation_ids(recommendation, stable_id)
            encoded = json.dumps(normalized, ensure_ascii=False)
            conn.execute(
                """INSERT INTO recommendation_events
                   (id, date, meal_type, source, recommendation_json, logged)
                   VALUES (?, ?, ?, ?, ?, 0)
                   ON CONFLICT(id) DO UPDATE SET
                     date = excluded.date,
                     meal_type = excluded.meal_type,
                     source = excluded.source,
                     recommendation_json = excluded.recommendation_json
                   WHERE recommendation_events.date IS NOT excluded.date
                      OR recommendation_events.meal_type IS NOT excluded.meal_type
                      OR recommendation_events.source IS NOT excluded.source
                      OR recommendation_events.recommendation_json IS NOT excluded.recommendation_json""",
                (stable_id, day, meal_type, source, encoded),
            )
            conn.commit()
        return normalized

    def get_recommendation_event(self, event_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM recommendation_events WHERE id = ?", (event_id,)
            ).fetchone()
        if not row:
            return None
        data = dict(row)
        data["recommendation"] = json.loads(data.pop("recommendation_json"))
        return data

    def mark_recommendation_logged(self, event_id: str) -> None:
        with self._get_conn() as conn:
            conn.execute(
                """UPDATE recommendation_events
                   SET logged = 1, logged_at = CURRENT_TIMESTAMP
                   WHERE id = ? AND logged = 0""",
                (event_id,),
            )
            conn.commit()

    # ── Delivery Order Drafts ───────────────────────────────────────

    def save_delivery_order_draft(
        self,
        recommendation_id: str,
        day: str,
        meal_type: str,
        provider: str,
        draft: dict,
    ) -> dict:
        draft_id = __import__("uuid").uuid4().hex[:12]
        payload = {
            **draft,
            "id": draft_id,
            "recommendation_id": recommendation_id,
            "date": day,
            "meal_type": meal_type,
            "provider": provider or draft.get("provider", "auto"),
        }
        with self._get_conn() as conn:
            conn.execute(
                """INSERT INTO delivery_order_drafts
                   (id, recommendation_id, date, meal_type, provider, search_query, order_note, draft_json)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    draft_id,
                    recommendation_id,
                    day,
                    meal_type,
                    payload["provider"],
                    payload.get("search_query", ""),
                    payload.get("order_note", ""),
                    json.dumps(payload, ensure_ascii=False),
                ),
            )
            conn.commit()
        return payload

    def get_delivery_order_draft(self, draft_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT draft_json FROM delivery_order_drafts WHERE id = ?", (draft_id,)
            ).fetchone()
        if not row:
            return None
        try:
            return json.loads(row["draft_json"])
        except Exception:
            return None

    def list_delivery_order_drafts(self, day: str | None = None, limit: int = 20) -> list[dict]:
        limit = max(1, min(50, int(limit or 20)))
        with self._get_conn() as conn:
            if day:
                rows = conn.execute(
                    """SELECT draft_json FROM delivery_order_drafts
                       WHERE date = ? ORDER BY created_at DESC LIMIT ?""",
                    (day, limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT draft_json FROM delivery_order_drafts ORDER BY created_at DESC LIMIT ?",
                    (limit,),
                ).fetchall()
        drafts = []
        for row in rows:
            try:
                drafts.append(json.loads(row["draft_json"]))
            except Exception:
                continue
        return drafts

    # ── Ingredient Recipe Events ────────────────────────────────────

    @staticmethod
    def _normalized_recipe_title(value: str) -> str:
        return "".join(str(value or "").strip().casefold().split())

    @staticmethod
    def _recipe_title(recipe: dict | None) -> str:
        if not isinstance(recipe, dict):
            return ""
        return str(recipe.get("title") or recipe.get("name") or "").strip()

    def save_recipe_suggestion_event(self, event_id: str, day: str, source: str, recipe: dict) -> dict:
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO recipe_suggestion_events
                   (id, date, source, recipe_json, logged, logged_count, logged_at)
                   VALUES (?, ?, ?, ?, COALESCE((SELECT logged FROM recipe_suggestion_events WHERE id = ?), 0),
                           COALESCE((SELECT logged_count FROM recipe_suggestion_events WHERE id = ?), 0),
                           (SELECT logged_at FROM recipe_suggestion_events WHERE id = ?))""",
                (event_id, day, source, json.dumps(recipe, ensure_ascii=False), event_id, event_id, event_id),
            )
            conn.commit()
        return recipe

    def get_recipe_suggestion_event(self, event_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM recipe_suggestion_events WHERE id = ?", (event_id,)
            ).fetchone()
        if not row:
            return None
        data = dict(row)
        data["recipe"] = json.loads(data.pop("recipe_json"))
        return data

    def find_recipe_suggestion_event_by_title(self, title: str, exclude_id: str | None = None) -> dict | None:
        target = self._normalized_recipe_title(title)
        if not target:
            return None
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM recipe_suggestion_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
        for row in rows:
            if exclude_id and row["id"] == exclude_id:
                continue
            data = dict(row)
            try:
                recipe = json.loads(data.pop("recipe_json"))
            except Exception:
                continue
            if self._normalized_recipe_title(self._recipe_title(recipe)) == target:
                data["recipe"] = recipe
                return data
        return None

    def dedupe_recipe_suggestion_events_by_title(self) -> int:
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM recipe_suggestion_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
            groups: dict[str, list[dict]] = {}
            for row in rows:
                data = dict(row)
                try:
                    recipe = json.loads(data.get("recipe_json") or "{}")
                except Exception:
                    continue
                title_key = self._normalized_recipe_title(self._recipe_title(recipe))
                if not title_key:
                    continue
                data["recipe"] = recipe
                groups.setdefault(title_key, []).append(data)

            deleted = 0
            for items in groups.values():
                if len(items) <= 1:
                    continue
                keep = items[0]
                duplicates = items[1:]
                logged_count = sum(int(item.get("logged_count") or 0) for item in items)
                logged = 1 if any(int(item.get("logged") or 0) for item in items) else 0
                logged_at_values = [str(item.get("logged_at") or "") for item in items if str(item.get("logged_at") or "")]
                logged_at = max(logged_at_values) if logged_at_values else None
                conn.execute(
                    """UPDATE recipe_suggestion_events
                       SET logged = ?, logged_count = ?, logged_at = COALESCE(?, logged_at)
                       WHERE id = ?""",
                    (logged, logged_count, logged_at, keep["id"]),
                )
                for item in duplicates:
                    conn.execute("DELETE FROM recipe_suggestion_events WHERE id = ?", (item["id"],))
                    deleted += 1
            conn.commit()
        return deleted

    def update_recipe_suggestion_event(self, event_id: str, recipe: dict, day: str | None = None, source: str | None = None) -> dict | None:
        existing = self.get_recipe_suggestion_event(event_id)
        if not existing:
            return None
        with self._get_conn() as conn:
            conn.execute(
                """UPDATE recipe_suggestion_events
                   SET recipe_json = ?,
                       date = COALESCE(?, date),
                       source = COALESCE(?, source)
                   WHERE id = ?""",
                (json.dumps(recipe, ensure_ascii=False), day, source, event_id),
            )
            conn.commit()
        updated = self.get_recipe_suggestion_event(event_id)
        return updated

    @staticmethod
    def _normalize_recipe_meal_type(value: str | None) -> str:
        text = str(value or "").strip().lower()
        if not text:
            return ""
        if text in {"breakfast", "morning"} or "早餐" in text or "早饭" in text:
            return "breakfast"
        if text in {"lunch", "noon"} or "午餐" in text or "中餐" in text or "午饭" in text:
            return "lunch"
        if text in {"dinner", "supper"} or "晚餐" in text or "晚饭" in text or "正餐" in text:
            return "dinner"
        if text in {"snack", "tea"} or "加餐" in text or "零食" in text or "点心" in text or "下午茶" in text:
            return "snack"
        return ""

    @classmethod
    def _recipe_matches_meal_type(cls, recipe: dict, meal_type: str) -> bool:
        normalized = cls._normalize_recipe_meal_type(meal_type)
        if not normalized:
            return True
        candidates: list[str] = []
        for value in recipe.get("meal_types") or []:
            item = cls._normalize_recipe_meal_type(value)
            if item and item not in candidates:
                candidates.append(item)
        for value in recipe.get("tags") or []:
            item = cls._normalize_recipe_meal_type(value)
            if item and item not in candidates:
                candidates.append(item)
        return normalized in candidates

    @staticmethod
    def _normalize_recipe_tag(value: str | None) -> str:
        text = str(value or "").strip().lower()
        if not text:
            return ""
        compact = "".join(ch for ch in text if ch.isalnum() or "\u4e00" <= ch <= "\u9fff")
        aliases = {
            "highprotein": "high_protein",
            "高蛋白": "high_protein",
            "蛋白高": "high_protein",
            "低碳": "low_carb",
            "低碳水": "low_carb",
            "lowcarb": "low_carb",
            "低卡": "low_calorie",
            "低热量": "low_calorie",
            "lowcalorie": "low_calorie",
            "低钠": "low_sodium",
            "低盐": "low_sodium",
            "lowsodium": "low_sodium",
            "少油": "low_fat",
            "低脂": "low_fat",
            "lowfat": "low_fat",
            "高纤维": "high_fiber",
            "highfiber": "high_fiber",
            "素食": "vegetarian",
            "vegetarian": "vegetarian",
        }
        return aliases.get(compact, compact)

    @classmethod
    def _recipe_matches_tag(cls, recipe: dict, tag: str) -> bool:
        normalized = cls._normalize_recipe_tag(tag)
        if not normalized:
            return True
        candidates: list[str] = []
        for value in recipe.get("tags") or []:
            item = cls._normalize_recipe_tag(value)
            if item and item not in candidates:
                candidates.append(item)
        return normalized in candidates

    def list_recipe_suggestion_events(self, limit: int = 10, query: str = "", sort: str = "created", offset: int = 0, favorite: bool = False, imported: bool = False, meal_type: str = "", tag: str = "") -> list[dict]:
        limit = max(1, min(100, int(limit or 10)))
        offset = max(0, min(10000, int(offset or 0)))
        clean_query = str(query or "").strip()
        clean_sort = str(sort or "created").strip().lower()
        clean_meal_type = self._normalize_recipe_meal_type(meal_type)
        clean_tag = self._normalize_recipe_tag(tag)
        if clean_sort == "frequent":
            order_clause = "logged_count DESC, COALESCE(logged_at, '') DESC, created_at DESC"
        elif clean_sort == "logged":
            order_clause = "COALESCE(logged_at, '') DESC, created_at DESC"
        else:
            order_clause = "created_at DESC"
        needs_python_sort = clean_sort in {"calories", "name"} or favorite or imported or bool(clean_meal_type) or bool(clean_tag)
        fetch_limit = 5000 if (favorite or imported or clean_meal_type or clean_tag) else (min(5000, offset + limit) if needs_python_sort else limit)
        with self._get_conn() as conn:
            if clean_query:
                pattern = f"%{clean_query}%"
                if needs_python_sort:
                    rows = conn.execute(
                        """SELECT * FROM recipe_suggestion_events
                           WHERE recipe_json LIKE ?
                           ORDER BY """ + order_clause + """
                           LIMIT ?""",
                        (pattern, fetch_limit),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """SELECT * FROM recipe_suggestion_events
                           WHERE recipe_json LIKE ?
                           ORDER BY """ + order_clause + """
                           LIMIT ? OFFSET ?""",
                        (pattern, limit, offset),
                    ).fetchall()
            else:
                if needs_python_sort:
                    rows = conn.execute(
                        """SELECT * FROM recipe_suggestion_events
                           ORDER BY """ + order_clause + """
                           LIMIT ?""",
                        (fetch_limit,),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """SELECT * FROM recipe_suggestion_events
                           ORDER BY """ + order_clause + """
                           LIMIT ? OFFSET ?""",
                        (limit, offset),
                    ).fetchall()
        items = []
        for row in rows:
            data = dict(row)
            try:
                data["recipe"] = json.loads(data.pop("recipe_json"))
            except Exception:
                continue
            if favorite and not bool(data["recipe"].get("favorite")):
                continue
            if imported:
                source = str(data["recipe"].get("source") or data.get("source") or "").strip().lower()
                source_url = str(data["recipe"].get("source_url") or "").strip()
                if source != "recipe_url_import" and not source_url:
                    continue
            if clean_meal_type and not self._recipe_matches_meal_type(data["recipe"], clean_meal_type):
                continue
            if clean_tag and not self._recipe_matches_tag(data["recipe"], clean_tag):
                continue
            items.append(data)
        if clean_sort == "calories":
            items.sort(key=lambda item: float((item.get("recipe") or {}).get("calories") or 0), reverse=True)
            items = items[offset:offset + limit]
        elif clean_sort == "name":
            items.sort(key=lambda item: str((item.get("recipe") or {}).get("title") or "").casefold())
            items = items[offset:offset + limit]
        elif favorite or imported or clean_meal_type or clean_tag:
            items = items[offset:offset + limit]
        return items

    def mark_recipe_suggestion_logged(self, event_id: str) -> None:
        with self._get_conn() as conn:
            conn.execute(
                "UPDATE recipe_suggestion_events SET logged = 1, logged_count = COALESCE(logged_count, 0) + 1, logged_at = CURRENT_TIMESTAMP WHERE id = ?",
                (event_id,),
            )
            conn.commit()

    def delete_recipe_suggestion_event(self, event_id: str) -> bool:
        with self._get_conn() as conn:
            cur = conn.execute(
                "DELETE FROM recipe_suggestion_events WHERE id = ?",
                (event_id,),
            )
            conn.commit()
            return cur.rowcount > 0

    # ── Saved Meals ───────────────────────────────────────────────────

    @staticmethod
    def _normalized_saved_meal_title(value: str) -> str:
        return "".join(str(value or "").strip().casefold().split())

    def save_saved_meal_event(
        self,
        meal_id: str,
        title: str,
        foods: list[dict],
        source: str = "user",
        meal_category: str = "",
        image_url: str = "",
        note: str = "",
        instructions: list[str] | None = None,
        favorite: bool = False,
    ) -> dict:
        clean_title = str(title or "").strip()[:80] or "我的餐品"
        clean_note = str(note or "").strip()[:500]
        clean_instructions = [str(item or "").strip()[:240] for item in (instructions or []) if str(item or "").strip()]
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO saved_meal_events
                   (id, title, source, meal_category, image_url, note, instructions_json, favorite, foods_json, logged_count, logged_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT logged_count FROM saved_meal_events WHERE id = ?), 0),
                           COALESCE((SELECT logged_at FROM saved_meal_events WHERE id = ?), NULL))""",
                (
                    meal_id,
                    clean_title,
                    str(source or "user")[:40],
                    str(meal_category or "")[:40],
                    str(image_url or ""),
                    clean_note,
                    json.dumps(clean_instructions, ensure_ascii=False),
                    1 if favorite else 0,
                    json.dumps(foods, ensure_ascii=False),
                    meal_id,
                    meal_id,
                ),
            )
            conn.commit()
        return self.get_saved_meal_event(meal_id) or {}

    def find_saved_meal_event_by_title(self, title: str, exclude_id: str | None = None) -> dict | None:
        target = self._normalized_saved_meal_title(title)
        if not target:
            return None
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM saved_meal_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
        for row in rows:
            if exclude_id and row["id"] == exclude_id:
                continue
            if self._normalized_saved_meal_title(row["title"]) != target:
                continue
            data = dict(row)
            try:
                data["foods"] = json.loads(data.pop("foods_json"))
            except Exception:
                data["foods"] = []
            try:
                data["instructions"] = json.loads(data.pop("instructions_json", "[]") or "[]")
            except Exception:
                data["instructions"] = []
            data["favorite"] = bool(data.get("favorite") or 0)
            return data
        return None

    def dedupe_saved_meal_events_by_title(self) -> int:
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM saved_meal_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
            groups: dict[str, list[dict]] = {}
            for row in rows:
                data = dict(row)
                title_key = self._normalized_saved_meal_title(data.get("title") or "")
                if not title_key:
                    continue
                groups.setdefault(title_key, []).append(data)

            deleted = 0
            for items in groups.values():
                if len(items) <= 1:
                    continue
                keep = items[0]
                duplicates = items[1:]
                logged_count = sum(int(item.get("logged_count") or 0) for item in items)
                logged_at_values = [str(item.get("logged_at") or "") for item in items if str(item.get("logged_at") or "")]
                logged_at = max(logged_at_values) if logged_at_values else None
                favorite = 1 if any(int(item.get("favorite") or 0) for item in items) else 0
                conn.execute(
                    """UPDATE saved_meal_events
                       SET logged_count = ?, logged_at = COALESCE(?, logged_at), favorite = ?
                       WHERE id = ?""",
                    (logged_count, logged_at, favorite, keep["id"]),
                )
                for item in duplicates:
                    conn.execute("DELETE FROM saved_meal_events WHERE id = ?", (item["id"],))
                    deleted += 1
            conn.commit()
        return deleted

    def get_saved_meal_event(self, meal_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM saved_meal_events WHERE id = ?", (meal_id,)
            ).fetchone()
        if not row:
            return None
        data = dict(row)
        try:
            data["foods"] = json.loads(data.pop("foods_json"))
        except Exception:
            data["foods"] = []
        try:
            data["instructions"] = json.loads(data.pop("instructions_json", "[]") or "[]")
        except Exception:
            data["instructions"] = []
        data["favorite"] = bool(data.get("favorite") or 0)
        return data

    def update_saved_meal_event(
        self,
        meal_id: str,
        title: str,
        foods: list[dict],
        meal_category: str = "",
        image_url: str = "",
        note: str | None = None,
        instructions: list[str] | None = None,
        favorite: bool | None = None,
    ) -> dict | None:
        existing = self.get_saved_meal_event(meal_id)
        if not existing:
            return None
        clean_title = str(title or "").strip()[:80] or existing.get("title") or "我的餐品"
        clean_note = str(note if note is not None else existing.get("note") or "").strip()[:500]
        clean_instructions = [str(item or "").strip()[:240] for item in (instructions if instructions is not None else existing.get("instructions") or []) if str(item or "").strip()]
        with self._get_conn() as conn:
            conn.execute(
                """UPDATE saved_meal_events
                   SET title = ?, meal_category = ?, image_url = ?, note = ?, instructions_json = ?, favorite = ?, foods_json = ?
                   WHERE id = ?""",
                (
                    clean_title,
                    str(meal_category or existing.get("meal_category") or "")[:40],
                    str(image_url or existing.get("image_url") or ""),
                    clean_note,
                    json.dumps(clean_instructions, ensure_ascii=False),
                    1 if (favorite if favorite is not None else bool(existing.get("favorite"))) else 0,
                    json.dumps(foods, ensure_ascii=False),
                    meal_id,
                ),
            )
            conn.commit()
        return self.get_saved_meal_event(meal_id)

    def list_saved_meal_events(
        self,
        limit: int = 20,
        query: str = "",
        sort: str = "created",
        offset: int = 0,
        meal_category: str = "",
        favorite: bool = False,
    ) -> list[dict]:
        limit = max(1, min(100, int(limit or 20)))
        offset = max(0, min(10000, int(offset or 0)))
        clean_query = str(query or "").strip()
        clean_meal_category = str(meal_category or "").strip()[:40]
        clean_sort = str(sort or "created").strip().lower()
        if clean_sort == "name":
            order_clause = "LOWER(title) ASC, created_at DESC"
        elif clean_sort == "frequent":
            order_clause = "logged_count DESC, COALESCE(logged_at, '') DESC, created_at DESC"
        elif clean_sort == "logged":
            order_clause = "COALESCE(logged_at, '') DESC, created_at DESC"
        else:
            order_clause = "created_at DESC"
        fetch_limit = min(5000, offset + limit) if clean_sort == "calories" else limit
        where_clauses = []
        params: list[object] = []
        if clean_meal_category:
            where_clauses.append("meal_category = ?")
            params.append(clean_meal_category)
        if favorite:
            where_clauses.append("favorite = 1")
        if clean_query:
            pattern = f"%{clean_query}%"
            where_clauses.append(
                "(title LIKE ? OR meal_category LIKE ? OR foods_json LIKE ? OR note LIKE ? OR instructions_json LIKE ?)"
            )
            params.extend([pattern, pattern, pattern, pattern, pattern])
        where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
        with self._get_conn() as conn:
            if clean_sort == "calories":
                rows = conn.execute(
                    f"""SELECT * FROM saved_meal_events
                       {where_sql}
                       ORDER BY {order_clause}
                       LIMIT ?""",
                    (*params, fetch_limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    f"""SELECT * FROM saved_meal_events
                       {where_sql}
                       ORDER BY {order_clause}
                       LIMIT ? OFFSET ?""",
                    (*params, limit, offset),
                ).fetchall()
        items = []
        for row in rows:
            data = dict(row)
            try:
                data["foods"] = json.loads(data.pop("foods_json"))
            except Exception:
                data["foods"] = []
            try:
                data["instructions"] = json.loads(data.pop("instructions_json", "[]") or "[]")
            except Exception:
                data["instructions"] = []
            data["favorite"] = bool(data.get("favorite") or 0)
            items.append(data)
        if clean_sort == "calories":
            items.sort(key=lambda item: sum(float(food.get("calories") or 0) for food in item.get("foods", [])), reverse=True)
            items = items[offset:offset + limit]
        return items

    def mark_saved_meal_logged(self, meal_id: str) -> None:
        with self._get_conn() as conn:
            conn.execute(
                "UPDATE saved_meal_events SET logged_count = COALESCE(logged_count, 0) + 1, logged_at = CURRENT_TIMESTAMP WHERE id = ?",
                (meal_id,),
            )
            conn.commit()

    def delete_saved_meal_event(self, meal_id: str) -> bool:
        with self._get_conn() as conn:
            cur = conn.execute("DELETE FROM saved_meal_events WHERE id = ?", (meal_id,))
            conn.commit()
            return cur.rowcount > 0

    # ── Saved Foods ───────────────────────────────────────────────────

    @staticmethod
    def _normalized_saved_food_name(value: str) -> str:
        return "".join(str(value or "").strip().casefold().split())

    def save_saved_food_event(
        self,
        food_id: str,
        name: str,
        food: dict,
        source: str = "user",
    ) -> dict:
        clean_name = str(name or "").strip()[:80] or "我的食物"
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO saved_food_events
                   (id, name, source, food_json, logged_count, logged_at)
                   VALUES (?, ?, ?, ?, COALESCE((SELECT logged_count FROM saved_food_events WHERE id = ?), 0),
                           COALESCE((SELECT logged_at FROM saved_food_events WHERE id = ?), NULL))""",
                (
                    food_id,
                    clean_name,
                    str(source or "user")[:40],
                    json.dumps(food, ensure_ascii=False),
                    food_id,
                    food_id,
                ),
            )
            conn.commit()
        return self.get_saved_food_event(food_id) or {}

    def find_saved_food_event_by_name(self, name: str, exclude_id: str | None = None) -> dict | None:
        target = self._normalized_saved_food_name(name)
        if not target:
            return None
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM saved_food_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
        for row in rows:
            if exclude_id and row["id"] == exclude_id:
                continue
            if self._normalized_saved_food_name(row["name"]) != target:
                continue
            data = dict(row)
            try:
                data["food"] = json.loads(data.pop("food_json"))
            except Exception:
                data["food"] = {}
            return data
        return None

    def dedupe_saved_food_events_by_name(self) -> int:
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM saved_food_events
                   ORDER BY COALESCE(logged_at, '') DESC, created_at DESC"""
            ).fetchall()
            groups: dict[str, list[dict]] = {}
            for row in rows:
                data = dict(row)
                name_key = self._normalized_saved_food_name(data.get("name") or "")
                if not name_key:
                    continue
                groups.setdefault(name_key, []).append(data)

            deleted = 0
            for items in groups.values():
                if len(items) <= 1:
                    continue
                keep = items[0]
                duplicates = items[1:]
                logged_count = sum(int(item.get("logged_count") or 0) for item in items)
                logged_at_values = [str(item.get("logged_at") or "") for item in items if str(item.get("logged_at") or "")]
                logged_at = max(logged_at_values) if logged_at_values else None
                conn.execute(
                    """UPDATE saved_food_events
                       SET logged_count = ?, logged_at = COALESCE(?, logged_at)
                       WHERE id = ?""",
                    (logged_count, logged_at, keep["id"]),
                )
                for item in duplicates:
                    conn.execute("DELETE FROM saved_food_events WHERE id = ?", (item["id"],))
                    deleted += 1
            conn.commit()
        return deleted

    def get_saved_food_event(self, food_id: str) -> dict | None:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM saved_food_events WHERE id = ?", (food_id,)
            ).fetchone()
        if not row:
            return None
        data = dict(row)
        try:
            data["food"] = json.loads(data.pop("food_json"))
        except Exception:
            data["food"] = {}
        return data

    def update_saved_food_event(self, food_id: str, name: str, food: dict) -> dict | None:
        existing = self.get_saved_food_event(food_id)
        if not existing:
            return None
        clean_name = str(name or "").strip()[:80] or existing.get("name") or "我的食物"
        with self._get_conn() as conn:
            conn.execute(
                """UPDATE saved_food_events
                   SET name = ?, food_json = ?
                   WHERE id = ?""",
                (clean_name, json.dumps(food, ensure_ascii=False), food_id),
            )
            conn.commit()
        return self.get_saved_food_event(food_id)

    def list_saved_food_events(self, limit: int = 50, query: str = "", sort: str = "created", offset: int = 0) -> list[dict]:
        limit = max(1, min(100, int(limit or 50)))
        offset = max(0, min(10000, int(offset or 0)))
        clean_query = str(query or "").strip()
        clean_sort = str(sort or "created").strip().lower()
        if clean_sort == "name":
            order_clause = "LOWER(name) ASC, created_at DESC"
        elif clean_sort == "frequent":
            order_clause = "logged_count DESC, COALESCE(logged_at, '') DESC, created_at DESC"
        elif clean_sort == "logged":
            order_clause = "COALESCE(logged_at, '') DESC, created_at DESC"
        else:
            order_clause = "created_at DESC"
        fetch_limit = min(5000, offset + limit) if clean_sort == "calories" else limit
        with self._get_conn() as conn:
            if clean_query:
                pattern = f"%{clean_query}%"
                if clean_sort == "calories":
                    rows = conn.execute(
                        """SELECT * FROM saved_food_events
                           WHERE name LIKE ? OR food_json LIKE ?
                           ORDER BY """ + order_clause + """
                           LIMIT ?""",
                        (pattern, pattern, fetch_limit),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """SELECT * FROM saved_food_events
                           WHERE name LIKE ? OR food_json LIKE ?
                           ORDER BY """ + order_clause + """
                           LIMIT ? OFFSET ?""",
                        (pattern, pattern, limit, offset),
                    ).fetchall()
            else:
                if clean_sort == "calories":
                    rows = conn.execute(
                        """SELECT * FROM saved_food_events
                           ORDER BY """ + order_clause + """
                           LIMIT ?""",
                        (fetch_limit,),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """SELECT * FROM saved_food_events
                           ORDER BY """ + order_clause + """
                           LIMIT ? OFFSET ?""",
                        (limit, offset),
                    ).fetchall()
        items = []
        for row in rows:
            data = dict(row)
            try:
                data["food"] = json.loads(data.pop("food_json"))
            except Exception:
                data["food"] = {}
            items.append(data)
        if clean_sort == "calories":
            items.sort(key=lambda item: float((item.get("food") or {}).get("calories") or 0), reverse=True)
            items = items[offset:offset + limit]
        return items

    def mark_saved_food_logged(self, food_id: str) -> None:
        with self._get_conn() as conn:
            conn.execute(
                "UPDATE saved_food_events SET logged_count = COALESCE(logged_count, 0) + 1, logged_at = CURRENT_TIMESTAMP WHERE id = ?",
                (food_id,),
            )
            conn.commit()

    def delete_saved_food_event(self, food_id: str) -> bool:
        with self._get_conn() as conn:
            cur = conn.execute("DELETE FROM saved_food_events WHERE id = ?", (food_id,))
            conn.commit()
            return cur.rowcount > 0

    # ── Coach Messages ─────────────────────────────────────────────

    def save_coach_message(self, role: str, content: str, payload: dict | None = None, day: str | None = None) -> dict:
        message_id = __import__("uuid").uuid4().hex[:12]
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            conn.execute(
                """INSERT INTO coach_messages (id, date, role, content, payload_json)
                   VALUES (?, ?, ?, ?, ?)""",
                (message_id, day, role, content, json.dumps(payload or {}, ensure_ascii=False)),
            )
            conn.commit()
        return {"id": message_id, "date": day, "role": role, "content": content, "payload": payload or {}}

    def get_coach_messages(self, day: str | None = None, limit: int = 30) -> list[dict]:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM coach_messages WHERE date = ? ORDER BY created_at DESC LIMIT ?",
                (day, limit),
            ).fetchall()
        messages = []
        for row in reversed(rows):
            item = dict(row)
            try:
                item["payload"] = json.loads(item.pop("payload_json") or "{}")
            except Exception:
                item["payload"] = {}
            messages.append(item)
        return messages

    # ── Decision Events ─────────────────────────────────────────────

    def save_decision_event(
        self,
        event_id: str,
        day: str,
        event_type: str,
        source: str,
        score: int,
        title: str,
        payload: dict,
    ) -> dict:
        with self._get_conn() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO decision_events
                   (id, date, event_type, source, score, title, payload_json)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    event_id,
                    day,
                    event_type,
                    source,
                    int(max(0, min(100, score))),
                    title[:120],
                    json.dumps(payload, ensure_ascii=False),
                ),
            )
            conn.commit()
        return payload

    def list_decision_events(self, day: str | None = None, limit: int = 30) -> list[dict]:
        day = day or date.today().isoformat()
        limit = max(1, min(100, int(limit or 30)))
        with self._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM decision_events
                   WHERE date = ?
                   ORDER BY created_at DESC
                   LIMIT ?""",
                (day, limit),
            ).fetchall()
        events = []
        for row in rows:
            item = dict(row)
            try:
                item["payload"] = json.loads(item.pop("payload_json") or "{}")
            except Exception:
                item["payload"] = {}
            events.append(item)
        return events

    # ── Friends ──────────────────────────────────────────────────────

    def send_friend_request(self, from_user: str, to_user: str) -> dict:
        fid = __import__("uuid").uuid4().hex[:12]
        with self._get_conn() as conn:
            conn.execute(
                "INSERT INTO friend_requests (id, from_user, to_user) VALUES (?, ?, ?)",
                (fid, from_user, to_user),
            )
            conn.commit()
        return {"id": fid, "status": "pending"}

    def accept_friend_request(self, request_id: str) -> dict:
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM friend_requests WHERE id = ? AND status = 'pending'", (request_id,)
            ).fetchone()
            if not row:
                return {"error": "Request not found"}
            conn.execute("UPDATE friend_requests SET status = 'accepted' WHERE id = ?", (request_id,))
            fid = __import__("uuid").uuid4().hex[:12]
            conn.execute(
                "INSERT INTO friendships (id, user_a, user_b) VALUES (?, ?, ?)",
                (fid, row["from_user"], row["to_user"]),
            )
            conn.commit()
        return {"status": "accepted", "friendship_id": fid}

    def reject_friend_request(self, request_id: str) -> dict:
        with self._get_conn() as conn:
            conn.execute(
                "UPDATE friend_requests SET status = 'rejected' WHERE id = ?", (request_id,)
            )
            conn.commit()
        return {"status": "rejected"}

    def remove_friend(self, friendship_id: str) -> dict:
        with self._get_conn() as conn:
            conn.execute("DELETE FROM friendships WHERE id = ?", (friendship_id,))
            conn.commit()
        return {"status": "removed"}

    def get_friends(self, user: str) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM friendships WHERE user_a = ? OR user_b = ?", (user, user)
            ).fetchall()
        friends = []
        for r in rows:
            friend = r["user_b"] if r["user_a"] == user else r["user_a"]
            friends.append({"friendship_id": r["id"], "friend": friend, "since": r["created_at"]})
        return friends

    def get_friend_requests(self, user: str) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM friend_requests WHERE to_user = ? AND status = 'pending' ORDER BY created_at DESC",
                (user,),
            ).fetchall()
        return [{"id": r["id"], "from_user": r["from_user"], "created_at": r["created_at"]} for r in rows]

    def get_leaderboard(self, user: str) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT user_a, user_b FROM friendships WHERE user_a = ? OR user_b = ?",
                (user, user),
            ).fetchall()
        friends = set()
        for r in rows:
            friends.add(r["user_b"] if r["user_a"] == user else r["user_a"])
        friends.add(user)

        leaderboard = []
        for friend in friends:
            weights = self.get_weights(7)
            streak = (date.today() - date.today()).days
            leaderboard.append({"user": friend, "streak_days": streak, "weights_count": len(weights)})
        leaderboard.sort(key=lambda x: x["streak_days"], reverse=True)
        return leaderboard

    # ── Reminders ────────────────────────────────────────────────────

    def save_reminders(self, reminders: list[dict]) -> list[dict]:
        saved = []
        with self._get_conn() as conn:
            conn.execute("DELETE FROM reminders")
            for r in reminders:
                rid = r.get("id") or __import__("uuid").uuid4().hex[:12]
                category = r.get("category") or "meal"
                meal_type = r.get("meal_type") or r.get("type") or category
                payload = {
                    "id": rid,
                    "meal_type": meal_type,
                    "time": r.get("time", ""),
                    "enabled": bool(r.get("enabled", True)),
                    "category": category,
                    "title": r.get("title") or meal_type.replace("_", " ").title(),
                    "target_id": r.get("target_id") or "",
                    "days_of_week": r.get("days_of_week") or "",
                    "interval_minutes": int(r.get("interval_minutes") or 60),
                }
                payload["interval_minutes"] = max(5, min(720, payload["interval_minutes"]))
                conn.execute(
                    """INSERT INTO reminders
                       (id, meal_type, time, enabled, category, title, target_id, days_of_week, interval_minutes)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        payload["id"], payload["meal_type"], payload["time"],
                        1 if payload["enabled"] else 0, payload["category"],
                        payload["title"], payload["target_id"], payload["days_of_week"],
                        payload["interval_minutes"],
                    ),
                )
                saved.append(payload)
            conn.commit()
        return saved

    def get_reminders(self) -> list[dict]:
        with self._get_conn() as conn:
            rows = conn.execute("SELECT * FROM reminders ORDER BY time").fetchall()
        return [
            {
                "id": r["id"],
                "meal_type": r["meal_type"],
                "time": r["time"],
                "enabled": bool(r["enabled"]),
                "category": r["category"],
                "title": r["title"],
                "target_id": r["target_id"],
                "days_of_week": r["days_of_week"],
                "interval_minutes": int(r["interval_minutes"] or 60),
            }
            for r in rows
        ]

    # ── Macro Goals ──────────────────────────────────────────────────

    def save_macro_goals(self, goals: dict) -> dict:
        import json
        meal_shares = goals.get("meal_shares")
        meal_shares_json = json.dumps(meal_shares, ensure_ascii=False) if isinstance(meal_shares, dict) else "{}"
        with self._get_conn() as conn:
            conn.execute("UPDATE macro_goals SET active = 0")
            conn.execute(
                "INSERT INTO macro_goals (daily_calories, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, water_ml, meal_shares_json, active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)",
                (goals.get("daily_calories"), goals.get("protein_g"), goals.get("carbs_g"), goals.get("fat_g"),
                 goals.get("fiber_g"), goals.get("sugar_g"), goals.get("sodium_mg"),
                 goals.get("water_ml"), meal_shares_json),
            )
            conn.commit()
        return self.get_macro_goals() or goals

    def get_macro_goals(self) -> dict | None:
        import json
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT * FROM macro_goals WHERE active = 1 ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        if not row:
            return None
        meal_shares = {}
        try:
            meal_shares = json.loads(row["meal_shares_json"] or "{}")
        except Exception:
            meal_shares = {}
        return {"daily_calories": row["daily_calories"], "protein_g": row["protein_g"], "carbs_g": row["carbs_g"], "fat_g": row["fat_g"],
                "fiber_g": row["fiber_g"], "sugar_g": row["sugar_g"], "sodium_mg": row["sodium_mg"],
                "water_ml": row["water_ml"], "meal_shares": meal_shares}

    # ── Daily Summary ─────────────────────────────────────────────

    def get_daily_summary(
        self, day: str | None = None,
        foods: list[Food] | None = None,
        goal: Goal | None = None,
    ) -> DailySummary:
        day = day or date.today().isoformat()
        g = goal or Goal()

        # Aggregate foods
        total_cal = sum(f.calories for f in (foods or []))
        total_p = sum(f.protein for f in (foods or []))
        total_c = sum(f.carbs for f in (foods or []))
        total_f = sum(f.fat for f in (foods or []))
        total_fiber = sum(f.fiber for f in (foods or []))
        total_sugar = sum(getattr(f, "sugar", 0) for f in (foods or []))
        total_added_sugar = sum(getattr(f, "added_sugar", 0) for f in (foods or []))
        total_sodium = sum(getattr(f, "sodium", 0) for f in (foods or []))
        total_sat_fat = sum(getattr(f, "sat_fat", 0) for f in (foods or []))
        total_trans_fat = sum(getattr(f, "trans_fat", 0) for f in (foods or []))
        total_cholesterol = sum(getattr(f, "cholesterol", 0) for f in (foods or []))
        total_vitamin_a = sum(getattr(f, "vitamin_a", 0) for f in (foods or []))
        total_vitamin_c = sum(getattr(f, "vitamin_c", 0) for f in (foods or []))
        total_calcium = sum(getattr(f, "calcium", 0) for f in (foods or []))
        total_iron = sum(getattr(f, "iron", 0) for f in (foods or []))
        total_potassium = sum(getattr(f, "potassium", 0) for f in (foods or []))
        total_magnesium = sum(getattr(f, "magnesium", 0) for f in (foods or []))
        total_zinc = sum(getattr(f, "zinc", 0) for f in (foods or []))
        total_folate = sum(getattr(f, "folate", 0) for f in (foods or []))
        total_vitamin_d = sum(getattr(f, "vitamin_d", 0) for f in (foods or []))
        total_vitamin_b12 = sum(getattr(f, "vitamin_b12", 0) for f in (foods or []))
        total_vitamin_e = sum(getattr(f, "vitamin_e", 0) for f in (foods or []))
        total_vitamin_k = sum(getattr(f, "vitamin_k", 0) for f in (foods or []))
        total_omega_3 = sum(getattr(f, "omega_3", 0) for f in (foods or []))
        total_monounsaturated_fat = sum(getattr(f, "monounsaturated_fat", 0) for f in (foods or []))
        total_polyunsaturated_fat = sum(getattr(f, "polyunsaturated_fat", 0) for f in (foods or []))

        # Exercise calories
        exercises = self.get_exercises(day)
        exercise_cal = sum(ex.calories_burned for ex in exercises)

        # Water / drinks
        hydration = self.get_hydration_summary(day)
        legacy_water = self.get_water(day)
        drink_calories = hydration.get("calories", 0)
        drink_sugar = hydration.get("sugar_g", 0)
        total_cal += drink_calories
        total_p += hydration.get("protein_g", 0)
        total_c += hydration.get("carbs_g", 0)
        total_f += hydration.get("fat_g", 0)
        total_sugar += drink_sugar
        water = hydration["hydration_effective_ml"] if hydration.get("drink_count", 0) > 0 else legacy_water

        # Steps
        steps = self.get_steps(day)

        # Weight (latest today)
        weights = self.get_weights(1)
        latest_weight = weights[-1].weight_kg if weights else None

        # Custom macro goals override defaults
        macro = self.get_macro_goals()
        protein_goal = macro["protein_g"] if macro and macro.get("protein_g") else g.protein
        carbs_goal = macro["carbs_g"] if macro and macro.get("carbs_g") else g.carbs
        fat_goal = macro["fat_g"] if macro and macro.get("fat_g") else g.fat
        fiber_goal = macro["fiber_g"] if macro and macro.get("fiber_g") else g.fiber
        sugar_goal = macro["sugar_g"] if macro and macro.get("sugar_g") else 50
        sodium_goal = macro["sodium_mg"] if macro and macro.get("sodium_mg") else 2300
        water_goal = macro["water_ml"] if macro and macro.get("water_ml") else 2000
        # Base calorie goal from plan, plus exercise adjustment
        plan = self.get_active_goal_plan()
        base_cal_goal = (
            macro["daily_calories"]
            if macro and macro.get("daily_calories")
            else (plan["daily_calorie_target"] if plan and plan.get("daily_calorie_target") else g.calories)
        )
        adjusted_cal_goal = base_cal_goal + exercise_cal

        # Weight projection: "If every day were like today..."
        net_daily = total_cal - adjusted_cal_goal  # positive = surplus, negative = deficit
        kg_per_day = net_daily / 7700.0  # 7700 kcal ≈ 1 kg
        weeks5 = 5 * 7  # 35 days
        projected_change = kg_per_day * weeks5
        if latest_weight:
            projected_weight = latest_weight + projected_change
            if net_daily < -50:
                projection_text = f"如果每天都像今天，5周后你将减至 {projected_weight:.1f} kg"
            elif net_daily > 50:
                projection_text = f"如果每天都像今天，5周后你将增至 {projected_weight:.1f} kg"
            else:
                projection_text = "如果每天都像今天，5周后体重将维持不变"
        else:
            projection_text = None

        return DailySummary(
            date=day,
            calories_consumed=total_cal,
            calories_burned=exercise_cal,
            calories_goal=adjusted_cal_goal,
            exercise_adjustment=exercise_cal,
            protein=total_p,
            protein_goal=protein_goal,
            carbs=total_c,
            carbs_goal=carbs_goal,
            fat=total_f,
            fat_goal=fat_goal,
            fiber=total_fiber,
            fiber_goal=fiber_goal,
            sugar=total_sugar,
            sugar_goal=sugar_goal,
            added_sugar=total_added_sugar,
            added_sugar_goal=sugar_goal,
            sodium=total_sodium,
            sodium_goal=sodium_goal,
            sat_fat=total_sat_fat,
            trans_fat=total_trans_fat,
            cholesterol=total_cholesterol,
            vitamin_a=total_vitamin_a,
            vitamin_c=total_vitamin_c,
            calcium=total_calcium,
            iron=total_iron,
            potassium=total_potassium,
            magnesium=total_magnesium,
            zinc=total_zinc,
            folate=total_folate,
            vitamin_d=total_vitamin_d,
            vitamin_b12=total_vitamin_b12,
            vitamin_e=total_vitamin_e,
            vitamin_k=total_vitamin_k,
            omega_3=total_omega_3,
            monounsaturated_fat=total_monounsaturated_fat,
            polyunsaturated_fat=total_polyunsaturated_fat,
            water_ml=water,
            water_goal_ml=water_goal,
            hydration_ml=hydration.get("hydration_ml", 0) or water,
            hydration_effective_ml=hydration.get("hydration_effective_ml", 0) or water,
            hydration_goal_ml=water_goal,
            caffeine_mg=hydration.get("caffeine_mg", 0),
            alcohol_g=hydration.get("alcohol_g", 0),
            drink_sugar_g=drink_sugar,
            drink_calories=drink_calories,
            drink_count=hydration.get("drink_count", 0),
            weight_kg=latest_weight,
            meals_count=len(foods or []),
            exercise_count=len(exercises),
            steps=steps,
            weight_projection=projection_text,
        )

    # ── Diary Notes ───────────────────────────────────────────────

    def get_diary_note(self, day: str | None = None) -> dict:
        day = day or date.today().isoformat()
        with self._get_conn() as conn:
            row = conn.execute(
                "SELECT date, note, updated_at FROM diary_notes WHERE date = ?",
                (day,),
            ).fetchone()
        if not row:
            return {"date": day, "note": "", "updated_at": ""}
        return {
            "date": row["date"],
            "note": row["note"] or "",
            "updated_at": row["updated_at"] or "",
        }

    def save_diary_note(self, day: str | None, note: str) -> dict:
        day = day or date.today().isoformat()
        clean_note = (note or "").strip()[:2000]
        updated_at = datetime.now().isoformat(timespec="seconds")
        with self._get_conn() as conn:
            conn.execute(
                """
                INSERT INTO diary_notes (date, note, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET
                    note = excluded.note,
                    updated_at = excluded.updated_at
                """,
                (day, clean_note, updated_at),
            )
        return {"date": day, "note": clean_note, "updated_at": updated_at}

    # ── Insights ──────────────────────────────────────────────────

    def add_insight(self, insight: Insight) -> Insight:
        with self._get_conn() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO insights (id, date, title, body, type, icon) VALUES (?, ?, ?, ?, ?, ?)",
                (insight.id, insight.date, insight.title, insight.body, insight.type, insight.icon),
            )
            conn.commit()
        return insight

    # ── Meal Plans ───────────────────────────────────────────────

    def _save_meal_plan(self, plan, data: dict):
        """Save meal plan to DB."""
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS meal_plans (
                    id TEXT PRIMARY KEY, name TEXT, daily_calorie_target REAL,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            conn.execute(
                "INSERT INTO meal_plans (id, name, daily_calorie_target, data_json) VALUES (?, ?, ?, ?)",
                (plan.id, plan.name or data.get("plan_name", ""), plan.daily_calorie_target, __import__("json").dumps(data, ensure_ascii=False)),
            )
            conn.commit()

    def get_meal_plans(self) -> list[dict]:
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS meal_plans (
                    id TEXT PRIMARY KEY, name TEXT, daily_calorie_target REAL,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            rows = conn.execute(
                "SELECT * FROM meal_plans ORDER BY created_at DESC LIMIT 20"
            ).fetchall()
        return [{"id": r["id"], "name": r["name"], "daily_calorie_target": r["daily_calorie_target"],
                 "created_at": r["created_at"], **(__import__("json").loads(r["data_json"]) if r["data_json"] else {})}
                for r in rows]

    def get_meal_plan(self, plan_id: str) -> dict | None:
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS meal_plans (
                    id TEXT PRIMARY KEY, name TEXT, daily_calorie_target REAL,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            row = conn.execute(
                "SELECT * FROM meal_plans WHERE id = ?",
                (plan_id,),
            ).fetchone()
        if row is None:
            return None
        data = __import__("json").loads(row["data_json"]) if row["data_json"] else {}
        return {"id": row["id"], "name": row["name"], "daily_calorie_target": row["daily_calorie_target"],
                "created_at": row["created_at"], **data}

    def update_meal_plan(self, plan_id: str, data: dict) -> dict | None:
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS meal_plans (
                    id TEXT PRIMARY KEY, name TEXT, daily_calorie_target REAL,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            existing = conn.execute(
                "SELECT * FROM meal_plans WHERE id = ?",
                (plan_id,),
            ).fetchone()
            if existing is None:
                return None
            name = data.get("plan_name") or data.get("name") or existing["name"]
            target = (data.get("daily_targets") or {}).get("calories") or data.get("daily_calorie_target") or existing["daily_calorie_target"]
            conn.execute(
                "UPDATE meal_plans SET name = ?, daily_calorie_target = ?, data_json = ? WHERE id = ?",
                (name, target, __import__("json").dumps(data, ensure_ascii=False), plan_id),
            )
            conn.commit()
        return self.get_meal_plan(plan_id)

    def delete_meal_plan(self, plan_id: str) -> bool:
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS meal_plans (
                    id TEXT PRIMARY KEY, name TEXT, daily_calorie_target REAL,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE
                )
            """)
            cursor = conn.execute("DELETE FROM meal_plans WHERE id = ?", (plan_id,))
            conn.commit()
            return cursor.rowcount > 0

    # ── Goal Plan ───────────────────────────────────────────────

    def save_goal_plan(self, plan_data: dict):
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS goal_plans (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    data_json TEXT,
                    created_at TEXT DEFAULT CURRENT_DATE,
                    active INTEGER DEFAULT 1
                )
            """)
            # Deactivate old plans
            conn.execute("UPDATE goal_plans SET active = 0")
            conn.execute(
                "INSERT INTO goal_plans (data_json, active) VALUES (?, 1)",
                (__import__("json").dumps(plan_data, ensure_ascii=False),),
            )
            conn.commit()

    def get_active_goal_plan(self) -> dict | None:
        with self._get_conn() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS goal_plans (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    data_json TEXT, created_at TEXT DEFAULT CURRENT_DATE, active INTEGER DEFAULT 1
                )
            """)
            row = conn.execute(
                "SELECT data_json FROM goal_plans WHERE active = 1 ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        if row:
            return __import__("json").loads(row["data_json"])
        return None

    def get_insights(self, days: int = 7) -> list[Insight]:
        since = (date.today() - timedelta(days=days)).isoformat()
        with self._get_conn() as conn:
            rows = conn.execute(
                "SELECT * FROM insights WHERE date >= ? ORDER BY date DESC",
                (since,),
            ).fetchall()
        return [Insight(**dict(r)) for r in rows]
