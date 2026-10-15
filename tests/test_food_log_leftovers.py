"""Tests for after-meal leftovers adjustments."""

import base64
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import server
from models.food import Food
from services.food_database import FoodDatabase


def test_leftovers_adjustment_subtracts_from_matching_food_and_reuses_original(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    monkeypatch.setattr(server, "static_dir", str(tmp_path / "static"))
    day = "2026-05-24"
    group_id = "leftover_test_group"
    image_base64 = base64.b64encode(b"fake image").decode()

    server._save_foods_to_log(
        [
            Food(name="鸡胸肉", calories=200, protein=40, carbs=0, fat=4, fiber=0, sugar=0, sodium=120),
            Food(name="米饭", calories=300, protein=6, carbs=66, fat=1, fiber=1, sugar=0, sodium=5),
        ],
        day,
        upload_group_id=group_id,
    )

    first = server._apply_leftovers_to_log(
        group_id,
        [Food(name="米饭", calories=80, protein=1, carbs=18, fat=0, fiber=0, sugar=0, sodium=1)],
        image_base64,
        day,
    )

    assert first["original_calories"] == 500
    assert first["leftover_calories"] == 80
    assert first["consumed_calories"] == 420
    assert first["daily_summary"]["calories_consumed"] == 420

    with server.food_db._get_conn() as conn:
        rows = conn.execute(
            "SELECT food_name, calories, original_nutrition_json, leftover_calories, consumed_ratio "
            "FROM food_log_history WHERE upload_group_id = ? ORDER BY food_name",
            (group_id,),
        ).fetchall()

    by_name = {row["food_name"]: row for row in rows}
    assert by_name["米饭"]["calories"] == 220
    assert by_name["鸡胸肉"]["calories"] == 200
    assert by_name["米饭"]["original_nutrition_json"]
    assert by_name["米饭"]["leftover_calories"] == 80
    assert by_name["米饭"]["consumed_ratio"] == 0.84

    second = server._apply_leftovers_to_log(
        group_id,
        [Food(name="米饭", calories=250, protein=4, carbs=55, fat=1, fiber=1, sugar=0, sodium=2)],
        image_base64,
        day,
    )

    assert second["consumed_calories"] == 250
    assert second["daily_summary"]["calories_consumed"] == 250

    with server.food_db._get_conn() as conn:
        rice = conn.execute(
            "SELECT calories FROM food_log_history WHERE upload_group_id = ? AND food_name = ?",
            (group_id, "米饭"),
        ).fetchone()
    assert rice["calories"] == 50


def test_leftover_percentages_apply_per_food_independently(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    monkeypatch.setattr(server, "static_dir", str(tmp_path / "static"))
    day = "2026-05-24"
    group_id = "leftover_percent_group"

    saved = server._save_foods_to_log(
        [
            Food(name="米饭", calories=300, protein=6, carbs=66, fat=1, fiber=1, sugar=0, sodium=5),
            Food(name="鸡胸肉", calories=200, protein=40, carbs=0, fat=4, fiber=0, sugar=0, sodium=120),
        ],
        day,
        upload_group_id=group_id,
    )

    with server.food_db._get_conn() as conn:
        rows = conn.execute(
            "SELECT id, food_name FROM food_log_history WHERE upload_group_id = ? ORDER BY food_name",
            (group_id,),
        ).fetchall()
    ids = {row["food_name"]: row["id"] for row in rows}

    result = server._apply_leftover_percentages_to_log(
        group_id,
        [
            {"id": ids["米饭"], "name": "米饭", "remaining_percent": 30, "confidence": 0.8},
            {"id": ids["鸡胸肉"], "name": "鸡胸肉", "remaining_percent": 0, "confidence": 0.9},
        ],
        day=day,
    )

    assert saved
    assert result["original_calories"] == 500
    assert result["leftover_calories"] == 90
    assert result["consumed_calories"] == 410
    assert result["daily_summary"]["calories_consumed"] == 410

    with server.food_db._get_conn() as conn:
        rows = conn.execute(
            "SELECT food_name, calories, leftover_calories, leftover_nutrition_json "
            "FROM food_log_history WHERE upload_group_id = ? ORDER BY food_name",
            (group_id,),
        ).fetchall()

    by_name = {row["food_name"]: row for row in rows}
    assert by_name["米饭"]["calories"] == 210
    assert by_name["米饭"]["leftover_calories"] == 90
    assert by_name["鸡胸肉"]["calories"] == 200
    assert by_name["鸡胸肉"]["leftover_calories"] == 0
    assert '"remaining_percent": 30' in by_name["米饭"]["leftover_nutrition_json"]
