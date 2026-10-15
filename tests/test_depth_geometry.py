import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import numpy as np

from services.depth_geometry import (
    back_project,
    estimate_volume_grid,
    fit_plane_ransac,
    scale_intrinsics,
)


def test_metric3d_predicted_depth_is_marked_as_depth_source(monkeypatch):
    import scripts.cloud_depth_pipeline_server as pipeline

    monkeypatch.setattr(pipeline, "METRIC3D_ENABLED", True)
    monkeypatch.setattr(
        pipeline,
        "predict_metric3d_depth",
        lambda image, metadata: (
            np.full((12, 12), 0.52, dtype=np.float32),
            np.full((12, 12), 128, dtype=np.uint8),
            {**metadata, "depth_source": "metric3d_predicted_depth"},
        ),
    )

    image = pipeline.Image.new("RGB", (12, 12), "white")
    depth, confidence, metadata, source = pipeline.depth_or_metric3d(image, None, None, {})

    assert source == "metric3d_predicted_depth"
    assert metadata["depth_source"] == "metric3d_predicted_depth"
    assert depth.shape == (12, 12)
    assert confidence.shape == (12, 12)


def test_metric3d_depth_volume_accepts_depth_above_lidar_near_range():
    import scripts.cloud_depth_pipeline_server as pipeline

    image = pipeline.Image.new("RGB", (64, 64), "white")
    mask = np.zeros((64, 64), dtype=bool)
    mask[20:44, 20:44] = True
    depth = np.full((64, 64), 2.0, dtype=np.float32)
    depth[mask] = 1.92
    confidence = np.full((64, 64), 192, dtype=np.uint8)
    metadata = {
        "depth_source": "metric3d_predicted_depth",
        "camera": {
            "intrinsics": [[80.0, 0.0, 32.0], [0.0, 80.0, 32.0], [0.0, 0.0, 1.0]],
            "intrinsics_reference_dimensions": {"width": 64, "height": 64},
        },
    }

    volume_ml, quality, method, fallback, reason = pipeline.estimate_volume_from_depth_mask(
        mask,
        [20, 20, 44, 44],
        depth,
        confidence,
        metadata,
        image,
        {"category": "staple", "name_zh": "面条"},
    )

    assert fallback is False
    assert reason == ""
    assert method == "depth_mask_local_baseline_integration"
    assert volume_ml > 0
    assert quality["valid_depth_ratio"] == 1.0


def test_scale_intrinsics():
    K = np.array([[1000, 0, 500], [0, 1000, 400], [0, 0, 1]], dtype=np.float32)
    K2 = scale_intrinsics(K, from_size=(1000, 800), to_size=(250, 200))
    assert K2[0, 0] == 250
    assert K2[1, 1] == 250
    assert K2[0, 2] == 125
    assert K2[1, 2] == 100


def test_back_project_center_pixel():
    depth = np.ones((3, 3), dtype=np.float32)
    valid = np.zeros((3, 3), dtype=bool)
    valid[1, 1] = True
    K = np.array([[100, 0, 1], [0, 100, 1], [0, 0, 1]], dtype=np.float32)
    points, pixels = back_project(depth, K, valid)
    assert np.allclose(points[0], [0, 0, 1])
    assert np.array_equal(pixels[0], [1, 1])


def test_fit_plane_ransac_horizontal_plane():
    xs, ys = np.meshgrid(np.linspace(-0.1, 0.1, 20), np.linspace(-0.1, 0.1, 20))
    points = np.stack([xs.ravel(), ys.ravel(), np.zeros(xs.size)], axis=1).astype(np.float32)
    (n, d), inliers = fit_plane_ransac(points)
    assert abs(abs(n[2]) - 1.0) < 1e-5
    assert abs(d) < 1e-5
    assert inliers.mean() > 0.95


def test_estimate_volume_grid_box_100ml():
    width_m = 0.10
    length_m = 0.10
    height_m = 0.01
    xs, ys = np.meshgrid(np.linspace(0, width_m, 45), np.linspace(0, length_m, 45))
    heights = np.full(xs.size, height_m, dtype=np.float32)
    food_points = np.stack([xs.ravel(), ys.ravel(), heights], axis=1).astype(np.float32)
    volume_ml = estimate_volume_grid(
        food_points=food_points,
        heights_m=heights,
        plane_n=np.array([0, 0, 1], dtype=np.float32),
        plane_d=0.0,
        grid_size_m=0.003,
    )
    assert abs(volume_ml - 100.0) / 100.0 < 0.15
