"""Auto-complete service for food search suggestions.

Mirrors Cal AI's /v6/describeMeal/autoComplete and
/v6/describeMeal/autoComplete/suggestions endpoints.
"""

from services.food_database import FoodDatabase


class AutoCompleteService:
    """Food name auto-complete using the food database."""

    def __init__(self, food_db: FoodDatabase):
        self.food_db = food_db

    async def suggest(self, query: str, limit: int = 5) -> list[str]:
        """Return matching food name suggestions."""
        if not query or len(query.strip()) < 2:
            return []
        return await self.food_db.suggest(query.strip(), limit=limit)

    async def search(self, query: str, limit: int = 10) -> list[dict]:
        """Search for foods and return simplified results for auto-complete display."""
        foods = await self.food_db.search(query, limit=limit)
        return [
            {
                "name": f.name,
                "calories": f.calories,
                "serving_size": f.serving_size,
            }
            for f in foods
        ]
