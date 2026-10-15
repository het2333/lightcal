"""Tests for persistent meal image storage."""

import base64
import os
import sqlite3

import server


def test_configured_static_dir_honors_environment(tmp_path, monkeypatch):
    configured = tmp_path / "persistent static"
    monkeypatch.setenv("CAL_STATIC_DIR", str(configured))

    assert server._configured_static_dir() == os.path.abspath(configured)


def test_saved_upload_can_be_read_back(tmp_path, monkeypatch):
    static_dir = tmp_path / "static"
    monkeypatch.setattr(server, "static_dir", str(static_dir))
    image_bytes = b"persistent meal image"

    image_url = server._save_upload_image(base64.b64encode(image_bytes).decode(), "meal/test")

    assert image_url == "/static/uploads/meal_test.jpg"
    assert (static_dir / "uploads" / "meal_test.jpg").read_bytes() == image_bytes
    assert base64.b64decode(server._image_url_to_base64(image_url)) == image_bytes


def test_food_log_payload_hides_missing_local_image(tmp_path, monkeypatch):
    static_dir = tmp_path / "static"
    uploads_dir = static_dir / "uploads"
    uploads_dir.mkdir(parents=True)
    monkeypatch.setattr(server, "static_dir", str(static_dir))

    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.execute(
        "CREATE TABLE foods (calories REAL, image_url TEXT, leftover_image_url TEXT, original_nutrition_json TEXT, consumed_ratio REAL, leftover_calories REAL)"
    )
    connection.execute(
        "INSERT INTO foods VALUES (100, '/static/uploads/missing.jpg', '/static/uploads/missing-leftover.jpg', '', 1, 0)"
    )
    row = connection.execute("SELECT * FROM foods").fetchone()

    assert server._food_log_row_payload(row)["image_url"] == ""
    assert server._food_log_row_payload(row)["leftover_image_url"] == ""

    (uploads_dir / "existing.jpg").write_bytes(b"image")
    connection.execute("DELETE FROM foods")
    connection.execute(
        "INSERT INTO foods VALUES (100, '/static/uploads/existing.jpg', 'https://example.com/leftover.jpg', '', 1, 0)"
    )
    row = connection.execute("SELECT * FROM foods").fetchone()

    payload = server._food_log_row_payload(row)
    assert payload["image_url"] == "/static/uploads/existing.jpg"
    assert payload["leftover_image_url"] == "https://example.com/leftover.jpg"
