"""Tests for the health score calculation system."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

from models.health import HealthScore, ArtificialScore, NetCarbsScore, AddedSugarScore, ScoreLevel
from models.food import Food, ProcessingLevel


class TestArtificialScore:
    def test_whole_food_scores_low(self):
        score = ArtificialScore.from_food("whole", "Fresh Apple")
        assert score.score <= 2
        assert score.level in ("minimal",)

    def test_ultra_processed_scores_high(self):
        score = ArtificialScore.from_food("ultra_processed", "Frozen Pizza")
        assert score.score >= 8
        assert score.level in ("high", "maximum")

    def test_description_contains_food_name(self):
        score = ArtificialScore.from_food("whole", "Fresh Salad")
        assert "Fresh Salad" in score.description or "fresh vegetables" in score.description


class TestNetCarbsScore:
    def test_low_carbs_scores_low(self):
        # 5g total carbs, 3g fiber → 2g net carbs per 100g
        score = NetCarbsScore.from_food(total_carbs=5, fiber=3)
        assert score.score == 0
        assert score.net_carbs_per_100g == 2.0
        assert score.level == "minimal"

    def test_high_carbs_scores_high(self):
        # 150g total carbs, 2g fiber → 148g net carbs per 100g
        score = NetCarbsScore.from_food(total_carbs=150, fiber=2)
        assert score.score >= 9
        assert score.level in ("high", "maximum")

    def test_medium_carbs(self):
        # 40g total carbs, 1g fiber → 39g net carbs per 100g
        # 39/15 = 2.6 → score = 2, which maps to "minimal" (0-2)
        score = NetCarbsScore.from_food(total_carbs=40, fiber=1)
        assert score.score == 2
        assert score.level == "minimal"

    def test_to_description(self):
        score = NetCarbsScore.from_food(total_carbs=39, fiber=0.3)
        desc = score.to_description()
        assert "38.7" in desc or "38" in desc
        assert "net carbs" in desc.lower()


class TestAddedSugarScore:
    def test_no_sugar_scores_zero(self):
        score = AddedSugarScore.from_food(added_sugar=0)
        assert score.score == 0
        assert "No Added Sugar" in score.to_description()

    def test_high_sugar_scores_high(self):
        score = AddedSugarScore.from_food(added_sugar=6)
        assert score.score == 10
        assert score.level in ("high", "maximum")


class TestHealthScore:
    def test_healthy_food_high_score(self):
        """A whole green salad should score well."""
        score = HealthScore.calculate(
            food_name="Mixed Green Salad",
            processing_level="whole",
            total_carbs=3,
            fiber=2,
            added_sugar=0,
        )
        # artificial=1, net_carbs=0, added_sugar=0
        # raw = 1*0.4 + 0*0.3 + 0*0.3 = 0.4 → total ≈ 10
        assert score.total >= 8
        assert "Overall Health Score" in score.description
        assert "salad" in score.description.lower() or "vegetables" in score.description.lower()

    def test_unhealthy_food_low_score(self):
        """Ultra-processed high-carb high-sugar food should score low."""
        score = HealthScore.calculate(
            food_name="Candy Bar",
            processing_level="ultra_processed",
            total_carbs=60,
            fiber=1,
            added_sugar=45,
        )
        # artificial=9, net_carbs=3, added_sugar=10 (capped)
        # raw = 9*0.4 + 3*0.3 + 10*0.3 = 3.6+0.9+3.0 = 7.5
        # total = round(10 - 7.5) = 2 or 3
        assert score.total <= 4

    def test_mixed_food_mid_score(self):
        """Whole wheat bread - some processing, moderate carbs, some added sugar."""
        score = HealthScore.calculate(
            food_name="Whole Wheat Bread",
            processing_level="processed",
            total_carbs=14,
            fiber=2,
            added_sugar=1.4,
        )
        # artificial=6, net_carbs=0 (12g/100g→0), added_sugar=2 (1.4*2=2.8→2)
        # raw = 6*0.4 + 0*0.3 + 2*0.3 = 2.4+0+0.6 = 3.0 → total = 7
        assert 4 <= score.total <= 8


class TestScoreLevel:
    def test_level_for_score(self):
        assert ScoreLevel.for_score(0) == "minimal"
        assert ScoreLevel.for_score(3) == "low"
        assert ScoreLevel.for_score(6) == "moderate"
        assert ScoreLevel.for_score(8) == "high"
        assert ScoreLevel.for_score(10) == "maximum"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
