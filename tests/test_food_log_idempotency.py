"""Request-level idempotency coverage for all generic food-log clients."""

import asyncio
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest
from fastapi import HTTPException

import server
import services.tracking_service as tracking_module
from models.food import Food
from services.decision_service import DecisionService
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


def configure_isolated_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    tracking = TrackingService()
    decision_service = DecisionService(tracking=tracking)
    monkeypatch.setattr(server, "food_db", food_db)
    monkeypatch.setattr(server, "tracking", tracking)
    monkeypatch.setattr(server, "decision_service", decision_service)
    monkeypatch.setattr(server, "_FOOD_STREAK_CACHE", {"value": None, "at": 0.0})
    return food_db, tracking


def make_request(request_id="retry-123", calories=78):
    return server.FoodLogRequest(
        request_id=request_id,
        date="2026-08-15",
        meal_category="breakfast",
        group_title="鸡蛋早餐",
        foods=[
            Food(
                name="鸡蛋", calories=calories, protein=6, carbs=1, fat=5,
                fiber=0, sugar=0, sodium=62, serving_size="1个",
            )
        ],
    )


def count(connection_factory, table, where="", params=()):
    with connection_factory() as conn:
        sql = f"SELECT COUNT(*) AS count FROM {table}"
        if where:
            sql += f" WHERE {where}"
        return conn.execute(sql, params).fetchone()["count"]


@pytest.mark.asyncio
async def test_food_log_retry_returns_original_without_duplicate_side_effects(tmp_path, monkeypatch):
    food_db, tracking = configure_isolated_services(tmp_path, monkeypatch)
    request = make_request()

    first = await server.save_food_log_endpoint(request)
    second = await server.save_food_log_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is True
    assert first["saved"] == second["saved"] == 1
    assert first["foods"] == second["foods"]
    assert first["daily_summary"]["calories_consumed"] == 78
    assert second["daily_summary"]["calories_consumed"] == 78
    assert count(food_db._get_conn, "food_log_history") == 1
    assert count(food_db._get_conn, "food_log_idempotency") == 1
    assert count(tracking._get_conn, "habit_events", "event_type = ?", ("food",)) == 1
    assert count(tracking._get_conn, "decision_events", "source = ?", ("food_log",)) == 1


def run_save(request):
    return asyncio.run(server.save_food_log_endpoint(request))


def test_concurrent_food_log_retry_writes_once(tmp_path, monkeypatch):
    food_db, tracking = configure_isolated_services(tmp_path, monkeypatch)
    request = make_request("concurrent-123")

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [future.result(timeout=10) for future in [
            pool.submit(run_save, request),
            pool.submit(run_save, request),
        ]]

    assert sorted(result["already_logged"] for result in results) == [False, True]
    assert count(food_db._get_conn, "food_log_history") == 1
    assert count(tracking._get_conn, "habit_events", "event_type = ?", ("food",)) == 1
    assert count(tracking._get_conn, "decision_events", "source = ?", ("food_log",)) == 1


@pytest.mark.asyncio
async def test_same_request_id_cannot_be_reused_for_different_food(tmp_path, monkeypatch):
    food_db, _ = configure_isolated_services(tmp_path, monkeypatch)
    await server.save_food_log_endpoint(make_request("collision-123", calories=78))

    with pytest.raises(HTTPException) as caught:
        await server.save_food_log_endpoint(make_request("collision-123", calories=156))

    assert caught.value.status_code == 409
    assert count(food_db._get_conn, "food_log_history") == 1


@pytest.mark.asyncio
async def test_legacy_requests_without_request_id_can_intentionally_log_twice(tmp_path, monkeypatch):
    food_db, _ = configure_isolated_services(tmp_path, monkeypatch)
    request = make_request(request_id="")

    first = await server.save_food_log_endpoint(request)
    second = await server.save_food_log_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is False
    assert count(food_db._get_conn, "food_log_history") == 2
