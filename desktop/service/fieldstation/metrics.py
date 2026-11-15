"""Local geometric measurements from metric point clouds.

Every function returns plain dicts with explicit units, method, and
limitations. Nothing here says anything about rock type, mineralogy or
planetary analog suitability.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import numpy as np

from . import PIPELINE_VERSION
from .camera_model import stereo_rms_noise_m

MIN_POINTS = 50


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _r(x, nd=6):
    return None if x is None or not np.isfinite(x) else round(float(x), nd)


def plane_fit(points: np.ndarray, robust: bool = False, max_iter: int = 5, k_mad: float = 3.0) -> dict:
    """Total-least-squares plane (SVD). Residual = signed orthogonal distance to the plane.

    robust=True repeatedly drops points with |r - median| > k_mad * 1.4826 * MAD and refits; the number
    dropped is reported. Never applied unless requested.
    """
    pts = np.asarray(points, np.float64)
    keep = np.ones(len(pts), bool)
    if len(pts) < 3:
        raise ValueError("need at least 3 points for a plane fit")
    for it in range(max_iter if robust else 1):
        sub = pts[keep]
        c = sub.mean(axis=0)
        _, s, vt = np.linalg.svd(sub - c, full_matrices=False)
        nrm = vt[2]
        r_all = (pts - c) @ nrm
        if not robust:
            break
        r = r_all[keep]
        med = np.median(r)
        mad = 1.4826 * np.median(np.abs(r - med))
        new_keep = keep & (np.abs(r_all - med) <= max(k_mad * mad, 1e-12))
        if new_keep.sum() < 3 or np.array_equal(new_keep, keep):
            break
        keep = new_keep
    # orient the normal toward the camera origin (so "above the plane" means toward the sensor)
    if np.dot(nrm, -c) < 0:
        nrm = -nrm
    r_all = (pts - c) @ nrm
    r = r_all[keep]
    in_plane = (pts[keep] - c) @ vt[:2].T
    return {
        "centroid_m": c.tolist(), "normal": nrm.tolist(), "axes_in_plane": vt[:2].tolist(),
        "n_points": int(len(pts)), "n_used": int(keep.sum()), "n_rejected": int((~keep).sum()),
        "rms_orthogonal_m": float(np.sqrt(np.mean(r ** 2))),
        "residual_p05_m": float(np.percentile(r, 5)), "residual_p95_m": float(np.percentile(r, 95)),
        "residual_max_abs_m": float(np.max(np.abs(r))),
        "extent_major_m": float(np.ptp(in_plane[:, 0])), "extent_minor_m": float(np.ptp(in_plane[:, 1])),
        "residuals": r_all, "keep": keep,
    }


def tilt_from_optical_axis_deg(normal) -> float:
    n = np.asarray(normal, np.float64)
    return float(np.degrees(np.arccos(min(1.0, abs(n[2]) / np.linalg.norm(n)))))


def roi_points_from_pixels(depth_m: np.ndarray, rect, intr) -> tuple[np.ndarray, np.ndarray]:
    """rect = [u0, v0, u1, v1] in depth-image pixels (inclusive-exclusive). Returns (Nx3 points, Nx2 [v,u])."""
    from .camera_model import deproject
    u0, v0, u1, v1 = [int(round(x)) for x in rect]
    h, w = depth_m.shape
    u0, u1 = max(0, min(u0, u1)), min(w, max(u0, u1))
    v0, v1 = max(0, min(v0, v1)), min(h, max(v0, v1))
    sub = depth_m[v0:v1, u0:u1]
    vv, uu = np.nonzero(sub > 0)
    vv, uu = vv + v0, uu + u0
    return deproject(intr, uu.astype(float), vv.astype(float), depth_m[vv, uu]), np.stack([vv, uu], -1)


def roi_points_sphere(points: np.ndarray, center, radius_m: float) -> np.ndarray:
    d = np.linalg.norm(points - np.asarray(center, np.float64), axis=1)
    return points[d <= radius_m]


def roi_record(roi: dict | None, n_points: int | None = None) -> dict | None:
    if not roi:
        return None
    out = {"kind": roi.get("kind")}
    for k_in, k_out in (("center_m", "center"), ("center", "center"), ("radius_m", "radius_m"), ("rect_px", "rect_px"), ("points", "points")):
        if k_in in roi:
            out[k_out] = roi[k_in]
    if n_points is not None:
        out["n_points"] = int(n_points)
    return out


def measurement(name: str, value, unit: str, method: str, roi: dict | None, *, label: str = "", status: str = "measured",
                uncertainty: dict | None = None, validity: list[str] | None = None, source_artifact: str | None = None,
                frame: str = "camera_optical_m", n_points: int | None = None, extra: dict | None = None) -> dict:
    """Measurement record, field names per contracts/SCAN_BUNDLE_V1.md (measurements[])."""
    return {
        "id": str(uuid.uuid4()), "label": label or (roi or {}).get("label", ""), "name": name,
        "value": value, "unit": unit, "status": status, "method": method,
        "source_artifact": source_artifact, "frame": frame, "roi": roi_record(roi, n_points),
        "extra": extra or {},
        "uncertainty": uncertainty or {"method": "none from a single scan; compare repeat scans with the same label", "n": 1},
        "validity": validity or [], "created_utc": utc_now(), "pipeline_version": PIPELINE_VERSION,
    }


def roughness_analysis(points: np.ndarray, roi: dict, *, robust: bool = False, per_frame_rms: list[float] | None = None,
                       noise_model: dict | None = None, source_artifact: str = "", frame: str = "camera_optical_m",
                       gravity_up: list[float] | None = None, label: str = "") -> dict:
    """Plane-fit residual roughness, plane orientation, and visible-patch extents.

    gravity_up: unit vector of measured "up" in the points' frame (e.g. [0,1,0] for arkit_session_world).
    Without it, plane orientation is reported relative to the camera optical axis only.
    """
    if len(points) < MIN_POINTS:
        return {"status": "not_measured", "reason": f"only {len(points)} valid points in the region (need {MIN_POINTS})",
                "measurements": []}
    fit = plane_fit(points, robust=robust)
    n = len(points)
    validity = [
        "partial view: only surfaces visible to the sensor are measured",
        "roughness depends on the region size (baseline_m); compare only at similar baselines",
        "not comparable with 400-3200 m planetary/DEM roughness descriptors",
    ]
    unc = {"method": "none from a single scan; compare repeat scans with the same label", "n": 1}
    if per_frame_rms:
        arr = np.asarray(per_frame_rms, float)
        unc = {"method": "per_frame_spread", "n": int(len(arr)), "std_m": _r(arr.std(ddof=1)) if len(arr) > 1 else None,
               "min_m": _r(arr.min()), "max_m": _r(arr.max()),
               "note": "spread of the same estimator on each raw frame of this stationary capture; precision, not accuracy"}
    status = "measured"
    floor = None
    if noise_model and frame == "camera_optical_m":
        z_med = float(np.median(points[:, 2]))
        floor = float(stereo_rms_noise_m(z_med, noise_model["fx_px"], noise_model["baseline_m"], noise_model.get("subpixel", 0.08)))
        unc["expected_sensor_noise_rms_m"] = _r(floor)
        unc["noise_model"] = "Intel D400 RMS model z^2*subpixel/(fx*baseline), subpixel=0.08 (typical, not measured for this unit)"
        if fit["rms_orthogonal_m"] < 2.0 * floor:
            status = "at_noise_floor"
            validity.append("residual RMS is under 2x the expected sensor noise: surface roughness is not resolved at this range")
    if robust:
        validity.append(f"robust fit rejected {fit['n_rejected']} of {fit['n_points']} points (|r| > 3 MAD)")
    method_r = "total least squares plane (SVD/PCA) on ROI points; RMS of orthogonal residuals" + ("; robust 3-MAD rejection" if robust else "")
    baseline = max(fit["extent_major_m"], fit["extent_minor_m"])
    common = dict(roi=roi, source_artifact=source_artifact, frame=frame, n_points=n, label=label)
    ms = [
        measurement("plane_fit_roughness", _r(fit["rms_orthogonal_m"]), "m", method_r, status=status, uncertainty=unc,
                    validity=validity,
                    extra={"baseline_m": _r(baseline), "n_used": fit["n_used"], "residual_p05_m": _r(fit["residual_p05_m"]),
                           "residual_p95_m": _r(fit["residual_p95_m"]), "residual_max_abs_m": _r(fit["residual_max_abs_m"]),
                           "expected_sensor_noise_rms_m": _r(floor)}, **common),
        measurement("plane_tilt_from_optical_axis", _r(tilt_from_optical_axis_deg(fit["normal"]) if frame == "camera_optical_m" else None, 3),
                    "deg", "angle between fitted plane normal and the camera optical axis (+Z)",
                    status="measured" if frame == "camera_optical_m" else "not_measured",
                    validity=["relative to the camera, NOT to horizontal"], **common),
        measurement("extent_in_plane_major", _r(fit["extent_major_m"]), "m", "extent of ROI points along the plane's first principal axis",
                    validity=["visible extent only; the object may continue outside the ROI or behind occlusions"], **common),
        measurement("extent_in_plane_minor", _r(fit["extent_minor_m"]), "m", "extent of ROI points along the plane's second principal axis",
                    validity=["visible extent only"], **common),
        measurement("median_range", _r(float(np.median(np.linalg.norm(points, axis=1)))) if frame == "camera_optical_m" else None, "m",
                    "median distance of ROI points from the optical centre",
                    status="measured" if frame == "camera_optical_m" else "not_measured", **common),
    ]
    if gravity_up is not None:
        up = np.asarray(gravity_up, float) / np.linalg.norm(gravity_up)
        tilt = float(np.degrees(np.arccos(min(1.0, abs(float(np.dot(fit["normal"], up)))))))
        ms.append(measurement("plane_tilt_from_horizontal", _r(tilt, 3), "deg", "angle between fitted plane normal and the frame's measured up axis",
                              validity=["gravity direction from the capturing device's tracking; trusted only while tracking was normal"], **common))
    else:
        ms.append(measurement("plane_tilt_from_horizontal", None, "deg", "not computed", status="not_measured",
                              validity=["no measured world-up: the D435 has no IMU and no levelling reference was recorded"], **common))
    return {"status": status, "plane": {k: v for k, v in fit.items() if k not in ("residuals", "keep")},
            "expected_noise_rms_m": _r(floor), "measurements": ms}


def protrusion_analysis(object_pts: np.ndarray, reference_pts: np.ndarray, object_roi: dict, reference_roi: dict,
                        source_artifact: str = "", frame: str = "camera_optical_m", label: str = "") -> dict:
    """Height of an object's visible points above a user-selected local reference surface."""
    if len(reference_pts) < MIN_POINTS or len(object_pts) < 10:
        return {"status": "not_measured", "reason": "too few points in the object or reference region", "measurements": []}
    ref = plane_fit(reference_pts, robust=True)
    c, nrm = np.asarray(ref["centroid_m"]), np.asarray(ref["normal"])
    h = (object_pts - c) @ nrm
    axes = np.asarray(ref["axes_in_plane"])
    above = object_pts[h > 2 * ref["rms_orthogonal_m"]]
    fp = (above - c) @ axes.T if len(above) else np.zeros((0, 2))
    if len(fp) >= 3:   # align with the footprint's own principal axes; robust 1-99 % extents
        fpc = fp - fp.mean(axis=0)
        _, _, v2 = np.linalg.svd(fpc, full_matrices=False)
        fp = fpc @ v2.T
    validity = [
        "height is measured toward the sensor side of the reference plane; occluded parts are not measured",
        "the reference plane is the user's choice; a different reference changes the height",
        "any rover-clearance comparison is a team-defined illustration, not a NASA flight-qualified limit",
    ]
    unc = {"method": "reference_plane_residual", "n": 1, "reference_rms_m": _r(ref["rms_orthogonal_m"]),
           "note": "heights within ~2x this value of the plane are not distinguishable from it"}
    return {"status": "measured", "reference_plane": {k: v for k, v in ref.items() if k not in ("residuals", "keep")},
            "measurements": [measurement(
                "protrusion_above_plane", _r(np.percentile(h, 95)), "m",
                "95th percentile of object-point heights above a robust plane fitted to the reference ROI",
                object_roi, uncertainty=unc, validity=validity, source_artifact=source_artifact, frame=frame,
                n_points=len(object_pts), label=label,
                extra={"height_max_m": _r(np.max(h)), "height_p50_m": _r(np.percentile(h, 50)),
                       "reference_roi": roi_record(reference_roi, len(reference_pts)),
                       "footprint_major_m": _r(np.percentile(fp[:, 0], 99) - np.percentile(fp[:, 0], 1)) if len(fp) else None,
                       "footprint_minor_m": _r(np.percentile(fp[:, 1], 99) - np.percentile(fp[:, 1], 1)) if len(fp) else None,
                       "footprint_method": "object points > 2x reference RMS above the plane, projected onto it; 1-99 percentile extents along their principal axes"})]}


def distance_measurement(p1, p2, source_artifact: str = "", frame: str = "camera_optical_m", label: str = "", note: str = "") -> dict:
    p1, p2 = np.asarray(p1, float), np.asarray(p2, float)
    return measurement("distance", _r(np.linalg.norm(p2 - p1)), "m",
                       "straight-line distance between two picked 3D points" + (f"; {note}" if note else ""),
                       {"kind": "points", "points": [p1.round(6).tolist(), p2.round(6).tolist()]},
                       source_artifact=source_artifact, frame=frame, label=label,
                       validity=["each end point inherits depth noise at its range; picking on an edge mixes surfaces"],
                       extra={"p1_m": p1.round(6).tolist(), "p2_m": p2.round(6).tolist()})


def capture_quality(depth_stack_raw: np.ndarray, depth_scale_m: float, filtered: dict | None = None) -> dict:
    n, h, w = depth_stack_raw.shape
    valid = depth_stack_raw > 0
    per_frame = valid.reshape(n, -1).mean(axis=1)
    z = depth_stack_raw[valid].astype(np.float64) * depth_scale_m
    q = {
        "frames": int(n), "pixels_per_frame": int(h * w),
        "depth_valid_fraction_per_frame": [round(float(x), 4) for x in per_frame],
        "depth_valid_fraction_mean": round(float(per_frame.mean()), 4),
        "pixels_valid_in_all_frames": round(float(valid.all(axis=0).mean()), 4),
        "range_m_percentiles": {str(p): (round(float(np.percentile(z, p)), 4) if z.size else None) for p in (5, 25, 50, 75, 95)},
    }
    if filtered is not None:
        tsd = filtered["temporal_std_m"]
        fin = tsd[np.isfinite(tsd) & (filtered["depth_filtered_m"] > 0)]
        q["filtered_points"] = int(len(filtered["points"]))
        q["filtered_valid_fraction"] = round(float((filtered["depth_filtered_m"] > 0).mean()), 4)
        q["temporal_std_median_m"] = round(float(np.median(fin)), 6) if fin.size else None
        q["temporal_std_note"] = "per-pixel std across frames of a stationary capture: frame-to-frame noise, not accuracy"
    return q


def repeatability(values: list[float], scan_ids: list[str], name: str) -> dict:
    a = np.asarray([v for v in values if v is not None], float)
    if len(a) < 2:
        return {"name": name, "n": int(len(a)), "status": "not_measured", "reason": "need at least 2 scans with this measurement"}
    return {"name": name, "n": int(len(a)), "scan_ids": scan_ids, "mean": _r(a.mean()), "std": _r(a.std(ddof=1)),
            "min": _r(a.min()), "max": _r(a.max()), "range": _r(np.ptp(a)),
            "cv": _r(a.std(ddof=1) / a.mean()) if a.mean() != 0 else None,
            "status": "measured",
            "note": "empirical spread across repeated stationary captures at the same settings; not ground-truth accuracy"}
