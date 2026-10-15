"""Regression coverage for the review-then-save meal flow."""

import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
from models.food import Food
from services.food_database import FoodDatabase


@pytest.mark.asyncio
async def test_confirmed_food_log_is_persisted_and_readable(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-10"
    request = server.FoodLogRequest(
        date=day,
        meal_category="lunch",
        group_title="鸡胸肉和米饭",
        foods=[
            Food(
                name="鸡胸肉", calories=240, protein=42, carbs=0, fat=6, fiber=0, sugar=0,
                sodium=180, magnesium=51, zinc=1.8, folate=18, vitamin_d=0.3,
                vitamin_b12=0.7, vitamin_e=1.2, vitamin_k=4, omega_3=0.12,
                monounsaturated_fat=2.1, polyunsaturated_fat=1.4,
                serving_size="180克", grams_per_unit=180, quantity_count=1, quantity_unit="份",
            ),
            Food(name="米饭", calories=210, protein=4, carbs=46, fat=1, fiber=1, sugar=0, sodium=5, serving_size="160克"),
        ],
    )

    saved = await server.save_food_log_endpoint(request)

    assert saved["status"] == "ok"
    assert saved["saved"] == 2
    assert saved["daily_summary"]["calories_consumed"] == 450
    group_id = saved["foods"][0]["upload_group_id"]
    assert group_id
    assert {item["name"] for item in saved["foods"]} == {"鸡胸肉", "米饭"}

    history = await server.get_foods_endpoint(date=day, days=1)

    assert history["date"] == day
    assert len(history["foods"]) == 2
    assert {item["food_name"] for item in history["foods"]} == {"鸡胸肉", "米饭"}
    assert {item["upload_group_id"] for item in history["foods"]} == {group_id}
    assert {item["meal_category"] for item in history["foods"]} == {"lunch"}
    chicken = next(item for item in history["foods"] if item["food_name"] == "鸡胸肉")
    assert chicken["magnesium"] == 51
    assert chicken["zinc"] == 1.8
    assert chicken["folate"] == 18
    assert chicken["vitamin_d"] == 0.3
    assert chicken["vitamin_b12"] == 0.7
    assert chicken["vitamin_e"] == 1.2
    assert chicken["vitamin_k"] == 4
    assert chicken["omega_3"] == 0.12
    assert chicken["monounsaturated_fat"] == 2.1
    assert chicken["polyunsaturated_fat"] == 1.4
    assert chicken["grams_per_unit"] == 180
    assert chicken["quantity_unit"] == "份"


@pytest.mark.asyncio
async def test_consumed_portion_scales_every_nutrition_field(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-11"
    food = Food(
        name="鲑鱼沙拉", calories=300, protein=20, carbs=10, fat=20, fiber=6, sugar=3,
        sodium=400, magnesium=80, zinc=4, folate=200, vitamin_d=10, vitamin_b12=3,
        vitamin_e=6, vitamin_k=90, omega_3=2, monounsaturated_fat=8,
        polyunsaturated_fat=5, serving_size="200克", grams_per_unit=200,
    )
    server._save_foods_to_log([food], day)
    history = await server.get_foods_endpoint(date=day, days=1)
    log_id = history["foods"][0]["id"]

    adjusted = await server.adjust_food_log_portion_endpoint(
        log_id,
        server.FoodLogPortionRequest(consumed_ratio=0.5, date=day),
    )

    row = adjusted["food"]
    assert row["calories"] == 150
    assert row["magnesium"] == 40
    assert row["zinc"] == 2
    assert row["folate"] == 100
    assert row["vitamin_d"] == 5
    assert row["vitamin_b12"] == 1.5
    assert row["vitamin_e"] == 3
    assert row["vitamin_k"] == 45
    assert row["omega_3"] == 1
    assert row["monounsaturated_fat"] == 4
    assert row["polyunsaturated_fat"] == 2.5


@pytest.mark.asyncio
async def test_initial_partial_portion_preserves_original_nutrition(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-12"
    food = Food(
        name="炸鸡翅", calories=245, protein=13.125, carbs=10.5, fat=15.75,
        fiber=0.875, sugar=0, sodium=525, serving_size="175克",
        grams_per_unit=1, quantity_count=175, quantity_unit="克", consumed_ratio=0.5,
    )

    saved = await server.save_food_log_endpoint(server.FoodLogRequest(date=day, foods=[food]))
    history = await server.get_foods_endpoint(date=day, days=1)
    row = history["foods"][0]

    assert saved["daily_summary"]["calories_consumed"] == 245
    assert row["calories"] == 245
    assert row["original_calories"] == 490
    assert row["consumed_ratio"] == 0.5


@pytest.mark.asyncio
async def test_zero_consumed_items_are_not_persisted(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-13"
    request = server.FoodLogRequest(
        date=day,
        foods=[
            Food(name="没吃的薯条", calories=0, protein=0, carbs=0, fat=0, fiber=0, sugar=0, sodium=0, consumed_ratio=0),
            Food(name="吃完的鸡蛋", calories=78, protein=6, carbs=1, fat=5, fiber=0, sugar=0, sodium=62),
        ],
    )

    saved = await server.save_food_log_endpoint(request)
    history = await server.get_foods_endpoint(date=day, days=1)

    assert saved["saved"] == 1
    assert [item["food_name"] for item in history["foods"]] == ["吃完的鸡蛋"]
    assert saved["daily_summary"]["calories_consumed"] == 78


@pytest.mark.asyncio
async def test_all_zero_consumed_meal_is_rejected(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    request = server.FoodLogRequest(
        date="2026-07-14",
        foods=[Food(name="未食用", calories=0, protein=0, carbs=0, fat=0, fiber=0, sugar=0, sodium=0, consumed_ratio=0)],
    )

    with pytest.raises(server.HTTPException) as error:
        await server.save_food_log_endpoint(request)

    assert error.value.status_code == 400
    assert (await server.get_foods_endpoint(date="2026-07-14", days=1))["foods"] == []


@pytest.mark.asyncio
async def test_consumed_ratio_above_one_is_rejected(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-14"
    request = server.FoodLogRequest(
        date=day,
        foods=[Food(
            name="异常份量", calories=100, protein=1, carbs=20, fat=1,
            fiber=0, sugar=0, sodium=0, consumed_ratio=1.5,
        )],
    )

    with pytest.raises(server.HTTPException) as error:
        await server.save_food_log_endpoint(request)

    assert error.value.status_code == 400
    assert "0–1" in error.value.detail
    assert (await server.get_foods_endpoint(date=day, days=1))["foods"] == []


@pytest.mark.asyncio
async def test_adjusting_saved_item_to_zero_removes_it(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-07-15"
    server._save_foods_to_log(
        [Food(name="苹果", calories=95, protein=0.5, carbs=25, fat=0.3, fiber=4, sugar=19, sodium=2)],
        day,
    )
    history = await server.get_foods_endpoint(date=day, days=1)

    adjusted = await server.adjust_food_log_portion_endpoint(
        history["foods"][0]["id"],
        server.FoodLogPortionRequest(consumed_ratio=0, date=day),
    )

    assert adjusted["removed"] == 1
    assert adjusted["daily_summary"]["calories_consumed"] == 0
    assert (await server.get_foods_endpoint(date=day, days=1))["foods"] == []


@pytest.mark.asyncio
async def test_copy_yesterday_preserves_full_nutrition_and_portion(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    food = Food(
        name="昨日坚果杯", calories=220, protein=7, carbs=18, fat=14, fiber=5,
        sugar=6, sodium=30, magnesium=95, zinc=2.6, folate=48, vitamin_e=5.4,
        omega_3=1.1, monounsaturated_fat=7.2, polyunsaturated_fat=4.3,
        serving_size="1杯（180克）", grams_per_unit=180, quantity_count=1, quantity_unit="杯",
    )
    server._save_foods_to_log([food], yesterday, meal_category="breakfast")

    copied = await server.copy_yesterday_endpoint()
    today = await server.get_foods_endpoint(date=date.today().isoformat(), days=1)
    row = next(item for item in today["foods"] if item["food_name"] == "昨日坚果杯")

    assert copied["copied"] == 1
    assert row["magnesium"] == 95
    assert row["zinc"] == 2.6
    assert row["folate"] == 48
    assert row["vitamin_e"] == 5.4
    assert row["omega_3"] == 1.1
    assert row["monounsaturated_fat"] == 7.2
    assert row["polyunsaturated_fat"] == 4.3
    assert row["serving_size"] == "1杯（180克）"
    assert row["grams_per_unit"] == 180
    assert row["quantity_unit"] == "杯"
