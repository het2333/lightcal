"""Server-side Open Food Facts barcode lookup and normalization."""

from __future__ import annotations

import re
from typing import Any

import httpx

from models.food import Food, ProcessingLevel


OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/api/v2/product/{barcode}.json"


def _number(value: Any) -> float:
    try:
        return max(0.0, float(value or 0))
    except (TypeError, ValueError):
        return 0.0


def _amount(nutriments: dict, key: str, target_unit: str, default_unit: str = "g") -> float:
    value = _number(nutriments.get(f"{key}_100g"))
    if value <= 0:
        return 0.0
    unit = str(nutriments.get(f"{key}_unit") or default_unit).strip().lower().replace("µ", "u")
    to_grams = {
        "kg": 1000.0,
        "g": 1.0,
        "mg": 0.001,
        "ug": 0.000001,
        "mcg": 0.000001,
    }.get(unit, 1.0)
    grams = value * to_grams
    if target_unit == "g":
        return grams
    if target_unit == "mg":
        return grams * 1000.0
    if target_unit == "mcg":
        return grams * 1_000_000.0
    return value


def _serving_grams(product: dict) -> float:
    quantity = _number(product.get("serving_quantity"))
    if quantity > 0:
        return quantity
    text = str(product.get("serving_size") or product.get("quantity") or "")
    match = re.search(r"(\d+(?:\.\d+)?)\s*(g|ml)\b", text, re.IGNORECASE)
    return _number(match.group(1)) if match else 100.0


def _processing_level(product: dict) -> ProcessingLevel:
    nova = int(_number(product.get("nova_group")))
    if nova >= 4:
        return ProcessingLevel.ultra_processed
    if nova == 3:
        return ProcessingLevel.processed
    if nova == 2:
        return ProcessingLevel.minimally_processed
    return ProcessingLevel.whole


class OpenFoodFactsService:
    """Fetch packaged-food nutrition without exposing a third-party API to iOS."""

    def __init__(self, timeout_seconds: float = 8.0):
        self.timeout_seconds = timeout_seconds

    async def lookup(self, barcode: str) -> Food | None:
        clean = re.sub(r"\D", "", barcode or "")
        if len(clean) < 8:
            return None
        fields = ",".join(
            [
                "code", "product_name", "product_name_zh", "generic_name", "brands",
                "quantity", "serving_size", "serving_quantity", "nova_group", "nutriments",
            ]
        )
        headers = {"User-Agent": "Shiguang/1.0 (nutrition barcode lookup)"}
        async with httpx.AsyncClient(timeout=self.timeout_seconds, follow_redirects=True, trust_env=False) as client:
            response = await client.get(OPEN_FOOD_FACTS_URL.format(barcode=clean), params={"fields": fields}, headers=headers)
        response.raise_for_status()
        payload = response.json()
        product = payload.get("product") if isinstance(payload, dict) else None
        if payload.get("status") != 1 or not isinstance(product, dict):
            return None

        nutriments = product.get("nutriments") if isinstance(product.get("nutriments"), dict) else {}
        name = str(
            product.get("product_name_zh")
            or product.get("product_name")
            or product.get("generic_name")
            or "包装食品"
        ).strip()
        brand = str(product.get("brands") or "").split(",")[0].strip()
        if brand and brand.lower() not in name.lower():
            name = f"{brand} {name}".strip()

        serving_grams = _serving_grams(product)
        serving_ratio = serving_grams / 100.0

        def per_serving(value: float) -> float:
            return round(max(0.0, float(value or 0)) * serving_ratio, 6)

        serving_size = str(product.get("serving_size") or "").strip() or f"{serving_grams:g}克"
        vitamin_a_mcg = _amount(nutriments, "vitamin-a", "mcg")
        food = Food(
            name=name,
            calories=per_serving(_number(nutriments.get("energy-kcal_100g") or nutriments.get("energy-kcal"))),
            protein=per_serving(_amount(nutriments, "proteins", "g")),
            carbs=per_serving(_amount(nutriments, "carbohydrates", "g")),
            fat=per_serving(_amount(nutriments, "fat", "g")),
            fiber=per_serving(_amount(nutriments, "fiber", "g")),
            sugar=per_serving(_amount(nutriments, "sugars", "g")),
            sodium=per_serving(_amount(nutriments, "sodium", "mg")),
            added_sugar=per_serving(_amount(nutriments, "added-sugars", "g")),
            sat_fat=per_serving(_amount(nutriments, "saturated-fat", "g")),
            trans_fat=per_serving(_amount(nutriments, "trans-fat", "g")),
            cholesterol=per_serving(_amount(nutriments, "cholesterol", "mg")),
            vitamin_a=per_serving(vitamin_a_mcg * 3.333),
            vitamin_c=per_serving(_amount(nutriments, "vitamin-c", "mg")),
            calcium=per_serving(_amount(nutriments, "calcium", "mg")),
            iron=per_serving(_amount(nutriments, "iron", "mg")),
            potassium=per_serving(_amount(nutriments, "potassium", "mg")),
            magnesium=per_serving(_amount(nutriments, "magnesium", "mg")),
            zinc=per_serving(_amount(nutriments, "zinc", "mg")),
            folate=per_serving(_amount(nutriments, "folates", "mcg")),
            vitamin_d=per_serving(_amount(nutriments, "vitamin-d", "mcg")),
            vitamin_b12=per_serving(_amount(nutriments, "vitamin-b12", "mcg")),
            vitamin_e=per_serving(_amount(nutriments, "vitamin-e", "mg")),
            vitamin_k=per_serving(_amount(nutriments, "vitamin-k", "mcg")),
            omega_3=per_serving(_amount(nutriments, "omega-3-fat", "g")),
            monounsaturated_fat=per_serving(_amount(nutriments, "monounsaturated-fat", "g")),
            polyunsaturated_fat=per_serving(_amount(nutriments, "polyunsaturated-fat", "g")),
            serving_size=serving_size,
            quantity_count=1,
            quantity_unit="份",
            quantity_description=f"1份（{serving_grams:g}克）",
            grams_per_unit=serving_grams,
            processing_level=_processing_level(product),
            barcode=clean,
            nutrition_source="open_food_facts",
        )
        return food
