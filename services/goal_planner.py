"""Weight goal planning — BMR, TDEE, projected timeline.

Mifflin-St Jeor equation for BMR.
7700 kcal ≈ 1 kg body fat.
"""

from datetime import date, timedelta
from enum import Enum
from typing import Optional
import math


class ActivityLevel(str, Enum):
    sedentary = "sedentary"           # 1.2
    light = "light"                   # 1.375
    moderate = "moderate"             # 1.55
    active = "active"                 # 1.725
    very_active = "very_active"       # 1.9


ACTIVITY_MULTIPLIERS = {
    ActivityLevel.sedentary: 1.2,
    ActivityLevel.light: 1.375,
    ActivityLevel.moderate: 1.55,
    ActivityLevel.active: 1.725,
    ActivityLevel.very_active: 1.9,
}

KCAL_PER_KG = 7700  # approximate kcal per kg of body fat


def calculate_bmr(weight_kg: float, height_cm: float, age: int, gender: str = "male") -> float:
    """Mifflin-St Jeor BMR equation."""
    if gender == "male":
        return 10 * weight_kg + 6.25 * height_cm - 5 * age + 5
    else:
        return 10 * weight_kg + 6.25 * height_cm - 5 * age - 161


def calculate_tdee(bmr: float, activity: ActivityLevel) -> float:
    return bmr * ACTIVITY_MULTIPLIERS[activity]


def calculate_daily_calories(tdee: float, deficit_pct: float = 20) -> dict:
    """Calculate intake for weight loss, maintenance, or weight gain."""
    deficit_pct = max(-20, min(30, deficit_pct))
    deficit_kcal = tdee * (deficit_pct / 100)
    intake = max(1000, min(6000, tdee - deficit_kcal))
    return {
        "tdee": round(tdee),
        "deficit_pct": deficit_pct,
        "deficit_kcal": round(deficit_kcal),
        "recommended_intake": round(intake),
        "weekly_loss_kg": round(deficit_kcal * 7 / KCAL_PER_KG, 2),
    }


class GoalPlan:
    """Full weight goal plan."""

    def __init__(
        self,
        current_weight_kg: float,
        goal_weight_kg: float,
        height_cm: float = 170,
        age: int = 30,
        gender: str = "male",
        activity: ActivityLevel = ActivityLevel.moderate,
        deficit_pct: float = 20,
    ):
        self.current_weight = current_weight_kg
        self.goal_weight = goal_weight_kg
        self.height_cm = height_cm
        self.age = age
        self.gender = gender
        self.activity = activity

        self.bmr = calculate_bmr(current_weight_kg, height_cm, age, gender)
        self.tdee = calculate_tdee(self.bmr, activity)
        self.calorie_plan = calculate_daily_calories(self.tdee, deficit_pct)

        # Time projection
        weight_delta = current_weight_kg - goal_weight_kg
        if weight_delta > 0:
            # Weight loss
            self.direction = "lose"
            self.total_kcal_to_burn = weight_delta * KCAL_PER_KG
            daily_deficit = self.calorie_plan["deficit_kcal"]
            if daily_deficit > 0:
                self.estimated_days = math.ceil(self.total_kcal_to_burn / daily_deficit)
                self.goal_date = (date.today() + timedelta(days=self.estimated_days)).isoformat()
            else:
                self.estimated_days = None
                self.goal_date = None
        elif weight_delta < 0:
            # Weight gain
            self.direction = "gain"
            self.estimated_days = None
            self.goal_date = None
        else:
            # Maintenance
            self.direction = "maintain"
            self.estimated_days = 0
            self.goal_date = date.today().isoformat()

    def to_dict(self) -> dict:
        return {
            "current_weight_kg": self.current_weight,
            "goal_weight_kg": self.goal_weight,
            "direction": self.direction,
            "weight_delta_kg": round(abs(self.current_weight - self.goal_weight), 1),
            "bmr": round(self.bmr),
            "tdee": round(self.tdee),
            "daily_calorie_target": self.calorie_plan["recommended_intake"],
            "deficit_kcal_per_day": self.calorie_plan["deficit_kcal"],
            "weekly_loss_kg": self.calorie_plan["weekly_loss_kg"],
            "estimated_days": self.estimated_days,
            "goal_date": self.goal_date,
            "activity_level": self.activity.value,
        }

    def progress_report(self, latest_weight_kg: float) -> dict:
        """Generate progress report based on latest weight."""
        if self.direction == "lose":
            lost = max(0, self.current_weight - latest_weight_kg)
            total = self.current_weight - self.goal_weight
            pct = min(100, round(lost / total * 100)) if total > 0 else 100
        elif self.direction == "gain":
            gained = max(0, latest_weight_kg - self.current_weight)
            total = self.goal_weight - self.current_weight
            pct = min(100, round(gained / total * 100)) if total > 0 else 100
        else:
            lost = 0; total = 0; pct = 100

        # Recalculate estimated days based on actual progress
        if self.direction == "lose" and lost > 0:
            elapsed = (date.today() - date.fromisoformat(self.current_weight if isinstance(self.current_weight, str) else "2026-01-01")).days
            elapsed = max(1, elapsed)
            rate = lost / elapsed  # kg/day
            remaining = total - lost
            est_remaining = math.ceil(remaining / rate) if rate > 0 and remaining > 0 else None
        else:
            est_remaining = self.estimated_days

        return {
            "progress_pct": pct,
            "weight_lost_kg": round(lost, 1),
            "weight_remaining_kg": round(total - lost, 1),
            "estimated_days_remaining": est_remaining,
            "projected_goal_date": (
                (date.today() + timedelta(days=est_remaining)).isoformat()
                if est_remaining else None
            ),
        }
