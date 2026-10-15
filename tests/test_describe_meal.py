"""Tests for the describeMeal service and API endpoints."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import base64
import asyncio
import json
import sqlite3
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient

from models.food import Food, DescribeMealRequest, DescribeMealResponse, ScanSource
from models.health import HealthScore
from services.describe_meal import DescribeMealService
from services.llm_providers import QwenVLProvider


class TestFoodModel:
    def test_food_creation(self):
        food = Food(
            name="Test Apple",
            calories=95,
            protein=0.5,
            carbs=25,
            fat=0.3,
            fiber=4.4,
            sugar=19,
            sodium=2,
            serving_size="1 medium",
        )
        assert food.name == "Test Apple"
        assert food.calories == 95
        assert food.serving_size == "1 medium"

    def test_food_defaults(self):
        food = Food(name="Test", calories=100, protein=5, carbs=10, fat=3, fiber=1, sugar=2, sodium=100)
        assert food.serving_size == "100g"
        assert food.processing_level.value == "whole"
        assert food.added_sugar == 0.0
        assert food.id  # auto-generated

    def test_meal_totals(self):
        from models.food import Meal
        foods = [
            Food(name="A", calories=100, protein=10, carbs=5, fat=3, fiber=1, sugar=2, sodium=50),
            Food(name="B", calories=200, protein=20, carbs=10, fat=6, fiber=2, sugar=4, sodium=100),
        ]
        meal = Meal(name="Lunch", foods=foods)
        assert meal.total_calories == 300
        assert meal.total_protein == 30
        assert meal.total_carbs == 15
        assert meal.total_fat == 9
        assert meal.total_fiber == 3


class TestDescribeMealRequest:
    def test_image_scan_request(self):
        req = DescribeMealRequest(
            source=ScanSource.image_scan,
            image_base64="fake_base64_data",
        )
        assert req.source == ScanSource.image_scan
        assert req.image_base64 == "fake_base64_data"

    def test_text_request(self):
        req = DescribeMealRequest(
            source=ScanSource.manually,
            text="chicken breast with rice",
        )
        assert req.source == ScanSource.manually
        assert req.text == "chicken breast with rice"

    def test_barcode_request(self):
        req = DescribeMealRequest(
            source=ScanSource.barcode_scan,
            barcode="049000000443",
        )
        assert req.source == ScanSource.barcode_scan


class TestHealthScoreIntegration:
    def test_full_health_score_pipeline(self):
        """Integration: Food → HealthScore """
        food = Food(
            name="Grilled Salmon with Broccoli",
            calories=243,
            protein=22.4,
            carbs=7,
            fat=13.4,
            fiber=3.3,
            sugar=1.4,
            added_sugar=0,
            sodium=100,
            serving_size="200g",
            processing_level="whole",
        )

        score = HealthScore.calculate(
            food_name=food.name,
            processing_level=food.processing_level.value,
            total_carbs=food.carbs,
            fiber=food.fiber,
            added_sugar=food.added_sugar,
        )

        assert 0 <= score.total <= 10
        assert score.artificial_score.score <= 2  # whole food
        assert score.net_carbs_score.score >= 0
        assert score.added_sugar_score.score == 0  # no added sugar
        assert "Salmon" in score.description or "Broccoli" in score.description or "whole foods" in score.description


class TestResponseParsing:
    def test_parse_valid_json(self):
        """Test parsing Gemini's JSON response."""
        response = json.dumps({
            "foods": [{
                "name": "Grilled Chicken",
                "calories": 165,
                "protein": 31,
                "carbs": 0,
                "fat": 3.6,
                "fiber": 0,
                "sugar": 0,
                "added_sugar": 0,
                "sodium": 74,
                "serving_size": "100g",
                "processing_level": "whole",
            }],
            "description": "A healthy grilled chicken breast.",
        })

        # simulate parsing
        data = json.loads(response)
        food = Food(
            name=data["foods"][0]["name"],
            calories=data["foods"][0]["calories"],
            protein=data["foods"][0]["protein"],
            carbs=data["foods"][0]["carbs"],
            fat=data["foods"][0]["fat"],
            fiber=data["foods"][0]["fiber"],
            sugar=data["foods"][0]["sugar"],
            sodium=data["foods"][0]["sodium"],
            serving_size=data["foods"][0]["serving_size"],
            processing_level=data["foods"][0]["processing_level"],
            added_sugar=data["foods"][0].get("added_sugar", 0),
        )

        assert food.name == "Grilled Chicken"
        assert food.calories == 165
        assert food.protein == 31

    def test_parse_empty_foods(self):
        """Test handling of 'no food detected' response."""
        response = json.dumps({
            "foods": [],
            "description": "No food detected",
        })
        data = json.loads(response)
        assert len(data["foods"]) == 0
        assert data["description"] == "No food detected"


def test_describe_meal_image_request_reaches_photo_analyzer(monkeypatch):
    import server

    class FakeDescribeMeal:
        def __init__(self):
            self.seen_source = None
            self.seen_image = None

        async def analyze(self, request):
            self.seen_source = request.source
            self.seen_image = request.image_base64
            return DescribeMealResponse(foods=[], description="photo route ok")

    fake = FakeDescribeMeal()
    monkeypatch.setattr(server, "describe_meal", fake)

    client = TestClient(server.app)
    response = client.post(
        "/v6/describeMeal",
        json={
            "source": "library",
            "image_base64": "tiny-photo-base64",
            "capture_metadata": {"has_depth": False, "capture_pipeline": "photo_only_fallback"},
        },
    )

    assert response.status_code == 200
    assert response.json()["description"] == "photo route ok"
    assert fake.seen_source == ScanSource.library
    assert fake.seen_image == "tiny-photo-base64"


def test_describe_meal_preview_scores_without_persisting(monkeypatch):
    import server

    food = Food(name="预览餐", calories=320, protein=20, carbs=30, fat=12, fiber=4, sugar=2, sodium=300)

    class FakeDescribeMeal:
        async def analyze(self, request):
            return DescribeMealResponse(foods=[food], description="preview")

    captured = {}

    def fake_score(*args, **kwargs):
        captured.update(kwargs)
        return {"score": 80}

    monkeypatch.setattr(server, "describe_meal", FakeDescribeMeal())
    monkeypatch.setattr(server.decision_service, "score_foods", fake_score)
    response = TestClient(server.app).post(
        "/v6/describeMeal",
        json={"source": "library", "image_base64": "photo"},
    )

    assert response.status_code == 200
    assert response.json()["decision"]["score"] == 80
    assert captured["persist"] is False


def test_qwen_uses_deterministic_temperature_by_default(monkeypatch):
    monkeypatch.delenv("QWEN_TEMPERATURE", raising=False)
    provider = QwenVLProvider("test-key")
    assert provider.temperature == 0


def test_qwen_temperature_can_be_configured(monkeypatch):
    monkeypatch.setenv("QWEN_TEMPERATURE", "0.15")
    provider = QwenVLProvider("test-key")
    assert provider.temperature == 0.15


def test_vision_flywheel_deduplicates_names_and_preserves_existing_rows(tmp_path):
    db_path = tmp_path / "foods.db"
    from services.food_database import FoodDatabase

    food_db = FoodDatabase(db_path=db_path)
    service = DescribeMealService(provider=None, food_db=food_db)
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """INSERT INTO foods
               (id, name, calories, protein, carbs, fat, fiber, sugar, sodium, source)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("trusted-fries", "薯条", 312, 3.4, 41, 15, 3.8, 0, 260, "trusted"),
        )
    estimates = [
        Food(name="薯条", calories=999, protein=0, carbs=0, fat=0, fiber=0, sugar=0, sodium=0),
        Food(name="炸鱼排", calories=350, protein=20, carbs=20, fat=20, fiber=1, sugar=0, sodium=500),
    ]

    service._save_to_db(estimates)
    service._save_to_db(estimates)

    with sqlite3.connect(db_path) as conn:
        fries = conn.execute("SELECT calories, source FROM foods WHERE id = 'trusted-fries'").fetchone()
        fish_rows = conn.execute("SELECT id, source FROM foods WHERE name = '炸鱼排'").fetchall()
    assert fries == (312.0, "trusted")
    assert len(fish_rows) == 1
    assert fish_rows[0][0].startswith("vision_")


def test_direct_photo_result_cache_returns_same_result_without_second_model_call(tmp_path, monkeypatch):
    from services.food_database import FoodDatabase

    class CountingProvider:
        model = "test-vision"
        temperature = 0

        def __init__(self):
            self.calls = 0

        async def analyze_image_with_prompt(self, *args, **kwargs):
            self.calls += 1
            return json.dumps({
                "foods": [{
                    "n": "薯条", "g": 120, "q": "一份", "m": "炸", "conf": 0.9,
                    "kcal": 374.4, "p": 4.1, "c": 49.2, "f": 18, "fi": 4.6,
                    "na": 312, "pl": "processed"
                }],
                "description": "测试拼盘"
            }, ensure_ascii=False)

    monkeypatch.setenv("PHOTO_ANALYSIS_CACHE_ENABLED", "true")
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    provider = CountingProvider()
    service = DescribeMealService(provider=provider, food_db=food_db)

    first = asyncio.run(service._analyze_image_direct_nutrition("same-image", "same-context"))
    second = asyncio.run(service._analyze_image_direct_nutrition("same-image", "same-context"))

    assert provider.calls == 1
    assert [food.model_dump() for food in first[0]] == [food.model_dump() for food in second[0]]
    assert first[2]["cache_hit"] is False
    assert second[2]["cache_hit"] is True


def test_photo_analysis_does_not_write_unconfirmed_foods_to_reference_db(tmp_path, monkeypatch):
    from services.food_database import FoodDatabase

    monkeypatch.delenv("PHOTO_ANALYSIS_FLYWHEEL_ENABLED", raising=False)
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    service = DescribeMealService(provider=None, food_db=food_db)
    before = sqlite3.connect(food_db.db_path).execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    service._save_to_db = MagicMock()

    request = DescribeMealRequest(source=ScanSource.image_scan, image_base64="photo")
    food = Food(name="模型估算食物", calories=100, protein=1, carbs=1, fat=1, fiber=0, sugar=0, sodium=0)
    service._analyze_image = AsyncMock(return_value=([food], "ok", {}))
    asyncio.run(service.analyze(request))

    service._save_to_db.assert_not_called()
    after = sqlite3.connect(food_db.db_path).execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    assert after == before


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
