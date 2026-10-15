import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from services.describe_meal import DescribeMealService
from services.food_database import FoodDatabase
from services.open_food_facts import OpenFoodFactsService


class FakeResponse:
    status_code = 200

    def raise_for_status(self):
        return None

    def json(self):
        return {
            "status": 1,
            "product": {
                "product_name_zh": "条码测试燕麦条",
                "brands": "食光测试",
                "serving_size": "30 g",
                "serving_quantity": 30,
                "nova_group": 4,
                "nutriments": {
                    "energy-kcal_100g": 450,
                    "proteins_100g": 10,
                    "carbohydrates_100g": 60,
                    "fat_100g": 18,
                    "fiber_100g": 8,
                    "sugars_100g": 22,
                    "sodium_100g": 0.4,
                    "sodium_unit": "g",
                    "magnesium_100g": 80,
                    "magnesium_unit": "mg",
                    "vitamin-b12_100g": 2,
                    "vitamin-b12_unit": "mcg",
                    "omega-3-fat_100g": 1.5,
                },
            },
        }


class FakeAsyncClient:
    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, *args, **kwargs):
        return FakeResponse()


@pytest.mark.asyncio
async def test_open_food_facts_scales_per_100g_values_to_one_serving(monkeypatch):
    monkeypatch.setattr("services.open_food_facts.httpx.AsyncClient", FakeAsyncClient)

    food = await OpenFoodFactsService().lookup("1234567890123")

    assert food is not None
    assert food.serving_size == "30 g"
    assert food.grams_per_unit == 30
    assert food.calories == 135
    assert food.protein == 3
    assert food.carbs == 18
    assert food.sodium == 120
    assert food.magnesium == 24
    assert food.vitamin_b12 == 0.6
    assert food.omega_3 == 0.45


@pytest.mark.asyncio
async def test_external_barcode_result_is_cached_for_next_scan(tmp_path, monkeypatch):
    monkeypatch.setattr("services.open_food_facts.httpx.AsyncClient", FakeAsyncClient)
    database = FoodDatabase(tmp_path / "foods.db")
    service = DescribeMealService(provider=None, food_db=database)

    first, first_description = await service._lookup_barcode("1234567890123")
    assert first and "Open Food Facts" in first_description

    class MustNotRun:
        async def lookup(self, barcode):
            raise AssertionError("the second scan should use the local cache")

    service.open_food_facts = MustNotRun()
    second, second_description = await service._lookup_barcode("1234567890123")

    assert second and second[0].name == first[0].name
    assert second[0].calories == 135
    assert "Open Food Facts" not in second_description
