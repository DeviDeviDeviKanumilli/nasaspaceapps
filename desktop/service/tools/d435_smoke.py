"""D435 hardware acceptance gate (HANDOFF 02 section 2). Run BEFORE trusting anything else.

    cd desktop/service && .venv/bin/python tools/d435_smoke.py [--out DIR] [--profile field_static]

1. reports the librealsense Python package and lists every RealSense device (name, serial, firmware, USB type);
2. streams the chosen profile, waits through 30 auto-exposure frames, then grabs 30 frame sets;
3. writes a signed-off JSON log + one raw depth PNG (16-bit) + one colour PNG to --out.

Exit codes: 0 = real non-empty depth acquired; 2 = SDK missing; 3 = no device; 4 = streaming failed; 5 = depth empty.
Nothing is simulated. If this fails, record the error text and use replay mode, never a fake capture.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

from fieldstation.adapters.base import PROFILES  # noqa: E402


_KEEP: list = []  # librealsense objects kept alive until exit: freeing them after a failed open segfaults on macOS


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path.home() / "Library" / "Application Support" / "FieldStation" / "hardware_smoke")
    ap.add_argument("--profile", default=None, choices=list(PROFILES),
                    help="default: field_static on USB 3, usb2_fallback on a USB 2 link")
    ap.add_argument("--frames", type=int, default=30)
    a = ap.parse_args()
    log = {"tool": "d435_smoke", "started_utc": now(), "host": {"os": f"macOS {platform.mac_ver()[0]}", "machine": platform.machine(),
                                                                   "python": platform.python_version()}, "profile": a.profile}

    def done(code: int, msg: str) -> int:
        log.update(result_code=code, result=msg, finished_utc=now())
        a.out.mkdir(parents=True, exist_ok=True)
        p = a.out / f"hardware_smoke_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
        p.write_text(json.dumps(log, indent=2))
        print(json.dumps({k: log[k] for k in ("result_code", "result")}, indent=2))
        print(f"log: {p}")
        return code

    try:
        import pyrealsense2 as rs
        from fieldstation.adapters.realsense import _hold_libusb
        _hold_libusb()  # same libusb race workaround as Field Station itself
        log["sdk"] = {"package": "pyrealsense2-macosx", "module": rs.__file__}
    except Exception as exc:
        return done(2, f"pyrealsense2 not importable: {exc}")
    devs = []
    ctx = rs.context()
    found = ctx.query_devices()
    _KEEP.extend([ctx, found])  # never freed before os._exit (see the bottom of this file)
    try:
        for d in found:
            g = lambda k: d.get_info(k) if d.supports(k) else None  # noqa: E731
            devs.append({"name": g(rs.camera_info.name), "serial": g(rs.camera_info.serial_number),
                         "firmware": g(rs.camera_info.firmware_version), "usb": g(rs.camera_info.usb_type_descriptor),
                         "product_line": g(rs.camera_info.product_line)})
    except RuntimeError as exc:
        # macOS: "failed to set power state" = the camera is on USB but this user cannot claim it (needs sudo)
        log["devices"] = devs
        return done(3, f"RealSense device listed but could not be opened as this user: {exc} "
                       "(on recent macOS librealsense needs root; desktop/d435.sh retries with sudo)")
    log["devices"] = devs
    print("devices:", json.dumps(devs, indent=2))
    if not devs:
        return done(3, "no RealSense device enumerated (check USB 3 DATA cable, port/hub, then retry; "
                       "if it appears in System Information > USB but not here, retry with sudo and note it)")
    if a.profile is None:
        usb2 = bool(devs[0]["usb"]) and not str(devs[0]["usb"]).startswith("3")
        a.profile = "usb2_fallback" if usb2 else "field_static"
        log["profile"] = a.profile
        if usb2:
            print(f"USB {devs[0]['usb']} link: using the usb2_fallback profile (640x480 @ 15 fps)")
    prof = PROFILES[a.profile]
    cfg, pipe = rs.config(), rs.pipeline()
    cfg.enable_device(devs[0]["serial"])
    cfg.enable_stream(rs.stream.depth, *prof["depth"][:2], rs.format.z16, prof["depth"][2])
    cfg.enable_stream(rs.stream.color, *prof["color"][:2], rs.format.rgb8, prof["color"][2])
    try:
        profile = pipe.start(cfg)
    except Exception as exc:
        return done(4, f"pipeline.start failed for {a.profile}: {exc}")
    try:
        scale = profile.get_device().first_depth_sensor().get_depth_scale()
        intr = profile.get_stream(rs.stream.depth).as_video_stream_profile().get_intrinsics()
        log["depth_scale_m"] = scale
        log["depth_intrinsics"] = {"w": intr.width, "h": intr.height, "fx": intr.fx, "fy": intr.fy, "ppx": intr.ppx, "ppy": intr.ppy,
                                   "model": str(intr.model), "coeffs": list(intr.coeffs)}
        for _ in range(30):
            pipe.wait_for_frames(5000)
        stats, t0, last = [], time.monotonic(), None
        for _ in range(a.frames):
            fs = pipe.wait_for_frames(5000)
            dpt, col = fs.get_depth_frame(), fs.get_color_frame()
            z = np.asanyarray(dpt.get_data()).copy()
            v = z > 0
            stats.append({"frame_number": dpt.get_frame_number(), "valid_fraction": float(v.mean()),
                          "median_m": float(np.median(z[v]) * scale) if v.any() else None})
            last = (z, np.asanyarray(col.get_data()).copy() if col else None)
        log["measured_fps"] = round(a.frames / (time.monotonic() - t0), 2)
        log["frames"] = stats
    except Exception as exc:
        pipe.stop()
        return done(4, f"streaming failed: {exc}")
    pipe.stop()
    a.out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dp, cp = a.out / f"depth_{stamp}.png", a.out / f"color_{stamp}.png"
    Image.fromarray(np.ascontiguousarray(last[0], dtype="<u2")).save(dp)
    if last[1] is not None:
        Image.fromarray(last[1]).save(cp)
    log["artifacts"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (dp, cp) if p.exists()}
    vf = float(np.mean([s["valid_fraction"] for s in stats]))
    log["mean_valid_fraction"] = vf
    if vf <= 0:
        return done(5, "frames arrived but depth is empty (all zero)")
    return done(0, f"REAL depth acquired: {len(stats)} frames, mean valid fraction {vf:.3f}, USB {devs[0]['usb']}")


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)  # skip interpreter teardown: librealsense on macOS can segfault freeing devices after a failed open
