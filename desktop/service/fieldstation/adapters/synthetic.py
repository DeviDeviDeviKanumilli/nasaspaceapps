"""SYNTHETIC test scene: a ray-cast stand-in for a depth camera, for tests and labelled demos.

It is NOT a sensor. Everything it produces is stamped origin=synthetic_fixture,
and it is only offered when fixtures are explicitly enabled. Ground truth is
known exactly, which is what the tests need:

  * a flat board whose normal is tilted TILT_DEG from the optical axis, passing through (0, 0, BOARD_Z)
  * a box BOX_SIZE (length, width, height above the board) sitting on the board at the image centre
  * a sphere cap ("boulder") of radius SPHERE_R, centred on the board, to one side

Depth noise follows the Intel D400 RMS model at each pixel's range (Gaussian),
values are quantised to 1 mm units like a D435, ~1% random dropouts, and the
left-edge band that a left-imager stereo camera cannot match is left invalid.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import numpy as np

from ..camera_model import Extrinsics, Intrinsics, deproject, stereo_rms_noise_m
from .base import AdapterError, Calibration, Frame, PROFILES, utc_now

TILT_DEG = 30.0
BOARD_Z = 1.2
BOX_SIZE = (0.30, 0.20, 0.15)
SPHERE_R = 0.12
SPHERE_OFFSET = (-0.35, 0.0)   # in-plane offset of the cap centre from the box centre (m)
BASELINE_M = 0.050
DEPTH_SCALE = 0.001


def _intr(w, h, hfov_deg):
    fx = (w / 2) / np.tan(np.radians(hfov_deg / 2))
    return Intrinsics(w, h, fx, fx, (w - 1) / 2 + 0.3, (h - 1) / 2 - 0.2, "brown_conrady", [0.0] * 5)


class Scene:
    def __init__(self):
        t = np.radians(TILT_DEG)
        # board normal (pointing back toward the camera), tilted about the camera X axis
        self.n = np.array([0.0, -np.sin(t), -np.cos(t)])
        self.p0 = np.array([0.0, 0.0, BOARD_Z])
        # in-plane axes: a = camera X; b = n x a
        self.a = np.array([1.0, 0.0, 0.0])
        self.b = np.cross(self.n, self.a)
        L, W, H = BOX_SIZE
        self.box_half = np.array([L / 2, W / 2, H / 2])
        self.box_c = self.p0 + self.n * (H / 2)          # box centre, H/2 above the board
        self.sph_c = self.p0 + self.a * SPHERE_OFFSET[0] + self.b * SPHERE_OFFSET[1]

    def box_corners_top(self) -> np.ndarray:
        L, W, H = BOX_SIZE
        top = self.p0 + self.n * H
        return np.array([top + sa * self.a * L / 2 + sb * self.b * W / 2 for sa in (-1, 1) for sb in (-1, 1)])

    def raycast(self, origin: np.ndarray, dirs: np.ndarray):
        """dirs: Nx3 unit-ish rays from origin (camera frame). Returns (t, material id)."""
        n = len(dirs)
        t_best = np.full(n, np.inf)
        mat = np.zeros(n, np.int8)
        # board
        den = dirs @ self.n
        with np.errstate(divide="ignore", invalid="ignore"):
            tp = ((self.p0 - origin) @ self.n) / den
        ok = np.isfinite(tp) & (tp > 0)
        t_best[ok] = tp[ok]
        mat[ok] = 1
        # box (slab test in the box's local frame)
        R = np.stack([self.a, self.b, self.n])     # rows: local axes
        o = R @ (origin - self.box_c)
        d = dirs @ R.T
        with np.errstate(divide="ignore", invalid="ignore"):
            t1 = (-self.box_half - o) / d
            t2 = (self.box_half - o) / d
        tmin = np.nanmax(np.minimum(t1, t2), axis=1)
        tmax = np.nanmin(np.maximum(t1, t2), axis=1)
        hit = (tmax >= tmin) & (tmin > 0) & (tmin < t_best)
        t_best[hit] = tmin[hit]
        mat[hit] = 2
        # sphere (only the part above the board is visible anyway)
        oc = origin - self.sph_c
        bq = dirs @ oc
        cq = oc @ oc - SPHERE_R ** 2
        aq = np.einsum("ij,ij->i", dirs, dirs)
        disc = bq * bq - aq * cq
        okd = disc > 0
        ts = np.full(n, np.inf)
        ts[okd] = (-bq[okd] - np.sqrt(disc[okd])) / aq[okd]
        hit = okd & (ts > 0) & (ts < t_best)
        t_best[hit] = ts[hit]
        mat[hit] = 3
        return t_best, mat


class SyntheticAdapter:
    adapter_id = "synthetic"
    origin = "synthetic_fixture"
    label = "SYNTHETIC test scene (not a sensor)"
    is_real_sensor = False

    def __init__(self, seed: int = 7):
        self.seed = seed
        self.scene = Scene()
        self.calib: Calibration | None = None
        self._i = 0
        self._cache = None

    def discover(self) -> list[dict]:
        return [{"device_id": "synthetic:scene-v1", "name": "SYNTHETIC test scene", "serial": None, "firmware": None,
                 "usb_type": None, "is_real_sensor": False,
                 "note": "Ray-cast board + 0.30x0.20x0.15 m box + 0.12 m sphere cap. For tests and labelled demos only."}]

    def open(self, device_id: str, config: dict) -> None:
        prof = PROFILES.get(config.get("profile", "field_static"))
        if prof is None:
            raise AdapterError(f"unknown profile {config.get('profile')!r}")
        dw, dh, fps = prof["depth"]
        cw, ch, cfps = prof["color"]
        di = _intr(dw, dh, 87.0)
        ci = _intr(cw, ch, 69.0)
        ci.model = "inverse_brown_conrady"
        self.calib = Calibration(
            depth_scale_m=DEPTH_SCALE, depth=di, color=ci,
            depth_to_color=Extrinsics([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [0.015, 0.0, 0.0]),
            depth_fps=fps, color_fps=cfps, stereo_baseline_m=BASELINE_M, baseline_source="synthetic_parameter",
            device={"name": "SYNTHETIC test scene", "serial": None, "firmware": None, "usb_type": None, "product_line": "synthetic"},
            sensor_options={"noise_model": "Intel D400 RMS, subpixel 0.08", "dropout_fraction": 0.01, "seed": self.seed},
            source="synthetic",
        )
        self._render_static()
        self._i = 0

    def _render_static(self):
        c = self.calib
        di = c.depth
        vv, uu = np.mgrid[0:di.height, 0:di.width]
        rays = deproject(di, uu.ravel().astype(float), vv.ravel().astype(float), np.ones(uu.size))
        t, _ = self.scene.raycast(np.zeros(3), rays)
        z = (t * rays[:, 2]).reshape(di.height, di.width)
        # left band a left-imager stereo camera cannot match: u < fx*B/Z
        band = uu < (di.fx * BASELINE_M / np.maximum(z, 1e-6))
        z[band | ~np.isfinite(z)] = 0
        ci = c.color
        vv2, uu2 = np.mgrid[0:ci.height, 0:ci.width]
        rays_c = deproject(ci, uu2.ravel().astype(float), vv2.ravel().astype(float), np.ones(uu2.size))
        # colour camera origin in the depth frame is -t (R = I)
        org = -np.asarray(c.depth_to_color.translation)
        tc, mc = self.scene.raycast(org, rays_c)
        hitp = org + rays_c * tc[:, None]
        rgb = np.zeros((uu2.size, 3), np.uint8)
        rel = hitp - self.scene.p0
        ca, cb = rel @ self.scene.a, rel @ self.scene.b
        checker = ((np.floor(ca / 0.05) + np.floor(cb / 0.05)) % 2).astype(bool)
        board = mc == 1
        rgb[board & checker] = (205, 200, 190)
        rgb[board & ~checker] = (70, 72, 76)
        rgb[mc == 2] = (196, 112, 52)
        rgb[mc == 3] = (120, 98, 80)
        rgb[mc == 0] = (30, 30, 30)
        self._cache = (z, rgb.reshape(ci.height, ci.width, 3))

    def get_calibration(self) -> Calibration:
        if self.calib is None:
            raise AdapterError("not open")
        return self.calib

    def read_frame(self, timeout_ms: int) -> Frame:
        if self._cache is None:
            raise AdapterError("not open")
        z, rgb = self._cache
        rng = np.random.default_rng(self.seed * 100003 + self._i)
        sigma = stereo_rms_noise_m(z, self.calib.depth.fx, BASELINE_M)
        zn = z + rng.normal(size=z.shape) * sigma
        zn[(z <= 0) | (rng.random(z.shape) < 0.01)] = 0
        raw = np.clip(np.round(zn / DEPTH_SCALE), 0, 65535).astype(np.uint16)
        ts = self._i * 1000.0 / self.calib.depth_fps
        f = Frame(self._i, raw, rgb.copy(), ts, ts, "synthetic", self._i, self._i, utc_now())
        self._i += 1
        return f

    def start_recording(self, session_id: str) -> None:
        pass

    def stop_recording(self) -> dict:
        return {}

    def close(self) -> None:
        self._cache = None
