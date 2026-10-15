"""Density and nutrition calculation for the RGB + depth meal pipeline."""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class FoodDensity:
    food_key: str
    zh_name: str
    density_min: float
    density_default: float
    density_max: float
    density_type: str
    source: str
    source_confidence: str


@dataclass(frozen=True)
class NutritionFood:
    food_key: str
    zh_name: str
    category: str
    calories_per_100g: float
    protein_per_100g: float
    carbs_per_100g: float
    fat_per_100g: float
    fiber_per_100g: float = 0.0
    sodium_mg_per_100g: float = 0.0
    source: str = "seed"


@dataclass(frozen=True)
class RecipeIngredient:
    dish_key: str
    ingredient_food_key: str
    ingredient_name_zh: str
    ratio_default: float
    ratio_min: float
    ratio_max: float
    cooking_method: str
    oil_level: str = "normal"


DENSITY_TABLE: dict[str, FoodDensity] = {
    "rice_cooked": FoodDensity("rice_cooked", "熟米饭", 0.700, 0.730, 0.800, "bulk_density", "FAO/INFOODS Density Database V2", "high"),
    "rice_fried": FoodDensity("rice_fried", "炒饭", 0.680, 0.750, 0.850, "bulk_density", "FAO/INFOODS + app heuristic", "medium"),
    "noodles_boiled": FoodDensity("noodles_boiled", "熟面条", 0.550, 0.590, 0.700, "bulk_density", "FAO/INFOODS Density Database V2", "high"),
    "noodles_fried": FoodDensity("noodles_fried", "炒面", 0.700, 0.800, 0.900, "bulk_density", "FAO/INFOODS Density Database V2", "medium"),
    "soup_mixed": FoodDensity("soup_mixed", "混合汤", 1.000, 1.050, 1.100, "mass_density", "FAO/INFOODS Density Database V2", "high"),
    "tea_unsweetened": FoodDensity("tea_unsweetened", "无糖茶", 0.990, 1.000, 1.010, "mass_density", "app_template", "high"),
    "water": FoodDensity("water", "水", 0.990, 1.000, 1.010, "mass_density", "app_template", "high"),
    "porridge": FoodDensity("porridge", "粥", 0.950, 1.020, 1.080, "mass_density", "FAO/INFOODS + app heuristic", "medium"),
    "milk_tea_base": FoodDensity("milk_tea_base", "奶茶无料", 1.000, 1.030, 1.080, "mass_density", "FAO/INFOODS + app heuristic", "medium"),
    "soda_regular": FoodDensity("soda_regular", "含糖汽水", 0.990, 1.020, 1.050, "mass_density", "app_template", "medium"),
    "lemon_tea_sweet": FoodDensity("lemon_tea_sweet", "含糖柠檬茶", 0.990, 1.020, 1.050, "mass_density", "app_template", "medium"),
    "cooking_oil": FoodDensity("cooking_oil", "食用油", 0.880, 0.920, 0.930, "mass_density", "FAO/INFOODS Density Database V2", "high"),
    "soy_sauce": FoodDensity("soy_sauce", "酱油", 1.100, 1.120, 1.150, "mass_density", "FAO/INFOODS Density Database V2", "high"),
    "egg_boiled": FoodDensity("egg_boiled", "熟鸡蛋", 0.550, 0.600, 0.700, "bulk_density", "FAO/INFOODS Density Database V2", "medium"),
    "pork_cooked": FoodDensity("pork_cooked", "熟猪肉", 0.650, 0.700, 0.850, "bulk_density", "FAO/INFOODS Density Database V2", "medium"),
    "chicken_cooked": FoodDensity("chicken_cooked", "熟鸡肉块", 0.850, 0.950, 1.050, "bulk_density", "app heuristic", "medium"),
    "stir_fried_vegetables": FoodDensity("stir_fried_vegetables", "炒青菜", 0.400, 0.550, 0.800, "bulk_density", "FAO/INFOODS + app heuristic", "low"),
    "green_pepper_pork_stir_fry": FoodDensity("green_pepper_pork_stir_fry", "青椒炒肉", 0.650, 0.750, 0.900, "bulk_density", "app heuristic", "medium"),
    "tomato_egg": FoodDensity("tomato_egg", "番茄炒蛋", 0.650, 0.750, 0.900, "bulk_density", "app heuristic", "medium"),
    "mapo_tofu": FoodDensity("mapo_tofu", "麻婆豆腐", 0.750, 0.900, 1.050, "bulk_density", "app heuristic", "medium"),
    "dumpling": FoodDensity("dumpling", "饺子", 0.750, 0.850, 0.950, "bulk_density", "app heuristic", "medium"),
    "baozi_steamed_bun": FoodDensity("baozi_steamed_bun", "包子/馒头", 0.250, 0.350, 0.500, "bulk_density", "app heuristic", "low"),
    "fried_chicken": FoodDensity("fried_chicken", "炸鸡/炸物", 0.450, 0.650, 0.850, "bulk_density", "app heuristic", "low"),
    "french_fries": FoodDensity("french_fries", "薯条", 0.350, 0.500, 0.700, "bulk_density", "app heuristic", "medium"),
    "potato_wedges": FoodDensity("potato_wedges", "薯角/土豆块", 0.500, 0.650, 0.800, "bulk_density", "app heuristic", "medium"),
    "egg_tart": FoodDensity("egg_tart", "蛋挞", 0.550, 0.730, 0.900, "bulk_density", "app heuristic", "medium"),
    "sausage_cooked": FoodDensity("sausage_cooked", "香肠/烤肠", 0.850, 0.950, 1.050, "bulk_density", "app heuristic", "medium"),
    "fried_cheese_stick": FoodDensity("fried_cheese_stick", "炸芝士条", 0.450, 0.650, 0.800, "bulk_density", "app heuristic", "low"),
    "fried_potato_ball": FoodDensity("fried_potato_ball", "炸丸/土豆球", 0.500, 0.730, 0.900, "bulk_density", "app heuristic", "medium"),
    "onion_rings": FoodDensity("onion_rings", "炸洋葱圈", 0.350, 0.450, 0.650, "bulk_density", "app heuristic", "medium"),
    "apple_red": FoodDensity("apple_red", "苹果", 0.700, 0.780, 0.900, "bulk_density", "FAO/INFOODS + app heuristic", "medium"),
    "fruit_fresh": FoodDensity("fruit_fresh", "新鲜水果", 0.650, 0.800, 0.950, "bulk_density", "FAO/INFOODS + app heuristic", "medium"),
    "malatang_solid": FoodDensity("malatang_solid", "麻辣烫固体食材", 0.550, 0.750, 0.950, "bulk_density", "app heuristic", "medium"),
}


DENSITY_ALIAS_MAP: dict[str, str] = {
    "麻辣烫": "malatang_solid",
    "麻辣拌": "malatang_solid",
    "麻辣香锅": "malatang_solid",
}


def _load_external_density_data() -> None:
    """Extend static density seeds with generated FAO/Chinese density data."""
    root = Path(__file__).resolve().parent.parent
    merged_dir = root / "data/raw/density/merged"
    density_csv = merged_dir / "food_density_unified.csv"
    aliases_csv = merged_dir / "food_density_aliases_zh.csv"

    if density_csv.exists():
        with density_csv.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                try:
                    food_key = str(row.get("food_key") or "").strip()
                    if not food_key or food_key in DENSITY_TABLE:
                        continue
                    DENSITY_TABLE[food_key] = FoodDensity(
                        food_key=food_key,
                        zh_name=str(row.get("zh_name") or row.get("en_name") or food_key),
                        density_min=float(row.get("density_min") or row.get("density_default") or 0.0),
                        density_default=float(row.get("density_default") or 0.0),
                        density_max=float(row.get("density_max") or row.get("density_default") or 0.0),
                        density_type=str(row.get("density_type") or ""),
                        source=str(row.get("source") or ""),
                        source_confidence=str(row.get("source_confidence") or ""),
                    )
                except Exception:
                    continue

    if aliases_csv.exists():
        with aliases_csv.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                alias = str(row.get("alias_zh") or "").strip()
                food_key = str(row.get("food_key") or "").strip()
                if alias and food_key:
                    DENSITY_ALIAS_MAP[alias] = food_key


_load_external_density_data()


NUTRITION_TABLE: dict[str, NutritionFood] = {
    "rice_cooked": NutritionFood("rice_cooked", "熟米饭", "staple", 116, 2.6, 26.0, 0.3, 0.4, 1, "中国食物成分表近似"),
    "rice_fried": NutritionFood("rice_fried", "炒饭", "mixed_dish", 188, 5.0, 28.0, 6.0, 1.2, 430, "app_template"),
    "noodles_fried": NutritionFood("noodles_fried", "炒面", "staple", 220, 6.0, 33.0, 7.0, 2.0, 480, "app_template"),
    "pork_lean_cooked": NutritionFood("pork_lean_cooked", "熟瘦猪肉", "protein", 202, 27.0, 0.0, 10.0, 0.0, 60, "中国食物成分表近似"),
    "green_pepper_cooked": NutritionFood("green_pepper_cooked", "熟青椒", "vegetable", 28, 1.1, 5.8, 0.3, 1.8, 4, "中国食物成分表近似"),
    "cooking_oil": NutritionFood("cooking_oil", "食用油", "fat", 900, 0.0, 0.0, 100.0, 0.0, 0, "中国食物成分表近似"),
    "sauce_stir_fry": NutritionFood("sauce_stir_fry", "炒菜调味汁", "sauce", 80, 2.0, 12.0, 2.0, 0.0, 900, "app_template"),
    "green_pepper_pork_stir_fry": NutritionFood("green_pepper_pork_stir_fry", "青椒炒肉", "mixed_dish", 216, 12.5, 8.0, 13.5, 1.0, 420, "app_template"),
    "tea_unsweetened": NutritionFood("tea_unsweetened", "无糖茶", "drink", 1, 0.0, 0.0, 0.0, 0.0, 3, "app_template"),
    "water": NutritionFood("water", "水", "drink", 0, 0.0, 0.0, 0.0, 0.0, 0, "app_template"),
    "milk_tea_base": NutritionFood("milk_tea_base", "奶茶", "drink", 55, 1.0, 9.0, 1.8, 0.0, 35, "app_template"),
    "soda_regular": NutritionFood("soda_regular", "含糖汽水", "drink", 42, 0.0, 10.6, 0.0, 0.0, 8, "app_template"),
    "lemon_tea_sweet": NutritionFood("lemon_tea_sweet", "含糖柠檬茶", "drink", 21, 0.0, 5.2, 0.0, 0.0, 10, "pack_label_88kj_per_100ml"),
    "soup_clear": NutritionFood("soup_clear", "清汤/汤水", "soup", 13, 0.6, 1.2, 0.6, 0.0, 280, "app_template"),
    "fried_chicken": NutritionFood("fried_chicken", "炸鸡/炸物", "protein", 280, 17.0, 12.0, 18.0, 1.0, 620, "app_template"),
    "french_fries": NutritionFood("french_fries", "薯条", "snack", 312, 3.4, 41.0, 15.0, 3.8, 210, "app_template"),
    "potato_wedges": NutritionFood("potato_wedges", "薯角/土豆块", "snack", 230, 3.0, 33.0, 9.0, 3.0, 260, "app_template"),
    "egg_tart": NutritionFood("egg_tart", "蛋挞", "dessert", 300, 5.5, 32.0, 16.0, 0.8, 180, "app_template"),
    "sausage_cooked": NutritionFood("sausage_cooked", "香肠/烤肠", "protein", 290, 12.0, 7.0, 24.0, 0.0, 850, "app_template"),
    "fried_cheese_stick": NutritionFood("fried_cheese_stick", "炸芝士条", "snack", 330, 13.0, 24.0, 21.0, 1.0, 620, "app_template"),
    "fried_potato_ball": NutritionFood("fried_potato_ball", "炸丸/土豆球", "snack", 260, 4.0, 32.0, 13.0, 2.5, 360, "app_template"),
    "onion_rings": NutritionFood("onion_rings", "炸洋葱圈", "snack", 240, 4.0, 29.0, 12.0, 2.0, 420, "app_template"),
    "chicken_cooked": NutritionFood("chicken_cooked", "熟鸡肉", "protein", 165, 31.0, 0.0, 3.6, 0.0, 74, "中国食物成分表近似"),
    "stir_fried_vegetables": NutritionFood("stir_fried_vegetables", "清炒蔬菜", "vegetable", 82, 2.6, 7.5, 4.5, 3.0, 360, "app_template"),
    "apple_red": NutritionFood("apple_red", "苹果", "fruit", 53, 0.3, 13.7, 0.2, 2.4, 1, "中国食物成分表近似"),
    "fruit_fresh": NutritionFood("fruit_fresh", "新鲜水果", "fruit", 55, 0.6, 13.5, 0.3, 2.0, 2, "app_template"),
}


RECIPE_TEMPLATES: dict[str, list[RecipeIngredient]] = {
    "green_pepper_pork_stir_fry": [
        RecipeIngredient("green_pepper_pork_stir_fry", "pork_lean_cooked", "猪肉", 0.35, 0.25, 0.45, "stir_fried"),
        RecipeIngredient("green_pepper_pork_stir_fry", "green_pepper_cooked", "青椒", 0.45, 0.35, 0.55, "stir_fried"),
        RecipeIngredient("green_pepper_pork_stir_fry", "cooking_oil", "食用油", 0.08, 0.04, 0.12, "stir_fried"),
        RecipeIngredient("green_pepper_pork_stir_fry", "sauce_stir_fry", "调味汁", 0.12, 0.08, 0.18, "stir_fried"),
    ]
}


def get_density(food_key: str) -> FoodDensity:
    key = str(food_key or "").strip()
    return DENSITY_TABLE.get(key) or DENSITY_TABLE.get(DENSITY_ALIAS_MAP.get(key, "")) or DENSITY_TABLE["rice_cooked"]


def _resolve_density(food_key: str) -> FoodDensity | None:
    key = str(food_key or "").strip()
    return DENSITY_TABLE.get(key) or DENSITY_TABLE.get(DENSITY_ALIAS_MAP.get(key, ""))


def _density_bounds_for_context(food_key: str = "", category: str = "", name: str = "") -> tuple[float, float]:
    text = f"{food_key} {category} {name}".lower()
    if any(token in text for token in ("tea", "water", "broth", "soup", "汤", "茶", "水")):
        return 0.95, 1.10
    if any(token in text for token in ("rice", "饭", "炒饭")):
        return 0.60, 0.90
    if any(token in text for token in ("noodle", "面")):
        return 0.50, 0.90
    if any(token in text for token in ("fried", "fries", "炸", "薯条", "薯角", "鸡块")):
        return 0.30, 0.90
    if any(token in text for token in ("meat", "pork", "beef", "chicken", "sausage", "肉", "鸡", "肠")):
        return 0.65, 1.10
    if any(token in text for token in ("vegetable", "veg", "菜", "蔬", "甘蓝", "胡萝卜", "番茄")):
        return 0.25, 0.90
    if any(token in text for token in ("bread", "cake", "bun", "面包", "蛋糕", "包子", "馒头")):
        return 0.15, 0.65
    if any(token in text for token in ("sauce", "oil", "酱", "汁", "油")):
        return 0.85, 1.20
    if any(token in text for token in ("fruit", "水果", "苹果")):
        return 0.55, 1.00
    return 0.30, 1.10


def _as_float(value, default: float | None = None) -> float | None:
    try:
        return float(value)
    except Exception:
        return default


def _density_from_hint(
    density_hint: dict | None,
    food_key: str = "",
    category: str = "",
    name: str = "",
) -> dict | None:
    if not isinstance(density_hint, dict):
        return None
    raw_density = _as_float(
        density_hint.get("density_g_per_ml")
        or density_hint.get("density_default_g_per_ml")
        or density_hint.get("density")
    )
    if raw_density is None or raw_density <= 0:
        return None
    confidence = _as_float(density_hint.get("confidence"), 0.0) or 0.0
    if confidence < 0.35:
        return None

    lower, upper = _density_bounds_for_context(food_key, category, name)
    hint_range = density_hint.get("range")
    if isinstance(hint_range, list) and len(hint_range) >= 2:
        range_min = _as_float(hint_range[0], lower) or lower
        range_max = _as_float(hint_range[1], upper) or upper
        lower = max(lower, min(range_min, range_max))
        upper = min(upper, max(range_min, range_max))
        if upper < lower:
            lower, upper = _density_bounds_for_context(food_key, category, name)

    density_default = max(lower, min(raw_density, upper))
    return {
        "density_key": "glm_density_hint",
        "density_g_per_ml": round(density_default, 4),
        "density_min": round(lower, 4),
        "density_max": round(upper, 4),
        "density_source": "glm_density_hint_clipped",
        "density_confidence": "medium" if confidence >= 0.65 else "low",
        "density_hint_basis": str(density_hint.get("basis") or ""),
        "density_hint_confidence": round(confidence, 4),
    }


def estimate_weight_from_volume(
    food_key: str,
    volume_ml: float,
    density_hint: dict | None = None,
    category: str = "",
    name: str = "",
) -> dict:
    density = _resolve_density(food_key)
    if density is not None:
        grams = volume_ml * density.density_default
        return {
            "density_key": density.food_key,
            "density_g_per_ml": density.density_default,
            "estimated_grams": round(grams, 1),
            "estimated_grams_min": round(volume_ml * density.density_min, 1),
            "estimated_grams_max": round(volume_ml * density.density_max, 1),
            "density_source": density.source,
            "density_confidence": density.source_confidence,
            "density_selection": "database_exact_or_alias",
        }

    hint_density = _density_from_hint(density_hint, food_key, category, name)
    if hint_density is not None:
        grams = volume_ml * hint_density["density_g_per_ml"]
        return {
            **hint_density,
            "estimated_grams": round(grams, 1),
            "estimated_grams_min": round(volume_ml * hint_density["density_min"], 1),
            "estimated_grams_max": round(volume_ml * hint_density["density_max"], 1),
            "density_selection": "glm_hint_clipped_by_category",
        }

    density = get_density(food_key)
    grams = volume_ml * density.density_default
    return {
        "density_key": density.food_key,
        "density_g_per_ml": density.density_default,
        "estimated_grams": round(grams, 1),
        "estimated_grams_min": round(volume_ml * density.density_min, 1),
        "estimated_grams_max": round(volume_ml * density.density_max, 1),
        "density_source": density.source,
        "density_confidence": density.source_confidence,
        "density_selection": "fallback_default",
    }


def calculate_single_food_nutrition(food_key: str, grams: float) -> dict:
    food = NUTRITION_TABLE.get(food_key) or NUTRITION_TABLE["rice_cooked"]
    factor = grams / 100.0
    return {
        "calories": round(food.calories_per_100g * factor, 1),
        "protein_g": round(food.protein_per_100g * factor, 1),
        "carbs_g": round(food.carbs_per_100g * factor, 1),
        "fat_g": round(food.fat_per_100g * factor, 1),
        "fiber_g": round(food.fiber_per_100g * factor, 1),
        "sodium_mg": round(food.sodium_mg_per_100g * factor, 1),
    }


def _valid_nutrition_density(nutrition_per_100g: dict | None) -> dict | None:
    if not isinstance(nutrition_per_100g, dict):
        return None
    values = {
        "calories": _as_float(nutrition_per_100g.get("calories"), 0.0) or 0.0,
        "protein_g": _as_float(nutrition_per_100g.get("protein_g"), 0.0) or 0.0,
        "carbs_g": _as_float(nutrition_per_100g.get("carbs_g"), 0.0) or 0.0,
        "fat_g": _as_float(nutrition_per_100g.get("fat_g"), 0.0) or 0.0,
        "fiber_g": _as_float(nutrition_per_100g.get("fiber_g"), 0.0) or 0.0,
        "sodium_mg": _as_float(nutrition_per_100g.get("sodium_mg"), 0.0) or 0.0,
    }
    if not any(value > 0 for value in values.values()):
        return None
    if not 0 <= values["calories"] <= 900:
        return None
    if any(values[key] < 0 or values[key] > 100 for key in ("protein_g", "carbs_g", "fat_g", "fiber_g")):
        return None
    if not 0 <= values["sodium_mg"] <= 8000:
        return None
    return values


def calculate_nutrition_from_density(nutrition_per_100g: dict | None, grams: float) -> dict | None:
    density = _valid_nutrition_density(nutrition_per_100g)
    if density is None:
        return None
    factor = grams / 100.0
    return {
        "calories": round(density["calories"] * factor, 1),
        "protein_g": round(density["protein_g"] * factor, 1),
        "carbs_g": round(density["carbs_g"] * factor, 1),
        "fat_g": round(density["fat_g"] * factor, 1),
        "fiber_g": round(density["fiber_g"] * factor, 1),
        "sodium_mg": round(density["sodium_mg"] * factor, 1),
    }


def calculate_mixed_dish_nutrition(dish_key: str, total_grams: float, oil_level: str = "normal") -> dict:
    template = RECIPE_TEMPLATES.get(dish_key)
    if not template:
        return {"total": calculate_single_food_nutrition(dish_key, total_grams), "ingredients": []}

    total = {"calories": 0.0, "protein_g": 0.0, "carbs_g": 0.0, "fat_g": 0.0, "fiber_g": 0.0, "sodium_mg": 0.0}
    ingredients = []
    for row in template:
        grams = total_grams * row.ratio_default
        nutri = calculate_single_food_nutrition(row.ingredient_food_key, grams)
        ingredient = {
            "food_key": row.ingredient_food_key,
            "name_zh": row.ingredient_name_zh,
            "ratio": row.ratio_default,
            "grams": round(grams, 1),
            **nutri,
        }
        ingredients.append(ingredient)
        for key in total:
            total[key] += nutri[key]

    return {"total": {k: round(v, 1) for k, v in total.items()}, "ingredients": ingredients}


def calculate_item_nutrition(
    food_key: str,
    grams: float,
    mixed_dish: bool = False,
    oil_level: str = "normal",
    nutrition_per_100g: dict | None = None,
) -> dict:
    direct = calculate_nutrition_from_density(nutrition_per_100g, grams)
    if direct is not None:
        return {"total": direct, "ingredients": []}
    if mixed_dish:
        return calculate_mixed_dish_nutrition(food_key, grams, oil_level)
    return {"total": calculate_single_food_nutrition(food_key, grams), "ingredients": []}


def apply_eaten_ratio(nutrition: dict, eaten_ratio: float) -> dict:
    return {key: round(float(value) * eaten_ratio, 1) for key, value in nutrition.items()}
