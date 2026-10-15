"""Tests for grounded meal recommendations and preference persistence."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import services.tracking_service as tracking_module
from models.tracking import DailySummary
from services.food_database import FoodDatabase
from services.recommendation_service import RecommendationService
from services.tracking_service import TrackingService


def make_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    service = RecommendationService(food_db=food_db, tracking=tracking)
    return food_db, tracking, service


@pytest.mark.asyncio
async def test_today_recommendations_are_persisted(tmp_path, monkeypatch):
    _, tracking, service = make_services(tmp_path, monkeypatch)
    summary = DailySummary(
        date="2026-05-23",
        calories_consumed=600,
        calories_goal=1900,
        protein=30,
        protein_goal=110,
        carbs=80,
        carbs_goal=210,
        fat=20,
        fat_goal=60,
    )

    payload = await service.today(summary, meal_type="dinner", limit=2, use_ai=False)

    assert payload["source"] == "rules"
    assert len(payload["recommendations"]) == 2
    first = payload["recommendations"][0]
    assert first["calories"] > 0
    assert first["protein"] >= 0
    assert first["foods"]
    event = tracking.get_recommendation_event(first["id"])
    assert event is not None
    assert event["recommendation"]["id"] == first["id"]


@pytest.mark.asyncio
async def test_reloading_same_recommendations_does_not_create_or_update_events(tmp_path, monkeypatch):
    _, tracking, service = make_services(tmp_path, monkeypatch)
    summary = DailySummary(
        date="2026-05-23",
        calories_consumed=600,
        calories_goal=1900,
        protein=30,
        protein_goal=110,
        carbs=80,
        carbs_goal=210,
        fat=20,
        fat_goal=60,
    )

    first = await service.today(summary, meal_type="dinner", limit=2, use_ai=False)
    with tracking._get_conn() as conn:
        before = [tuple(row) for row in conn.execute(
            "SELECT id, date, meal_type, source, recommendation_json, logged, logged_at "
            "FROM recommendation_events ORDER BY id"
        ).fetchall()]

    second = await service.today(summary, meal_type="dinner", limit=2, use_ai=False)
    with tracking._get_conn() as conn:
        after = [tuple(row) for row in conn.execute(
            "SELECT id, date, meal_type, source, recommendation_json, logged, logged_at "
            "FROM recommendation_events ORDER BY id"
        ).fetchall()]

    assert [item["id"] for item in second["recommendations"]] == [
        item["id"] for item in first["recommendations"]
    ]
    assert after == before


@pytest.mark.asyncio
async def test_reloading_reuses_legacy_event_with_random_ids(tmp_path, monkeypatch):
    _, tracking, service = make_services(tmp_path, monkeypatch)
    summary = DailySummary(date="2026-05-23", calories_goal=1800, protein_goal=90)
    generated = await service.today(summary, meal_type="dinner", limit=1, use_ai=False)
    recommendation = generated["recommendations"][0]
    legacy = {
        **recommendation,
        "id": "legacy-random",
        "foods": [
            {**food, "id": f"legacy-food-{index}"}
            for index, food in enumerate(recommendation["foods"])
        ],
    }
    with tracking._get_conn() as conn:
        conn.execute("DELETE FROM recommendation_events")
        conn.execute(
            """INSERT INTO recommendation_events
               (id, date, meal_type, source, recommendation_json, logged)
               VALUES (?, ?, ?, ?, ?, 0)""",
            ("legacy-random", summary.date, "dinner", "rules", json.dumps(legacy, ensure_ascii=False)),
        )
        conn.commit()

    reloaded = await service.today(summary, meal_type="dinner", limit=1, use_ai=False)
    with tracking._get_conn() as conn:
        rows = conn.execute("SELECT id, recommendation_json FROM recommendation_events").fetchall()

    assert reloaded["recommendations"][0]["id"] == "legacy-random"
    assert len(rows) == 1
    assert json.loads(rows[0]["recommendation_json"]) == legacy


def test_challenge_seed_does_not_touch_unchanged_templates(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    with tracking._get_conn() as conn:
        conn.execute(
            "UPDATE challenges SET updated_at = '2020-01-02 03:04:05' WHERE id = 'photo_checkin_7'"
        )
        conn.commit()

    TrackingService()

    with tracking._get_conn() as conn:
        row = conn.execute(
            "SELECT title, status, updated_at FROM challenges WHERE id = 'photo_checkin_7'"
        ).fetchone()
    assert tuple(row) == ("7天拍照记录", "available", "2020-01-02 03:04:05")


@pytest.mark.asyncio
async def test_preferences_filter_recommendations(tmp_path, monkeypatch):
    _, _, service = make_services(tmp_path, monkeypatch)
    service.tracking.save_user_preferences({
        "diet_type": "vegetarian",
        "avoid_ingredients": ["鸡"],
        "allergies": [],
        "favorite_cuisines": ["中式"],
        "taste_tags": ["清淡"],
    })
    summary = DailySummary(date="2026-05-23", calories_goal=1800, protein_goal=80)

    payload = await service.today(summary, meal_type="lunch", limit=3, use_ai=False)

    blocked = ["鸡", "牛", "猪", "鱼", "虾", "肉"]
    for rec in payload["recommendations"]:
        for food in rec["foods"]:
            assert all(term not in food["name"] for term in blocked)


@pytest.mark.asyncio
async def test_recommendation_scaling_and_logged_state(tmp_path, monkeypatch):
    _, tracking, service = make_services(tmp_path, monkeypatch)
    payload = await service.today(DailySummary(date="2026-05-23"), meal_type="snack", limit=1, use_ai=False)
    rec = payload["recommendations"][0]

    scaled = service.scale_recommendation_foods(rec, 1.5)
    tracking.mark_recommendation_logged(rec["id"])
    event = tracking.get_recommendation_event(rec["id"])

    assert scaled
    assert sum(food.calories for food in scaled) > rec["calories"]
    assert event["logged"] == 1


@pytest.mark.asyncio
async def test_delivery_draft_is_nutrition_grounded_and_persisted(tmp_path, monkeypatch):
    _, tracking, service = make_services(tmp_path, monkeypatch)
    day = "2026-05-23"
    payload = await service.today(DailySummary(date=day, calories_goal=1800, protein_goal=90), meal_type="dinner", limit=1, use_ai=False)
    rec = payload["recommendations"][0]

    draft = service.build_delivery_draft(rec, portion_multiplier=1.2, provider="meituan")
    saved = tracking.save_delivery_order_draft(rec["id"], day, rec["meal_type"], "meituan", draft)
    loaded = tracking.get_delivery_order_draft(saved["id"])
    recent = tracking.list_delivery_order_drafts(day)

    assert saved["provider"] == "meituan"
    assert saved["nutrition"]["calories"] > rec["calories"]
    assert saved["search_query"]
    assert "少油少盐" in saved["order_note"]
    assert loaded and loaded["id"] == saved["id"]
    assert recent and recent[0]["recommendation_id"] == rec["id"]
