"""Depth geometry helpers for RGB + depth meal volume estimation."""

from __future__ import annotations

import numpy as np


def scale_intrinsics(K: np.ndarray, from_size: tuple[int, int], to_size: tuple[int, int]) -> np.ndarray:
    """Scale an RGB camera intrinsic matrix to another image resolution."""
    from_w, from_h = from_size
    to_w, to_h = to_size
    sx = to_w / from_w
    sy = to_h / from_h

    K2 = np.array(K, dtype=np.float32).copy()
    K2[0, 0] *= sx
    K2[1, 1] *= sy
    K2[0, 2] *= sx
    K2[1, 2] *= sy
    return K2


def back_project(depth_m: np.ndarray, K: np.ndarray, valid_mask: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Back-project valid depth pixels to camera-space 3D points."""
    fx = float(K[0, 0])
    fy = float(K[1, 1])
    cx = float(K[0, 2])
    cy = float(K[1, 2])

    ys, xs = np.where(valid_mask)
    z = depth_m[ys, xs].astype(np.float32)
    x = (xs.astype(np.float32) - cx) * z / fx
    y = (ys.astype(np.float32) - cy) * z / fy

    points = np.stack([x, y, z], axis=1)
    pixels = np.stack([xs, ys], axis=1)
    return points, pixels


def fit_plane_ransac(
    points: np.ndarray,
    iterations: int = 256,
    threshold_m: float = 0.008,
    rng: np.random.Generator | None = None,
) -> tuple[tuple[np.ndarray, float], np.ndarray]:
    """Fit a plane to 3D base-surface points using RANSAC."""
    if points.shape[0] < 3:
        raise ValueError("Not enough points to fit plane")

    rng = rng or np.random.default_rng(12345)
    best_plane: tuple[np.ndarray, float] | None = None
    best_inliers: np.ndarray | None = None

    for _ in range(iterations):
        idx = rng.choice(points.shape[0], 3, replace=False)
        p1, p2, p3 = points[idx]

        n = np.cross(p2 - p1, p3 - p1)
        norm = np.linalg.norm(n)
        if norm < 1e-6:
            continue

        n = n / norm
        d = -float(np.dot(n, p1))
        distances = np.abs(points @ n + d)
        inliers = distances < threshold_m

        if best_inliers is None or int(inliers.sum()) > int(best_inliers.sum()):
            best_inliers = inliers
            best_plane = (n.astype(np.float32), d)

    if best_plane is None or best_inliers is None:
        raise ValueError("Cannot fit plane")

    return best_plane, best_inliers


def orient_plane_normal(
    n: np.ndarray,
    d: float,
    food_points: np.ndarray,
    base_points: np.ndarray,
) -> tuple[np.ndarray, float]:
    """Orient the base plane normal so food heights are positive."""
    food_mean = food_points.mean(axis=0)
    base_mean = base_points.mean(axis=0)
    food_side = float(np.dot(n, food_mean) + d)
    base_side = float(np.dot(n, base_mean) + d)

    if food_side < base_side:
        return -n, -d
    return n, d


def compute_heights(food_points: np.ndarray, n: np.ndarray, d: float, max_height_m: float = 0.15) -> np.ndarray:
    """Compute clipped item heights above the fitted base plane."""
    heights = food_points @ n + d
    return np.clip(heights, 0.0, max_height_m)


def build_plane_basis(n: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Build two orthonormal axes on a plane with normal n."""
    n = n / np.linalg.norm(n)
    ref = np.array([1.0, 0.0, 0.0], dtype=np.float32)
    if abs(float(np.dot(ref, n))) > 0.9:
        ref = np.array([0.0, 1.0, 0.0], dtype=np.float32)

    e1 = np.cross(n, ref)
    e1 = e1 / np.linalg.norm(e1)
    e2 = np.cross(n, e1)
    e2 = e2 / np.linalg.norm(e2)
    return e1.astype(np.float32), e2.astype(np.float32)


def estimate_volume_grid(
    food_points: np.ndarray,
    heights_m: np.ndarray,
    plane_n: np.ndarray,
    plane_d: float,
    grid_size_m: float = 0.003,
) -> float:
    """Integrate food height over a base-plane grid and return volume in ml."""
    if food_points.size == 0 or heights_m.size == 0:
        return 0.0

    e1, e2 = build_plane_basis(plane_n)
    distances = food_points @ plane_n + plane_d
    feet = food_points - distances[:, None] * plane_n[None, :]

    u = feet @ e1
    v = feet @ e2
    u_min = float(u.min())
    v_min = float(v.min())

    ui = np.floor((u - u_min) / grid_size_m).astype(np.int32)
    vi = np.floor((v - v_min) / grid_size_m).astype(np.int32)

    cells: dict[tuple[int, int], list[float]] = {}
    for a, b, h in zip(ui, vi, heights_m):
        if h <= 0.002:
            continue
        cells.setdefault((int(a), int(b)), []).append(float(h))

    cell_area = grid_size_m * grid_size_m
    volume_m3 = 0.0
    for values in cells.values():
        volume_m3 += cell_area * float(np.percentile(values, 75))

    return volume_m3 * 1_000_000.0


def compute_depth_quality(
    mask: np.ndarray,
    depth_m: np.ndarray,
    confidence: np.ndarray,
    base_inlier_ratio: float,
    volume_ml: float,
) -> dict:
    """Score how trustworthy a depth volume estimate is."""
    valid = mask & (depth_m > 0) & (confidence >= 128)
    valid_depth_ratio = float(valid.sum() / max(mask.sum(), 1))
    mean_confidence = float(confidence[valid].mean() / 255.0) if valid.sum() else 0.0
    score = 0.45 * valid_depth_ratio + 0.35 * mean_confidence + 0.20 * base_inlier_ratio
    return {
        "valid_depth_ratio": round(valid_depth_ratio, 4),
        "mean_confidence": round(mean_confidence, 4),
        "base_plane_inlier_ratio": round(float(base_inlier_ratio), 4),
        "volume_confidence": round(float(min(max(score, 0.0), 1.0)), 4),
        "volume_ml": round(float(volume_ml), 1),
    }


def should_fallback_from_quality(quality: dict, volume_ml: float) -> bool:
    """Return true when depth quality is too low for volume-based grams."""
    return (
        volume_ml <= 0
        or quality.get("valid_depth_ratio", 0) < 0.35
        or quality.get("mean_confidence", 0) < 0.45
        or quality.get("base_plane_inlier_ratio", 0) < 0.35
        or quality.get("volume_confidence", 0) < 0.45
    )
