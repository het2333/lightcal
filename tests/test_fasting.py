"""Tests for optional intermittent fasting API logic."""

import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
import services.tracking_service as tracking_module
from services.tracking_service import TrackingService


@pytest.fixture()
def isolated_tracking(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())


def test_fasting_preferences_status_start_end_history(isolated_tracking):
    ended_at = datetime.now().astimezone() - timedelta(hours=1)
    started_at = ended_at - timedelta(hours=14, minutes=30)

    prefs = server._save_fasting_preferences(
        server.FastingPreferencesRequest(enabled=True, method="14:10", eating_window_start="09:30")
    )
    assert prefs["enabled"] is True
    assert prefs["method"] == "14:10"
    assert prefs["fasting_hours"] == 14

    status = server._get_fasting_status()
    assert status["enabled"] is True
    assert status["is_fasting"] is False

    started = server._start_fasting_session(
        server.FastingStartRequest(start_at=started_at.isoformat(timespec="seconds"))
    )
    assert started["is_fasting"] is True
    assert started["active_session"]["method"] == "14:10"
    assert started["active_session"]["target_seconds"] == 14 * 3600
    assert started["current_stage"]["id"]
    assert len(started["stage_plan"]) >= 4

    ended = server._end_fasting_session(
        server.FastingEndRequest(ended_at=ended_at.isoformat(timespec="seconds"), notes="完成")
    )
    assert ended["is_fasting"] is False
    assert ended["recent_sessions"][0]["status"] == "completed"
    assert ended["recent_sessions"][0]["completed"] is True

    history = server._get_fasting_history(7)
    assert history["summary"]["total_sessions"] == 1
    assert history["summary"]["completed_sessions"] == 1
    assert history["summary"]["average_hours"] == 14.5


def test_fasting_start_method_keeps_eating_window_consistent(isolated_tracking):
    started = server._start_fasting_session(
        server.FastingStartRequest(method="18:6", fasting_hours=18, start_at="2026-05-25T08:00:00+08:00")
    )

    assert started["is_fasting"] is True
    assert started["active_session"]["method"] == "18:6"
    assert started["preferences"]["enabled"] is True
    assert started["preferences"]["method"] == "18:6"
    assert started["preferences"]["eating_hours"] == 6


def test_fasting_stage_estimation():
    early = server._fasting_stage_for_elapsed(2 * 3600, 16 * 3600)
    dropping = server._fasting_stage_for_elapsed(4 * 3600, 16 * 3600)
    stable = server._fasting_stage_for_elapsed(10 * 3600, 16 * 3600)
    fat_burning = server._fasting_stage_for_elapsed(12 * 3600, 16 * 3600)
    ketosis = server._fasting_stage_for_elapsed(15 * 3600, 16 * 3600)
    autophagy = server._fasting_stage_for_elapsed(17 * 3600, 20 * 3600)

    assert early["id"] == "blood_sugar_rises"
    assert dropping["id"] == "blood_sugar_drops"
    assert stable["id"] == "blood_sugar_stabilizes"
    assert fat_burning["id"] == "fat_burning"
    assert ketosis["id"] == "ketosis"
    assert autophagy["id"] == "autophagy"
    assert fat_burning["next_label"] == "酮体开始"


def test_manual_fasting_session_updates_history(isolated_tracking):
    ended = datetime.now().astimezone() - timedelta(hours=2)
    start = ended - timedelta(hours=16, minutes=20)

    history = server._add_manual_fasting_session(
        server.FastingManualRequest(
            method="16:8",
            fasting_hours=16,
            start_at=start.isoformat(timespec="seconds"),
            ended_at=ended.isoformat(timespec="seconds"),
            notes="补记昨天晚上的断食",
        )
    )

    assert history["summary"]["total_sessions"] == 1
    assert history["summary"]["completed_sessions"] == 1
    assert history["summary"]["average_hours"] == 16.3
    assert history["sessions"][0]["method"] == "16:8"
    assert history["sessions"][0]["status"] == "completed"
    assert history["sessions"][0]["notes"] == "补记昨天晚上的断食"


def test_manual_fasting_rejects_invalid_time_range(isolated_tracking):
    now = datetime.now().astimezone()

    with pytest.raises(server.HTTPException) as exc:
        server._add_manual_fasting_session(
            server.FastingManualRequest(
                start_at=now.isoformat(timespec="seconds"),
                ended_at=(now - timedelta(hours=1)).isoformat(timespec="seconds"),
            )
        )

    assert exc.value.status_code == 400
