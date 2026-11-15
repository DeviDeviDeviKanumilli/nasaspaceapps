"""Sensor adapter boundary.

The UI and the recorder only see these types. Nothing outside
fieldstation/adapters/<vendor>.py imports a vendor SDK.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Protocol, runtime_checkable

import numpy as np

from ..camera_model import Extrinsics, Intrinsics


class AdapterError(RuntimeError):
    """Adapter could not do what was asked (bad profile, SDK missing, permission...)."""


class DeviceLost(AdapterError):
    """The device stopped delivering frames (unplugged, USB reset, power)."""


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


@dataclass
class Calibration:
    depth_scale_m: float
    depth: Intrinsics
    color: Intrinsics | None
    depth_to_color: Extrinsics | None
    depth_fps: int
    color_fps: int | None
    depth_format: str = "z16"
    color_format: str | None = "rgb8"
    alignment: str = "unaligned_native_streams"
    stereo_baseline_m: float | None = None
    baseline_source: str | None = None
    device: dict = field(default_factory=dict)
    sensor_options: dict = field(default_factory=dict)
    source: str = "sdk"

    def to_dict(self) -> dict:
        return {
            "depth_scale_m": self.depth_scale_m,
            "depth_intrinsics": self.depth.to_dict(),
            "color_intrinsics": self.color.to_dict() if self.color else None,
            "depth_to_color_extrinsics": self.depth_to_color.to_dict() if self.depth_to_color else None,
            "depth_fps": self.depth_fps, "color_fps": self.color_fps,
            "depth_format": self.depth_format, "color_format": self.color_format,
            "alignment": self.alignment,
            "alignment_note": "depth and colour are stored as separate native streams; colour is attached to points by projection with the extrinsics above",
            "stereo_baseline_m": self.stereo_baseline_m, "baseline_source": self.baseline_source,
            "device": self.device, "sensor_options": self.sensor_options, "source": self.source,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Calibration":
        return cls(
            depth_scale_m=float(d["depth_scale_m"]),
            depth=Intrinsics.from_dict(d["depth_intrinsics"]),
            color=Intrinsics.from_dict(d["color_intrinsics"]) if d.get("color_intrinsics") else None,
            depth_to_color=Extrinsics.from_dict(d["depth_to_color_extrinsics"]) if d.get("depth_to_color_extrinsics") else None,
            depth_fps=int(d["depth_fps"]), color_fps=d.get("color_fps"),
            depth_format=d.get("depth_format", "z16"), color_format=d.get("color_format"),
            alignment=d.get("alignment", "unaligned_native_streams"),
            stereo_baseline_m=d.get("stereo_baseline_m"), baseline_source=d.get("baseline_source"),
            device=d.get("device", {}), sensor_options=d.get("sensor_options", {}), source=d.get("source", "sdk"),
        )


@dataclass
class Frame:
    index: int
    depth: np.ndarray | None              # HxW uint16, sensor units (x depth_scale_m = metres), 0 = no data
    color: np.ndarray | None              # HxWx3 uint8 RGB
    depth_timestamp_ms: float | None = None
    color_timestamp_ms: float | None = None
    timestamp_domain: str | None = None   # e.g. "hardware_clock", "system_time", "synthetic"
    depth_frame_number: int | None = None
    color_frame_number: int | None = None
    wall_utc: str = field(default_factory=utc_now)


@runtime_checkable
class SensorAdapter(Protocol):
    adapter_id: str
    origin: str          # value written to manifest "origin" (e.g. realsense_d435, replay, synthetic_fixture)
    label: str           # human description shown in the UI
    is_real_sensor: bool

    def discover(self) -> list[dict]: ...
    def open(self, device_id: str, config: dict) -> None: ...
    def get_calibration(self) -> Calibration: ...
    def read_frame(self, timeout_ms: int) -> Frame: ...
    def start_recording(self, session_id: str) -> None: ...
    def stop_recording(self) -> dict: ...
    def close(self) -> None: ...


PROFILES = {
    "field_static": {"label": "Field static, 848x480 @ 30 fps (recommended for D435)",
                     "depth": [848, 480, 30], "color": [848, 480, 30], "frames": 30},
    "field_static_hd": {"label": "High resolution, 1280x720 @ 15 fps (USB 3 only)",
                        "depth": [1280, 720, 15], "color": [1280, 720, 15], "frames": 15},
    "usb2_fallback": {"label": "USB 2 fallback, 640x480 @ 15 fps",
                      "depth": [640, 480, 15], "color": [640, 480, 15], "frames": 15},
}
