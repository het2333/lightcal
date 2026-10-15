"""Tests for the unified nutrition decision engine."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from models.food import Food
from models.tracking import DailySummary
from services.decision_service import DecisionService


def test_context_combines_remaining_and_fasting_window():
    service = DecisionService()
    summary = DailySummary(
        date="2026-05-27",
        calories_consumed=1200,
        calories_goal=1880,
        protein=52,
        protein_goal=90,
    )
    fasting = {
        "preferences": {
            "enabled": True,
            "eating_window_start": "12:00",
            "eating_hours": 8,
            "method": "16:8",
        },
        "active_session": None,
        "recent_sessions": [],
    }

    context = service.build_context(summary, fasting_status=fasting)

    assert context["remaining"]["calories"] == 680
    assert context["remaining"]["protein"] == 38
    assert context["eating_window"]["label"] == "12:00 - 20:00"
    assert "高蛋白" in context["suggested_next_meal"]


def test_high_protein_meal_scores_as_today_fit():
    service = DecisionService()
    summary = DailySummary(
        date="2026-05-27",
        calories_consumed=900,
        calories_goal=1800,
        protein=35,
        protein_goal=95,
    )
    food = Food(
        name="香煎鸡胸轻食碗",
        calories=520,
        protein=42,
        carbs=48,
        fat=14,
        fiber=8,
        sugar=6,
        sodium=560,
        serving_size="1份",
        processing_level="minimally_processed",
    )

    decision = service.score_foods([food], summary, source="delivery", event_type="today_fit")

    assert decision["score_type"] == "today_fit_score"
    assert decision["score"] >= 75
    assert decision["today_fit_score"] == decision["score"]
    assert any("蛋白" in item for item in decision["reasons"])


def test_packaged_sugary_product_is_warned():
    service = DecisionService()
    summary = DailySummary(date="2026-05-27", calories_goal=1800, protein_goal=90)
    food = Food(
        name="高糖奶茶",
        calories=430,
        protein=5,
        carbs=72,
        fat=14,
        fiber=0,
        sugar=48,
        added_sugar=36,
        sodium=260,
        serving_size="1杯",
        processing_level="ultra_processed",
    )

    decision = service.score_foods([food], summary, source="barcode", event_type="product_score")

    assert decision["score_type"] == "packaged_health_score"
    assert decision["score"] < 70
    assert decision["warnings"]
    assert any("糖" in item for item in decision["suggestions"] + decision["warnings"])


def test_preview_score_does_not_persist_decision_event():
    class CapturingTracking:
        def __init__(self):
            self.saved = []

        def save_decision_event(self, *args):
            self.saved.append(args)

    tracking = CapturingTracking()
    service = DecisionService(tracking=tracking)
    summary = DailySummary(date="2026-07-11")
    food = Food(
        name="测试餐", calories=420, protein=30, carbs=45, fat=12,
        fiber=5, sugar=4, sodium=350,
    )

    service.score_foods([food], summary, source="candidate", event_type="today_fit", persist=False)
    assert tracking.saved == []

    service.score_foods([food], summary, source="meal", event_type="after_log", persist=True)
    assert len(tracking.saved) == 1
