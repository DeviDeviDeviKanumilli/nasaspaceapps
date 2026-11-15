"""Headless command line (no GUI, no server). Same code paths as the app.

    python -m fieldstation.cli devices [--adapter realsense]
    python -m fieldstation.cli capture --adapter realsense --device realsense:<serial> [--profile field_static]
                                       [--frames 30] [--title ..] [--feature boulder] [--session <uuid>]
    python -m fieldstation.cli list
    python -m fieldstation.cli roughness <scan_id> --rect u0 v0 u1 v1 [--robust]
    python -m fieldstation.cli repeat <scan_id> <scan_id> [...] --rect u0 v0 u1 v1
    python -m fieldstation.cli export <scan_id>
    python -m fieldstation.cli import <file.zip|file.ply>

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import argparse
import json
import sys
import time

import numpy as np

from .adapters.base import Calibration
from .bundle import ScanStore, default_home, load_depth_png
from .capture import CaptureController
from .metrics import plane_fit, repeatability, roi_points_from_pixels, roughness_analysis


def _roi_pts(store, sid, rect):
    d = store.dir_of(sid)
    calib = Calibration.from_dict(json.loads((d / "calibration.json").read_text()))
    dm = load_depth_png(d / "depth_filtered.png").astype(np.float64) * calib.depth_scale_m
    return roi_points_from_pixels(dm, rect, calib.depth)[0], calib


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="fieldstation.cli")
    ap.add_argument("--home", default=None)
    ap.add_argument("--fixtures", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("devices"); s.add_argument("--adapter", default="realsense")
    s = sub.add_parser("capture")
    s.add_argument("--adapter", default="realsense"); s.add_argument("--device", required=True)
    s.add_argument("--profile", default="field_static"); s.add_argument("--frames", type=int, default=None)
    s.add_argument("--title", default=""); s.add_argument("--feature", default="other"); s.add_argument("--session", default=None)
    s.add_argument("--site", default=None); s.add_argument("--notes", default="")
    sub.add_parser("list")
    s = sub.add_parser("roughness"); s.add_argument("scan_id"); s.add_argument("--rect", nargs=4, type=float, required=True); s.add_argument("--robust", action="store_true")
    s = sub.add_parser("repeat"); s.add_argument("scan_ids", nargs="+"); s.add_argument("--rect", nargs=4, type=float, required=True)
    s = sub.add_parser("export"); s.add_argument("scan_id")
    s = sub.add_parser("import"); s.add_argument("path")
    a = ap.parse_args(argv)
    from pathlib import Path
    home = Path(a.home) if a.home else default_home()
    store = ScanStore(home / "scans")
    out = None
    if a.cmd == "devices":
        out = CaptureController(store, fixtures=a.fixtures).discover(a.adapter)
    elif a.cmd == "capture":
        c = CaptureController(store, fixtures=a.fixtures)
        try:
            c.open(a.adapter, a.device, a.profile)
            time.sleep(1.0)       # let auto-exposure settle on a live camera
            r = c.start_recording(title=a.title, feature_type=a.feature, session_id=a.session, field_site_id=a.site,
                                  notes=a.notes, frames=a.frames, started_by="desktop_cli")
            print(json.dumps({"recording": r}), flush=True)
            while True:
                m = store.manifest(r["scan_id"])
                if m["status"] in ("complete", "incomplete") and c.state != "processing":
                    break
                time.sleep(0.2)
            out = {"scan_id": r["scan_id"], "status": m["status"], "status_reason": m.get("status_reason"),
                   "frames": m["capture"]["frames_recorded"], "quality": m.get("quality"),
                   "measurements": [{k: x[k] for k in ("name", "value", "unit", "status")} for x in m.get("measurements", [])],
                   "dir": str(store.dir_of(r["scan_id"]))}
        finally:
            c.close()
    elif a.cmd == "list":
        out = store.list()
    elif a.cmd == "roughness":
        pts, calib = _roi_pts(store, a.scan_id, a.rect)
        roi = {"kind": "pixel_rect", "rect_px": a.rect, "label": "cli"}
        res = roughness_analysis(pts, roi, robust=a.robust, source_artifact="depth_filtered.png",
                                 noise_model={"fx_px": calib.depth.fx, "baseline_m": calib.stereo_baseline_m} if calib.stereo_baseline_m else None)
        if res["status"] != "not_measured":
            store.add_analysis(a.scan_id, {"kind": "roughness", "request": {"roi": roi, "robust": a.robust}, **res})
        out = {"status": res["status"], "measurements": [{k: x[k] for k in ("name", "value", "unit", "status", "validity")} for x in res["measurements"]]}
    elif a.cmd == "repeat":
        vals = []
        for sid in a.scan_ids:
            pts, _ = _roi_pts(store, sid, a.rect)
            vals.append(plane_fit(pts)["rms_orthogonal_m"] if len(pts) >= 50 else None)
        out = repeatability(vals, a.scan_ids, "plane_fit_roughness_rms_m")
    elif a.cmd == "export":
        out = {"zip": str(store.export_zip(a.scan_id))}
    elif a.cmd == "import":
        p = Path(a.path)
        m = store.import_zip(p) if p.suffix.lower() == ".zip" else store.import_ply(p)
        out = {"scan_id": m["scan_id"], "origin": m["origin"], "status": m.get("status")}
    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
