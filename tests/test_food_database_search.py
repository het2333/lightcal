import asyncio

from services.food_database import FoodDatabase


def test_search_deduplicates_localized_equivalent_foods(tmp_path):
    database = FoodDatabase(tmp_path / "foods.db")
    with database._get_conn() as conn:
        apple = conn.execute(
            "SELECT * FROM foods WHERE name = ?",
            ("Apple, raw, medium",),
        ).fetchone()
        conn.execute(
            """
            INSERT INTO foods (
                id, name, calories, protein, carbs, fat, fiber, sugar,
                added_sugar, sodium, serving_size, grams_per_unit,
                processing_level, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "localized-apple",
                "苹果",
                apple["calories"],
                apple["protein"],
                apple["carbs"],
                apple["fat"],
                apple["fiber"],
                apple["sugar"],
                apple["added_sugar"],
                apple["sodium"],
                "1 个中等大小（182克）",
                apple["grams_per_unit"],
                apple["processing_level"],
                apple["source"],
            ),
        )

    foods = asyncio.run(database.search("苹果"))

    assert len(foods) == 1
    assert foods[0].name == "苹果"
