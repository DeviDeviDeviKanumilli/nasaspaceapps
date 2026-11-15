"""Projection, plane fitting and measurements against analytic ground truth.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json

import numpy as np
import pytest

from fieldstation.adapters.synthetic import BOX_SIZE, SPHERE_R, TILT_DEG, SyntheticAdapter
from fieldstation.bundle import load_depth_png
from fieldstation.camera_model import Extrinsics, Intrinsics, deproject, deproject_image, project, stereo_rms_noise_m
from fieldstation.metrics import plane_fit, protrusion_analysis, roi_points_from_pixels, roughness_analysis, tilt_from_optical_axis_deg
from fieldstation.adapters.base import Calibration

rs = pytest.importorskip("pyrealsense2")


def test_matches_librealsense_projection():
    rng = np.random.default_rng(1)
    names = {"brown_conrady": rs.distortion.brown_conrady, "inverse_brown_conrady": rs.distortion.inverse_brown_conrady,
             "none": rs.distortion.none}
    for name, model in names.items():
        c = [0.04, -0.08, 0.001, -0.0015, 0.01]
        ri = rs.intrinsics()
        ri.width, ri.height, ri.fx, ri.fy, ri.ppx, ri.ppy, ri.model, ri.coeffs = 848, 480, 427.0, 428.0, 421.0, 238.5, model, c
        mine = Intrinsics(848, 480, 427.0, 428.0, 421.0, 238.5, name, c)
        u, v, z = rng.uniform(0, 848, 40), rng.uniform(0, 480, 40), rng.uniform(0.3, 4, 40)
        sdk = np.array([rs.rs2_deproject_pixel_to_point(ri, [a, b], d) for a, b, d in zip(u, v, z)])
        assert np.abs(deproject(mine, u, v, z) - sdk).max() < 1e-5
        P = sdk
        sdkp = np.array([rs.rs2_project_point_to_pixel(ri, list(p)) for p in P])
        assert np.abs(project(mine, P) - sdkp).max() < 0.01


def test_extrinsics_column_major_matches_sdk():
    ext = rs.extrinsics()
    ang = np.radians(3.0)
    R = np.array([[np.cos(ang), 0, np.sin(ang)], [0, 1, 0], [-np.sin(ang), 0, np.cos(ang)]])
    ext.rotation = list(R.T.ravel())          # SDK stores column-major
    ext.translation = [0.015, -0.0003, 0.0002]
    mine = Extrinsics.from_sdk_column_major(ext.rotation, ext.translation)
    p = [0.1, -0.2, 1.3]
    assert np.allclose(mine.apply(np.array([p]))[0], rs.rs2_transform_point_to_point(ext, p), atol=1e-6)


def test_synthetic_plane_projection_exact():
    """A perfect plane rendered into a depth image comes back as that plane, at the right distance and tilt."""
    intr = Intrinsics(640, 480, 380.0, 380.0, 319.5, 239.5)
    vv, uu = np.mgrid[0:480, 0:640]
    rays = deproject(intr, uu.ravel().astype(float), vv.ravel().astype(float), np.ones(uu.size))
    n = np.array([0.0, -np.sin(np.radians(25)), -np.cos(np.radians(25))])
    p0 = np.array([0.0, 0.0, 1.5])
    t = (p0 @ n) / (rays @ n)
    depth = (t * rays[:, 2]).reshape(480, 640)
    pts, _ = deproject_image(intr, depth)
    f = plane_fit(pts)
    assert f["rms_orthogonal_m"] < 1e-9
    assert abs(tilt_from_optical_axis_deg(f["normal"]) - 25.0) < 1e-6
    assert abs(abs(np.dot(np.asarray(f["centroid_m"]) - p0, n))) < 1e-9


def test_plane_fit_noise_and_robust():
    rng = np.random.default_rng(3)
    xy = rng.uniform(-0.2, 0.2, (4000, 2))
    pts = np.column_stack([xy, 1.0 + 0.0 * xy[:, 0]]) + rng.normal(0, 0.002, (4000, 3)) * [0, 0, 1]
    f = plane_fit(pts)
    assert 0.0018 < f["rms_orthogonal_m"] < 0.0022     # small, not arbitrarily zero
    pts[:40, 2] += 0.3                                  # 1 % gross outliers
    plain, rob = plane_fit(pts), plane_fit(pts, robust=True)
    assert plain["rms_orthogonal_m"] > 0.02
    assert rob["rms_orthogonal_m"] < 0.0025 and rob["n_rejected"] >= 40


def _calib_and_frames(n=10):
    a = SyntheticAdapter()
    a.open("synthetic:scene-v1", {"profile": "field_static"})
    return a, a.get_calibration(), [a.read_frame(100) for _ in range(n)]


def _px(calib, P):
    return project(calib.depth, np.asarray(P, float)[None, :])[0]


def test_board_roughness_is_at_noise_floor_and_tilt_is_right():
    a, calib, frames = _calib_and_frames(10)
    sc = a.scene
    c = sc.p0 + sc.a * 0.40     # flat board, right of the box
    u, v = _px(calib, c)
    rect = [u - 25, v - 25, u + 25, v + 25]
    from fieldstation.pointcloud import build_filtered_cloud
    stack = np.stack([f.depth for f in frames])
    filt = build_filtered_cloud(stack, calib.depth_scale_m, calib.depth, frames[0].color, calib.color, calib.depth_to_color)
    pts, _ = roi_points_from_pixels(filt["depth_filtered_m"], rect, calib.depth)
    res = roughness_analysis(pts, {"kind": "pixel_rect", "rect_px": rect},
                             noise_model={"fx_px": calib.depth.fx, "baseline_m": calib.stereo_baseline_m})
    ms = {m["name"]: m for m in res["measurements"]}
    assert abs(ms["plane_tilt_from_optical_axis"]["value"] - TILT_DEG) < 1.0
    # a flat board: residual is sensor noise (reduced by the 10-frame median), flagged as not resolving roughness
    assert res["status"] == "at_noise_floor"
    assert ms["plane_fit_roughness"]["value"] < stereo_rms_noise_m(c[2], calib.depth.fx, calib.stereo_baseline_m)
    assert ms["plane_tilt_from_horizontal"]["status"] == "not_measured"


def test_box_height_and_width_against_ground_truth():
    a, calib, frames = _calib_and_frames(10)
    sc = a.scene
    from fieldstation.pointcloud import build_filtered_cloud
    stack = np.stack([f.depth for f in frames])
    filt = build_filtered_cloud(stack, calib.depth_scale_m, calib.depth, frames[0].color, calib.color, calib.depth_to_color)
    dm = filt["depth_filtered_m"]
    top = sc.box_corners_top()
    uv = project(calib.depth, top)
    obj = [uv[:, 0].min() - 3, uv[:, 1].min() - 3, uv[:, 0].max() + 3, uv[:, 1].max() + 3]
    ref_c = _px(calib, sc.p0 + sc.a * 0.42)
    ref = [ref_c[0] - 30, ref_c[1] - 30, ref_c[0] + 30, ref_c[1] + 30]
    opts, _ = roi_points_from_pixels(dm, obj, calib.depth)
    rpts, _ = roi_points_from_pixels(dm, ref, calib.depth)
    res = protrusion_analysis(opts, rpts, {"kind": "pixel_rect", "rect_px": obj}, {"kind": "pixel_rect", "rect_px": ref})
    m = res["measurements"][0]
    assert m["name"] == "protrusion_above_plane"
    assert abs(m["value"] - BOX_SIZE[2]) < 0.01          # within 1 cm of the true 0.15 m
    assert abs(m["extra"]["footprint_major_m"] - BOX_SIZE[0]) < 0.03


def test_processed_bundle_point_cloud_scale(synthetic_scan, store):
    """Distance between two box-top corners measured from the saved filtered depth equals the box length."""
    d = store.dir_of(synthetic_scan)
    calib = Calibration.from_dict(json.loads((d / "calibration.json").read_text()))
    dm = load_depth_png(d / "depth_filtered.png").astype(float) * calib.depth_scale_m
    sc = SyntheticAdapter().scene
    L, W, H = BOX_SIZE
    top = sc.p0 + sc.n * H
    p1, p2 = top - sc.a * (L / 2 - 0.03), top + sc.a * (L / 2 - 0.03)   # 3 cm inside the edges
    out = []
    for P in (p1, p2):
        u, v = _px(calib, P)
        win = dm[int(round(v)) - 2:int(round(v)) + 3, int(round(u)) - 2:int(round(u)) + 3]
        out.append(deproject(calib.depth, np.array([u]), np.array([v]), np.array([np.median(win[win > 0])]))[0])
    assert abs(np.linalg.norm(out[1] - out[0]) - (L - 0.06)) < 0.01
