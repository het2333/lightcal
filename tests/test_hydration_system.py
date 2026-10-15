"""Tests for hydration, challenges, HealthKit import, and voice logging."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
import services.tracking_service as tracking_module
from models.tracking import WaterLog
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


def test_hydration_summary_and_daily_summary_include_drink_nutrients(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    day = "2026-05-27"

    tracking.add_hydration({"drink_type": "coffee", "amount_ml": 240, "date": day})
    tracking.add_hydration({"drink_type": "juice", "amount_ml": 240, "date": day})

    hydration = tracking.get_hydration_summary(day)
    assert hydration["hydration_ml"] == 480
    assert hydration["hydration_effective_ml"] == pytest.approx(396)
    assert hydration["caffeine_mg"] == pytest.approx(95)
    assert hydration["sugar_g"] == pytest.approx(22)

    daily = tracking.get_daily_summary(day, foods=[])
    assert daily.water_ml == pytest.approx(396)
    assert daily.hydration_effective_ml == pytest.approx(396)
    assert daily.caffeine_mg == pytest.approx(95)
    assert daily.drink_sugar_g == pytest.approx(22)
    assert daily.calories_consumed == pytest.approx(110)
    assert daily.protein == pytest.approx(1)
    assert daily.carbs == pytest.approx(26)
    assert daily.fat == pytest.approx(0.2)


def test_water_endpoint_compatibility_writes_hydration_log(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    day = "2026-05-27"

    tracking.add_water(WaterLog(amount_ml=500, date=day))

    assert tracking.get_water(day) == 500
    hydration = tracking.get_hydration_summary(day)
    assert hydration["drink_count"] == 1
    assert hydration["hydration_effective_ml"] == 500


def test_hydration_settings_preserve_macro_goals(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    day = "2026-05-27"

    tracking.save_macro_goals({
        "daily_calories": 1888,
        "protein_g": 98,
        "carbs_g": 210,
        "fat_g": 58,
        "fiber_g": 28,
        "sugar_g": 42,
        "sodium_mg": 2100,
        "water_ml": 2000,
    })

    settings = tracking.save_hydration_settings(2600)
    macro = tracking.get_macro_goals()
    summary = tracking.get_hydration_summary(day)

    assert settings["hydration_goal_ml"] == pytest.approx(2600)
    assert macro["daily_calories"] == pytest.approx(1888)
    assert macro["protein_g"] == pytest.approx(98)
    assert macro["water_ml"] == pytest.approx(2600)
    assert summary["hydration_goal_ml"] == pytest.approx(2600)


@pytest.mark.asyncio
async def test_health_log_endpoints_reject_nonpositive_values(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    day = "2026-05-27"

    with pytest.raises(server.HTTPException):
        await server.add_weight_endpoint(server.AddWeightRequest(weight_kg=-1, date=day))
    with pytest.raises(server.HTTPException):
        await server.add_water_endpoint(server.AddWaterRequest(amount_ml=-250, date=day))
    with pytest.raises(server.HTTPException):
        await server.add_hydration_endpoint(server.HydrationLogRequest(amount_ml=0, date=day))
    with pytest.raises(server.HTTPException):
        await server.add_sleep_endpoint(server.SleepLogRequest(duration_hours=0, date=day))

    assert server.tracking.get_weights() == []
    assert server.tracking.get_hydration_summary(day)["drink_count"] == 0
    assert server.tracking.get_sleep_logs(day) == []


def test_reminders_preserve_ids_and_categories(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()

    saved = tracking.save_reminders([
        {
            "id": "hydration_daily_goal",
            "meal_type": "hydration",
            "time": "15:00",
            "enabled": True,
            "category": "hydration",
            "title": "补充饮水",
            "target_id": "daily_water_goal",
            "days_of_week": "1,2,3,4,5,6,7",
            "interval_minutes": 90,
        },
        {
            "id": "fasting_window_end",
            "meal_type": "fasting",
            "time": "20:00",
            "enabled": True,
            "category": "fasting",
            "title": "准备进入断食",
            "target_id": "fasting_window_end",
            "days_of_week": "1,2,3,4,5,6,7",
        },
    ])

    assert {item["id"] for item in saved} == {"hydration_daily_goal", "fasting_window_end"}
    loaded = tracking.get_reminders()
    assert loaded[0]["id"] in {"hydration_daily_goal", "fasting_window_end"}
    assert {item["category"] for item in loaded} == {"hydration", "fasting"}
    by_id = {item["id"]: item for item in loaded}
    assert by_id["hydration_daily_goal"]["interval_minutes"] == 90
    assert by_id["fasting_window_end"]["interval_minutes"] == 60


def test_challenge_progress_and_health_import_dedupe(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    today = tracking_module.date.today().isoformat()

    joined = tracking.join_challenge("hydrate_7")
    assert joined["status"] == "active"

    tracking.add_hydration({"drink_type": "water", "amount_ml": 2000, "date": today})
    refreshed = tracking.refresh_challenge("hydrate_7")
    assert refreshed["progress"]["completed_days"] == 1

    imported = tracking.import_health_records([
        {"source": "healthkit", "external_id": "hk-water-1", "record_type": "water", "value": 0.25, "unit": "l", "date": today}
    ])
    duplicate = tracking.import_health_records([
        {"source": "healthkit", "external_id": "hk-water-1", "record_type": "water", "value": 0.25, "unit": "l", "date": today}
    ])

    assert imported["imported_count"] == 1
    assert duplicate["skipped_count"] == 1


def test_sleep_logs_summary_import_and_challenge(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    today = tracking_module.date.today().isoformat()

    sleep = tracking.add_sleep({"date": today, "duration_hours": 7.5, "quality": 4, "note": "睡得不错"})
    assert sleep["duration_hours"] == pytest.approx(7.5)

    summary = tracking.get_sleep_summary(today)
    assert summary["logs_count"] == 1
    assert summary["duration_hours"] == pytest.approx(7.5)
    assert summary["status"] == "green"

    joined = tracking.join_challenge("sleep_7h_7")
    assert joined["status"] == "active"
    refreshed = tracking.refresh_challenge("sleep_7h_7")
    assert refreshed["progress"]["completed_days"] == 1

    imported = tracking.import_health_records([
        {"source": "healthkit", "external_id": "hk-sleep-1", "record_type": "sleep_duration", "value": 420, "unit": "min", "date": today}
    ])
    duplicate = tracking.import_health_records([
        {"source": "healthkit", "external_id": "hk-sleep-1", "record_type": "sleep_duration", "value": 420, "unit": "min", "date": today}
    ])

    assert imported["imported_count"] == 1
    assert duplicate["skipped_count"] == 1


@pytest.mark.asyncio
async def test_voice_log_fallback_parse_and_apply(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    monkeypatch.setattr(server, "llm_provider", None)

    day = "2026-05-27"
    text = "喝了 500ml 水，午餐半碗米饭"
    parsed = await server.parse_voice_log_endpoint(server.VoiceLogParseRequest(text=text, date=day))
    assert parsed["source"] == "rules"
    assert parsed["hydration"][0]["drink_type"] == "water"
    assert parsed["hydration"][0]["amount_ml"] == 500
    assert parsed["foods"][0]["name"] == "米饭"

    applied = await server.apply_voice_log_endpoint(server.VoiceLogApplyRequest(text=text, date=day))
    assert applied["status"] == "ok"
    assert applied["daily_summary"]["hydration_effective_ml"] == 500
    assert applied["daily_summary"]["calories_consumed"] == pytest.approx(105)


@pytest.mark.asyncio
async def test_voice_log_counts_eggs_and_includes_milk_nutrition(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    monkeypatch.setattr(server, "llm_provider", None)

    day = "2026-05-28"
    text = "早餐两个鸡蛋，一杯牛奶"
    parsed = await server.parse_voice_log_endpoint(server.VoiceLogParseRequest(text=text, date=day))

    assert parsed["foods"] == [pytest.approx({
        **parsed["foods"][0],
        "calories": 156,
        "protein": 12,
        "carbs": 1.2,
        "fat": 10,
    })]
    assert parsed["foods"][0]["serving_size"] == "2个"
    assert parsed["hydration"][0]["drink_type"] == "milk"
    assert parsed["hydration"][0]["amount_ml"] == pytest.approx(240)
    assert parsed["hydration"][0]["calories"] == pytest.approx(120)
    assert parsed["hydration"][0]["protein_g"] == pytest.approx(8)
    assert parsed["hydration"][0]["carbs_g"] == pytest.approx(12)
    assert parsed["hydration"][0]["fat_g"] == pytest.approx(4.5)

    applied = await server.apply_voice_log_endpoint(server.VoiceLogApplyRequest(text=text, date=day))
    summary = applied["daily_summary"]
    assert summary["calories_consumed"] == pytest.approx(276)
    assert summary["protein"] == pytest.approx(20)
    assert summary["carbs"] == pytest.approx(13.2)
    assert summary["fat"] == pytest.approx(14.5)
    assert summary["drink_count"] == 1


@pytest.mark.asyncio
async def test_voice_log_rejects_invalid_drink_before_saving_any_food(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))

    day = "2026-05-29"
    request = server.VoiceLogApplyRequest(
        text="两个鸡蛋，一杯牛奶",
        date=day,
        foods=[{
            "name": "鸡蛋", "calories": 156, "protein": 12,
            "carbs": 1.2, "fat": 10, "serving_size": "2个",
        }],
        hydration=[{"drink_type": "milk", "amount_ml": -100}],
    )

    with pytest.raises(server.HTTPException) as error:
        await server.apply_voice_log_endpoint(request)

    assert error.value.status_code == 400
    assert "毫升数必须大于 0" in error.value.detail
    assert (await server.get_foods_endpoint(date=day, days=1))["foods"] == []
    assert server.tracking.get_hydration_summary(day)["drink_count"] == 0


@pytest.mark.asyncio
async def test_food_log_rejects_negative_nutrition_before_saving_batch(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    day = "2026-05-30"
    valid = server.Food(
        name="鸡蛋", calories=78, protein=6, carbs=0.6, fat=5,
        fiber=0, sugar=0.4, sodium=62,
    )
    invalid = server.Food(
        name="异常食物", calories=-10, protein=0, carbs=0, fat=0,
        fiber=0, sugar=0, sodium=0,
    )

    with pytest.raises(server.HTTPException) as error:
        await server.save_food_log_endpoint(server.FoodLogRequest(
            foods=[valid, invalid], date=day, meal_category="dinner",
        ))

    assert error.value.status_code == 400
    assert "calories不能小于 0" in error.value.detail
    assert (await server.get_foods_endpoint(date=day, days=1))["foods"] == []


@pytest.mark.asyncio
async def test_voice_log_uses_drink_specific_cup_size_over_llm_generic_amount(tmp_path, monkeypatch):
    class GenericCupLLM:
        async def raw_completion(self, *_args, **_kwargs):
            return """{
                "confidence": 0.95,
                "meal_category": "breakfast",
                "hydration": [{"drink_type": "milk", "amount_ml": 250, "note": ""}],
                "foods": [{"name": "鸡蛋", "calories": 78, "protein": 6, "carbs": 0.6, "fat": 5}]
            }"""

    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))
    monkeypatch.setattr(server, "llm_provider", GenericCupLLM())

    parsed = await server.parse_voice_log_endpoint(
        server.VoiceLogParseRequest(text="早餐两个鸡蛋，一杯牛奶", date="2026-05-28")
    )

    assert parsed["hydration"][0]["amount_ml"] == pytest.approx(240)
    assert parsed["hydration"][0]["calories"] == pytest.approx(120)
    assert parsed["foods"][0]["calories"] == pytest.approx(156)
