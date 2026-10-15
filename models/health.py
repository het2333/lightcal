"""Health score models — multi-factor food quality assessment."""

from pydantic import BaseModel, Field


class ScoreLevel(str):
    """String labels for score ranges."""
    @staticmethod
    def for_score(score: int) -> str:
        if score <= 2:
            return "minimal"
        elif score <= 5:
            return "low"
        elif score <= 7:
            return "moderate"
        elif score <= 9:
            return "high"
        return "maximum"


class ArtificialScore(BaseModel):
    """How processed / artificial the food is.  Lower = less processed."""
    score: int = Field(ge=0, le=10)
    level: str = ""
    description: str = ""

    @classmethod
    def from_food(cls, processing_level: str, food_name: str) -> "ArtificialScore":
        mapping = {
            "whole": (1, "fresh vegetables, whole foods with no additives"),
            "minimally_processed": (3, "minimal processing, few or no additives"),
            "processed": (6, "contains preservatives and additives typical of processed foods"),
            "ultra_processed": (9, "heavily processed with multiple artificial ingredients"),
        }
        score, note = mapping.get(processing_level, (5, "moderate processing"))
        level = ScoreLevel.for_score(score)

        if processing_level == "whole":
            desc = (
                f"Artificial Score ({score}/10): This food is primarily composed of "
                f"{note}, which are naturally low in added sugars, sodium, and artificial ingredients."
            )
        elif processing_level == "minimally_processed":
            desc = (
                f"Artificial Score ({score}/10): Contains some additives and preservatives "
                f"typical of {food_name}, but minimal artificial ingredients."
            )
        elif processing_level == "ultra_processed":
            desc = (
                f"Artificial Score ({score}/10): {food_name} is highly processed "
                f"with multiple artificial ingredients, preservatives, and additives."
            )
        else:
            desc = (
                f"Artificial Score ({score}/10): {food_name} contains "
                f"preservatives and additives typical of processed foods."
            )

        return cls(score=score, level=level, description=desc)


class NetCarbsScore(BaseModel):
    """Net carbs per 100g score.  Lower = fewer net carbs."""
    score: int = Field(ge=0, le=10)
    net_carbs_per_100g: float
    total_carbs: float
    fiber: float
    level: str = ""

    @classmethod
    def from_food(cls, total_carbs: float, fiber: float) -> "NetCarbsScore":
        net_carbs = max(0, total_carbs - fiber)
        # scale: 0-15g → 0-1, 15-30g → 1-2, … 135-150g → 9-10
        score = min(10, int(net_carbs / 15))
        level = ScoreLevel.for_score(score)
        return cls(
            score=score,
            net_carbs_per_100g=round(net_carbs, 1),
            total_carbs=round(total_carbs, 1),
            fiber=round(fiber, 1),
            level=level,
        )

    def to_description(self) -> str:
        return (
            f"{self.level.capitalize()} ({self.score}/10) Net Carbs: "
            f"This food contains {self.net_carbs_per_100g}g of net carbs per 100g "
            f"(total carbs: {self.total_carbs}g, fiber: {self.fiber}g)."
        )


class AddedSugarScore(BaseModel):
    """Added sugar score.  Lower = less added sugar."""
    score: int = Field(ge=0, le=10)
    added_sugar_per_100g: float
    level: str = ""

    @classmethod
    def from_food(cls, added_sugar: float) -> "AddedSugarScore":
        # scale: 0g→0, 0.5g→1, 1g→2, … 5g+→10
        score = min(10, int(added_sugar * 2))
        level = ScoreLevel.for_score(score)
        return cls(
            score=score,
            added_sugar_per_100g=round(added_sugar, 1),
            level=level,
        )

    def to_description(self) -> str:
        if self.score <= 1:
            prefix = "No Added Sugar"
        else:
            prefix = f"{self.level.capitalize()} Added Sugar"
        return (
            f"{prefix} ({self.score}/10): This food contains "
            f"{self.added_sugar_per_100g}g of added sugar per 100g."
        )


class HealthScore(BaseModel):
    """Composite health score 0-10.  10 = healthiest."""
    total: int = Field(ge=0, le=10)
    artificial_score: ArtificialScore
    net_carbs_score: NetCarbsScore
    added_sugar_score: AddedSugarScore
    description: str = ""

    @classmethod
    def calculate(
        cls,
        food_name: str,
        processing_level: str,
        total_carbs: float,
        fiber: float,
        added_sugar: float,
    ) -> "HealthScore":
        artificial = ArtificialScore.from_food(processing_level, food_name)
        net_carbs = NetCarbsScore.from_food(total_carbs, fiber)
        added_sugar_sc = AddedSugarScore.from_food(added_sugar)

        # weighted composite: artificial 40%, net carbs 30%, added sugar 30%
        raw = (
            artificial.score * 0.4
            + net_carbs.score * 0.3
            + added_sugar_sc.score * 0.3
        )
        total = max(0, min(10, round(10 - raw)))

        # build natural language description (matching Cal AI format)
        parts = [
            f"Our health score is a complex formula taking into account several "
            f"factors given a multitude of common foods.",
            f"",
            f"Below are the factors we take into account when calculating health score:",
            f"",
            artificial.description,
            net_carbs.to_description(),
            added_sugar_sc.to_description(),
            f"",
            f"Overall Health Score: {total}/10",
        ]

        description = "\n".join(parts)

        return cls(
            total=total,
            artificial_score=artificial,
            net_carbs_score=net_carbs,
            added_sugar_score=added_sugar_sc,
            description=description,
        )
