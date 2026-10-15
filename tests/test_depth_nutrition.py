import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from services.depth_nutrition import (
    calculate_item_nutrition,
    calculate_single_food_nutrition,
    estimate_weight_from_volume,
)
from services.depth_cloud_pipeline import canonical_food_key
from services.depth_cloud_pipeline import normalize_cloud_items


def test_volume_to_grams():
    result = estimate_weight_from_volume("rice_cooked", 100)
    assert result["estimated_grams"] == 73
    assert result["density_source"]
    assert result["density_selection"] == "database_exact_or_alias"


def test_glm_density_hint_used_for_unknown_food_key():
    result = estimate_weight_from_volume(
        "unknown_crispy_item",
        100,
        {"density_g_per_ml": 0.62, "range": [0.45, 0.8], "basis": "crispy fried snack", "confidence": 0.8},
        category="snack",
        name="炸脆小食",
    )
    assert result["density_key"] == "glm_density_hint"
    assert result["density_selection"] == "glm_hint_clipped_by_category"
    assert result["estimated_grams"] == 62


def test_glm_density_hint_is_clipped_by_category_bounds():
    result = estimate_weight_from_volume(
        "unknown_soup",
        100,
        {"density_g_per_ml": 2.5, "range": [2.0, 3.0], "basis": "bad hint", "confidence": 0.9},
        category="soup",
        name="清汤",
    )
    assert result["density_key"] == "glm_density_hint"
    assert result["density_g_per_ml"] <= 1.10


def test_single_food_nutrition():
    result = calculate_single_food_nutrition("rice_cooked", 200)
    assert result["calories"] == 232
    assert result["carbs_g"] == 52


def test_mixed_dish_template():
    result = calculate_item_nutrition("green_pepper_pork_stir_fry", 200, mixed_dish=True)
    assert result["total"]["calories"] > 250
    assert len(result["ingredients"]) == 4
    assert sum(row["ratio"] for row in result["ingredients"]) == 1.0


def test_food_r1_nutrition_density_overrides_local_table():
    result = calculate_item_nutrition(
        "soda_regular",
        250,
        nutrition_per_100g={
            "calories": 35,
            "protein_g": 0,
            "carbs_g": 8.8,
            "fat_g": 0,
            "fiber_g": 0,
            "sodium_mg": 6,
        },
    )
    assert result["total"]["calories"] == 87.5
    assert result["total"]["carbs_g"] == 22.0


def test_bad_model_nutrition_density_falls_back_to_local_table():
    result = calculate_item_nutrition(
        "rice_cooked",
        100,
        nutrition_per_100g={"calories": 5000, "protein_g": 0, "carbs_g": 0, "fat_g": 0},
    )
    assert result["total"]["calories"] == 116


def test_cloud_food_key_maps_unknown_model_keys_to_local_nutrition_keys():
    assert canonical_food_key({"canonical_food_key": "white_rice", "name_en": "White rice"}) == "rice_cooked"
    assert canonical_food_key({"canonical_food_key": "marinated_chicken_leg", "name_zh": "卤鸡腿"}) == "chicken_cooked"
    vegetables = calculate_single_food_nutrition("stir_fried_vegetables", 200)
    assert 120 <= vegetables["calories"] <= 200


def test_trusted_clean_lookup_overrides_wrong_model_food_key():
    item = {
        "name_zh": "麻辣烫",
        "canonical_food_key": "rice_cooked",
        "nutrition_key": "麻辣烫",
        "density_key": "麻辣烫",
        "nutrition_lookup": {"matched": True, "source": "dish_lookup_v1"},
        "category": "mixed_dish",
    }
    assert canonical_food_key(item) == "麻辣烫"


def test_malatang_uses_solid_ingredient_density_not_rice_density():
    result = estimate_weight_from_volume("麻辣烫", 120.9, category="mixed_dish", name="麻辣烫")
    assert result["density_key"] == "malatang_solid"
    assert result["density_g_per_ml"] == 0.75
    assert result["estimated_grams"] == 90.7

    dry_result = estimate_weight_from_volume("麻辣拌", 350, category="mixed_dish", name="麻辣拌")
    assert dry_result["density_key"] == "malatang_solid"
    assert dry_result["estimated_grams"] == 262.5


def test_fried_platter_items_map_to_specific_nutrition_keys():
    assert canonical_food_key({"name_zh": "薯条", "name_en": "french fries"}) == "french_fries"
    assert canonical_food_key({"name_zh": "蛋挞", "name_en": "egg tart"}) == "egg_tart"
    assert canonical_food_key({"name_zh": "香肠", "name_en": "sausage"}) == "sausage_cooked"
    assert canonical_food_key({"name_zh": "炸土豆球", "name_en": "fried potato balls"}) == "fried_potato_ball"
    assert canonical_food_key({"name_zh": "炸薯球", "name_en": "potato balls"}) == "fried_potato_ball"
    assert canonical_food_key({"name_zh": "炸洋葱圈", "name_en": "onion rings"}) == "onion_rings"


def test_unsweetened_tea_stays_near_zero_not_clear_soup():
    assert canonical_food_key({"name_zh": "茶汤", "category": "drink", "name_en": "tea soup"}) == "tea_unsweetened"
    weight = estimate_weight_from_volume("tea_unsweetened", 250)
    assert weight["estimated_grams"] == 250
    nutrition = calculate_single_food_nutrition("tea_unsweetened", weight["estimated_grams"])
    assert nutrition["calories"] <= 3
    assert nutrition["sodium_mg"] <= 10


def test_fried_rice_maps_to_fried_rice_nutrition_key():
    assert canonical_food_key({"name_zh": "辣味炒饭", "name_en": "spicy fried rice"}) == "rice_fried"
    nutrition = calculate_single_food_nutrition("rice_fried", 200)
    assert nutrition["calories"] > calculate_single_food_nutrition("rice_cooked", 200)["calories"]
    assert nutrition["fat_g"] > 5


def test_cloud_depth_volume_preserves_raw_depth_estimate():
    items = normalize_cloud_items(
        {
            "items": [
                {
                    "name_zh": "辣味炒饭",
                    "name_en": "spicy fried rice",
                    "category": "staple|mixed_dish",
                    "mixed_dish": True,
                    "volume": {
                        "estimated_volume_ml": 46.0,
                        "volume_method": "depth_mask_local_baseline_integration",
                        "depth_quality": {"volume_confidence": 0.77},
                    },
                    "detection": {
                        "bbox_xyxy": [309.0, 537.0, 936.0, 895.0],
                        "score": 0.45,
                    },
                    "segmentation": {
                        "area_pixels": 110_979,
                        "mask_confidence": 0.91,
                    },
                }
            ]
        },
        metadata={"rgb": {"width": 1440, "height": 1920}},
    )
    item = items[0]
    assert item["food_key"] == "rice_fried"
    assert item["volume_ml"] == 46.0
    assert item["volume_method"] == "depth_mask_local_baseline_integration"
    assert "plausibility_adjustment" not in item["depth_quality"]


def test_packaged_drink_volume_is_not_overwritten_by_capacity_rule():
    items = normalize_cloud_items(
        {
            "items": [
                {
                    "name_zh": "饮品",
                    "name_en": "Pepsi can",
                    "category": "drink",
                    "liquid": True,
                    "volume": {
                        "estimated_volume_ml": 63.0,
                        "volume_method": "depth_mask_local_baseline_integration",
                        "depth_quality": {"volume_confidence": 0.71},
                    },
                }
            ]
        }
    )
    item = items[0]
    assert item["name_zh"] == "百事可乐"
    assert item["food_key"] == "soda_regular"
    assert item["volume_ml"] == 63.0
    assert item["volume_method"] == "depth_mask_local_baseline_integration"
    assert "packaged_capacity_ml" not in item["depth_quality"]


def test_missing_or_rejected_volume_does_not_use_category_portion_default():
    items = normalize_cloud_items(
        {
            "items": [
                {
                    "name_zh": "蛋挞",
                    "name_en": "egg tart",
                    "category": "dessert",
                    "estimated_volume_ml": 0.0,
                    "volume": {
                        "estimated_volume_ml": 0.0,
                        "volume_method": "metric3d_geometry_unreliable_no_portion_preset",
                        "fallback": True,
                        "depth_quality": {"volume_available": False},
                    },
                }
            ]
        }
    )
    item = items[0]
    assert item["food_key"] == "egg_tart"
    assert item["volume_ml"] == 0.0
    assert "estimated_grams" in item["needs_user_check"]
