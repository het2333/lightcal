"""Tests for ingredient-based recipe suggestions and logging."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest
from fastapi import HTTPException

import server
import services.tracking_service as tracking_module
from services.food_database import FoodDatabase
from services.recommendation_service import RecommendationService
from services.tracking_service import TrackingService


def make_services(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    food_db = FoodDatabase(db_path=tmp_path / "foods.db")
    service = RecommendationService(food_db=food_db, tracking=tracking)
    monkeypatch.setattr(server, "tracking", tracking)
    monkeypatch.setattr(server, "food_db", food_db)
    monkeypatch.setattr(server, "recommendation_service", service)
    monkeypatch.setattr(server, "describe_meal", None)
    return food_db, tracking, service


def test_recipe_amount_labels_use_concrete_or_photo_units():
    assert server._format_display_amount("香蕉", 120, "1根") == "1根（约120g）"
    assert server._format_display_amount("鸡胸肉", 150, "图片中的鸡胸肉") == "图片中的鸡胸肉（约150g）"
    assert "大把" not in server._human_amount_label("西兰花", 180)
    assert "掌心" not in server._human_amount_label("鸡胸肉", 150)


@pytest.mark.asyncio
async def test_ingredient_recipes_fallback_without_llm(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)

    payload = await server.recipes_from_ingredients_endpoint(server.IngredientRecipeRequest(
        ingredients="鸡胸肉，米饭，西兰花",
        use_ai=True,
        date="2026-05-24",
    ))

    assert payload["source"] == "rules"
    assert payload["identified_ingredients"]
    assert len(payload["recipes"]) >= 1
    first = payload["recipes"][0]
    assert first["calories"] > 0
    assert first["ingredients_breakdown"]
    assert all(item.get("display_amount") for item in first["ingredients_breakdown"])
    assert all("掌心" not in item["display_amount"] and "大把" not in item["display_amount"] and "大盘" not in item["display_amount"] for item in first["ingredients_breakdown"])
    assert any(
        any(unit in item["display_amount"] for unit in ["碗", "块", "根", "个", "片", "朵", "杯", "份"])
        for item in first["ingredients_breakdown"]
    )
    event = tracking.get_recipe_suggestion_event(first["id"])
    assert event is not None
    assert event["recipe"]["id"] == first["id"]


def test_recipe_import_extracts_json_ld_without_llm():
    recipe = {
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": "番茄鸡蛋面",
        "image": ["https://example.com/tomato-egg-noodles.jpg"],
        "recipeYield": "2 servings",
        "totalTime": "PT35M",
        "prepTime": "PT12M",
        "cookTime": "PT23M",
        "recipeIngredient": ["面条 200g", "鸡蛋 2个", "番茄 1个"],
        "recipeInstructions": [
            {"@type": "HowToStep", "text": "番茄切块，鸡蛋打散。"},
            {"@type": "HowToStep", "text": "煮面后加入番茄鸡蛋汤底。"},
        ],
        "nutrition": {
            "@type": "NutritionInformation",
            "calories": "430 calories",
            "proteinContent": "18 g",
            "carbohydrateContent": "61 g",
            "fatContent": "13 g",
            "servingSize": "1 bowl",
        },
    }
    page = f"""
    <html><head>
    <script type="application/ld+json">{json.dumps(recipe, ensure_ascii=False)}</script>
    </head><body>recipe</body></html>
    """

    parsed = server._extract_recipe_from_json_ld(page, "https://example.com/recipe")

    assert parsed is not None
    assert parsed["recipe_name"] == "番茄鸡蛋面"
    assert parsed["servings"] == 2
    assert parsed["serving_size_label"] == "1碗"
    assert parsed["cooking_time"] == "35分钟"
    assert parsed["active_time_minutes"] == 12
    assert parsed["inactive_time_minutes"] == 23
    assert parsed["ingredients"] == ["面条 200g", "鸡蛋 2个", "番茄 1个"]
    assert parsed["instructions"][0] == "番茄切块，鸡蛋打散。"
    assert parsed["calories_per_serving"] == 430
    assert parsed["protein_per_serving"] == 18
    assert parsed["source_url"] == "https://example.com/recipe"
    assert parsed["image_url"] == "https://example.com/tomato-egg-noodles.jpg"
    assert parsed["import_source"] == "json_ld"


@pytest.mark.asyncio
async def test_recipe_import_endpoint_uses_json_ld(monkeypatch):
    recipe = {
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": "紫米鸡蛋饭",
        "image": {"url": "https://example.com/purple-rice.jpg"},
        "recipeYield": "1 serving",
        "totalTime": "PT12M",
        "recipeIngredient": ["紫米饭 150g", "鸡蛋 1个"],
        "recipeInstructions": ["加热米饭。", "煎鸡蛋后盖在米饭上。"],
        "nutrition": {
            "@type": "NutritionInformation",
            "calories": "310 calories",
            "proteinContent": "13 g",
            "carbohydrateContent": "45 g",
            "fatContent": "9 g",
        },
    }
    page = f"""
    <html><head>
    <script type="application/ld+json">{json.dumps(recipe, ensure_ascii=False)}</script>
    </head><body>recipe</body></html>
    """

    class FakeResponse:
        text = page

        def raise_for_status(self):
            return None

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url, headers=None):
            assert url == "https://example.com/recipe"
            return FakeResponse()

    import httpx

    monkeypatch.setattr(httpx, "AsyncClient", FakeAsyncClient)

    imported = await server.recipe_import_endpoint(server.RecipeImportRequest(
        url="https://example.com/recipe"
    ))

    assert imported["recipe_name"] == "紫米鸡蛋饭"
    assert imported["servings"] == 1
    assert imported["calories_per_serving"] == 310
    assert imported["ingredients"] == ["紫米饭 150g", "鸡蛋 1个"]
    assert imported["instructions"] == ["加热米饭。", "煎鸡蛋后盖在米饭上。"]
    assert imported["image_url"] == "https://example.com/purple-rice.jpg"
    assert imported["import_source"] == "json_ld"


@pytest.mark.asyncio
async def test_ingredient_recipes_respect_avoid_preferences(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    tracking.save_user_preferences({
        "diet_type": "balanced",
        "avoid_ingredients": ["鸡"],
        "allergies": [],
        "favorite_cuisines": [],
        "taste_tags": [],
    })

    payload = await server.recipes_from_ingredients_endpoint(server.IngredientRecipeRequest(
        ingredients="鸡胸肉，米饭，西兰花",
        use_ai=False,
        date="2026-05-24",
    ))

    for recipe in payload["recipes"]:
        for item in recipe["ingredients_breakdown"]:
            assert "鸡" not in item["name"]


@pytest.mark.asyncio
async def test_log_ingredient_recipe_persists_food_and_refreshes_summary(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-24"
    payload = await server.recipes_from_ingredients_endpoint(server.IngredientRecipeRequest(
        ingredients="鸡胸肉，米饭，西兰花",
        use_ai=False,
        date=day,
    ))
    recipe = payload["recipes"][0]

    result = await server.log_ingredient_recipe_endpoint(recipe["id"], server.IngredientRecipeLogRequest(
        portion_multiplier=1.2,
        meal_category="dinner",
        date=day,
    ))

    assert result["status"] == "ok"
    assert result["summary"]["calories_consumed"] > 0
    assert tracking.get_recipe_suggestion_event(recipe["id"])["logged"] == 1
    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == recipe["title"]
    assert row["meal_category"] == "dinner"


@pytest.mark.asyncio
async def test_saved_meal_log_updates_meal_category_and_logged_sort(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-24"
    rice = server.Food(
        name="紫米饭",
        date=day,
        calories=180,
        protein=4,
        carbs=38,
        fat=1,
        fiber=2,
        sugar=0,
        sodium=8,
        serving_size="150g",
    )
    egg = server.Food(
        name="煎蛋",
        date=day,
        calories=95,
        protein=7,
        carbs=1,
        fat=7,
        fiber=0,
        sugar=0,
        sodium=90,
        serving_size="1个",
    )

    first = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="紫米早餐",
        foods=[rice],
        meal_category="breakfast",
        source="ios_test",
    ))
    second = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="鸡蛋午餐",
        foods=[egg],
        meal_category="lunch",
        source="ios_test",
    ))

    logged = await server.log_saved_meal_endpoint(
        second["meal"]["id"],
        server.SavedMealLogRequest(date=day, meal_category="lunch", portion_multiplier=1.5),
    )
    assert logged["status"] == "ok"
    assert logged["saved"] == 1

    meals = await server.saved_meals_endpoint(limit=10, sort="logged")
    assert meals["meals"][0]["id"] == second["meal"]["id"]
    assert meals["meals"][0]["logged_count"] == 1
    assert meals["meals"][0]["meal_category"] == "lunch"
    assert any(meal["id"] == first["meal"]["id"] for meal in meals["meals"])

    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, meal_category, calories, protein, carbs, fat FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == "煎蛋"
    assert row["meal_category"] == "lunch"
    assert row["calories"] == 142.5
    assert row["protein"] == 10.5
    assert row["carbs"] == 1.5
    assert row["fat"] == 10.5

    await server.log_saved_meal_endpoint(
        first["meal"]["id"],
        server.SavedMealLogRequest(date=day, meal_category="breakfast"),
    )
    await server.log_saved_meal_endpoint(
        first["meal"]["id"],
        server.SavedMealLogRequest(date=day, meal_category="breakfast"),
    )
    frequent_meals = await server.saved_meals_endpoint(limit=10, sort="frequent")
    assert frequent_meals["meals"][0]["id"] == first["meal"]["id"]
    assert frequent_meals["meals"][0]["logged_count"] == 2


@pytest.mark.asyncio
async def test_update_saved_meal_replaces_existing_template(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-25"
    rice = server.Food(
        name="白米饭",
        date=day,
        calories=170,
        protein=3,
        carbs=37,
        fat=0.5,
        fiber=1,
        sugar=0,
        sodium=5,
        serving_size="130g",
    )
    chicken = server.Food(
        name="鸡胸肉",
        date=day,
        calories=198,
        protein=36,
        carbs=0,
        fat=4,
        fiber=0,
        sugar=0,
        sodium=120,
        serving_size="120g",
    )
    broccoli = server.Food(
        name="西兰花",
        date=day,
        calories=45,
        protein=4,
        carbs=7,
        fat=0.5,
        fiber=4,
        sugar=1,
        sodium=30,
        serving_size="150g",
    )

    created = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="旧午餐",
        foods=[rice],
        meal_category="lunch",
        source="ios_test",
        note="少油备餐",
        instructions=["鸡胸肉提前煎好", "米饭分装"],
    ))
    meal_id = created["meal"]["id"]
    assert created["meal"]["note"] == "少油备餐"
    assert created["meal"]["instructions"] == ["鸡胸肉提前煎好", "米饭分装"]

    updated = await server.update_saved_meal_endpoint(meal_id, server.SavedMealRequest(
        title="高蛋白午餐",
        foods=[chicken, broccoli],
        meal_category="dinner",
        source="ios_test",
    ))

    assert updated["status"] == "ok"
    assert updated["meal"]["id"] == meal_id
    assert updated["meal"]["title"] == "高蛋白午餐"
    assert updated["meal"]["meal_category"] == "dinner"
    assert updated["meal"]["note"] == "少油备餐"
    assert updated["meal"]["instructions"] == ["鸡胸肉提前煎好", "米饭分装"]
    assert [food["name"] for food in updated["meal"]["foods"]] == ["鸡胸肉", "西兰花"]
    assert tracking.get_saved_meal_event(meal_id)["foods"][0]["name"] == "鸡胸肉"

    cleared = await server.update_saved_meal_endpoint(meal_id, server.SavedMealRequest(
        title="高蛋白午餐",
        foods=[chicken, broccoli],
        meal_category="dinner",
        source="ios_test",
        note="",
        instructions=[],
    ))
    assert cleared["meal"]["note"] == ""
    assert cleared["meal"]["instructions"] == []

    logged = await server.log_saved_meal_endpoint(
        meal_id,
        server.SavedMealLogRequest(date=day),
    )

    assert logged["status"] == "ok"
    assert logged["saved"] == 2
    assert logged["foods"][0]["upload_group_title"] == "高蛋白午餐"

    with server.food_db._get_conn() as conn:
        rows = conn.execute(
            """SELECT food_name, meal_category, upload_group_title
               FROM food_log_history
               WHERE date = ?
               ORDER BY id DESC
               LIMIT 2""",
            (day,),
        ).fetchall()
    assert {row["food_name"] for row in rows} == {"鸡胸肉", "西兰花"}
    assert {row["meal_category"] for row in rows} == {"dinner"}
    assert {row["upload_group_title"] for row in rows} == {"高蛋白午餐"}

    meals = await server.saved_meals_endpoint(limit=10, meal_category="dinner")
    assert [meal["id"] for meal in meals["meals"]] == [meal_id]


@pytest.mark.asyncio
async def test_saved_meal_same_title_upserts_and_logs_latest_foods(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-26"
    rice = server.Food(
        name="白米饭",
        date=day,
        calories=170,
        protein=3,
        carbs=37,
        fat=0.5,
        fiber=1,
        sugar=0,
        sodium=5,
        serving_size="130g",
    )
    chicken = server.Food(
        name="鸡胸肉",
        date=day,
        calories=198,
        protein=36,
        carbs=0,
        fat=4,
        fiber=0,
        sugar=0,
        sodium=120,
        serving_size="120g",
    )

    first = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="同名训练餐",
        foods=[rice],
        meal_category="breakfast",
        source="ios_test",
        note="训练前备餐",
        instructions=["米饭分装", "训练后加热"],
    ))
    second = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title=" 同名训练餐 ",
        foods=[chicken],
        meal_category="lunch",
        source="ios_test",
    ))

    assert second["meal"]["id"] == first["meal"]["id"]
    assert second["meal"]["meal_category"] == "lunch"
    assert second["meal"]["note"] == "训练前备餐"
    assert second["meal"]["instructions"] == ["米饭分装", "训练后加热"]
    assert [food["name"] for food in second["meal"]["foods"]] == ["鸡胸肉"]
    assert len((await server.saved_meals_endpoint(limit=10, query="同名训练餐"))["meals"]) == 1
    assert [meal["id"] for meal in (await server.saved_meals_endpoint(limit=10, query="训练前备餐"))["meals"]] == [first["meal"]["id"]]
    assert [meal["id"] for meal in (await server.saved_meals_endpoint(limit=10, query="训练后加热"))["meals"]] == [first["meal"]["id"]]

    logged = await server.log_saved_meal_endpoint(
        second["meal"]["id"],
        server.SavedMealLogRequest(date=day),
    )

    assert logged["saved"] == 1
    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, calories, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == "鸡胸肉"
    assert row["calories"] == 198
    assert row["meal_category"] == "lunch"
    assert tracking.get_saved_meal_event(first["meal"]["id"])["logged_count"] == 1


@pytest.mark.asyncio
async def test_saved_meal_preserves_extended_nutrition_when_logged(tmp_path, monkeypatch):
    food_db, _, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-26"
    salmon = server.Food(
        name="三文鱼饭",
        date=day,
        calories=430,
        protein=32,
        carbs=42,
        fat=15,
        fiber=4,
        sugar=3,
        sodium=620,
        added_sugar=1,
        sat_fat=3.2,
        trans_fat=0.1,
        cholesterol=58,
        vitamin_a=22,
        vitamin_c=8,
        calcium=90,
        iron=2.4,
        potassium=780,
        serving_size="1碗",
    )

    created = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="完整营养餐品",
        foods=[salmon],
        meal_category="lunch",
        source="ios_test",
    ))

    saved_food = created["meal"]["foods"][0]
    assert saved_food["sat_fat"] == 3.2
    assert saved_food["cholesterol"] == 58
    assert saved_food["potassium"] == 780

    logged = await server.log_saved_meal_endpoint(
        created["meal"]["id"],
        server.SavedMealLogRequest(date=day, portion_multiplier=1.5, meal_category="dinner"),
    )
    food = logged["foods"][0]
    assert food["calories"] == 645
    assert food["sat_fat"] == 4.8
    assert food["cholesterol"] == 87
    assert food["potassium"] == 1170

    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, sat_fat, cholesterol, potassium, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == "三文鱼饭"
    assert row["sat_fat"] == 4.8
    assert row["cholesterol"] == 87
    assert row["potassium"] == 1170
    assert row["meal_category"] == "dinner"


@pytest.mark.asyncio
async def test_saved_meal_update_title_collision_merges_existing_meal(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-27"
    rice = server.Food(name="米饭", date=day, calories=180, protein=4, carbs=39, fat=1, fiber=1, sugar=0, sodium=6)
    egg = server.Food(name="鸡蛋", date=day, calories=90, protein=7, carbs=1, fat=6, fiber=0, sugar=0, sodium=70)
    tofu = server.Food(name="豆腐", date=day, calories=120, protein=12, carbs=4, fat=7, fiber=1, sugar=1, sodium=80)

    keep = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="目标餐品",
        foods=[rice],
        meal_category="breakfast",
        source="ios_test",
    ))
    renamed = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="待改名餐品",
        foods=[egg],
        meal_category="lunch",
        source="ios_test",
    ))

    updated = await server.update_saved_meal_endpoint(renamed["meal"]["id"], server.SavedMealRequest(
        title="目标餐品",
        foods=[tofu],
        meal_category="dinner",
        source="ios_test",
    ))

    assert updated["meal"]["id"] == keep["meal"]["id"]
    assert tracking.get_saved_meal_event(renamed["meal"]["id"]) is None
    assert [food["name"] for food in updated["meal"]["foods"]] == ["豆腐"]
    meals = await server.saved_meals_endpoint(limit=10, query="目标餐品")
    assert [meal["id"] for meal in meals["meals"]] == [keep["meal"]["id"]]


@pytest.mark.asyncio
async def test_recipe_suggestion_same_title_upserts_and_logs_latest_nutrition(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-28"
    base_recipe = {
        "title": "同名食谱",
        "servings": 1,
        "calories": 120,
        "protein": 8,
        "carbs": 10,
        "fat": 5,
        "fiber": 1,
        "sodium": 80,
        "sugar": 2,
        "prep_time_minutes": 5,
        "active_time_minutes": 5,
        "inactive_time_minutes": 13,
        "reason": "测试",
        "instructions": ["混合"],
        "ingredients_breakdown": [],
        "missing_ingredients": [],
        "source_url": "https://example.com/same-recipe",
        "image_url": "https://example.com/same-recipe.jpg",
        "cooking_time": "18分钟",
        "serving_size_label": "1碗",
    }

    first = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=base_recipe,
        date=day,
        source="ios_test",
    ))
    second = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={**base_recipe, "title": " 同名食谱 ", "calories": 150, "protein": 11},
        date=day,
        source="ios_test",
    ))

    assert second["recipe_id"] == first["recipe_id"]
    assert second["recipe"]["calories"] == 150
    assert second["recipe"]["source_url"] == "https://example.com/same-recipe"
    assert second["recipe"]["image_url"] == "https://example.com/same-recipe.jpg"
    assert second["recipe"]["cooking_time"] == "18分钟"
    assert second["recipe"]["serving_size_label"] == "1碗"
    assert second["recipe"]["active_time_minutes"] == 5
    assert second["recipe"]["inactive_time_minutes"] == 13
    assert len((await server.recipe_suggestions_endpoint(limit=10, query="同名食谱"))["recipes"]) == 1
    assert [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, query="测试"))["recipes"]] == [first["recipe_id"]]
    assert [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, query="混合"))["recipes"]] == [first["recipe_id"]]
    assert [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, query="same-recipe"))["recipes"]] == [first["recipe_id"]]
    assert [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, query="18分钟"))["recipes"]] == [first["recipe_id"]]

    logged = await server.log_ingredient_recipe_endpoint(
        second["recipe_id"],
        server.IngredientRecipeLogRequest(date=day, meal_category="dinner", portion_multiplier=2),
    )

    assert logged["saved"] == 1
    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, calories, protein, serving_size, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == "同名食谱"
    assert row["calories"] == 300
    assert row["protein"] == 22
    assert row["serving_size"] == "2 × 1碗"
    assert row["meal_category"] == "dinner"
    assert tracking.get_recipe_suggestion_event(first["recipe_id"])["logged"] == 1


@pytest.mark.asyncio
async def test_recipe_serving_size_options_are_preserved_and_logged(tmp_path, monkeypatch):
    food_db, _, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-28"

    created = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "title": "份量选项食谱",
            "servings": 1,
            "serving_size_label": "1碗",
            "serving_sizes": [
                {"value": 0.5, "unit": "碗", "nutrition_multiplier": 0.5, "label": "半碗"},
                {"value": 1.0, "unit": "碗", "nutrition_multiplier": 1.0, "label": "1碗"},
                {"value": 2.0, "unit": "碗", "nutrition_multiplier": 2.0, "label": "2碗"},
            ],
            "calories": 240,
            "protein": 18,
            "carbs": 28,
            "fat": 8,
            "fiber": 4,
            "sodium": 160,
            "sugar": 3,
            "prep_time_minutes": 12,
            "reason": "测试份量选项",
            "instructions": ["混合后分碗。"],
            "ingredients_breakdown": [],
            "missing_ingredients": [],
        },
        date=day,
        source="ios_test",
    ))

    serving_sizes = created["recipe"]["serving_sizes"]
    assert [item["label"] for item in serving_sizes[:3]] == ["半碗", "1碗", "2碗"]
    assert serving_sizes[0]["nutrition_multiplier"] == 0.5

    logged = await server.log_ingredient_recipe_endpoint(
        created["recipe_id"],
        server.IngredientRecipeLogRequest(
            date=day,
            meal_category="lunch",
            portion_multiplier=0.5,
            serving_size_label="半碗",
        ),
    )

    assert logged["foods"][0]["calories"] == 120
    assert logged["foods"][0]["protein"] == 9
    assert logged["foods"][0]["serving_size"] == "半碗"
    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, calories, protein, serving_size, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == "份量选项食谱"
    assert row["calories"] == 120
    assert row["protein"] == 9
    assert row["serving_size"] == "半碗"
    assert row["meal_category"] == "lunch"


@pytest.mark.asyncio
async def test_recipe_suggestions_logged_and_frequent_sort(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-28"
    base_recipe = {
        "title": "排序食谱A",
        "servings": 1,
        "calories": 200,
        "protein": 12,
        "carbs": 22,
        "fat": 7,
        "fiber": 2,
        "sodium": 120,
        "sugar": 3,
        "prep_time_minutes": 6,
        "reason": "排序测试",
        "instructions": ["混合"],
        "ingredients_breakdown": [],
        "missing_ingredients": [],
    }

    first = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=base_recipe,
        date=day,
        source="ios_test",
    ))
    second = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={**base_recipe, "title": "排序食谱B", "calories": 260},
        date=day,
        source="ios_test",
    ))

    await server.log_ingredient_recipe_endpoint(
        first["recipe_id"],
        server.IngredientRecipeLogRequest(date=day, meal_category="lunch"),
    )
    await server.log_ingredient_recipe_endpoint(
        second["recipe_id"],
        server.IngredientRecipeLogRequest(date=day, meal_category="dinner"),
    )
    await server.log_ingredient_recipe_endpoint(
        second["recipe_id"],
        server.IngredientRecipeLogRequest(date=day, meal_category="dinner"),
    )

    with tracking._get_conn() as conn:
        conn.execute(
            "UPDATE recipe_suggestion_events SET logged_at = ? WHERE id = ?",
            ("2026-05-28 08:00:00", first["recipe_id"]),
        )
        conn.execute(
            "UPDATE recipe_suggestion_events SET logged_at = ? WHERE id = ?",
            ("2026-05-28 12:00:00", second["recipe_id"]),
        )
        conn.commit()

    logged = await server.recipe_suggestions_endpoint(limit=10, sort="logged")
    assert logged["recipes"][0]["id"] == second["recipe_id"]
    assert logged["recipes"][0]["logged_count"] == 2

    frequent = await server.recipe_suggestions_endpoint(limit=10, sort="frequent")
    assert frequent["recipes"][0]["id"] == second["recipe_id"]
    assert frequent["recipes"][0]["logged_count"] == 2


@pytest.mark.asyncio
async def test_recipe_update_title_collision_merges_existing_recipe(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-29"
    target_recipe = {
        "title": "目标食谱",
        "servings": 1,
        "calories": 180,
        "protein": 10,
        "carbs": 20,
        "fat": 6,
        "fiber": 2,
        "sodium": 100,
        "sugar": 3,
        "prep_time_minutes": 8,
        "active_time_minutes": 8,
        "inactive_time_minutes": 14,
        "reason": "测试",
        "instructions": ["做法"],
        "source_url": "https://example.com/update-recipe",
        "cooking_time": "22分钟",
        "tags": ["高蛋白", "晚餐"],
        "ingredients_breakdown": [],
        "missing_ingredients": [],
    }
    draft_recipe = {**target_recipe, "title": "待改名食谱", "calories": 90}

    keep = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=target_recipe,
        date=day,
        source="ios_test",
    ))
    renamed = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=draft_recipe,
        date=day,
        source="ios_test",
    ))

    update_recipe = {
        key: value
        for key, value in target_recipe.items()
        if key not in {"source_url", "cooking_time", "tags", "active_time_minutes", "inactive_time_minutes"}
    }
    updated = await server.update_recipe_suggestion_endpoint(renamed["recipe_id"], server.IngredientRecipeUpdateRequest(
        recipe={**update_recipe, "title": "目标食谱", "calories": 260, "protein": 18}
    ))

    assert updated["recipe_id"] == keep["recipe_id"]
    assert updated["recipe"]["calories"] == 260
    assert updated["recipe"]["source_url"] == "https://example.com/update-recipe"
    assert updated["recipe"]["cooking_time"] == "22分钟"
    assert updated["recipe"]["active_time_minutes"] == 8
    assert updated["recipe"]["inactive_time_minutes"] == 14
    assert updated["recipe"]["tags"] == ["高蛋白", "晚餐"]
    assert tracking.get_recipe_suggestion_event(renamed["recipe_id"]) is None
    recipes = await server.recipe_suggestions_endpoint(limit=10, query="目标食谱")
    assert [recipe["id"] for recipe in recipes["recipes"]] == [keep["recipe_id"]]
    assert recipes["recipes"][0]["recipe"]["tags"] == ["高蛋白", "晚餐"]


@pytest.mark.asyncio
async def test_recipe_favorite_toggle_and_filter(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    recipe = {
        "title": "收藏测试食谱",
        "servings": 1,
        "calories": 120,
        "protein": 8,
        "carbs": 16,
        "fat": 3,
        "fiber": 2,
        "sodium": 90,
        "sugar": 1,
        "prep_time_minutes": 12,
        "reason": "测试",
        "instructions": ["做法"],
        "ingredients_breakdown": [],
        "missing_ingredients": [],
    }

    created = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe,
        date=day,
        source="ios_test",
    ))
    recipe_id = created["recipe_id"]
    assert created["recipe"]["favorite"] is False

    starred = await server.toggle_recipe_favorite_endpoint(recipe_id)
    assert starred["recipe"]["favorite"] is True
    favorites = await server.recipe_suggestions_endpoint(limit=10, favorite=True)
    assert [item["id"] for item in favorites["recipes"]] == [recipe_id]

    unstarred = await server.toggle_recipe_favorite_endpoint(recipe_id)
    assert unstarred["recipe"]["favorite"] is False
    favorites = await server.recipe_suggestions_endpoint(limit=10, favorite=True)
    assert favorites["recipes"] == []


@pytest.mark.asyncio
async def test_recipe_suggestions_filter_by_tag_aliases(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"

    def recipe(title: str, tags: list[str]):
        return {
            "title": title,
            "servings": 1,
            "calories": 240,
            "protein": 28,
            "carbs": 18,
            "fat": 6,
            "fiber": 4,
            "sodium": 160,
            "sugar": 2,
            "prep_time_minutes": 12,
            "reason": "测试标签筛选",
            "instructions": ["按食谱制作。"],
            "ingredients_breakdown": [{"name": title, "display_amount": "1份"}],
            "missing_ingredients": [],
            "tags": tags,
        }

    high_protein = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("英文高蛋白鸡肉碗", ["High Protein", "Low Carb"]),
        date=day,
        source="ios_test",
    ))
    low_sodium = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("中文低钠蒸鱼", ["低钠", "晚餐"]),
        date=day,
        source="ios_test",
    ))
    regular = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("普通家常饭", ["家常"]),
        date=day,
        source="ios_test",
    ))

    high_protein_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, tag="高蛋白"))["recipes"]]
    low_carb_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, tag="low_carb"))["recipes"]]
    low_sodium_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, tag="Low Sodium"))["recipes"]]

    assert high_protein_ids == [high_protein["recipe_id"]]
    assert low_carb_ids == [high_protein["recipe_id"]]
    assert low_sodium_ids == [low_sodium["recipe_id"]]
    assert regular["recipe_id"] not in high_protein_ids


@pytest.mark.asyncio
async def test_recipe_preserves_extended_nutrition_from_myfitnesspal_shape(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"

    created = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "title": "完整营养鸡肉碗",
            "servings": 1,
            "nutritional_contents": {
                "energy": {"unit": "calories", "value": 350},
                "protein": 40,
                "carbohydrates": 25,
                "fat": 12,
                "fiber": 2,
                "sugar": 1,
                "sodium": 700,
                "saturated_fat": 3,
                "trans_fat": 0.2,
                "cholesterol": 11,
                "calcium": 80,
                "iron": 3.4,
                "potassium": 320,
                "vitamin_a": 16,
                "vitamin_c": 10,
            },
            "prep_time_minutes": 12,
            "reason": "测试完整营养",
            "instructions": ["拌匀。"],
            "ingredients_breakdown": [],
            "missing_ingredients": [],
        },
        date=day,
        source="ios_test",
    ))

    recipe = created["recipe"]
    assert recipe["calories"] == 350
    assert recipe["carbs"] == 25
    assert recipe["sat_fat"] == 3
    assert recipe["trans_fat"] == 0.2
    assert recipe["cholesterol"] == 11
    assert recipe["calcium"] == 80
    assert recipe["iron"] == 3.4
    assert recipe["potassium"] == 320
    assert recipe["nutrition_details"]["vitamin_c"] == 10

    logged = await server.log_ingredient_recipe_endpoint(
        created["recipe_id"],
        server.IngredientRecipeLogRequest(portion_multiplier=2, meal_category="lunch", date=day),
    )
    food = logged["foods"][0]
    assert food["calories"] == 700
    assert food["sat_fat"] == 6
    assert food["cholesterol"] == 22
    assert food["calcium"] == 160
    assert food["potassium"] == 640


@pytest.mark.asyncio
async def test_recipe_create_normalizes_myfitnesspal_recipe_payload(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"

    created = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "name": "MFP 风格鸡肉晚餐",
            "servings": 4,
            "imageUrl": "https://example.com/chicken.jpg",
            "directions": "预热烤箱。\\n\\n放入鸡肉和蔬菜烤 20 分钟。\\n\\n静置后装盘。",
            "tags": [
                {"id": "1", "name": "High Protein"},
                {"id": "2", "name": "Dinner"},
            ],
            "nutritional_contents": {
                "energy": {"unit": "calories", "value": 420},
                "protein": 38,
                "carbohydrates": 18,
                "fat": 20,
                "sodium": 520,
            },
            "ingredients": [
                {
                    "food": {
                        "description": "Chicken",
                        "nutritional_contents": {
                            "energy": {"unit": "calories", "value": 200},
                            "protein": 30,
                            "carbohydrates": 0,
                            "fat": 8,
                            "sugar": 0,
                        },
                    },
                    "servings": 1,
                    "serving_size": {"value": 8, "unit": "oz", "nutrition_multiplier": 1},
                    "raw_text": "鸡肉 8 oz",
                },
                {
                    "food": {
                        "description": "Olive Oil",
                        "nutritional_contents": {
                            "energy": {"unit": "calories", "value": 120},
                            "protein": 0,
                            "carbohydrates": 0,
                            "fat": 14,
                        },
                    },
                    "servings": 1,
                    "serving_size": {"value": 1, "unit": "tbsp", "nutrition_multiplier": 1},
                    "raw_text": "橄榄油 1 tbsp",
                },
            ],
        },
        date=day,
        source="recipe_url_import",
    ))

    recipe = created["recipe"]
    assert recipe["title"] == "MFP 风格鸡肉晚餐"
    assert recipe["image_url"] == "https://example.com/chicken.jpg"
    assert recipe["instructions"] == ["预热烤箱。", "放入鸡肉和蔬菜烤 20 分钟。", "静置后装盘。"]
    assert recipe["tags"] == ["High Protein", "Dinner"]
    assert recipe["meal_types"] == ["dinner"]
    assert recipe["calories"] == 420
    assert recipe["carbs"] == 18
    assert recipe["ingredients_breakdown"][0]["name"] == "Chicken"
    assert recipe["ingredients_breakdown"][0]["display_amount"] == "鸡肉 8 oz"
    assert recipe["ingredients_breakdown"][0]["serving_size"] == "8 oz"
    assert recipe["ingredients_breakdown"][1]["name"] == "Olive Oil"

    logged = await server.log_ingredient_recipe_endpoint(
        created["recipe_id"],
        server.IngredientRecipeLogRequest(portion_multiplier=1, meal_category="dinner", date=day),
    )
    assert logged["foods"][0]["name"] == "MFP 风格鸡肉晚餐"
    assert logged["foods"][0]["serving_size"] == "1份"


@pytest.mark.asyncio
async def test_meal_plan_recipe_collections_use_saved_recipes(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    empty = await server.meal_plan_recipe_collections_endpoint()
    assert empty["collections"] == []

    await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "title": "高蛋白鸡肉碗",
            "servings": 1,
            "calories": 430,
            "protein": 42,
            "carbs": 26,
            "fat": 14,
            "fiber": 4,
            "sodium": 520,
            "tags": [{"name": "High Protein"}, {"name": "Dinner"}],
            "imageUrl": "https://example.com/high-protein.jpg",
            "directions": "烤鸡肉。\\n\\n装盘。",
            "ingredients": ["鸡胸肉 180g", "糙米饭 100g"],
        },
        date=day,
        source="recipe_url_import",
    ))
    await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "title": "低碳豆腐餐",
            "servings": 1,
            "calories": 360,
            "protein": 28,
            "carbs": 18,
            "fat": 18,
            "fiber": 5,
            "sodium": 420,
            "tags": ["Low Carb", "晚餐"],
            "ingredients_breakdown": [{"name": "豆腐", "amount": "200g", "calories": 160, "protein": 16}],
        },
        date=day,
        source="ios_test",
    ))

    payload = await server.meal_plan_recipe_collections_endpoint(limit=4)
    ids = [item["id"] for item in payload["collections"]]
    assert "high_protein" in ids
    assert "low_carb" in ids
    assert "dinner" in ids
    high_protein = next(item for item in payload["collections"] if item["id"] == "high_protein")
    assert high_protein["title"] == "高蛋白食谱集合"
    assert high_protein["recipe_count"] >= 1
    assert high_protein["image_url"] == "https://example.com/high-protein.jpg"
    assert high_protein["recipes"][0]["title"] == "高蛋白鸡肉碗"
    assert high_protein["recipes"][0]["imported"] is True
    assert high_protein["recipes"][0]["tags"] == ["High Protein", "Dinner"]


@pytest.mark.asyncio
async def test_saved_meal_favorite_toggle_and_filter(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    rice = server.Food(
        name="紫米饭",
        date=day,
        calories=180,
        protein=4,
        carbs=38,
        fat=1,
        fiber=2,
        sugar=0,
        sodium=8,
        serving_size="150g",
    )

    created = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="收藏测试餐品",
        foods=[rice],
        meal_category="breakfast",
        source="ios_test",
    ))
    meal_id = created["meal"]["id"]
    assert created["meal"]["favorite"] is False

    starred = await server.toggle_saved_meal_favorite_endpoint(meal_id)
    assert starred["meal"]["favorite"] is True
    favorites = await server.saved_meals_endpoint(limit=10, favorite=True)
    assert [item["id"] for item in favorites["meals"]] == [meal_id]

    unstarred = await server.toggle_saved_meal_favorite_endpoint(meal_id)
    assert unstarred["meal"]["favorite"] is False
    favorites = await server.saved_meals_endpoint(limit=10, favorite=True)
    assert favorites["meals"] == []


@pytest.mark.asyncio
async def test_recipe_imported_filter_uses_source_or_url(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    base_recipe = {
        "servings": 1,
        "calories": 120,
        "protein": 8,
        "carbs": 16,
        "fat": 3,
        "fiber": 2,
        "sodium": 90,
        "sugar": 1,
        "prep_time_minutes": 12,
        "reason": "测试",
        "instructions": ["做法"],
        "ingredients_breakdown": [],
        "missing_ingredients": [],
    }

    imported_by_source = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={**base_recipe, "title": "链接导入食谱", "source": "recipe_url_import"},
        date=day,
        source="recipe_url_import",
    ))
    imported_by_url = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={**base_recipe, "title": "带来源链接食谱", "source_url": "https://example.com/imported"},
        date=day,
        source="manual",
    ))
    manual = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={**base_recipe, "title": "本地手动食谱"},
        date=day,
        source="manual",
    ))

    imported = await server.recipe_suggestions_endpoint(limit=10, imported=True)
    imported_ids = {item["id"] for item in imported["recipes"]}

    assert imported_by_source["recipe_id"] in imported_ids
    assert imported_by_url["recipe_id"] in imported_ids
    assert manual["recipe_id"] not in imported_ids


@pytest.mark.asyncio
async def test_meal_plan_imported_recipe_preference_controls_inclusion(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    recipe = {
        "title": "导入鸡肉饭",
        "servings": 1,
        "calories": 520,
        "protein": 34,
        "carbs": 58,
        "fat": 16,
        "fiber": 5,
        "sodium": 520,
        "sugar": 4,
        "prep_time_minutes": 18,
        "active_time_minutes": 12,
        "reason": "导入食谱",
        "instructions": ["按原食谱制作。"],
        "ingredients_breakdown": [
            {"name": "鸡胸肉", "display_amount": "150克"},
            {"name": "米饭", "display_amount": "180克"},
        ],
        "missing_ingredients": [],
        "source_url": "https://example.com/imported-chicken-rice",
    }
    await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe,
        date=day,
        source="recipe_url_import",
    ))

    request = server.GenerateMealPlanRequest(
        daily_calories=1800,
        days=1,
        goal_type="fat_loss",
        meals_per_day=2,
        prep_time_minutes=20,
        protein_pct=30,
        carbs_pct=40,
        fat_pct=30,
    )

    tracking.save_user_preferences({"include_imported_recipes_in_meal_plans": True})
    included_plan = await server.generate_meal_plan_endpoint(request)
    included_meals = [meal for day_item in included_plan["days"] for meal in day_item["meals"]]
    assert included_plan["imported_recipes_included"] >= 1
    assert any(meal.get("source") == "imported_recipe" and "导入鸡肉饭" in meal.get("name", "") for meal in included_meals)

    tracking.save_user_preferences({"include_imported_recipes_in_meal_plans": False})
    excluded_plan = await server.generate_meal_plan_endpoint(request)
    excluded_meals = [meal for day_item in excluded_plan["days"] for meal in day_item["meals"]]
    assert excluded_plan.get("imported_recipes_included", 0) == 0
    assert all(meal.get("source") != "imported_recipe" for meal in excluded_meals)


@pytest.mark.asyncio
async def test_meal_plan_imported_recipes_match_recipe_meal_types(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-30"

    def imported_recipe(title: str, meal_types=None, tags=None):
        return {
            "title": title,
            "servings": 1,
            "calories": 500,
            "protein": 30,
            "carbs": 55,
            "fat": 15,
            "fiber": 5,
            "sodium": 480,
            "sugar": 3,
            "prep_time_minutes": 18,
            "reason": "导入食谱",
            "instructions": ["按原食谱制作。"],
            "ingredients_breakdown": [{"name": title, "display_amount": "1份"}],
            "missing_ingredients": [],
            "source_url": f"https://example.com/{title}",
            "meal_types": meal_types or [],
            "tags": tags or [],
        }

    await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=imported_recipe("导入午餐碗", meal_types=["lunch"]),
        date=day,
        source="recipe_url_import",
    ))
    await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=imported_recipe("导入晚餐鱼", meal_types=["dinner"]),
        date=day,
        source="recipe_url_import",
    ))
    inferred = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=imported_recipe("导入早餐燕麦", tags=["早餐", "导入"]),
        date=day,
        source="recipe_url_import",
    ))

    assert inferred["recipe"]["meal_types"] == ["breakfast"]

    request = server.GenerateMealPlanRequest(
        daily_calories=1800,
        days=1,
        goal_type="fat_loss",
        meals_per_day=2,
        prep_time_minutes=20,
        protein_pct=30,
        carbs_pct=40,
        fat_pct=30,
    )
    tracking.save_user_preferences({"include_imported_recipes_in_meal_plans": True})

    plan = await server.generate_meal_plan_endpoint(request)
    meals = [meal for day_item in plan["days"] for meal in day_item["meals"]]
    dinner = next(meal for meal in meals if meal.get("meal_type") == "dinner")

    assert dinner.get("source") == "imported_recipe"
    assert "导入晚餐鱼" in dinner.get("name", "")
    assert "dinner" in dinner.get("meal_types", [])
    assert all("导入午餐碗" not in meal.get("name", "") for meal in meals if meal.get("meal_type") != "lunch")


@pytest.mark.asyncio
async def test_recipe_suggestions_filter_by_meal_type(tmp_path, monkeypatch):
    make_services(tmp_path, monkeypatch)
    day = "2026-05-30"

    def recipe(title: str, meal_types=None, tags=None):
        return {
            "title": title,
            "servings": 1,
            "calories": 300,
            "protein": 20,
            "carbs": 36,
            "fat": 8,
            "fiber": 4,
            "sodium": 360,
            "sugar": 3,
            "prep_time_minutes": 12,
            "reason": "测试餐次筛选",
            "instructions": ["按食谱制作。"],
            "ingredients_breakdown": [{"name": title, "display_amount": "1份"}],
            "missing_ingredients": [],
            "meal_types": meal_types or [],
            "tags": tags or [],
        }

    breakfast = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("早餐蛋饼", meal_types=["breakfast"]),
        date=day,
        source="ios_test",
    ))
    dinner = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("晚餐鸡肉碗", meal_types=["dinner"]),
        date=day,
        source="ios_test",
    ))
    snack = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=recipe("下午茶酸奶杯", tags=["下午茶"]),
        date=day,
        source="ios_test",
    ))

    breakfast_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, meal_type="breakfast"))["recipes"]]
    snack_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, meal_type="snack"))["recipes"]]
    dinner_ids = [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, meal_type="晚餐"))["recipes"]]

    assert breakfast_ids == [breakfast["recipe_id"]]
    assert snack_ids == [snack["recipe_id"]]
    assert dinner_ids == [dinner["recipe_id"]]


@pytest.mark.asyncio
async def test_recipe_missing_ingredients_round_trip_and_clear_after_match(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-29"
    draft_recipe = {
        "title": "待匹配食谱",
        "servings": 2,
        "calories": 0,
        "protein": 0,
        "carbs": 0,
        "fat": 0,
        "fiber": 0,
        "sodium": 0,
        "sugar": 0,
        "prep_time_minutes": 12,
        "reason": "手动粘贴原料",
        "instructions": ["先保存待匹配原料。"],
        "ingredients_breakdown": [
            {
                "name": "神秘谷物",
                "amount": "120克",
                "display_amount": "120克",
                "calories": 0,
                "protein": 0,
                "carbs": 0,
                "fat": 0,
                "fiber": 0,
                "sodium": 0,
                "sugar": 0,
                "serving_size": "120克",
                "processing_level": "unmatched",
            }
        ],
        "missing_ingredients": ["神秘谷物"],
        "source": "manual",
    }

    created = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe=draft_recipe,
        date=day,
        source="ios_test",
    ))

    stored = tracking.get_recipe_suggestion_event(created["recipe_id"])
    assert stored["recipe"]["missing_ingredients"] == ["神秘谷物"]
    listed = await server.recipe_suggestions_endpoint(limit=10, query="待匹配食谱")
    assert listed["recipes"][0]["recipe"]["missing_ingredients"] == ["神秘谷物"]
    assert [item["id"] for item in (await server.recipe_suggestions_endpoint(limit=10, query="神秘谷物"))["recipes"]] == [created["recipe_id"]]

    matched_recipe = {
        **draft_recipe,
        "id": created["recipe_id"],
        "calories": 188,
        "protein": 4.2,
        "carbs": 40.5,
        "fat": 1.1,
        "ingredients_breakdown": [
            {
                "name": "熟米饭",
                "amount": "120克",
                "display_amount": "120克",
                "calories": 188,
                "protein": 4.2,
                "carbs": 40.5,
                "fat": 1.1,
                "fiber": 1.0,
                "sodium": 3,
                "sugar": 0.2,
                "serving_size": "120克",
                "processing_level": "whole",
            }
        ],
        "missing_ingredients": [],
    }

    updated = await server.update_recipe_suggestion_endpoint(
        created["recipe_id"],
        server.IngredientRecipeUpdateRequest(recipe=matched_recipe),
    )

    assert updated["recipe"]["missing_ingredients"] == []
    assert updated["recipe"]["ingredients_breakdown"][0]["name"] == "熟米饭"
    listed_after = await server.recipe_suggestions_endpoint(limit=10, query="待匹配食谱")
    assert listed_after["recipes"][0]["recipe"]["missing_ingredients"] == []
    assert listed_after["recipes"][0]["recipe"]["calories"] == 188


@pytest.mark.asyncio
async def test_saved_library_delete_endpoints_remove_items_and_404_on_repeat(tmp_path, monkeypatch):
    _, _, _ = make_services(tmp_path, monkeypatch)
    day = "2026-06-01"
    food = server.Food(
        name="可删除食物",
        date=day,
        calories=88,
        protein=6,
        carbs=10,
        fat=3,
        fiber=1,
        sugar=1,
        sodium=50,
        serving_size="1份",
    )

    saved_food = await server.create_saved_food_endpoint(server.SavedFoodRequest(food=food, source="ios_test"))
    saved_meal = await server.create_saved_meal_endpoint(server.SavedMealRequest(
        title="可删除餐品",
        foods=[food],
        meal_category="snack",
        source="ios_test",
    ))
    saved_recipe = await server.create_recipe_suggestion_endpoint(server.IngredientRecipeCreateRequest(
        recipe={
            "title": "可删除食谱",
            "servings": 1,
            "calories": 88,
            "protein": 6,
            "carbs": 10,
            "fat": 3,
            "fiber": 1,
            "sodium": 50,
            "sugar": 1,
            "prep_time_minutes": 5,
            "reason": "删除测试",
            "instructions": ["混合后食用。"],
            "ingredients_breakdown": [],
            "missing_ingredients": [],
        },
        date=day,
        source="ios_test",
    ))

    assert (await server.delete_saved_food_endpoint(saved_food["food"]["id"]))["deleted"] is True
    assert (await server.delete_saved_meal_endpoint(saved_meal["meal"]["id"]))["deleted"] is True
    assert (await server.delete_recipe_suggestion_endpoint(saved_recipe["recipe_id"]))["deleted"] is True

    assert (await server.saved_foods_endpoint(limit=10, query="可删除食物"))["foods"] == []
    assert (await server.saved_meals_endpoint(limit=10, query="可删除餐品"))["meals"] == []
    assert (await server.recipe_suggestions_endpoint(limit=10, query="可删除食谱"))["recipes"] == []

    with pytest.raises(HTTPException) as food_error:
        await server.delete_saved_food_endpoint(saved_food["food"]["id"])
    with pytest.raises(HTTPException) as meal_error:
        await server.delete_saved_meal_endpoint(saved_meal["meal"]["id"])
    with pytest.raises(HTTPException) as recipe_error:
        await server.delete_recipe_suggestion_endpoint(saved_recipe["recipe_id"])

    assert food_error.value.status_code == 404
    assert meal_error.value.status_code == 404
    assert recipe_error.value.status_code == 404


@pytest.mark.asyncio
async def test_barcode_scan_looks_up_food_database_without_llm(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "decision_service", server.DecisionService(tracking=tracking))
    monkeypatch.setattr(server, "describe_meal", server.DescribeMealService(provider=None, food_db=food_db))
    food = server.Food(
        name="条码测试酸奶",
        date="2026-06-01",
        calories=120,
        protein=8,
        carbs=16,
        fat=3,
        fiber=0,
        sugar=12,
        sodium=70,
        serving_size="180克",
        processing_level="processed",
    )
    await food_db.add(food)
    with food_db._get_conn() as conn:
        conn.execute("UPDATE foods SET barcode = ? WHERE id = ?", ("6901234567890", food.id))
        conn.commit()

    result = await server.describe_meal_endpoint(server.DescribeMealRequest(
        source=server.ScanSource.barcode_scan,
        barcode="6901234567890",
    ))

    assert result.description == "已找到：条码测试酸奶"
    assert len(result.foods) == 1
    assert result.foods[0].name == "条码测试酸奶"
    assert result.foods[0].calories == 120
    assert result.foods[0].serving_size == "180克"
    assert result.decision is not None


@pytest.mark.asyncio
async def test_barcode_scan_rejects_non_numeric_code_before_database_lookup():
    with pytest.raises(HTTPException) as error:
        await server.describe_meal_endpoint(server.DescribeMealRequest(
            source=server.ScanSource.barcode_scan,
            barcode="abc",
        ))

    assert error.value.status_code == 400
    assert "8–14 位数字" in error.value.detail


@pytest.mark.asyncio
async def test_saved_food_same_name_upserts_and_logs_latest_nutrition(tmp_path, monkeypatch):
    food_db, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-30"
    first_food = server.Food(
        name="同名自定义食物",
        date=day,
        calories=90,
        protein=7,
        carbs=1,
        fat=6,
        fiber=0,
        sugar=0,
        sodium=70,
        serving_size="1个",
    )
    second_food = server.Food(
        name=" 同名自定义食物 ",
        date=day,
        calories=130,
        protein=11,
        carbs=3,
        fat=8,
        fiber=1,
        sugar=1,
        sodium=90,
        serving_size="120克",
    )

    first = await server.create_saved_food_endpoint(server.SavedFoodRequest(food=first_food, source="ios_test"))
    second = await server.create_saved_food_endpoint(server.SavedFoodRequest(food=second_food, source="ios_test"))

    assert second["food"]["id"] == first["food"]["id"]
    assert second["food"]["food"]["calories"] == 130
    assert len((await server.saved_foods_endpoint(limit=10, query="同名自定义食物"))["foods"]) == 1

    logged = await server.log_saved_food_endpoint(
        second["food"]["id"],
        server.SavedFoodLogRequest(date=day, meal_category="snack", portion_multiplier=2),
    )

    assert logged["saved"] == 1
    with food_db._get_conn() as conn:
        row = conn.execute(
            "SELECT food_name, calories, protein, meal_category FROM food_log_history WHERE date = ? ORDER BY id DESC LIMIT 1",
            (day,),
        ).fetchone()
    assert row["food_name"] == " 同名自定义食物 "
    assert row["calories"] == 260
    assert row["protein"] == 22
    assert row["meal_category"] == "snack"
    assert tracking.get_saved_food_event(first["food"]["id"])["logged_count"] == 1


@pytest.mark.asyncio
async def test_saved_food_update_name_collision_merges_existing_food(tmp_path, monkeypatch):
    _, tracking, _ = make_services(tmp_path, monkeypatch)
    day = "2026-05-31"
    target = server.Food(name="目标自定义食物", date=day, calories=100, protein=8, carbs=10, fat=4, fiber=1, sugar=1, sodium=60)
    draft = server.Food(name="待改名自定义食物", date=day, calories=60, protein=3, carbs=7, fat=2, fiber=0, sugar=1, sodium=40)
    updated_food = server.Food(name="目标自定义食物", date=day, calories=180, protein=16, carbs=14, fat=8, fiber=2, sugar=2, sodium=90)

    keep = await server.create_saved_food_endpoint(server.SavedFoodRequest(food=target, source="ios_test"))
    renamed = await server.create_saved_food_endpoint(server.SavedFoodRequest(food=draft, source="ios_test"))

    updated = await server.update_saved_food_endpoint(
        renamed["food"]["id"],
        server.SavedFoodRequest(food=updated_food, source="ios_test"),
    )

    assert updated["food"]["id"] == keep["food"]["id"]
    assert updated["food"]["food"]["calories"] == 180
    assert tracking.get_saved_food_event(renamed["food"]["id"]) is None
    foods = await server.saved_foods_endpoint(limit=10, query="目标自定义食物")
    assert [food["id"] for food in foods["foods"]] == [keep["food"]["id"]]
