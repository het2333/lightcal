"""Tests for deleting persisted food logs."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
from models.food import Food
from services.food_database import FoodDatabase


@pytest.mark.asyncio
async def test_delete_food_log_group_removes_rows_and_refreshes_summary(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-05-24"
    group_id = "delete_test_group"
    foods = [
        Food(name="鸡胸肉", calories=240, protein=42, carbs=0, fat=6, fiber=0, sugar=0, sodium=180),
        Food(name="米饭", calories=210, protein=4, carbs=46, fat=1, fiber=1, sugar=0, sodium=5),
    ]
    server._save_foods_to_log(foods, day, upload_group_id=group_id)

    with server.food_db._get_conn() as conn:
        before = conn.execute("SELECT COUNT(*) AS c FROM food_log_history WHERE upload_group_id = ?", (group_id,)).fetchone()
    assert before["c"] == 2

    result = await server.delete_food_log_endpoint(server.FoodLogDeleteRequest(upload_group_id=group_id, date=day))

    assert result["deleted"] == 2
    assert result["daily_summary"]["calories_consumed"] == 0
    with server.food_db._get_conn() as conn:
        after = conn.execute("SELECT COUNT(*) AS c FROM food_log_history WHERE upload_group_id = ?", (group_id,)).fetchone()
    assert after["c"] == 0

    repeated = await server.delete_food_log_endpoint(
        server.FoodLogDeleteRequest(upload_group_id=group_id, date=day)
    )
    assert repeated["deleted"] == 0
    assert repeated["daily_summary"]["calories_consumed"] == 0


@pytest.mark.asyncio
async def test_move_food_log_changes_only_requested_row(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-05-25"
    server._save_foods_to_log(
        [
            Food(name="燕麦", calories=180, protein=6, carbs=31, fat=3, fiber=4, sugar=1, sodium=2),
            Food(name="牛奶", calories=120, protein=6, carbs=10, fat=5, fiber=0, sugar=10, sodium=90),
        ],
        day,
        meal_category="breakfast",
    )
    history = await server.get_foods_endpoint(date=day, days=1)
    oatmeal = next(item for item in history["foods"] if item["food_name"] == "燕麦")

    moved = await server.move_food_log_meal_category_endpoint(
        oatmeal["id"],
        server.FoodLogMoveRequest(meal_category="lunch", date=day),
    )

    assert moved["moved"] == 1
    assert moved["food"]["meal_category"] == "lunch"
    assert moved["daily_summary"]["calories_consumed"] == 300
    refreshed = await server.get_foods_endpoint(date=day, days=1)
    categories = {item["food_name"]: item["meal_category"] for item in refreshed["foods"]}
    assert categories == {"燕麦": "lunch", "牛奶": "breakfast"}
