"""Food and meal data models — mapping to Cal AI's LLMDescription + API types."""

from datetime import date
from enum import Enum
from typing import Optional
from uuid import uuid4

from pydantic import BaseModel, Field


def _new_id() -> str:
    return uuid4().hex[:12]


class ScanSource(str, Enum):
    """Input source types — matches Cal AI's Body enum."""
    image_scan = "image_scan"
    describe_meal = "describe_meal"
    barcode_scan = "barcode_scan"
    barcode_camera = "barcode_camera"
    label_scan = "label_scan"
    library = "library"
    database = "database"
    manually = "manually"


class ProcessingLevel(str, Enum):
    """Food processing classification."""
    whole = "whole"             # 天然食物
    minimally_processed = "minimally_processed"
    processed = "processed"     # 含添加剂/防腐剂
    ultra_processed = "ultra_processed"


class Food(BaseModel):
    """Single food item with full nutrition breakdown.

    Field mapping to Swift LLMDescription:
      date_SS4nameSd8caloriesSd7proteinSd5carbsSd3fatSd5fiberSd5sugarSd6sodium
    """
    id: str = Field(default_factory=_new_id)
    name: str
    date: str = Field(default_factory=lambda: date.today().isoformat())
    calories: float          # kcal
    protein: float           # g
    carbs: float             # g (total)
    fat: float               # g
    fiber: float             # g
    sugar: float             # g (total, including added)
    sodium: float            # mg
    serving_size: str = "100g"
    quantity_count: Optional[float] = None
    quantity_unit: str = ""
    quantity_description: str = ""
    consumed_ratio: float = 1.0
    processing_level: ProcessingLevel = ProcessingLevel.whole
    added_sugar: float = 0.0  # g of added sugar specifically
    sat_fat: float = 0.0      # g saturated fat
    trans_fat: float = 0.0    # g trans fat
    cholesterol: float = 0.0  # mg
    vitamin_a: float = 0.0    # IU
    vitamin_c: float = 0.0    # mg
    calcium: float = 0.0      # mg
    iron: float = 0.0         # mg
    potassium: float = 0.0    # mg
    magnesium: float = 0.0    # mg
    zinc: float = 0.0         # mg
    folate: float = 0.0       # mcg
    vitamin_d: float = 0.0    # mcg
    vitamin_b12: float = 0.0  # mcg
    vitamin_e: float = 0.0    # mg
    vitamin_k: float = 0.0    # mcg
    omega_3: float = 0.0      # g
    monounsaturated_fat: float = 0.0  # g
    polyunsaturated_fat: float = 0.0  # g
    grams_per_unit: float = 100.0
    barcode: str = ""
    nutrition_source: str = ""


class Meal(BaseModel):
    """A meal containing multiple foods."""
    id: str = Field(default_factory=_new_id)
    date: str = Field(default_factory=lambda: date.today().isoformat())
    name: str = ""
    foods: list[Food] = Field(default_factory=list)
    category: str = ""  # breakfast, lunch, dinner, snack

    @property
    def total_calories(self) -> float:
        return sum(f.calories for f in self.foods)

    @property
    def total_protein(self) -> float:
        return sum(f.protein for f in self.foods)

    @property
    def total_carbs(self) -> float:
        return sum(f.carbs for f in self.foods)

    @property
    def total_fat(self) -> float:
        return sum(f.fat for f in self.foods)

    @property
    def total_fiber(self) -> float:
        return sum(f.fiber for f in self.foods)


class DescribeMealRequest(BaseModel):
    """Request body for /v6/describeMeal."""
    source: ScanSource = ScanSource.image_scan
    image_base64: Optional[str] = None   # base64-encoded JPEG
    text: Optional[str] = None            # text description (for text mode)
    barcode: Optional[str] = None         # barcode number
    meal_category: Optional[str] = None   # breakfast/lunch/dinner/snack
    depth_metadata: Optional[dict] = None # iOS depth/volume hints from AVCapture
    capture_metadata: Optional[dict] = None # client capture context


class DescribeMealResponse(BaseModel):
    """Response from /v6/describeMeal."""
    model_config = {"arbitrary_types_allowed": True}

    foods: list[Food]
    health_score: Optional["HealthScore"] = None  # forward ref
    description: str = ""  # LLM's natural language description text
    decision: Optional[dict] = None
    estimation_metadata: Optional[dict] = None


# Resolve forward reference
from .health import HealthScore  # noqa: E402
DescribeMealResponse.model_rebuild()
