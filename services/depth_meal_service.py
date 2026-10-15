"""Third-stage RGB + depth meal analysis service skeleton.

The real detector and segmentation providers plug into this service. The local
implementation keeps the API and persistence contract runnable while those
model services are being deployed.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import date, datetime
from pathlib import Path
from uuid import uuid4

from services.depth_cloud_pipeline import DepthCloudPipelineClient
from services.depth_nutrition import (
    calculate_item_nutrition,
    estimate_weight_from_volume,
)

DATA_DIR = Path(__file__).parent.parent / "data"
DB_PATH = DATA_DIR / "depth_meal.db"
CAPTURE_FILE_DIR = DATA_DIR / "depth_captures"


class DepthMealService:
    def __init__(self, db_path: Path | None = None):
        self.db_path = db_path or DB_PATH
        self.cloud_pipeline = DepthCloudPipelineClient()
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        DATA_DIR.mkdir(exist_ok=True)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._get_conn() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS meal_captures (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    platform TEXT NOT NULL,
                    device_model TEXT,
                    depth_source TEXT,
                    rgb_url TEXT DEFAULT '',
                    depth_url TEXT DEFAULT '',
                    confidence_url TEXT DEFAULT '',
                    metadata_url TEXT DEFAULT '',
                    user_hint TEXT DEFAULT '',
                    container_hint TEXT DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'created',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS meal_analysis_jobs (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    capture_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    progress REAL DEFAULT 0,
                    message TEXT DEFAULT '',
                    error_message TEXT DEFAULT '',
                    meal_id TEXT DEFAULT '',
                    started_at TEXT,
                    completed_at TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS meal_logs (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    capture_id TEXT,
                    meal_type TEXT DEFAULT '',
                    image_url TEXT DEFAULT '',
                    total_calories REAL DEFAULT 0,
                    total_protein_g REAL DEFAULT 0,
                    total_carbs_g REAL DEFAULT 0,
                    total_fat_g REAL DEFAULT 0,
                    total_fiber_g REAL DEFAULT 0,
                    total_sodium_mg REAL DEFAULT 0,
                    status TEXT DEFAULT 'draft',
                    estimation_mode TEXT DEFAULT 'rgb_depth_grounded_sam2_volume',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    confirmed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS meal_items (
                    id TEXT PRIMARY KEY,
                    meal_id TEXT NOT NULL,
                    food_key TEXT,
                    density_key TEXT,
                    nutrition_key TEXT,
                    name_zh TEXT NOT NULL,
                    name_en TEXT DEFAULT '',
                    category TEXT DEFAULT '',
                    cooking_method TEXT DEFAULT '',
                    mixed_dish INTEGER DEFAULT 0,
                    liquid INTEGER DEFAULT 0,
                    detector TEXT DEFAULT '',
                    detector_phrase TEXT DEFAULT '',
                    detector_score REAL DEFAULT 0,
                    bbox_json TEXT DEFAULT '{}',
                    segmentation_model TEXT DEFAULT '',
                    mask_url TEXT DEFAULT '',
                    mask_preview_base64 TEXT DEFAULT '',
                    mask_area_pixels INTEGER DEFAULT 0,
                    mask_confidence REAL DEFAULT 0,
                    semantic_validation_json TEXT DEFAULT '{}',
                    estimated_volume_ml REAL DEFAULT 0,
                    volume_method TEXT DEFAULT '',
                    depth_source TEXT DEFAULT '',
                    volume_confidence REAL DEFAULT 0,
                    depth_quality_json TEXT DEFAULT '{}',
                    fallback INTEGER DEFAULT 0,
                    fallback_reason TEXT DEFAULT '',
                    density_g_per_ml REAL DEFAULT 0,
                    density_source TEXT DEFAULT '',
                    estimated_grams REAL DEFAULT 0,
                    estimated_grams_min REAL DEFAULT 0,
                    estimated_grams_max REAL DEFAULT 0,
                    calories REAL DEFAULT 0,
                    protein_g REAL DEFAULT 0,
                    carbs_g REAL DEFAULT 0,
                    fat_g REAL DEFAULT 0,
                    fiber_g REAL DEFAULT 0,
                    sodium_mg REAL DEFAULT 0,
                    eaten_ratio REAL DEFAULT 1,
                    oil_level TEXT DEFAULT 'normal',
                    needs_user_check_json TEXT DEFAULT '[]',
                    editable_fields_json TEXT DEFAULT '[]',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS meal_item_ingredients (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meal_item_id TEXT NOT NULL,
                    food_key TEXT NOT NULL,
                    name_zh TEXT NOT NULL,
                    ratio REAL,
                    grams REAL,
                    calories REAL,
                    protein_g REAL,
                    carbs_g REAL,
                    fat_g REAL,
                    fiber_g REAL DEFAULT 0,
                    sodium_mg REAL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS correction_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    meal_id TEXT NOT NULL,
                    item_id TEXT,
                    field_name TEXT NOT NULL,
                    old_value TEXT DEFAULT '{}',
                    new_value TEXT DEFAULT '{}',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS daily_intake (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    calories REAL DEFAULT 0,
                    protein_g REAL DEFAULT 0,
                    carbs_g REAL DEFAULT 0,
                    fat_g REAL DEFAULT 0,
                    fiber_g REAL DEFAULT 0,
                    sodium_mg REAL DEFAULT 0,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(user_id, date)
                );
                """
            )
            self._ensure_columns(
                conn,
                "meal_items",
                {
                    "mask_preview_base64": "TEXT DEFAULT ''",
                    "semantic_validation_json": "TEXT DEFAULT '{}'",
                },
            )

    def pipeline_status(self) -> dict:
        return {
            "cloud_pipeline": self.cloud_pipeline.status(),
        }

    def _ensure_columns(self, conn: sqlite3.Connection, table: str, columns: dict[str, str]) -> None:
        existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        for name, declaration in columns.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")

    def create_capture(self, user_id: str, payload: dict) -> dict:
        capture_id = f"cap_{uuid4().hex[:12]}"
        platform = payload.get("platform", "ios")
        depth_source = payload.get("depth_source", "ios_lidar_scene_depth")
        with self._get_conn() as conn:
            conn.execute(
                """
                INSERT INTO meal_captures
                (id, user_id, platform, device_model, depth_source, user_hint, container_hint)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    capture_id,
                    user_id,
                    platform,
                    payload.get("device_model", ""),
                    depth_source,
                    payload.get("meal_type", ""),
                    payload.get("container_hint", ""),
                ),
            )
        return {
            "capture_id": capture_id,
            "upload_urls": {
                "rgb": f"/v1/meal-captures/{capture_id}/files/rgb",
                "depth": f"/v1/meal-captures/{capture_id}/files/depth",
                "confidence": f"/v1/meal-captures/{capture_id}/files/confidence",
                "metadata": f"/v1/meal-captures/{capture_id}/files/metadata",
            },
        }

    def analyze_capture(self, capture_id: str, user_id: str, payload: dict) -> dict:
        capture = self._get_capture(capture_id)
        if not capture:
            raise KeyError("capture_not_found")

        job_id = f"job_{uuid4().hex[:12]}"
        now = datetime.utcnow().isoformat()
        with self._get_conn() as conn:
            conn.execute(
                """
                INSERT INTO meal_analysis_jobs
                (id, user_id, capture_id, status, progress, message, started_at)
                VALUES (?, ?, ?, 'queued', 0.05, '已创建分析任务', ?)
                """,
                (job_id, user_id, capture_id, now),
            )

        meal = self._run_local_pipeline(capture, user_id, payload)

        with self._get_conn() as conn:
            conn.execute(
                """
                UPDATE meal_analysis_jobs
                SET status='completed', progress=1, message='分析完成', meal_id=?, completed_at=?
                WHERE id=?
                """,
                (meal["meal_id"], datetime.utcnow().isoformat(), job_id),
            )
            conn.execute("UPDATE meal_captures SET status='analyzed' WHERE id=?", (capture_id,))
        return {"job_id": job_id, "status": "queued"}

    def save_capture_file(self, capture_id: str, kind: str, body: bytes) -> dict:
        capture = self._get_capture(capture_id)
        if not capture:
            raise KeyError("capture_not_found")
        if not body:
            raise ValueError("上传文件为空，请重新拍摄。")

        mapping = {
            "rgb": ("rgb.jpg", "rgb_url"),
            "depth": ("depth.bin", "depth_url"),
            "confidence": ("confidence.bin", "confidence_url"),
            "metadata": ("metadata.json", "metadata_url"),
        }
        auxiliary_match = re.fullmatch(r"auxiliary_([0-3])", kind)
        if kind not in mapping and not auxiliary_match:
            raise ValueError("上传文件类型无效，只支持 RGB、Depth、置信度、metadata 和最多 4 张辅助图。")

        if auxiliary_match:
            filename, column = f"auxiliary_{auxiliary_match.group(1)}.jpg", ""
        else:
            filename, column = mapping[kind]
        directory = CAPTURE_FILE_DIR / capture_id
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / filename
        path.write_bytes(body)

        if kind == "metadata":
            try:
                json.loads(body.decode("utf-8"))
            except Exception as exc:
                raise ValueError(f"深度拍摄 metadata 无效：{exc}") from exc

        with self._get_conn() as conn:
            if column:
                conn.execute(f"UPDATE meal_captures SET {column}=?, status='uploaded' WHERE id=?", (str(path), capture_id))
            else:
                conn.execute("UPDATE meal_captures SET status='uploaded' WHERE id=?", (capture_id,))

        return {
            "capture_id": capture_id,
            "kind": kind,
            "path": str(path),
            "bytes": len(body),
            "status": "uploaded",
        }

    def get_job(self, job_id: str) -> dict | None:
        with self._get_conn() as conn:
            job = conn.execute("SELECT * FROM meal_analysis_jobs WHERE id=?", (job_id,)).fetchone()
        if not job:
            return None
        result = self.get_meal(job["meal_id"]) if job["status"] == "completed" and job["meal_id"] else None
        return {
            "job_id": job["id"],
            "status": job["status"],
            "progress": job["progress"],
            "message": job["message"],
            "meal_id": job["meal_id"] or None,
            "result": result,
        }

    def get_meal(self, meal_id: str) -> dict | None:
        with self._get_conn() as conn:
            meal = conn.execute("SELECT * FROM meal_logs WHERE id=?", (meal_id,)).fetchone()
            items = conn.execute("SELECT * FROM meal_items WHERE meal_id=? ORDER BY created_at, id", (meal_id,)).fetchall()
            ingredients = conn.execute(
                """
                SELECT * FROM meal_item_ingredients
                WHERE meal_item_id IN (SELECT id FROM meal_items WHERE meal_id=?)
                ORDER BY id
                """,
                (meal_id,),
            ).fetchall()
        if not meal:
            return None

        ingredients_by_item: dict[str, list[dict]] = {}
        for row in ingredients:
            ingredients_by_item.setdefault(row["meal_item_id"], []).append(
                {
                    "food_key": row["food_key"],
                    "name_zh": row["name_zh"],
                    "ratio": row["ratio"],
                    "grams": row["grams"],
                    "calories": row["calories"],
                    "protein_g": row["protein_g"],
                    "carbs_g": row["carbs_g"],
                    "fat_g": row["fat_g"],
                    "fiber_g": row["fiber_g"],
                    "sodium_mg": row["sodium_mg"],
                }
            )

        return {
            "meal_id": meal["id"],
            "capture_id": meal["capture_id"],
            "status": "completed",
            "estimation_mode": meal["estimation_mode"],
            "total": {
                "calories": round(meal["total_calories"], 1),
                "protein_g": round(meal["total_protein_g"], 1),
                "carbs_g": round(meal["total_carbs_g"], 1),
                "fat_g": round(meal["total_fat_g"], 1),
                "fiber_g": round(meal["total_fiber_g"], 1),
                "sodium_mg": round(meal["total_sodium_mg"], 1),
            },
            "items": [self._serialize_item(row, ingredients_by_item.get(row["id"], [])) for row in items],
            "user_questions": self._build_user_questions(items),
        }

    def patch_item(self, user_id: str, meal_id: str, item_id: str, patch: dict) -> dict:
        with self._get_conn() as conn:
            item = conn.execute("SELECT * FROM meal_items WHERE id=? AND meal_id=?", (item_id, meal_id)).fetchone()
        if not item:
            raise KeyError("item_not_found")

        old_snapshot = dict(item)
        estimated_grams = float(patch.get("estimated_grams", item["estimated_grams"]))
        eaten_ratio = float(patch.get("eaten_ratio", item["eaten_ratio"]))
        oil_level = patch.get("oil_level", item["oil_level"])
        name_zh = patch.get("name_zh", item["name_zh"])

        nutrition_pack = calculate_item_nutrition(
            item["nutrition_key"] or item["food_key"],
            estimated_grams,
            bool(item["mixed_dish"]),
            oil_level,
        )
        nutrition = {
            key: round(value * eaten_ratio, 1)
            for key, value in nutrition_pack["total"].items()
        }

        with self._get_conn() as conn:
            conn.execute(
                """
                UPDATE meal_items
                SET name_zh=?, estimated_grams=?, eaten_ratio=?, oil_level=?,
                    estimated_grams_min=?, estimated_grams_max=?,
                    calories=?, protein_g=?, carbs_g=?, fat_g=?, fiber_g=?, sodium_mg=?,
                    updated_at=CURRENT_TIMESTAMP
                WHERE id=? AND meal_id=?
                """,
                (
                    name_zh,
                    estimated_grams,
                    eaten_ratio,
                    oil_level,
                    estimated_grams,
                    estimated_grams,
                    nutrition["calories"],
                    nutrition["protein_g"],
                    nutrition["carbs_g"],
                    nutrition["fat_g"],
                    nutrition["fiber_g"],
                    nutrition["sodium_mg"],
                    item_id,
                    meal_id,
                ),
            )
            conn.execute("DELETE FROM meal_item_ingredients WHERE meal_item_id=?", (item_id,))
            self._insert_ingredients(conn, item_id, nutrition_pack["ingredients"], eaten_ratio)
            conn.execute(
                """
                INSERT INTO correction_events
                (user_id, meal_id, item_id, field_name, old_value, new_value)
                VALUES (?, ?, ?, 'multi', ?, ?)
                """,
                (user_id, meal_id, item_id, json.dumps(old_snapshot, ensure_ascii=False), json.dumps(patch, ensure_ascii=False)),
            )

        self._recalculate_meal_total(meal_id)
        self._refresh_daily_intake_for_meal(user_id, meal_id)
        return self.get_meal(meal_id)

    def confirm_meal(self, user_id: str, meal_id: str) -> dict:
        meal = self.get_meal(meal_id)
        if not meal:
            raise KeyError("meal_not_found")
        today = date.today().isoformat()
        confirmed_at = datetime.now().isoformat(timespec="seconds")
        with self._get_conn() as conn:
            conn.execute(
                "UPDATE meal_logs SET status='confirmed', confirmed_at=? WHERE id=?",
                (confirmed_at, meal_id),
            )
        self._update_daily_intake(user_id, today)
        return {"meal_id": meal_id, "confirmed": True, "daily_intake": self.get_daily_intake(user_id, today)}

    def get_daily_intake(self, user_id: str, day: str) -> dict:
        with self._get_conn() as conn:
            row = conn.execute("SELECT * FROM daily_intake WHERE user_id=? AND date=?", (user_id, day)).fetchone()
        if not row:
            return {"user_id": user_id, "date": day, "calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0, "fiber_g": 0, "sodium_mg": 0}
        return {
            "user_id": user_id,
            "date": row["date"],
            "calories": row["calories"],
            "protein_g": row["protein_g"],
            "carbs_g": row["carbs_g"],
            "fat_g": row["fat_g"],
            "fiber_g": row["fiber_g"],
            "sodium_mg": row["sodium_mg"],
        }

    def _get_capture(self, capture_id: str) -> sqlite3.Row | None:
        with self._get_conn() as conn:
            return conn.execute("SELECT * FROM meal_captures WHERE id=?", (capture_id,)).fetchone()

    def _run_local_pipeline(self, capture: sqlite3.Row, user_id: str, payload: dict) -> dict:
        scene = self._scene_from_cloud(capture, payload)
        meal_id = f"meal_{uuid4().hex[:12]}"
        with self._get_conn() as conn:
            conn.execute(
                """
                INSERT INTO meal_logs (id, user_id, capture_id, meal_type, image_url, status)
                VALUES (?, ?, ?, ?, ?, 'draft')
                """,
                (meal_id, user_id, capture["id"], payload.get("meal_type", capture["user_hint"] or "lunch"), capture["rgb_url"] or ""),
            )
            items = self._filter_micro_pipeline_items(scene["items"])
            for index, item in enumerate(items, start=1):
                self._persist_pipeline_item(conn, meal_id, item, capture["depth_source"], index)
        self._recalculate_meal_total(meal_id)
        return self.get_meal(meal_id)

    def _filter_micro_pipeline_items(self, items: list[dict]) -> list[dict]:
        """Hide tiny depth fragments from the main meal result.

        The cloud pipeline can legitimately produce a very small SAM2 mask for
        garnish, bowl residue, or a background fragment. Those should not become
        user-facing meal items unless every detected item is tiny.
        """
        filtered = [item for item in items if not self._is_micro_pipeline_item(item)]
        return filtered or items

    def _is_micro_pipeline_item(self, item: dict) -> bool:
        try:
            volume_ml = float(item.get("volume_ml") or 0)
        except (TypeError, ValueError):
            volume_ml = 0.0
        if volume_ml <= 0:
            return False

        category = str(item.get("category") or "").lower()
        if any(token in category for token in ("sauce", "drink", "soup", "liquid", "酱", "饮", "汤")):
            return False

        name = str(item.get("name_zh") or item.get("name_en") or "")
        micro_name_tokens = ("葱", "香菜", "芝麻", "辣椒碎", "碎末", "少量", "点缀")
        if volume_ml < 8 and any(token in name for token in micro_name_tokens):
            return True

        detector_score = float(item.get("detector_score") or item.get("confidence") or 0.0)
        mask_area = int(item.get("mask_area_pixels") or 0)
        return volume_ml < 5 or (volume_ml < 10 and detector_score < 0.35 and mask_area < 12000)

    def _scene_from_cloud(self, capture: sqlite3.Row, payload: dict) -> dict:
        capture_dict = dict(capture)
        if not self.cloud_pipeline.enabled:
            raise RuntimeError("真实 Depth pipeline 未启动：请启动 18003 上的 VLM + GroundingDINO + SAM2 服务。")
        try:
            return self.cloud_pipeline.analyze_capture(capture_dict, payload)
        except Exception as exc:
            message = f"真实 Depth pipeline 调用失败：{type(exc).__name__}: {str(exc)[:220]}"
            print(f"[DepthMealService] {message}")
            raise RuntimeError(message) from exc

    def _persist_pipeline_item(self, conn: sqlite3.Connection, meal_id: str, item: dict, depth_source: str, index: int) -> None:
        item_id = f"item_{uuid4().hex[:12]}"
        weight = estimate_weight_from_volume(
            item["food_key"],
            item["volume_ml"],
            item.get("density_hint") if isinstance(item.get("density_hint"), dict) else None,
            item.get("category", ""),
            item.get("name_zh") or item.get("name_en") or "",
        )
        nutrition_pack = calculate_item_nutrition(
            item["food_key"],
            weight["estimated_grams"],
            bool(item["mixed_dish"]),
            nutrition_per_100g=item.get("nutrition_per_100g") if isinstance(item.get("nutrition_per_100g"), dict) else None,
        )
        nutrition = nutrition_pack["total"]
        depth_quality = item.get("depth_quality") or {
            "valid_depth_ratio": 0.0,
            "mean_confidence": 0.0,
            "base_plane_inlier_ratio": 0.0,
            "volume_confidence": 0.0,
        }
        volume_confidence = float(depth_quality.get("volume_confidence") or item.get("confidence") or 0.0)
        bbox = item.get("bbox") or [120 * index, 180, 420 * index, 680]
        editable_fields = ["estimated_grams", "eaten_ratio"]
        if item["mixed_dish"]:
            editable_fields += ["oil_level", "ingredient_ratio"]
        if item["liquid"]:
            editable_fields += ["eaten_ratio", "estimated_grams"]

        conn.execute(
            """
            INSERT INTO meal_items
            (id, meal_id, food_key, density_key, nutrition_key, name_zh, name_en, category,
             cooking_method, mixed_dish, liquid, detector, detector_phrase, detector_score,
             bbox_json, segmentation_model, mask_url, mask_preview_base64, mask_area_pixels, mask_confidence,
             semantic_validation_json,
             estimated_volume_ml, volume_method, depth_source, volume_confidence, depth_quality_json,
             fallback, fallback_reason, density_g_per_ml, density_source, estimated_grams,
             estimated_grams_min, estimated_grams_max, calories, protein_g, carbs_g, fat_g,
             fiber_g, sodium_mg, needs_user_check_json, editable_fields_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item_id,
                meal_id,
                item["food_key"],
                weight["density_key"],
                item["food_key"],
                item["name_zh"],
                item["name_en"],
                item["category"],
                item["cooking_method"],
                1 if item["mixed_dish"] else 0,
                1 if item["liquid"] else 0,
                item.get("detector", "grounding_dino_1_5"),
                item["detector_phrase"],
                float(item.get("detector_score") or 0.0),
                json.dumps(bbox),
                item.get("segmentation_model", "sam2"),
                item.get("mask_url") or f"s3://local-debug/masks/{item_id}.png",
                item.get("mask_preview_base64") or "",
                int(item.get("mask_area_pixels") or 0),
                float(item.get("mask_confidence") or 0.0),
                json.dumps(item.get("semantic_validation") or {}),
                item["volume_ml"],
                item.get("volume_method") or ("depth_plane_grid_integration" if not item["liquid"] else "container_capacity_fill_ratio"),
                depth_source,
                volume_confidence,
                json.dumps(depth_quality),
                1 if item.get("fallback") else 0,
                item.get("fallback_reason") or "",
                weight["density_g_per_ml"],
                weight["density_source"],
                weight["estimated_grams"],
                weight["estimated_grams_min"],
                weight["estimated_grams_max"],
                nutrition["calories"],
                nutrition["protein_g"],
                nutrition["carbs_g"],
                nutrition["fat_g"],
                nutrition["fiber_g"],
                nutrition["sodium_mg"],
                json.dumps(item.get("needs_user_check") or (["oil_level"] if item["mixed_dish"] else [])),
                json.dumps(editable_fields),
            ),
        )
        self._insert_ingredients(conn, item_id, nutrition_pack["ingredients"], 1.0)

    def _insert_ingredients(self, conn: sqlite3.Connection, item_id: str, ingredients: list[dict], eaten_ratio: float) -> None:
        for ingredient in ingredients:
            conn.execute(
                """
                INSERT INTO meal_item_ingredients
                (meal_item_id, food_key, name_zh, ratio, grams, calories, protein_g, carbs_g, fat_g, fiber_g, sodium_mg)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item_id,
                    ingredient["food_key"],
                    ingredient["name_zh"],
                    ingredient["ratio"],
                    round(ingredient["grams"] * eaten_ratio, 1),
                    round(ingredient["calories"] * eaten_ratio, 1),
                    round(ingredient["protein_g"] * eaten_ratio, 1),
                    round(ingredient["carbs_g"] * eaten_ratio, 1),
                    round(ingredient["fat_g"] * eaten_ratio, 1),
                    round(ingredient["fiber_g"] * eaten_ratio, 1),
                    round(ingredient["sodium_mg"] * eaten_ratio, 1),
                ),
            )

    def _serialize_item(self, row: sqlite3.Row, ingredients: list[dict]) -> dict:
        return {
            "item_id": row["id"],
            "name_zh": row["name_zh"],
            "name_en": row["name_en"],
            "canonical_food_key": row["food_key"],
            "category": row["category"],
            "cooking_method": row["cooking_method"],
            "mixed_dish": bool(row["mixed_dish"]),
            "liquid": bool(row["liquid"]),
            "detection": {
                "detector": row["detector"],
                "phrase": row["detector_phrase"],
                "bbox_xyxy": json.loads(row["bbox_json"] or "[]"),
                "score": row["detector_score"],
            },
            "segmentation": {
                "model": row["segmentation_model"],
                "mask_url": row["mask_url"],
                "mask_preview_base64": row["mask_preview_base64"],
                "area_pixels": row["mask_area_pixels"],
                "mask_confidence": row["mask_confidence"],
            },
            "semantic_validation": json.loads(row["semantic_validation_json"] or "{}"),
            "volume": {
                "estimated_volume_ml": row["estimated_volume_ml"],
                "volume_method": row["volume_method"],
                "depth_source": row["depth_source"],
                "fallback": bool(row["fallback"]),
                "fallback_reason": row["fallback_reason"] or None,
                "depth_quality": json.loads(row["depth_quality_json"] or "{}"),
            },
            "weight": {
                "density_key": row["density_key"],
                "density_g_per_ml": row["density_g_per_ml"],
                "estimated_grams": row["estimated_grams"],
                "estimated_grams_min": row["estimated_grams_min"],
                "estimated_grams_max": row["estimated_grams_max"],
                "density_source": row["density_source"],
            },
            "nutrition": {
                "calories": row["calories"],
                "protein_g": row["protein_g"],
                "carbs_g": row["carbs_g"],
                "fat_g": row["fat_g"],
                "fiber_g": row["fiber_g"],
                "sodium_mg": row["sodium_mg"],
            },
            "ingredients": ingredients,
            "editable_fields": json.loads(row["editable_fields_json"] or "[]"),
            "needs_user_check": json.loads(row["needs_user_check_json"] or "[]"),
        }

    def _build_user_questions(self, items: list[sqlite3.Row]) -> list[dict]:
        questions = []
        for row in items:
            if row["mixed_dish"]:
                questions.append(
                    {
                        "field": "oil_level",
                        "item_id": row["id"],
                        "question": f"{row['name_zh']}实际油量是少油、正常还是偏油？",
                        "options": ["少油", "正常", "偏油"],
                    }
                )
        questions.append(
            {
                "field": "eaten_ratio",
                "item_id": None,
                "question": "这顿饭吃完了吗？",
                "options": ["全部", "3/4", "一半", "1/4"],
            }
        )
        return questions

    def _recalculate_meal_total(self, meal_id: str) -> None:
        with self._get_conn() as conn:
            row = conn.execute(
                """
                SELECT
                    COALESCE(SUM(calories), 0) AS calories,
                    COALESCE(SUM(protein_g), 0) AS protein_g,
                    COALESCE(SUM(carbs_g), 0) AS carbs_g,
                    COALESCE(SUM(fat_g), 0) AS fat_g,
                    COALESCE(SUM(fiber_g), 0) AS fiber_g,
                    COALESCE(SUM(sodium_mg), 0) AS sodium_mg
                FROM meal_items WHERE meal_id=?
                """,
                (meal_id,),
            ).fetchone()
            conn.execute(
                """
                UPDATE meal_logs
                SET total_calories=?, total_protein_g=?, total_carbs_g=?, total_fat_g=?,
                    total_fiber_g=?, total_sodium_mg=?
                WHERE id=?
                """,
                (row["calories"], row["protein_g"], row["carbs_g"], row["fat_g"], row["fiber_g"], row["sodium_mg"], meal_id),
            )

    def _refresh_daily_intake_for_meal(self, user_id: str, meal_id: str) -> None:
        with self._get_conn() as conn:
            meal = conn.execute("SELECT status, confirmed_at, created_at FROM meal_logs WHERE id=? AND user_id=?", (meal_id, user_id)).fetchone()
        if not meal or meal["status"] != "confirmed":
            return
        day = (meal["confirmed_at"] or meal["created_at"] or date.today().isoformat())[:10]
        self._update_daily_intake(user_id, day)

    def _update_daily_intake(self, user_id: str, day: str) -> None:
        with self._get_conn() as conn:
            row = conn.execute(
                """
                SELECT
                    COALESCE(SUM(total_calories), 0) AS calories,
                    COALESCE(SUM(total_protein_g), 0) AS protein_g,
                    COALESCE(SUM(total_carbs_g), 0) AS carbs_g,
                    COALESCE(SUM(total_fat_g), 0) AS fat_g,
                    COALESCE(SUM(total_fiber_g), 0) AS fiber_g,
                    COALESCE(SUM(total_sodium_mg), 0) AS sodium_mg
                FROM meal_logs
                WHERE user_id=? AND status='confirmed' AND substr(COALESCE(confirmed_at, created_at), 1, 10)=?
                """,
                (user_id, day),
            ).fetchone()
            conn.execute(
                """
                INSERT INTO daily_intake
                (user_id, date, calories, protein_g, carbs_g, fat_g, fiber_g, sodium_mg, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(user_id, date) DO UPDATE SET
                    calories=excluded.calories,
                    protein_g=excluded.protein_g,
                    carbs_g=excluded.carbs_g,
                    fat_g=excluded.fat_g,
                    fiber_g=excluded.fiber_g,
                    sodium_mg=excluded.sodium_mg,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (user_id, day, row["calories"], row["protein_g"], row["carbs_g"], row["fat_g"], row["fiber_g"], row["sodium_mg"]),
            )
