"""Camera intrinsics/extrinsics and vectorised projection.

The distortion handling mirrors librealsense's rsutil.h
(rs2_project_point_to_pixel / rs2_deproject_pixel_to_point) so results match
the SDK; tests/test_camera_model.py cross-checks against pyrealsense2 itself.

Coordinate convention (RealSense "camera optical" frame): metres,
+X right, +Y down, +Z forward out of the lens, right-handed, origin at the
optical centre of the stream's imager.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

SUPPORTED_MODELS = {"none", "brown_conrady", "inverse_brown_conrady", "modified_brown_conrady"}

FRAME_CONVENTION = {
    "name": "camera_optical_m",
    "units": "m",
    "axes": "+X right, +Y down, +Z forward (out of the lens)",
    "handedness": "right",
    "origin": "optical centre of the depth imager",
}


@dataclass
class Intrinsics:
    width: int
    height: int
    fx: float
    fy: float
    ppx: float
    ppy: float
    model: str = "none"
    coeffs: list[float] = field(default_factory=lambda: [0.0] * 5)

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "Intrinsics":
        return cls(int(d["width"]), int(d["height"]), float(d["fx"]), float(d["fy"]), float(d["ppx"]), float(d["ppy"]),
                   str(d.get("model", "none")), [float(c) for c in d.get("coeffs", [0.0] * 5)])

    @property
    def distortion_is_zero(self) -> bool:
        return all(abs(c) < 1e-12 for c in self.coeffs)


@dataclass
class Extrinsics:
    """Rigid transform p_to = R @ p_from + t. R is stored row-major (unlike the SDK's column-major array)."""
    rotation: list[list[float]]
    translation: list[float]

    def to_dict(self) -> dict:
        return {"rotation_row_major": self.rotation, "translation_m": self.translation}

    @classmethod
    def from_dict(cls, d: dict) -> "Extrinsics":
        return cls([list(map(float, r)) for r in d["rotation_row_major"]], [float(x) for x in d["translation_m"]])

    @classmethod
    def from_sdk_column_major(cls, rotation9, translation3) -> "Extrinsics":
        r = list(rotation9)
        return cls([[r[0], r[3], r[6]], [r[1], r[4], r[7]], [r[2], r[5], r[8]]], [float(x) for x in translation3])

    @classmethod
    def identity(cls) -> "Extrinsics":
        return cls([[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]], [0.0, 0.0, 0.0])

    def apply(self, pts: np.ndarray) -> np.ndarray:
        R = np.asarray(self.rotation, dtype=np.float64)
        t = np.asarray(self.translation, dtype=np.float64)
        return pts @ R.T + t


def _check_model(intr: Intrinsics) -> None:
    if intr.model not in SUPPORTED_MODELS:
        raise ValueError(f"distortion model {intr.model!r} is not supported by this pipeline")


def deproject(intr: Intrinsics, u: np.ndarray, v: np.ndarray, z_m: np.ndarray) -> np.ndarray:
    """Pixel coordinates (u right, v down; pixel centres at integers as in the SDK) + depth Z (m) -> Nx3 points."""
    _check_model(intr)
    if intr.model == "modified_brown_conrady" and not intr.distortion_is_zero:
        raise ValueError("cannot deproject from a forward-distorted (modified Brown-Conrady) image")
    x = (np.asarray(u, np.float64) - intr.ppx) / intr.fx
    y = (np.asarray(v, np.float64) - intr.ppy) / intr.fy
    if not intr.distortion_is_zero and intr.model in ("brown_conrady", "inverse_brown_conrady"):
        c = intr.coeffs
        xo, yo = x.copy(), y.copy()
        for _ in range(10):
            r2 = x * x + y * y
            icdist = 1.0 / (1.0 + ((c[4] * r2 + c[1]) * r2 + c[0]) * r2)
            if intr.model == "inverse_brown_conrady":
                xq, yq = x / icdist, y / icdist
            else:
                xq, yq = x, y
            dx = 2 * c[2] * xq * yq + c[3] * (r2 + 2 * xq * xq)
            dy = 2 * c[3] * xq * yq + c[2] * (r2 + 2 * yq * yq)
            x = (xo - dx) * icdist
            y = (yo - dy) * icdist
    z = np.asarray(z_m, np.float64)
    return np.stack([x * z, y * z, z], axis=-1)


def project(intr: Intrinsics, pts: np.ndarray) -> np.ndarray:
    """Nx3 points (m) -> Nx2 pixel coordinates. Points with Z<=0 give NaN."""
    _check_model(intr)
    pts = np.asarray(pts, np.float64)
    z = pts[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        x = np.where(z > 0, pts[:, 0] / z, np.nan)
        y = np.where(z > 0, pts[:, 1] / z, np.nan)
    if not intr.distortion_is_zero:
        c = intr.coeffs
        r2 = x * x + y * y
        f = 1 + c[0] * r2 + c[1] * r2 * r2 + c[4] * r2 * r2 * r2
        if intr.model in ("modified_brown_conrady", "inverse_brown_conrady"):
            x, y = x * f, y * f
            dx = x + 2 * c[2] * x * y + c[3] * (r2 + 2 * x * x)
            dy = y + 2 * c[3] * x * y + c[2] * (r2 + 2 * y * y)
            x, y = dx, dy
        elif intr.model == "brown_conrady":
            dx = x * f + 2 * c[2] * x * y + c[3] * (r2 + 2 * x * x)
            dy = y * f + 2 * c[3] * x * y + c[2] * (r2 + 2 * y * y)
            x, y = dx, dy
    return np.stack([x * intr.fx + intr.ppx, y * intr.fy + intr.ppy], axis=-1)


def deproject_image(intr: Intrinsics, depth_m: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Whole depth image (HxW, metres, 0 = invalid) -> (Nx3 points, Nx2 integer pixel indices [v,u]) for valid pixels."""
    h, w = depth_m.shape
    if (w, h) != (intr.width, intr.height):
        raise ValueError(f"depth image {w}x{h} does not match intrinsics {intr.width}x{intr.height}")
    vv, uu = np.nonzero(np.isfinite(depth_m) & (depth_m > 0))
    pts = deproject(intr, uu.astype(np.float64), vv.astype(np.float64), depth_m[vv, uu])
    return pts, np.stack([vv, uu], axis=-1)


def stereo_rms_noise_m(z_m, fx_px: float, baseline_m: float, subpixel: float = 0.08):
    """Intel's published model for D400 depth RMS error at a flat, textured target.

    rms = Z^2 * subpixel / (fx * baseline). Source: Intel RealSense whitepaper
    "Tuning depth cameras for best performance" (Grunnet-Jepsen et al.), with the
    0.08 px subpixel figure they quote as typical. It is an expected noise floor,
    not a measured accuracy for this unit.
    """
    z = np.asarray(z_m, np.float64)
    return z * z * subpixel / (fx_px * baseline_m)
