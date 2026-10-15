"""Health score calculation service.

Mirrors Cal AI's /v6/health-score and /v6/health-score-description endpoints.
Computes the multi-factor 0-10 health score used to rate food quality.
"""

from models.food import Food
from models.health import HealthScore


class HealthScorer:
    """Calculates health scores for foods and meals."""

    def score_food(self, food: Food) -> HealthScore:
        """Calculate the health score for a single food item."""
        return HealthScore.calculate(
            food_name=food.name,
            processing_level=food.processing_level.value,
            total_carbs=food.carbs,
            fiber=food.fiber,
            added_sugar=food.added_sugar,
        )

    def score_foods(self, foods: list[Food]) -> list[HealthScore]:
        """Calculate health scores for multiple foods."""
        return [self.score_food(f) for f in foods]

    def describe(self) -> str:
        """Return the health score system explanation (for /v6/health-score-description)."""
        return (
            "Our health score is a complex formula taking into account several "
            "factors given a multitude of common foods.\n\n"
            "Below are the factors we take into account when calculating health score:\n\n"
            "1. Artificial Score (0-10): Measures how processed the food is. "
            "Whole foods score low (good), ultra-processed foods score high (bad). "
            "Considers the presence of preservatives, artificial ingredients, "
            "and additives.\n\n"
            "2. Net Carbs Score (0-10): Evaluates carbohydrate density. "
            "Net carbs = total carbohydrates - dietary fiber. "
            "Lower net carbs per 100g gives a better score.\n\n"
            "3. Added Sugar Score (0-10): Assesses added sugar content. "
            "Foods with no added sugar score best. "
            "Based on grams of added sugar per 100g.\n\n"
            "The total health score (0-10, 10 = healthiest) is calculated as: "
            "10 - (Artificial × 0.4 + Net Carbs × 0.3 + Added Sugar × 0.3). "
            "All three sub-scores contribute to the final result, "
            "with processing level weighted most heavily."
        )
