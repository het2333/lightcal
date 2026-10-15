import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import server
import services.tracking_service as tracking_module
from services.goal_planner import calculate_daily_calories
from services.tracking_service import TrackingService


def test_calorie_plan_supports_loss_maintenance_and_gain():
    assert calculate_daily_calories(2000, 15)["recommended_intake"] == 1700
    assert calculate_daily_calories(2000, 0)["recommended_intake"] == 2000
    assert calculate_daily_calories(2000, -10)["recommended_intake"] == 2200


@pytest.mark.asyncio
async def test_goal_plan_rejects_impossible_body_data_before_persisting(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())

    with pytest.raises(server.HTTPException) as error:
        await server.create_goal_plan_endpoint(server.GoalPlanRequest(
            current_weight_kg=-1,
            goal_weight_kg=65,
            height_cm=0,
            age=30,
        ))

    assert error.value.status_code == 400
    assert server.tracking.get_active_goal_plan() is None


@pytest.mark.asyncio
async def test_macro_goals_reject_negative_targets(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())

    with pytest.raises(server.HTTPException) as error:
        await server.save_macro_goals_endpoint(server.MacroGoalsRequest(
            daily_calories=-204,
            water_ml=-30,
        ))

    assert error.value.status_code == 400
    assert server.tracking.get_macro_goals() is None
