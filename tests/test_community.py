"""Tests for community meal sharing."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import server
import services.tracking_service as tracking_module
from models.food import Food
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


@pytest.fixture()
def isolated_social(tmp_path, monkeypatch):
    monkeypatch.setattr(tracking_module, "DB_PATH", tmp_path / "tracking.db")
    monkeypatch.setattr(server, "tracking", TrackingService())
    monkeypatch.setattr(server, "food_db", FoodDatabase(db_path=tmp_path / "foods.db"))


@pytest.mark.asyncio
async def test_share_meal_to_friends_and_discover_filters(isolated_social):
    day = "2026-05-29"
    group_id = "community_group"
    foods = [
        Food(name="鸡胸肉", calories=240, protein=42, carbs=0, fat=6, fiber=0, sugar=0, sodium=180),
        Food(name="米饭", calories=210, protein=4, carbs=46, fat=1, fiber=1, sugar=0, sodium=5),
    ]
    server._save_foods_to_log(foods, day, upload_group_id=group_id)

    created = await server.create_community_post_from_meal_endpoint(
        server.CommunityPostFromMealRequest(upload_group_id=group_id, visibility="friends", caption="食堂稳住")
    )
    post = created["post"]
    assert post["title"] == "鸡胸肉、米饭"
    assert post["visibility"] == "friends"
    assert post["calories"] == 450
    assert "高蛋白" in post["tags"]

    friends_feed = await server.get_community_feed_endpoint(tab="friends", user="me")
    assert [item["id"] for item in friends_feed["posts"]] == [post["id"]]

    discover_feed = await server.get_community_feed_endpoint(tab="discover", user="me")
    assert discover_feed["posts"] == []

    updated = await server.create_community_post_from_meal_endpoint(
        server.CommunityPostFromMealRequest(upload_group_id=group_id, visibility="public", caption="公开参考")
    )
    assert updated["post"]["id"] == post["id"]
    discover_feed = await server.get_community_feed_endpoint(tab="discover", user="me")
    assert [item["id"] for item in discover_feed["posts"]] == [post["id"]]


@pytest.mark.asyncio
async def test_daily_checkin_post_is_prioritized_in_friends_feed(isolated_social):
    day = "2026-05-29"
    group_id = "daily_checkin_group"
    foods = [Food(name="鸡胸肉沙拉", calories=420, protein=38, carbs=30, fat=14, fiber=8, sugar=5, sodium=520)]
    server._save_foods_to_log(foods, day, upload_group_id=group_id)
    server.tracking.add_hydration({"drink_type": "water", "amount_ml": 2000, "date": day})
    server.tracking.add_sleep({"date": day, "duration_hours": 7.2, "quality": 4})

    meal = await server.create_community_post_from_meal_endpoint(
        server.CommunityPostFromMealRequest(upload_group_id=group_id, visibility="friends")
    )
    checkin = await server.create_daily_checkin_post_endpoint(
        server.CommunityDailyCheckinRequest(date=day, visibility="friends", caption="今天稳住")
    )

    assert checkin["post"]["post_type"] == "daily_checkin"
    assert checkin["post"]["status_score"] > 0
    assert checkin["post"]["payload"]["dimensions"]
    assert checkin["post"]["checkin_date"] == day

    friends_feed = await server.get_community_feed_endpoint(tab="friends", user="me")
    assert friends_feed["posts"][0]["id"] == checkin["post"]["id"]
    assert meal["post"]["id"] in [item["id"] for item in friends_feed["posts"]]


@pytest.mark.asyncio
async def test_community_actions_and_log_same_meal(isolated_social):
    day = "2026-05-29"
    group_id = "community_actions_group"
    foods = [Food(name="番茄炒蛋", calories=260, protein=15, carbs=12, fat=16, fiber=2, sugar=5, sodium=420)]
    server._save_foods_to_log(foods, day, upload_group_id=group_id)
    created = await server.create_community_post_from_meal_endpoint(
        server.CommunityPostFromMealRequest(upload_group_id=group_id, visibility="public")
    )
    post_id = created["post"]["id"]

    liked = await server.react_community_post_endpoint(post_id, server.CommunityReactionRequest(user="me"))
    assert liked["post"]["reactions"]["like"] == 1
    assert liked["post"]["active_reactions"] == ["like"]

    commented = await server.comment_community_post_endpoint(
        post_id, server.CommunityCommentRequest(user="me", body="这个适合晚餐")
    )
    assert commented["post"]["comments_count"] == 1
    assert commented["post"]["recent_comments"][0]["body"] == "这个适合晚餐"

    bookmarked = await server.bookmark_community_post_endpoint(post_id, server.CommunityReactionRequest(user="me"))
    assert bookmarked["post"]["bookmarked"] is True
    assert bookmarked["post"]["bookmarks_count"] == 1

    copied = await server.log_same_community_meal_endpoint(
        post_id, server.CommunityLogSameMealRequest(user="me", date=day)
    )
    assert copied["saved"] == 1
    with server.food_db._get_conn() as conn:
        server._ensure_food_log_table(conn)
        count = conn.execute("SELECT COUNT(*) AS c FROM food_log_history WHERE date = ?", (day,)).fetchone()["c"]
    assert count == 2

    hidden = await server.report_community_post_endpoint(post_id, server.CommunityReportRequest(user="me"))
    assert hidden["hidden"] is True
    discover_feed = await server.get_community_feed_endpoint(tab="discover", user="me")
    assert discover_feed["posts"] == []
