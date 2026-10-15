import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from services.deepseek_nutrition import (
    nutrition_lookup_needs_generation,
    validate_generated_nutrition,
)


def test_missing_lookup_needs_generation():
    assert nutrition_lookup_needs_generation("麻辣烫", None) is True


def test_incomplete_complex_dish_lookup_needs_refresh():
    lookup = {
        "source": "dish_lookup_v1",
        "row_source": "ta_da_dishes_ingredients_x_food_lookup",
        "ingredient_count": 2,
    }
    assert nutrition_lookup_needs_generation("麻辣烫", lookup) is True


def test_valid_generated_nutrition_is_normalized():
    record = validate_generated_nutrition(
        {
            "canonical_name": "麻辣烫",
            "display_name": "麻辣烫",
            "category": "mixed_dish",
            "kcal100": 145,
            "p100": 8,
            "c100": 12,
            "f100": 7,
            "fi100": 2,
            "na100": 650,
            "density_g_per_ml": 0.78,
            "confidence": 0.8,
            "aliases": ["麻辣烫固体"],
        },
        "麻辣烫",
    )
    assert record is not None
    assert record["source"] == "deepseek_estimate_v1"
    assert record["confidence"] == 0.72
    assert record["density_g_per_ml"] == 0.78


def test_chinese_complex_dish_keeps_chinese_key_and_solid_density_bounds():
    record = validate_generated_nutrition(
        {
            "canonical_name": "malatang",
            "display_name": "麻辣烫",
            "category": "mixed_dish",
            "kcal100": 150,
            "p100": 8,
            "c100": 14,
            "f100": 7,
            "fi100": 2,
            "na100": 700,
            "density_g_per_ml": 1.05,
            "confidence": 0.7,
        },
        "麻辣烫",
    )
    assert record is not None
    assert record["canonical_name"] == "麻辣烫"
    assert record["density_g_per_ml"] == 0.95

    dry_record = validate_generated_nutrition(
        {
            "canonical_name": "spicy mixed hotpot",
            "category": "mixed_dish",
            "kcal100": 120,
            "p100": 8,
            "c100": 10,
            "f100": 5,
            "fi100": 2,
            "na100": 600,
            "density_g_per_ml": 1.0,
        },
        "麻辣拌",
    )
    assert dry_record is not None
    assert dry_record["canonical_name"] == "麻辣拌"
    assert dry_record["density_g_per_ml"] == 0.95


def test_invalid_generated_nutrition_is_rejected():
    assert validate_generated_nutrition(
        {
            "kcal100": 150,
            "p100": 80,
            "c100": 80,
            "f100": 80,
            "density_g_per_ml": 5,
        },
        "麻辣烫",
    ) is None
