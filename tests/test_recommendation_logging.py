"""Regression coverage for idempotent recommendation logging."""

import asyncio
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
import services.tracking_service as tracking_module
from models.food import Food
from services.decision_service import DecisionService
from services.food_database import FoodDatabase
from services.recommendation_service import RecommendationService
from services.tracking_service import TrackingService


def configure_isolated_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    tracking = TrackingService()
    decision_service = DecisionService(tracking=tracking)
    recommendation_service = RecommendationService(
        food_db=food_db,
        tracking=tracking,
        decision_service=decision_service,
    )
    monkeypatch.setattr(server, "food_db", food_db)
    monkeypatch.setattr(server, "tracking", tracking)
    monkeypatch.setattr(server, "decision_service", decision_service)
    monkeypatch.setattr(server, "recommendation_service", recommendation_service)
    monkeypatch.setattr(server, "_FOOD_STREAK_CACHE", {"value": None, "at": 0.0})

    day = "2026-08-14"
    recommendation = {
        "title": "鸡胸肉套餐",
        "meal_type": "dinner",
        "foods": [
            Food(
                name="烤鸡胸肉", calories=330, protein=62, carbs=0, fat=7,
                fiber=0, sugar=0, sodium=380, serving_size="250克",
            ).model_dump(),
            Food(
                name="熟白米饭", calories=260, protein=5, carbs=58, fat=1,
                fiber=1, sugar=0, sodium=5, serving_size="200克",
            ).model_dump(),
            Food(
                name="蒸西兰花", calories=110, protein=7, carbs=20, fat=1,
                fiber=8, sugar=3, sodium=90, serving_size="250克",
            ).model_dump(),
        ],
    }
    saved = tracking.save_recommendation_event(
        "ignored-id", day, "dinner", "rules", recommendation
    )
    return food_db, tracking, saved["id"], day


def table_count(connection_factory, table, where="", params=()):
    with connection_factory() as conn:
        query = f"SELECT COUNT(*) AS count FROM {table}"
        if where:
            query += f" WHERE {where}"
        return conn.execute(query, params).fetchone()["count"]


@pytest.mark.asyncio
async def test_recommendation_log_is_idempotent_and_preserves_first_logged_at(tmp_path, monkeypatch):
    food_db, tracking, recommendation_id, day = configure_isolated_services(tmp_path, monkeypatch)
    request = server.RecommendationLogRequest(
        date=day, meal_category="dinner", portion_multiplier=1
    )

    first = await server.log_recommendation_endpoint(recommendation_id, request)
    with tracking._get_conn() as conn:
        conn.execute(
            "UPDATE recommendation_events SET logged_at = '2020-01-02 03:04:05' WHERE id = ?",
            (recommendation_id,),
        )
        conn.commit()
    second = await server.log_recommendation_endpoint(recommendation_id, request)

    assert first["already_logged"] is False
    assert second["already_logged"] is True
    assert first["saved"] == second["saved"] == 3
    assert {item["upload_group_id"] for item in first["foods"]} == {
        item["upload_group_id"] for item in second["foods"]
    }
    assert first["summary"]["calories_consumed"] == 700
    assert second["summary"]["calories_consumed"] == 700
    assert table_count(food_db._get_conn, "food_log_history") == 3
    assert table_count(food_db._get_conn, "food_log_idempotency") == 1
    assert table_count(tracking._get_conn, "decision_events", "source = ?", ("recommendation",)) == 1
    assert table_count(tracking._get_conn, "habit_events", "event_type = ?", ("food",)) == 1
    with tracking._get_conn() as conn:
        event = conn.execute(
            "SELECT logged, logged_at FROM recommendation_events WHERE id = ?",
            (recommendation_id,),
        ).fetchone()
    assert tuple(event) == (1, "2020-01-02 03:04:05")


def run_recommendation_log(recommendation_id, request):
    return asyncio.run(server.log_recommendation_endpoint(recommendation_id, request))


def test_concurrent_recommendation_logs_create_only_one_meal(tmp_path, monkeypatch):
    food_db, tracking, recommendation_id, day = configure_isolated_services(tmp_path, monkeypatch)
    request = server.RecommendationLogRequest(
        date=day, meal_category="dinner", portion_multiplier=1
    )

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [
            pool.submit(run_recommendation_log, recommendation_id, request)
            for _ in range(2)
        ]
        results = [future.result(timeout=10) for future in futures]

    assert sorted(result["already_logged"] for result in results) == [False, True]
    assert {result["summary"]["calories_consumed"] for result in results} == {700}
    assert table_count(food_db._get_conn, "food_log_history") == 3
    assert table_count(food_db._get_conn, "food_log_idempotency") == 1
    assert table_count(tracking._get_conn, "decision_events", "source = ?", ("recommendation",)) == 1
    assert table_count(tracking._get_conn, "habit_events", "event_type = ?", ("food",)) == 1


@pytest.mark.asyncio
async def test_recommendation_idempotency_uses_effective_portion_and_meal_context(tmp_path, monkeypatch):
    food_db, _, recommendation_id, day = configure_isolated_services(tmp_path, monkeypatch)

    clamped = await server.log_recommendation_endpoint(
        recommendation_id,
        server.RecommendationLogRequest(date=day, meal_category="lunch", portion_multiplier=0.4),
    )
    same_effective_portion = await server.log_recommendation_endpoint(
        recommendation_id,
        server.RecommendationLogRequest(date=day, meal_category="lunch", portion_multiplier=0.5),
    )
    different_meal = await server.log_recommendation_endpoint(
        recommendation_id,
        server.RecommendationLogRequest(date=day, meal_category="dinner", portion_multiplier=0.5),
    )

    assert clamped["already_logged"] is False
    assert same_effective_portion["already_logged"] is True
    assert different_meal["already_logged"] is False
    assert table_count(food_db._get_conn, "food_log_history") == 6
    assert table_count(food_db._get_conn, "food_log_idempotency") == 2


@pytest.mark.asyncio
async def test_deleted_recommendation_can_be_logged_again(tmp_path, monkeypatch):
    food_db, _, recommendation_id, day = configure_isolated_services(tmp_path, monkeypatch)
    request = server.RecommendationLogRequest(
        date=day, meal_category="dinner", portion_multiplier=1
    )
    first = await server.log_recommendation_endpoint(recommendation_id, request)
    group_id = first["foods"][0]["upload_group_id"]

    deleted = await server.delete_food_log_endpoint(
        server.FoodLogDeleteRequest(upload_group_id=group_id, date=day)
    )
    relogged = await server.log_recommendation_endpoint(recommendation_id, request)

    assert deleted["deleted"] == 3
    assert relogged["already_logged"] is False
    assert relogged["saved"] == 3
    assert relogged["summary"]["calories_consumed"] == 700
    assert table_count(food_db._get_conn, "food_log_history") == 3
    assert table_count(food_db._get_conn, "food_log_idempotency") == 1
