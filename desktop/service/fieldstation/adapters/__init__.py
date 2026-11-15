"""Adapter registry. New sensors register a factory here; nothing else changes.

Only real sensors and replay are offered by default. The synthetic scene is
offered only when fixtures are explicitly enabled (FIELDSTATION_FIXTURES=1 or
--fixtures), so it cannot appear in a field session by accident.
"""
from __future__ import annotations

from pathlib import Path

from .base import AdapterError, Calibration, DeviceLost, Frame, PROFILES, SensorAdapter


def make_adapter(adapter_id: str, store_root: Path | None = None):
    if adapter_id == "realsense":
        from .realsense import RealSenseAdapter
        return RealSenseAdapter()
    if adapter_id == "replay":
        from .replay import ReplayAdapter
        return ReplayAdapter(store_root)
    if adapter_id == "synthetic":
        from .synthetic import SyntheticAdapter
        return SyntheticAdapter()
    raise AdapterError(f"unknown adapter {adapter_id!r}")


def adapter_ids(fixtures: bool) -> list[str]:
    return ["realsense", "replay"] + (["synthetic"] if fixtures else [])


__all__ = ["AdapterError", "Calibration", "DeviceLost", "Frame", "PROFILES", "SensorAdapter", "make_adapter", "adapter_ids"]
