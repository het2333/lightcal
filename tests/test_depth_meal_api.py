import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest
from fastapi.testclient import TestClient

import server
from services.depth_meal_service import DepthMealService


@pytest.fixture()
def isolated_depth_service(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "depth_meal_service", DepthMealService(tmp_path / "depth_meal.db"))

    class DefaultFakeCloudPipeline:
        enabled = True

        def analyze_capture(self, capture, payload):
            return {
                "items": [
                    {
                        "name_zh": "盒饭",
                        "name_en": "boxed meal",
                        "food_key": "mixed_dish_generic",
                        "category": "mixed_dish",
                        "cooking_method": "mixed",
                        "mixed_dish": True,
                        "liquid": False,
                        "volume_ml": 320.0,
                        "volume_method": "depth_plane_grid_integration",
                        "depth_quality": {"volume_confidence": 0.8},
                        "fallback": False,
                        "detector": "grounding_dino_open_source",
                        "detector_phrase": "boxed meal",
                        "detector_score": 0.8,
                        "bbox": [20, 20, 320, 320],
                        "segmentation_model": "sam2",
                    }
                ]
            }

    server.depth_meal_service.cloud_pipeline = DefaultFakeCloudPipeline()


def test_depth_capture_analyze_patch_confirm(isolated_depth_service):
    client = TestClient(server.app)

    created = client.post(
        "/v1/meal-captures",
        json={"platform": "ios", "device_model": "iPhone 15 Pro", "depth_source": "ios_lidar_scene_depth", "meal_type": "lunch"},
    )
    assert created.status_code == 200
    capture_id = created.json()["capture_id"]
    uploaded = client.put(
        f"/v1/meal-captures/{capture_id}/files/rgb",
        content=b"test-rgb-payload",
        headers={"Content-Type": "image/jpeg"},
    )
    assert uploaded.status_code == 200

    queued = client.post(f"/v1/meal-captures/{capture_id}/analyze", json={"user_hint": "盒饭"})
    assert queued.status_code == 200
    job_id = queued.json()["job_id"]

    job = client.get(f"/v1/meal-analysis-jobs/{job_id}")
    assert job.status_code == 200
    body = job.json()
    assert body["status"] == "completed"
    assert body["result"]["estimation_mode"] == "rgb_depth_grounded_sam2_volume"
    assert body["result"]["items"][0]["volume"]["estimated_volume_ml"] > 0

    meal_id = body["meal_id"]
    item_id = body["result"]["items"][0]["item_id"]
    patched = client.patch(f"/v1/meals/{meal_id}/items/{item_id}", json={"estimated_grams": 220, "eaten_ratio": 0.75})
    assert patched.status_code == 200
    assert patched.json()["items"][0]["weight"]["estimated_grams"] == 220

    confirmed = client.post(f"/v1/meals/{meal_id}/confirm", json={"confirmed": True})
    assert confirmed.status_code == 200
    assert confirmed.json()["confirmed"] is True
    assert confirmed.json()["daily_intake"]["calories"] > 0

    repatched = client.patch(f"/v1/meals/{meal_id}/items/{item_id}", json={"estimated_grams": 100, "eaten_ratio": 1.0})
    assert repatched.status_code == 200
    refreshed = client.post(f"/v1/meals/{meal_id}/confirm", json={"confirmed": True})
    assert refreshed.status_code == 200
    assert refreshed.json()["daily_intake"]["calories"] == pytest.approx(repatched.json()["total"]["calories"])


def test_depth_pipeline_preserves_sam2_and_semantic_evidence(isolated_depth_service):
    class FakeCloudPipeline:
        enabled = True

        def analyze_capture(self, capture, payload):
            return {
                "items": [
                    {
                        "name_zh": "紫米饭",
                        "name_en": "purple rice",
                        "food_key": "rice_cooked",
                        "category": "staple",
                        "cooking_method": "steamed",
                        "mixed_dish": False,
                        "liquid": False,
                        "volume_ml": 210.0,
                        "volume_method": "depth_plane_grid_integration",
                        "depth_quality": {
                            "volume_confidence": 0.81,
                            "valid_depth_ratio": 0.76,
                            "base_plane_inlier_ratio": 0.7,
                            "mean_confidence": 0.8,
                        },
                        "fallback": False,
                        "detector": "grounding_dino_open_source",
                        "detector_phrase": "purple rice",
                        "detector_score": 0.74,
                        "bbox": [10, 20, 120, 180],
                        "segmentation_model": "sam2",
                        "mask_url": "/tmp/masks/rice.png",
                        "mask_preview_base64": "iVBORw0KGgo=",
                        "mask_area_pixels": 12345,
                        "mask_confidence": 0.93,
                        "semantic_validation": {
                            "is_food": True,
                            "semantic_label": "staple",
                            "semantic_confidence": 0.88,
                            "needs_split": False,
                            "notes": ["ok"],
                        },
                    }
                ]
            }

    server.depth_meal_service.cloud_pipeline = FakeCloudPipeline()
    client = TestClient(server.app)

    created = client.post(
        "/v1/meal-captures",
        json={"platform": "ios", "device_model": "iPhone 15 Pro", "depth_source": "ios_lidar_scene_depth", "meal_type": "lunch"},
    )
    capture_id = created.json()["capture_id"]
    queued = client.post(f"/v1/meal-captures/{capture_id}/analyze", json={"user_hint": "紫米饭"})
    job_id = queued.json()["job_id"]

    job = client.get(f"/v1/meal-analysis-jobs/{job_id}")
    assert job.status_code == 200
    item = job.json()["result"]["items"][0]
    assert item["segmentation"]["model"] == "sam2"
    assert item["segmentation"]["mask_preview_base64"] == "iVBORw0KGgo="
    assert item["segmentation"]["area_pixels"] == 12345
    assert item["segmentation"]["mask_confidence"] == pytest.approx(0.93)
    assert item["semantic_validation"]["is_food"] is True
    assert item["semantic_validation"]["semantic_confidence"] == pytest.approx(0.88)
    assert item["volume"]["depth_quality"]["valid_depth_ratio"] == pytest.approx(0.76)


def test_depth_pipeline_filters_tiny_fragment_items(isolated_depth_service):
    class FakeCloudPipeline:
        enabled = True

        def analyze_capture(self, capture, payload):
            return {
                "items": [
                    {
                        "name_zh": "蔬菜碎片",
                        "name_en": "small leafy fragment",
                        "food_key": "stir_fried_vegetables",
                        "category": "vegetable",
                        "cooking_method": "unknown",
                        "mixed_dish": False,
                        "liquid": False,
                        "volume_ml": 1.2,
                        "volume_method": "depth_pointcloud_local_surface_integration",
                        "depth_quality": {"volume_confidence": 0.62},
                        "fallback": True,
                        "fallback_reason": "base_plane_unstable_used_local_surface",
                        "detector": "grounding_dino_open_source",
                        "detector_phrase": "leafy fragment",
                        "detector_score": 0.31,
                        "bbox": [453, 433, 942, 683],
                        "segmentation_model": "sam2",
                        "mask_area_pixels": 8688,
                        "mask_confidence": 0.73,
                    },
                    {
                        "name_zh": "辣味炒饭",
                        "name_en": "spicy fried rice",
                        "food_key": "rice_fried",
                        "category": "mixed_dish",
                        "cooking_method": "stir_fried",
                        "mixed_dish": True,
                        "liquid": False,
                        "volume_ml": 48.9,
                        "volume_method": "depth_pointcloud_local_surface_integration",
                        "depth_quality": {"volume_confidence": 0.72},
                        "fallback": True,
                        "fallback_reason": "base_plane_unstable_used_local_surface",
                        "detector": "grounding_dino_open_source",
                        "detector_phrase": "spicy fried rice",
                        "detector_score": 0.45,
                        "bbox": [307, 528, 936, 896],
                        "segmentation_model": "sam2",
                        "mask_area_pixels": 114911,
                        "mask_confidence": 0.91,
                    },
                ]
            }

    server.depth_meal_service.cloud_pipeline = FakeCloudPipeline()
    client = TestClient(server.app)

    created = client.post(
        "/v1/meal-captures",
        json={"platform": "ios", "device_model": "iPhone 16 Pro", "depth_source": "ios_lidar_scene_depth", "meal_type": "lunch"},
    )
    capture_id = created.json()["capture_id"]
    queued = client.post(f"/v1/meal-captures/{capture_id}/analyze", json={"user_hint": "剩余炒饭"})
    job = client.get(f"/v1/meal-analysis-jobs/{queued.json()['job_id']}")

    items = job.json()["result"]["items"]
    assert [item["name_zh"] for item in items] == ["辣味炒饭"]
    assert items[0]["volume"]["estimated_volume_ml"] == pytest.approx(48.9)
