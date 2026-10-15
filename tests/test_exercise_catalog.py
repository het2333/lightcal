"""Tests for exercise catalog estimates and persisted exercise summaries."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import services.tracking_service as tracking_module
import pytest
import server
from models.tracking import Exercise
from services.exercise_catalog import estimate_exercise_calories, get_exercise_catalog
from services.tracking_service import TrackingService


def test_exercise_catalog_has_real_categories():
    catalog = get_exercise_catalog()
    categories = {item["category"] for item in catalog}

    assert len(catalog) >= 20
    assert {"cardio", "strength", "mobility", "sports", "daily"}.issubset(categories)
    assert any(item["name"] == "羽毛球" for item in catalog)


def test_exercise_estimate_uses_intensity_and_weight():
    light = estimate_exercise_calories(
        exercise_id="running",
        duration_minutes=30,
        intensity="light",
        body_weight_kg=70,
    )
    vigorous = estimate_exercise_calories(
        exercise_id="running",
        duration_minutes=30,
        intensity="vigorous",
        body_weight_kg=70,
    )

    assert light["met"] < vigorous["met"]
    assert vigorous["calories_burned"] > light["calories_burned"]


def test_exercise_persists_and_refreshes_summary(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    estimate = estimate_exercise_calories(
        exercise_id="badminton",
        duration_minutes=45,
        intensity="moderate",
        body_weight_kg=70,
    )

    tracking.add_exercise(
        Exercise(
            name="羽毛球",
            duration_minutes=estimate["duration_minutes"],
            intensity=estimate["intensity"],
            calories_burned=estimate["calories_burned"],
            date="2026-05-23",
        )
    )
    summary = tracking.get_daily_summary("2026-05-23")

    assert summary.exercise_count == 1
    assert summary.calories_burned == estimate["calories_burned"]
    assert summary.exercise_adjustment == estimate["calories_burned"]


@pytest.mark.asyncio
async def test_exercise_endpoint_rejects_negative_manual_calories(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())

    with pytest.raises(server.HTTPException) as error:
        await server.add_exercise_endpoint(server.AddExerciseRequest(
            name="步行",
            duration_minutes=30,
            intensity="moderate",
            calories_burned=-100,
            date="2026-05-23",
        ))

    assert error.value.status_code == 400
    assert "不能小于 0" in error.value.detail
    assert server.tracking.get_exercises("2026-05-23") == []
