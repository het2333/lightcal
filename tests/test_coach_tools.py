import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import server
import services.tracking_service as tracking_module
from models.food import Food
from models.tracking import Exercise, WeightLog
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


def make_isolated_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    monkeypatch.setattr(server, "tracking", tracking)
    monkeypatch.setattr(server, "food_db", FoodDatabase(tmp_path / "foods.db"))
    monkeypatch.setattr(server, "_FOOD_STREAK_CACHE", {"value": None, "at": 0.0})
    return tracking


def test_coach_queries_recent_food_range_instead_of_all_history(tmp_path, monkeypatch):
    make_isolated_services(tmp_path, monkeypatch)
    server._save_foods_to_log(
        [Food(name="七日内鸡胸", calories=180, protein=35, carbs=0, fat=4, fiber=0, sugar=0, sodium=160)],
        "2026-07-06",
    )
    server._save_foods_to_log(
        [Food(name="区间外旧餐", calories=500, protein=10, carbs=70, fat=20, fiber=2, sugar=12, sodium=900)],
        "2026-07-01",
    )

    context = server._coach_tool_context("最近7天我吃了什么？", "2026-07-11")

    assert context["start_date"] == "2026-07-05"
    assert context["end_date"] == "2026-07-11"
    assert "query_food_logs" in context["tools_used"]
    assert [item["food_name"] for item in context["food_logs"]] == ["七日内鸡胸"]


def test_coach_queries_last_week_weight_and_training(tmp_path, monkeypatch):
    tracking = make_isolated_services(tmp_path, monkeypatch)
    tracking.add_weight(WeightLog(weight_kg=62.4, date="2026-07-08"))
    tracking.add_exercise(
        Exercise(name="慢跑", duration_minutes=35, intensity="moderate", calories_burned=260, date="2026-07-09")
    )
    tracking.add_steps(8200, day="2026-07-10")

    context = server._coach_tool_context("上周体重和训练怎么样？", "2026-07-13")

    assert context["start_date"] == "2026-07-06"
    assert context["end_date"] == "2026-07-12"
    assert context["weight_logs"][0]["weight_kg"] == 62.4
    assert context["training_logs"][0]["name"] == "慢跑"
    assert context["step_logs"][0]["steps"] == 8200
    assert "query_weight_logs" in context["tools_used"]
    assert "query_training_logs" in context["tools_used"]
