"""Built-in functions available in CEL expressions.

Mirrors the functions registered in Cal AI's HostContextImpl
(Superscript-iOS callback interface).

Categories:
  nutrition.*  — food health / nutrition queries
  badge.*      — badge unlock checks
  streak.*     — streak tracking
  date.*       — date utilities
  stats.*      — daily stats helpers
"""

from datetime import date, datetime, timedelta
from typing import Any, Callable


def make_builtins(
    *,
    daily_stats: Any = None,
    goal: Any = None,
    badges_unlocked: list[str] | None = None,
    streak_days: int = 0,
) -> dict[str, Callable]:
    """Create the built-in function registry for CEL evaluation."""

    badges = set(badges_unlocked or [])

    def nutrition_health_score(food_name: str) -> int:
        """Get the health score (0-10) for a food by name."""
        # delegates to the health scorer service — placeholder
        return 5  # default mid-range

    def nutrition_is_processed(food_name: str) -> bool:
        """Check if a food is processed."""
        processed_keywords = [
            "chip", "candy", "soda", "cookie", "cracker", "frozen",
            "instant", "fast food", "processed", "packaged", "canned",
            "sausage", "bacon", "nugget", "patty",
        ]
        name_lower = food_name.lower()
        return any(kw in name_lower for kw in processed_keywords)

    def nutrition_is_greens(food_name: str) -> bool:
        """Check if a food is a green vegetable."""
        greens = [
            "spinach", "kale", "lettuce", "broccoli", "cabbage",
            "arugula", "chard", "collard", "bok choy", "watercress",
            "green bean", "asparagus", "brussels sprout", "cucumber",
            "zucchini", "celery", "pea", "green pepper", "salad",
            "mixed greens", "romaine", "iceberg",
        ]
        name_lower = food_name.lower()
        return any(g in name_lower for g in greens)

    def badge_unlock(badge_id: str) -> bool:
        """Unlock a badge. Returns True if newly unlocked."""
        if badge_id not in badges:
            badges.add(badge_id)
            return True
        return False

    def badge_is_unlocked(badge_id: str) -> bool:
        return badge_id in badges

    def streak_current() -> int:
        return streak_days

    def date_today() -> str:
        return date.today().isoformat()

    def date_days_between(d1: str, d2: str) -> int:
        return abs((datetime.fromisoformat(d1) - datetime.fromisoformat(d2)).days)

    def stats_calories_left() -> float:
        if daily_stats and goal:
            return goal.calories - daily_stats.calories
        return 0

    def stats_protein_left() -> float:
        if daily_stats and goal:
            return goal.protein - daily_stats.protein
        return 0

    def stats_calorie_percent() -> float:
        if daily_stats and goal and goal.calories > 0:
            return (daily_stats.calories / goal.calories) * 100
        return 0

    def any_true(lst, fn) -> bool:
        """CEL-style: list.any(element, condition_function)"""
        if not callable(fn) and not lst:
            return False
        if callable(fn):
            return any(fn(item) for item in lst)
        return any(lst)

    return {
        "nutrition.health_score": nutrition_health_score,
        "nutrition.is_processed": nutrition_is_processed,
        "nutrition.is_greens": nutrition_is_greens,
        "badge.unlock": badge_unlock,
        "badge.is_unlocked": badge_is_unlocked,
        "streak.current": streak_current,
        "date.today": date_today,
        "date.days_between": date_days_between,
        "stats.calories_left": stats_calories_left,
        "stats.protein_left": stats_protein_left,
        "stats.calorie_percent": stats_calorie_percent,
        "any": any_true,
    }


# Standard builtins available without context
BUILTINS: dict[str, Callable] = make_builtins()
