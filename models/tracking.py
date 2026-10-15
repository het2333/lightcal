"""Tracking models — exercise, weight, water, meal plans, insights."""

from datetime import date, datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


# ── Exercise ──────────────────────────────────────────────────────

class ExerciseIntensity(str, Enum):
    light = "light"
    moderate = "moderate"
    vigorous = "vigorous"


class Exercise(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    name: str
    duration_minutes: int
    intensity: ExerciseIntensity = ExerciseIntensity.moderate
    calories_burned: float = 0
    date: str = Field(default_factory=lambda: date.today().isoformat())
    notes: str = ""


# ── Weight ────────────────────────────────────────────────────────

class WeightLog(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    weight_kg: float
    date: str = Field(default_factory=lambda: date.today().isoformat())
    notes: str = ""


# ── Water ─────────────────────────────────────────────────────────

class WaterLog(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    amount_ml: float
    date: str = Field(default_factory=lambda: date.today().isoformat())


class HydrationLog(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    drink_type: str = "water"
    amount_ml: float
    hydration_factor: float = 1
    effective_ml: float = 0
    caffeine_mg: float = 0
    alcohol_g: float = 0
    sugar_g: float = 0
    calories: float = 0
    protein_g: float = 0
    carbs_g: float = 0
    fat_g: float = 0
    source: str = "manual"
    note: str = ""
    external_id: str = ""
    date: str = Field(default_factory=lambda: date.today().isoformat())
    logged_at: str = Field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))


class DrinkPreset(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    drink_type: str
    name: str
    default_amount_ml: float = 250
    hydration_factor: float = 1
    caffeine_mg: float = 0
    alcohol_g: float = 0
    sugar_g: float = 0
    calories: float = 0
    protein_g: float = 0
    carbs_g: float = 0
    fat_g: float = 0
    color: str = "#2f80ed"
    icon: str = "drop"
    custom: bool = False


# ── Steps ──────────────────────────────────────────────────────────

class StepLog(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    date: str = Field(default_factory=lambda: date.today().isoformat())
    steps: int = 0
    source: str = "manual"  # manual | healthkit | google_fit


# ── Daily Summary ─────────────────────────────────────────────────

class DailySummary(BaseModel):
    date: str = Field(default_factory=lambda: date.today().isoformat())
    calories_consumed: float = 0
    calories_burned: float = 0
    calories_goal: float = 2000
    exercise_adjustment: float = 0  # calories added from exercise
    protein: float = 0
    protein_goal: float = 50
    carbs: float = 0
    carbs_goal: float = 250
    fat: float = 0
    fat_goal: float = 65
    fiber: float = 0
    fiber_goal: float = 25
    sugar: float = 0
    sugar_goal: float = 50
    added_sugar: float = 0
    added_sugar_goal: float = 50
    sodium: float = 0
    sodium_goal: float = 2300
    sat_fat: float = 0
    sat_fat_goal: float = 20
    trans_fat: float = 0
    cholesterol: float = 0
    cholesterol_goal: float = 300
    vitamin_a: float = 0
    vitamin_a_goal: float = 3000
    vitamin_c: float = 0
    vitamin_c_goal: float = 90
    calcium: float = 0
    calcium_goal: float = 1000
    iron: float = 0
    iron_goal: float = 18
    potassium: float = 0
    potassium_goal: float = 4700
    magnesium: float = 0
    magnesium_goal: float = 420
    zinc: float = 0
    zinc_goal: float = 11
    folate: float = 0
    folate_goal: float = 400
    vitamin_d: float = 0
    vitamin_d_goal: float = 20
    vitamin_b12: float = 0
    vitamin_b12_goal: float = 2.4
    vitamin_e: float = 0
    vitamin_e_goal: float = 15
    vitamin_k: float = 0
    vitamin_k_goal: float = 120
    omega_3: float = 0
    omega_3_goal: float = 1.6
    monounsaturated_fat: float = 0
    polyunsaturated_fat: float = 0
    water_ml: float = 0
    water_goal_ml: float = 2000
    hydration_ml: float = 0
    hydration_effective_ml: float = 0
    hydration_goal_ml: float = 2000
    caffeine_mg: float = 0
    alcohol_g: float = 0
    drink_sugar_g: float = 0
    drink_calories: float = 0
    drink_count: int = 0
    weight_kg: Optional[float] = None
    meals_count: int = 0
    exercise_count: int = 0
    streak_days: int = 0
    steps: int = 0
    steps_goal: int = 10000
    weight_projection: Optional[str] = None  # "If every day were like today..." message

    @property
    def calorie_pct(self) -> int:
        return min(100, int(self.calories_consumed / max(1, self.calories_goal) * 100))

    @property
    def protein_pct(self) -> int:
        return min(100, int(self.protein / max(1, self.protein_goal) * 100))

    @property
    def net_calories(self) -> float:
        return self.calories_consumed - self.calories_burned


# ── Meal Plan ─────────────────────────────────────────────────────

class MealPlanDay(BaseModel):
    day: str  # "Monday", etc.
    meals: list[dict] = Field(default_factory=list)  # [{name, calories, protein, carbs, fat}]


class MealPlan(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    name: str = ""
    daily_calorie_target: float = 2000
    days: list[MealPlanDay] = Field(default_factory=list)


# ── LLM Insight ───────────────────────────────────────────────────

class Insight(BaseModel):
    id: str = Field(default_factory=lambda: __import__("uuid").uuid4().hex[:12])
    date: str = Field(default_factory=lambda: date.today().isoformat())
    title: str = ""
    body: str = ""
    type: str = "general"  # general, nutrition, exercise, weight, streak, tip
    icon: str = "💡"
