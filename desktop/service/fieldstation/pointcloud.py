"""Depth frames -> metric point clouds.

Raw cloud: one recorded depth frame, every pixel with depth > 0 back-projected
with the calibrated depth intrinsics. Nothing else removed. Colour attached by
projecting into the colour camera with the recorded depth->colour extrinsics.

Filtered cloud: derived from ALL recorded frames of a stationary capture:
per-pixel temporal median, range clip, flying-pixel (edge halo) removal,
optional voxel downsample and optional statistical outlier removal. Every
parameter is returned so it can be written into the bundle.

Neither cloud contains surfaces the sensor did not see; no hole filling.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import numpy as np
from scipy.spatial import cKDTree

from .camera_model import Extrinsics, Intrinsics, deproject_image, project

FILTER_DEFAULTS = {
    "temporal_median_min_valid_fraction": 0.5,
    "range_min_m": 0.2,
    "range_max_m": 6.0,
    "flying_pixel_rel_jump": 0.03,
    "flying_pixel_abs_m": 0.01,
    "voxel_m": 0.0,
    "outlier_k": 0,
    "outlier_std_ratio": 2.0,
    "color_occlusion_tol_rel": 0.02,
    "color_occlusion_tol_abs_m": 0.01,
}


def temporal_median(depth_stack_raw: np.ndarray, depth_scale_m: float, min_valid_fraction: float):
    """depth_stack_raw: N x H x W integer sensor units, 0 = invalid.
    Returns (median_m HxW with 0 where unsupported, valid_count HxW, temporal_std_m HxW (nan where <2 samples))."""
    st = depth_stack_raw.astype(np.float64)
    st[st <= 0] = np.nan
    cnt = np.sum(np.isfinite(st), axis=0)
    need = max(1, int(np.ceil(min_valid_fraction * st.shape[0])))
    with np.errstate(all="ignore"):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            med = np.nanmedian(st, axis=0) * depth_scale_m
            sd = np.nanstd(st, axis=0) * depth_scale_m
    med = np.where(cnt >= need, med, 0.0)
    sd = np.where(cnt >= 2, sd, np.nan)
    return np.nan_to_num(med, nan=0.0), cnt, sd


def flying_pixel_mask(depth_m: np.ndarray, rel_jump: float, abs_m: float) -> np.ndarray:
    """True where a valid pixel has a 4-neighbour whose depth differs by more than max(abs_m, rel_jump*z).
    Such pixels sit on depth discontinuities where stereo matching mixes foreground and background."""
    z = depth_m
    valid = z > 0
    bad = np.zeros_like(valid)
    for dv, du in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        nb = np.roll(z, (dv, du), axis=(0, 1))
        nbv = np.roll(valid, (dv, du), axis=(0, 1))
        # do not wrap around the image border
        if dv == 1:
            nbv[0, :] = False
        if dv == -1:
            nbv[-1, :] = False
        if du == 1:
            nbv[:, 0] = False
        if du == -1:
            nbv[:, -1] = False
        thr = np.maximum(abs_m, rel_jump * z)
        bad |= valid & nbv & (np.abs(z - nb) > thr)
    return bad


def register_color(points: np.ndarray, color_intr: Intrinsics, depth_to_color: Extrinsics, color_img: np.ndarray,
                   tol_rel: float, tol_abs: float):
    """Nearest-pixel colour lookup with a simple z-buffer occlusion test in the colour camera.
    Returns (rgb Nx3 uint8, color_valid N bool). Points outside the colour image or hidden from the
    colour camera get grey (128) and color_valid=False."""
    n = len(points)
    rgb = np.full((n, 3), 128, np.uint8)
    ok = np.zeros(n, bool)
    if n == 0 or color_img is None:
        return rgb, ok
    pc = depth_to_color.apply(points)
    pix = project(color_intr, pc)
    u = np.round(np.nan_to_num(pix[:, 0], nan=-1.0, posinf=-1.0, neginf=-1.0)).astype(np.int64)
    v = np.round(np.nan_to_num(pix[:, 1], nan=-1.0, posinf=-1.0, neginf=-1.0)).astype(np.int64)
    h, w = color_img.shape[:2]
    inside = (u >= 0) & (u < w) & (v >= 0) & (v < h) & (pc[:, 2] > 0)
    idx = np.where(inside)[0]
    if len(idx):
        lin = v[idx] * w + u[idx]
        zc = pc[idx, 2]
        zmin = np.full(h * w, np.inf)
        np.minimum.at(zmin, lin, zc)
        visible = zc <= zmin[lin] + np.maximum(tol_abs, tol_rel * zmin[lin])
        sel = idx[visible]
        rgb[sel] = color_img[v[sel], u[sel], :3]
        ok[sel] = True
    return rgb, ok


def voxel_downsample(points: np.ndarray, rgb: np.ndarray, voxel_m: float, *extra: np.ndarray):
    """Deterministic: points sharing a voxel are replaced by their centroid (colour mean, extras max)."""
    if voxel_m <= 0 or len(points) == 0:
        return (points, rgb, *extra)
    keys = np.floor(points / voxel_m).astype(np.int64)
    _, inv, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    inv = inv.ravel()
    m = len(counts)
    out_p = np.zeros((m, 3))
    np.add.at(out_p, inv, points)
    out_p /= counts[:, None]
    out_c = np.zeros((m, 3))
    np.add.at(out_c, inv, rgb.astype(np.float64))
    out_c = np.round(out_c / counts[:, None]).astype(np.uint8)
    outs = []
    for e in extra:
        o = np.zeros(m, dtype=e.dtype)
        np.maximum.at(o, inv, e)
        outs.append(o)
    return (out_p, out_c, *outs)


def statistical_outliers(points: np.ndarray, k: int, std_ratio: float) -> np.ndarray:
    """True for points whose mean distance to k neighbours exceeds mean + std_ratio*std of that statistic."""
    if k <= 0 or len(points) <= k:
        return np.zeros(len(points), bool)
    d, _ = cKDTree(points).query(points, k=k + 1)
    md = d[:, 1:].mean(axis=1)
    return md > md.mean() + std_ratio * md.std()


def build_raw_cloud(depth_raw: np.ndarray, depth_scale_m: float, depth_intr: Intrinsics,
                    color_img: np.ndarray | None, color_intr: Intrinsics | None, d2c: Extrinsics | None,
                    params: dict | None = None) -> dict:
    p = {**FILTER_DEFAULTS, **(params or {})}
    z = depth_raw.astype(np.float64) * depth_scale_m
    pts, pix = deproject_image(depth_intr, z)
    if color_img is not None and color_intr is not None and d2c is not None:
        rgb, cok = register_color(pts, color_intr, d2c, color_img, p["color_occlusion_tol_rel"], p["color_occlusion_tol_abs_m"])
    else:
        rgb, cok = np.full((len(pts), 3), 128, np.uint8), np.zeros(len(pts), bool)
    return {"points": pts, "rgb": rgb, "color_valid": cok, "pixels": pix,
            "stats": {"pixels_total": int(z.size), "points": int(len(pts)), "valid_fraction": float(len(pts) / z.size)}}


def build_filtered_cloud(depth_stack_raw: np.ndarray, depth_scale_m: float, depth_intr: Intrinsics,
                         color_img: np.ndarray | None, color_intr: Intrinsics | None, d2c: Extrinsics | None,
                         params: dict | None = None) -> dict:
    p = {**FILTER_DEFAULTS, **(params or {})}
    n = depth_stack_raw.shape[0]
    med, cnt, tsd = temporal_median(depth_stack_raw, depth_scale_m, p["temporal_median_min_valid_fraction"])
    after_temporal = int((med > 0).sum())
    in_range = (med >= p["range_min_m"]) & (med <= p["range_max_m"])
    med = np.where(in_range, med, 0.0)
    after_range = int((med > 0).sum())
    fly = flying_pixel_mask(med, p["flying_pixel_rel_jump"], p["flying_pixel_abs_m"])
    med = np.where(fly, 0.0, med)
    after_flying = int((med > 0).sum())
    pts, pix = deproject_image(depth_intr, med)
    nvalid = cnt[pix[:, 0], pix[:, 1]].astype(np.uint8) if len(pix) else np.zeros(0, np.uint8)
    if color_img is not None and color_intr is not None and d2c is not None:
        rgb, cok = register_color(pts, color_intr, d2c, color_img, p["color_occlusion_tol_rel"], p["color_occlusion_tol_abs_m"])
    else:
        rgb, cok = np.full((len(pts), 3), 128, np.uint8), np.zeros(len(pts), bool)
    out_mask = statistical_outliers(pts, int(p["outlier_k"]), float(p["outlier_std_ratio"]))
    pts, rgb, cok, nvalid = pts[~out_mask], rgb[~out_mask], cok[~out_mask], nvalid[~out_mask]
    after_outlier = int(len(pts))
    pts, rgb, cok_u8, nvalid = voxel_downsample(pts, rgb, float(p["voxel_m"]), cok.astype(np.uint8), nvalid)
    return {
        "points": pts, "rgb": rgb, "color_valid": np.asarray(cok_u8).astype(bool), "n_valid_frames": nvalid,
        "depth_filtered_m": med, "temporal_std_m": tsd, "valid_count": cnt,
        "params": p,
        "operations": [
            {"op": "temporal_median", "frames": n, "min_valid_fraction": p["temporal_median_min_valid_fraction"], "pixels_after": after_temporal},
            {"op": "range_clip", "min_m": p["range_min_m"], "max_m": p["range_max_m"], "pixels_after": after_range},
            {"op": "flying_pixel_removal", "rel_jump": p["flying_pixel_rel_jump"], "abs_m": p["flying_pixel_abs_m"], "pixels_after": after_flying},
            {"op": "statistical_outlier_removal", "enabled": int(p["outlier_k"]) > 0, "k": p["outlier_k"], "std_ratio": p["outlier_std_ratio"], "points_after": after_outlier},
            {"op": "voxel_downsample", "enabled": float(p["voxel_m"]) > 0, "voxel_m": p["voxel_m"], "points_after": int(len(pts))},
            {"op": "color_registration", "method": "project into colour camera with recorded depth->colour extrinsics; nearest pixel; z-buffer occlusion test",
             "points_with_color": int(np.asarray(cok_u8).sum())},
        ],
    }
