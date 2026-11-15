"""Replay a saved scan bundle's raw frames as if streaming.

Used when no camera is attached (demo/rehearsal). Everything recorded from a
replay is stamped origin=replay with replay_of=<source scan id> and the
source's origin, so a replayed capture can never pass as a new field scan.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

from .base import AdapterError, Calibration, Frame, utc_now


class ReplayAdapter:
    adapter_id = "replay"
    origin = "replay"
    label = "Replay a saved scan (not live)"
    is_real_sensor = False

    def __init__(self, store_root: Path | None = None):
        self.store_root = Path(store_root) if store_root else None
        self.calib = None
        self.frames: list[dict] = []
        self.dir: Path | None = None
        self._i = 0
        self.source_manifest: dict = {}

    def discover(self) -> list[dict]:
        out = []
        if not self.store_root or not self.store_root.exists():
            return out
        for m in sorted(self.store_root.glob("scan-*/scan.json")):
            try:
                man = json.loads(m.read_text())
            except Exception:
                continue
            if not (man.get("capture") or {}).get("frames_recorded") or not (m.parent / "calibration.json").exists():
                continue
            title = (man.get("observation") or {}).get("title")
            out.append({"device_id": f"replay:{man['scan_id']}", "name": f"REPLAY: {title or man['scan_id'][:8]}",
                        "serial": None, "firmware": None, "usb_type": None, "is_real_sensor": False,
                        "source_origin": man.get("origin"), "captured_at_utc": (man.get("captured_at_utc") or {}).get("start")})
        return out

    def open(self, device_id: str, config: dict) -> None:
        sid = device_id.split(":", 1)[1]
        import uuid as _uuid
        _uuid.UUID(sid)
        d = self.store_root / f"scan-{sid}"
        if not (d / "frames.jsonl").exists():
            raise AdapterError(f"scan {sid} has no recorded frames")
        self.dir = d
        self.source_manifest = json.loads((d / "scan.json").read_text())
        cal = json.loads((d / "calibration.json").read_text())
        self.calib = Calibration.from_dict(cal)
        self.calib.source = "replay"
        self.calib.device = {**self.calib.device, "replay_of_scan_id": sid, "replay_of_origin": self.source_manifest.get("origin")}
        self.frames = [json.loads(l) for l in (d / "frames.jsonl").read_text().splitlines() if l.strip()]
        self._i = 0

    def get_calibration(self) -> Calibration:
        if self.calib is None:
            raise AdapterError("not open")
        return self.calib

    def read_frame(self, timeout_ms: int) -> Frame:
        if not self.frames:
            raise AdapterError("not open")
        rec = self.frames[self._i % len(self.frames)]
        depth = np.array(Image.open(self.dir / "frames" / rec["depth_file"]), dtype=np.uint16)
        color = np.array(Image.open(self.dir / "frames" / rec["color_file"]).convert("RGB")) if rec.get("color_file") else None
        f = Frame(self._i, depth, color, rec.get("depth_timestamp_ms"), rec.get("color_timestamp_ms"),
                  f"replay:{rec.get('timestamp_domain')}", rec.get("depth_frame_number"), rec.get("color_frame_number"), utc_now())
        self._i += 1
        return f

    def start_recording(self, session_id: str) -> None:
        pass

    def stop_recording(self) -> dict:
        return {}

    def close(self) -> None:
        self.frames = []
