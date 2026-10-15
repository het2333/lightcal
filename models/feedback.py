"""FixFood / ReportFood / VoteFood models — Cal AI's data flywheel.

These three operations form the correction loop:
  Gemini estimate → user sees result
    → VoteFood: "this looks right" (builds confidence)
    → FixFood:  "this is wrong, here's the correct data" (overwrites)
    → ReportFood: "this is broken/offensive/wrong category" (flags for review)
"""

from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class FixFoodRequest(BaseModel):
    """User corrects nutrition data for a food."""
    food_id: str
    original_name: str
    corrected_name: Optional[str] = None
    corrected_calories: Optional[float] = None
    corrected_protein: Optional[float] = None
    corrected_carbs: Optional[float] = None
    corrected_fat: Optional[float] = None
    corrected_fiber: Optional[float] = None
    corrected_sugar: Optional[float] = None
    corrected_sodium: Optional[float] = None
    corrected_serving_size: Optional[str] = None
    corrected_processing_level: Optional[str] = None
    note: str = ""


class FixFoodResponse(BaseModel):
    food_id: str
    status: str  # "updated" | "not_found"
    corrected_fields: list[str]
    message: str


class ReportReason(str, Enum):
    wrong_nutrition = "wrong_nutrition"
    wrong_name = "wrong_name"
    offensive = "offensive"
    duplicate = "duplicate"
    not_a_food = "not_a_food"
    other = "other"


class ReportFoodRequest(BaseModel):
    food_id: str
    food_name: str
    reason: ReportReason
    detail: str = ""


class VoteType(str, Enum):
    accurate = "accurate"       # 👍 this data is correct
    inaccurate = "inaccurate"   # 👎 this data is wrong
    helpful = "helpful"         # ⭐ this analysis was helpful


class VoteFoodRequest(BaseModel):
    food_id: str
    food_name: str
    vote: VoteType


class FoodConfidence(BaseModel):
    """Confidence tracking for each food in the database."""
    food_id: str
    food_name: str
    accurate_votes: int = 0
    inaccurate_votes: int = 0
    fix_count: int = 0
    report_count: int = 0
    last_updated: str = Field(default_factory=lambda: datetime.now().isoformat())
    source: str = "gemini"  # "gemini" | "user_fix" | "barcode" | "label_ocr"

    @property
    def confidence_score(self) -> float:
        """0.0 - 1.0 confidence based on votes and fixes."""
        total_votes = self.accurate_votes + self.inaccurate_votes
        if total_votes == 0 and self.fix_count == 0:
            return 0.3  # initial Gemini estimate: low confidence
        if total_votes == 0:
            return 0.5  # fixed but not voted
        accuracy = self.accurate_votes / total_votes
        # fixes reduce confidence initially, many accurate votes build it
        fix_penalty = max(0, self.fix_count * 0.1)
        return max(0.0, min(1.0, accuracy - fix_penalty))

    @property
    def level(self) -> str:
        """Human-readable confidence level."""
        s = self.confidence_score
        if s >= 0.8:
            return "verified"
        if s >= 0.5:
            return "reliable"
        if s >= 0.3:
            return "estimate"
        return "uncertain"
