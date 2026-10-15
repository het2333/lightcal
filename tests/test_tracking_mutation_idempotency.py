"""Retry safety for non-food tracking mutations."""

import asyncio
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import server
import services.tracking_service as tracking_module
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


def configure_isolated_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    monkeypatch.setattr(server, "tracking", tracking)
    monkeypatch.setattr(server, "food_db", food_db)
    return tracking, food_db


def count(tracking, table, where="", params=()):
    with tracking._get_conn() as conn:
        sql = f"SELECT COUNT(*) AS count FROM {table}"
        if where:
            sql += f" WHERE {where}"
        return conn.execute(sql, params).fetchone()["count"]


@pytest.mark.asyncio
async def test_hydration_retry_writes_log_and_habit_once(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    request = server.HydrationLogRequest(
        request_id="drink-retry-1",
        drink_type="water",
        amount_ml=250,
        source="ios_swiftui",
        date="2026-08-20",
    )

    first = await server.add_hydration_endpoint(request)
    second = await server.add_hydration_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is True
    assert first["id"] == second["id"]
    assert first["logged_at"] == second["logged_at"]
    assert count(tracking, "hydration_logs") == 1
    assert count(tracking, "habit_events", "event_type = ?", ("hydration",)) == 1


def test_concurrent_hydration_retry_writes_once(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    request = server.HydrationLogRequest(
        request_id="drink-concurrent-1",
        drink_type="water",
        amount_ml=250,
        source="ios_swiftui",
        date="2026-08-20",
    )

    def save():
        return asyncio.run(server.add_hydration_endpoint(request))

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [future.result(timeout=10) for future in [
            pool.submit(save), pool.submit(save),
        ]]

    assert sorted(result["already_logged"] for result in results) == [False, True]
    assert count(tracking, "hydration_logs") == 1
    assert count(tracking, "habit_events", "event_type = ?", ("hydration",)) == 1


@pytest.mark.asyncio
async def test_water_retry_writes_compatibility_tables_once(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    request = server.AddWaterRequest(
        request_id="water-retry-1", amount_ml=300, date="2026-08-20",
    )

    first = await server.add_water_endpoint(request)
    second = await server.add_water_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is True
    assert count(tracking, "water_logs") == 1
    assert count(tracking, "hydration_logs") == 1
    assert count(tracking, "habit_events", "event_type = ?", ("hydration",)) == 1


@pytest.mark.asyncio
async def test_exercise_weight_sleep_and_steps_retries_write_once(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    exercise = server.AddExerciseRequest(
        request_id="exercise-retry-1",
        name="步行",
        duration_minutes=30,
        intensity="moderate",
        calories_burned=120,
        date="2026-08-20",
    )
    weight = server.AddWeightRequest(
        request_id="weight-retry-1", weight_kg=60, date="2026-08-20",
    )
    sleep = server.SleepLogRequest(
        request_id="sleep-retry-1", duration_hours=7.5, quality=4, date="2026-08-20",
    )
    steps = server.AddStepsRequest(
        request_id="steps-retry-1", steps=8000, date="2026-08-20",
    )

    for request, endpoint in (
        (exercise, server.add_exercise_endpoint),
        (weight, server.add_weight_endpoint),
        (sleep, server.add_sleep_endpoint),
        (steps, server.add_steps_endpoint),
    ):
        first = await endpoint(request)
        second = await endpoint(request)
        assert first["already_logged"] is False
        assert second["already_logged"] is True

    assert count(tracking, "exercises") == 1
    assert count(tracking, "weight_logs") == 1
    assert count(tracking, "sleep_logs") == 1
    assert count(tracking, "step_logs") == 1


@pytest.mark.asyncio
async def test_request_id_collision_is_rejected(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    await server.add_hydration_endpoint(server.HydrationLogRequest(
        request_id="collision-1", amount_ml=250, date="2026-08-20",
    ))

    with pytest.raises(server.HTTPException) as caught:
        await server.add_hydration_endpoint(server.HydrationLogRequest(
            request_id="collision-1", amount_ml=500, date="2026-08-20",
        ))

    assert caught.value.status_code == 409
    assert count(tracking, "hydration_logs") == 1


@pytest.mark.asyncio
async def test_voice_log_retry_dedupes_food_drink_and_habits(tmp_path, monkeypatch):
    tracking, food_db = configure_isolated_services(tmp_path, monkeypatch)
    request = server.VoiceLogApplyRequest(
        request_id="voice-retry-1",
        text="一个鸡蛋，一杯水",
        date="2026-08-20",
        meal_category="breakfast",
        foods=[{
            "name": "鸡蛋", "calories": 78, "protein": 6,
            "carbs": 0.6, "fat": 5, "serving_size": "1个",
        }],
        hydration=[{"drink_type": "water", "amount_ml": 250}],
    )

    first = await server.apply_voice_log_endpoint(request)
    second = await server.apply_voice_log_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is True
    assert first["hydration"] == second["hydration"]
    assert count(tracking, "hydration_logs") == 1
    assert count(tracking, "habit_events", "event_type = ?", ("hydration",)) == 1
    assert count(tracking, "habit_events", "event_type = ?", ("food",)) == 1
    with food_db._get_conn() as conn:
        assert conn.execute("SELECT COUNT(*) FROM food_log_history").fetchone()[0] == 1


@pytest.mark.asyncio
async def test_legacy_tracking_requests_can_intentionally_log_twice(tmp_path, monkeypatch):
    tracking, _ = configure_isolated_services(tmp_path, monkeypatch)
    request = server.HydrationLogRequest(
        amount_ml=250, date="2026-08-20", source="legacy",
    )

    first = await server.add_hydration_endpoint(request)
    second = await server.add_hydration_endpoint(request)

    assert first["already_logged"] is False
    assert second["already_logged"] is False
    assert count(tracking, "hydration_logs") == 2
