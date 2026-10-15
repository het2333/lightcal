"""Tests for full daily nutrition totals beyond protein/carbs/fat."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import services.tracking_service as tracking_module
from models.food import Food
from services.tracking_service import TrackingService


def test_daily_summary_includes_full_nutrition(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    tracking = TrackingService()
    foods = [
        Food(
            name="Test food",
            calories=100,
            protein=10,
            carbs=12,
            fat=3,
            fiber=4,
            sugar=5,
            added_sugar=2,
            sodium=200,
            sat_fat=1.5,
            trans_fat=0.1,
            cholesterol=25,
            vitamin_a=120,
            vitamin_c=8,
            calcium=60,
            iron=2,
            potassium=300,
            magnesium=42,
            zinc=3,
            folate=120,
            vitamin_d=5,
            vitamin_b12=1.2,
            vitamin_e=4,
            vitamin_k=35,
            omega_3=0.8,
            monounsaturated_fat=2.1,
            polyunsaturated_fat=1.4,
        )
    ]

    summary = tracking.get_daily_summary("2026-05-23", foods=foods)

    assert summary.fiber == 4
    assert summary.sugar == 5
    assert summary.added_sugar == 2
    assert summary.sodium == 200
    assert summary.sat_fat == 1.5
    assert summary.trans_fat == 0.1
    assert summary.cholesterol == 25
    assert summary.vitamin_a == 120
    assert summary.vitamin_c == 8
    assert summary.calcium == 60
    assert summary.iron == 2
    assert summary.potassium == 300
    assert summary.magnesium == 42
    assert summary.zinc == 3
    assert summary.folate == 120
    assert summary.vitamin_d == 5
    assert summary.vitamin_b12 == 1.2
    assert summary.vitamin_e == 4
    assert summary.vitamin_k == 35
    assert summary.omega_3 == 0.8
    assert summary.monounsaturated_fat == 2.1
    assert summary.polyunsaturated_fat == 1.4
