"""Execution context factory for CEL evaluation.

Builds an ExecutionContext pre-populated with nutrition variables
and built-in functions, matching the structure of Superscript-iOS's
ASTExecutionContext { variables, expression, device }.
"""

from models.rules import DailyStats, ExecutionContext, Goal
from engine.builtins import make_builtins


def create_context(
    daily_stats: DailyStats | None = None,
    goal: Goal | None = None,
    streak_days: int = 0,
    badges_unlocked: list[str] | None = None,
    device_platform: str = "ios",
    timezone: str = "Asia/Shanghai",
) -> ExecutionContext:
    """Create an ExecutionContext pre-loaded with nutrition data."""

    stats = daily_stats or DailyStats()
    g = goal or Goal()

    variables = {
        "today": {
            "calories": stats.calories,
            "protein": stats.protein,
            "carbs": stats.carbs,
            "fat": stats.fat,
            "fiber": stats.fiber,
            "sugar": stats.sugar,
            "sodium": stats.sodium,
            "water_ml": stats.water_ml,
            "meals_count": stats.meals_count,
            "foods_count": stats.foods_count,
        },
        "goal": {
            "calories": g.calories,
            "protein": g.protein,
            "carbs": g.carbs,
            "fat": g.fat,
            "fiber": g.fiber,
            "sugar": g.sugar,
            "sodium": g.sodium,
            "water_ml": g.water_ml,
        },
        "user": {
            "streak": streak_days,
            "badges": badges_unlocked or [],
        },
    }

    functions = make_builtins(
        daily_stats=stats,
        goal=g,
        badges_unlocked=badges_unlocked,
        streak_days=streak_days,
    )

    device = {
        "platform": device_platform,
        "timezone": timezone,
    }

    return ExecutionContext(variables=variables, functions=functions, device=device)
