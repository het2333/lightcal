"""Rule engine models — CEL context, badges, goals."""

from datetime import date, datetime
from enum import Enum
from typing import Any, Callable, Optional

from pydantic import BaseModel, Field


class BadgeCategory(str, Enum):
    calories = "calories"
    meals = "meals"
    water = "water"
    weight = "weight"
    nutrition = "nutrition"
    streak = "streak"
    friends = "friends"
    workout = "workout"
    health = "health"


class Badge(BaseModel):
    """A badge/achievement that can be unlocked."""
    id: str
    name: str
    description: str
    category: BadgeCategory
    icon: str = ""
    condition: str = ""  # CEL expression that must evaluate to true
    is_unlocked: bool = False


class Goal(BaseModel):
    """A user's daily nutrition goal."""
    calories: float = 2000
    protein: float = 50
    carbs: float = 250
    fat: float = 65
    fiber: float = 25
    sugar: float = 50
    sodium: float = 2300
    water_ml: float = 2000


class DailyStats(BaseModel):
    """Today's accumulated nutrition stats."""
    date: str = Field(default_factory=lambda: date.today().isoformat())
    calories: float = 0
    protein: float = 0
    carbs: float = 0
    fat: float = 0
    fiber: float = 0
    sugar: float = 0
    sodium: float = 0
    water_ml: float = 0
    meals_count: int = 0
    foods_count: int = 0
    exercise_calories_burned: float = 0


class Rule(BaseModel):
    """A named CEL rule for evaluation."""
    id: str
    name: str
    description: str
    expression: str  # CEL expression string
    category: str = ""


class ExecutionContext:
    """Runtime context for CEL expression evaluation.

    Mirrors ASTExecutionContext from Superscript-iOS:
      variables, expression, device
    """

    def __init__(
        self,
        variables: Optional[dict[str, Any]] = None,
        functions: Optional[dict[str, Callable]] = None,
        device: Optional[dict[str, Any]] = None,
    ):
        self.variables = variables or {}
        self.functions = functions or {}
        self.device = device or {}

    def resolve(self, name: str) -> Any:
        """Resolve a variable or dotted-path access."""
        if "." in name:
            parts = name.split(".")
            root = self.variables
            for p in parts:
                if isinstance(root, dict):
                    root = root.get(p)
                elif hasattr(root, p):
                    root = getattr(root, p)
                else:
                    return None
            return root
        return self.variables.get(name)

    def call(self, name: str, *args) -> Any:
        """Call a registered function."""
        fn = self.functions.get(name)
        if fn is None:
            raise NameError(f"Function '{name}' is not defined")
        return fn(*args)
