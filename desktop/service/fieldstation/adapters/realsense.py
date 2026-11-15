"""Intel RealSense (D435 and other D400 depth cameras) through pyrealsense2.

On macOS this uses the community `pyrealsense2-macosx` wheel (librealsense
2.56.5). Intel/RealSense state macOS is not a fully supported platform, so
discover() reports SDK/USB problems as diagnostics instead of failing quietly.

The D435 has no IMU: nothing here produces a gravity direction.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import time

import numpy as np

from ..camera_model import Extrinsics, Intrinsics
from .base import AdapterError, Calibration, DeviceLost, Frame, PROFILES, utc_now

try:
    import pyrealsense2 as rs
    _IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on the machine
    rs = None
    _IMPORT_ERROR = f"{type(exc).__name__}: {exc}"

# librealsense objects from a discover() whose open failed. Freeing them then segfaults on macOS (2.56.5), so they
# are never freed: discover() runs in a short-lived child process (CaptureController.discover) that exits with os._exit.
_KEEP: list = []

_LIBUSB_HOLD = None


def _hold_libusb() -> None:
    """Keep one libusb context open for the life of this process (macOS only).

    librealsense's device watcher opens and closes a libusb context about every 100 ms on a background thread, and
    pipeline.start opens more on the calling thread. libusb's macOS backend sets itself up when the first context opens
    and tears down when the last one closes, and that is not thread-safe: libusb_init fails, librealsense carries on
    with a NULL context and the process segfaults in libusb_get_device_list (seen 15 Nov 2026 on macOS 26.6.2 with a
    D435, every open after the first). With one context held, setup/teardown never run again while the camera is used."""
    global _LIBUSB_HOLD
    if _LIBUSB_HOLD is not None or rs is None or sys.platform != "darwin":
        return
    import ctypes
    mod = getattr(rs, "__file__", None)
    path = os.path.join(os.path.dirname(mod), ".dylibs", "libusb-1.0.0.dylib") if mod else ""
    if not path or not os.path.exists(path):
        _LIBUSB_HOLD = False
        return
    try:
        lib = ctypes.CDLL(path)  # the same image librealsense loaded (@loader_path), so the same libusb state
        ctx = ctypes.c_void_p()
        _LIBUSB_HOLD = (lib, ctx) if lib.libusb_init(ctypes.byref(ctx)) == 0 else False
    except OSError:
        _LIBUSB_HOLD = False


_MODEL_NAMES = {}
if rs is not None:
    _MODEL_NAMES = {
        rs.distortion.none: "none", rs.distortion.brown_conrady: "brown_conrady",
        rs.distortion.inverse_brown_conrady: "inverse_brown_conrady",
        rs.distortion.modified_brown_conrady: "modified_brown_conrady",
        rs.distortion.ftheta: "ftheta", rs.distortion.kannala_brandt4: "kannala_brandt4",
    }


def _intr(i) -> Intrinsics:
    return Intrinsics(int(i.width), int(i.height), float(i.fx), float(i.fy), float(i.ppx), float(i.ppy),
                      _MODEL_NAMES.get(i.model, str(i.model)), [float(c) for c in i.coeffs])


def _info(dev, key):
    try:
        return dev.get_info(key) if dev.supports(key) else None
    except Exception:
        return None


def usb_seen() -> list[dict]:
    """RealSense devices macOS lists on USB (vendor 0x8086), whether or not librealsense can open them. Lets
    discover() tell "nothing plugged in" apart from "plugged in but this user can't open it" (needs sudo)."""
    if sys.platform != "darwin":
        return []
    try:
        raw = subprocess.run(["ioreg", "-p", "IOUSB", "-l", "-a"], capture_output=True, timeout=10).stdout
        root = plistlib.loads(raw)
    except Exception:
        return []
    out: list[dict] = []

    def walk(n):
        if isinstance(n, dict):
            if n.get("idVendor") == 0x8086:
                out.append({"product_id": f"{int(n.get('idProduct', 0)):04x}", "link_bps": int(n.get("UsbLinkSpeed") or 0),
                            "name": n.get("USB Product Name") or n.get("IORegistryEntryName")})
            for c in n.get("IORegistryEntryChildren", []):
                walk(c)
        elif isinstance(n, list):
            for c in n:
                walk(c)

    walk(root)
    return out


def sdk_status() -> dict:
    if rs is None:
        return {"available": False, "error": _IMPORT_ERROR}
    pkg = "pyrealsense2-macosx" if sys.platform == "darwin" else "pyrealsense2"
    ver = getattr(rs, "__version__", None)
    if not ver:  # the macOS wheel does not set __version__; the installed package metadata has it
        try:
            from importlib.metadata import version
            ver = version(pkg)
        except Exception:
            ver = None
    return {"available": True, "package": pkg, "version": ver}


class RealSenseAdapter:
    adapter_id = "realsense"
    origin = "realsense_d435"
    label = "Intel RealSense depth camera (librealsense)"
    is_real_sensor = True

    def __init__(self):
        _hold_libusb()
        self.pipe = None
        self.profile = None
        self.calib: Calibration | None = None
        self._i = 0

    def discover(self) -> list[dict]:
        if rs is None:
            raise AdapterError(f"pyrealsense2 is not importable: {_IMPORT_ERROR}")
        out = []
        ctx = rs.context()
        devlist = ctx.query_devices()
        _KEEP.extend([ctx, devlist])  # see _KEEP
        try:
            found = list(devlist)
        except RuntimeError as exc:
            # macOS: "failed to set power state" when the system owns the camera's USB interface and this user cannot
            # claim it. (librealsense may then crash when these objects are freed: callers run this in a child process.)
            raise AdapterError(self._cannot_open(f"librealsense: {exc}")) from exc
        for dev in found:
            usb = _info(dev, rs.camera_info.usb_type_descriptor)
            d = {
                "device_id": f"realsense:{_info(dev, rs.camera_info.serial_number)}",
                "name": _info(dev, rs.camera_info.name), "serial": _info(dev, rs.camera_info.serial_number),
                "firmware": _info(dev, rs.camera_info.firmware_version), "usb_type": usb,
                "product_line": _info(dev, rs.camera_info.product_line), "is_real_sensor": True,
            }
            if usb and not str(usb).startswith("3"):
                d["recommended_profile"] = "usb2_fallback"
                d["warning"] = (f"Connected over USB {usb}, too slow for depth + colour at 848x480. Field Station opens it with "
                                "the USB 2 fallback profile (640x480 @ 15 fps). For full resolution: flip the USB-C plug at the "
                                "camera end, use a USB 3 data cable, plug straight into the Mac (no hub), then Scan again.")
            out.append(d)
        if not out:
            seen = usb_seen()
            if any(d["product_id"] in ("0adb", "0adc", "0ab3") for d in seen):
                raise AdapterError("A RealSense camera is on USB in firmware RECOVERY mode. Unplug it, wait 10 s and plug it in "
                                   "again; if it stays in recovery it needs a firmware update with Intel's tools.")
            if seen:
                raise AdapterError(self._cannot_open(None, seen))
        return out

    @staticmethod
    def _cannot_open(detail: str | None, seen: list[dict] | None = None) -> str:
        seen = usb_seen() if seen is None else seen
        name = (seen[0]["name"] if seen else None) or "The RealSense camera"
        root = hasattr(os, "geteuid") and os.geteuid() == 0
        where = "is plugged in (macOS sees it on USB) but" if seen else ""
        msg = (f"{name} {where} librealsense cannot open it".replace("  ", " ")
               + (" even as root. Unplug it for 10 s, try the other port, then Scan again." if root else
                  " as this user. On recent macOS it needs root: quit Field Station, then in Terminal run "
                  "desktop/d435.sh (checks the camera, asks for your Mac password once) and then desktop/d435.sh run."))
        return msg + (f" ({detail})" if detail else "")

    def open(self, device_id: str, config: dict) -> None:
        if rs is None:
            raise AdapterError(f"pyrealsense2 is not importable: {_IMPORT_ERROR}")
        prof = PROFILES.get(config.get("profile", "field_static"))
        if prof is None:
            raise AdapterError(f"unknown profile {config.get('profile')!r}")
        serial = device_id.split(":", 1)[1] if ":" in device_id else device_id
        cfg = rs.config()
        cfg.enable_device(serial)
        dw, dh, dfps = prof["depth"]
        cw, ch, cfps = prof["color"]
        cfg.enable_stream(rs.stream.depth, dw, dh, rs.format.z16, dfps)
        cfg.enable_stream(rs.stream.color, cw, ch, rs.format.rgb8, cfps)
        self.pipe = rs.pipeline()
        # On macOS the system camera helper (UVCAssistant) sometimes still holds the D435's colour camera for a moment,
        # and start fails with "failed to set power state"; a second attempt a moment later succeeds (seen 15 Nov 2026).
        for attempt in range(3):
            try:
                self.profile = self.pipe.start(cfg)
                break
            except RuntimeError as exc:
                if "power state" in str(exc) and attempt < 2:
                    time.sleep(1.5)
                    continue
                self.pipe = None
                raise AdapterError(f"could not start streams {dw}x{dh}@{dfps} depth + {cw}x{ch}@{cfps} colour: {exc}") from exc
        dev = self.profile.get_device()
        dsensor = dev.first_depth_sensor()
        dprof = self.profile.get_stream(rs.stream.depth).as_video_stream_profile()
        cprof = self.profile.get_stream(rs.stream.color).as_video_stream_profile()
        ext = dprof.get_extrinsics_to(cprof)
        baseline, bsrc = None, None
        if dsensor.supports(rs.option.stereo_baseline):
            baseline, bsrc = float(dsensor.get_option(rs.option.stereo_baseline)) / 1000.0, "device_option_stereo_baseline"
        else:
            baseline, bsrc = 0.050, "nominal_D435_spec_50mm"
        opts = {}
        for name in ("emitter_enabled", "laser_power", "enable_auto_exposure", "exposure", "gain", "visual_preset", "depth_units"):
            o = getattr(rs.option, name, None)
            try:
                if o is not None and dsensor.supports(o):
                    opts[name] = float(dsensor.get_option(o))
            except Exception:
                pass
        self.calib = Calibration(
            depth_scale_m=float(dsensor.get_depth_scale()),
            depth=_intr(dprof.get_intrinsics()), color=_intr(cprof.get_intrinsics()),
            depth_to_color=Extrinsics.from_sdk_column_major(ext.rotation, ext.translation),
            depth_fps=int(dprof.fps()), color_fps=int(cprof.fps()),
            stereo_baseline_m=baseline, baseline_source=bsrc,
            device={"name": _info(dev, rs.camera_info.name), "serial": _info(dev, rs.camera_info.serial_number),
                    "firmware": _info(dev, rs.camera_info.firmware_version),
                    "usb_type": _info(dev, rs.camera_info.usb_type_descriptor),
                    "product_line": _info(dev, rs.camera_info.product_line),
                    "sdk": sdk_status()},
            sensor_options=opts, source="sdk",
        )
        self._i = 0

    def get_calibration(self) -> Calibration:
        if self.calib is None:
            raise AdapterError("not open")
        return self.calib

    def read_frame(self, timeout_ms: int) -> Frame:
        if self.pipe is None:
            raise AdapterError("not open")
        if self._i == 0:
            timeout_ms = max(timeout_ms, 10000)  # the first frames after start can take seconds (auto-exposure, USB 2)
        try:
            ok, frames = self.pipe.try_wait_for_frames(timeout_ms)
        except RuntimeError as exc:
            raise DeviceLost(str(exc)) from exc
        if not ok:
            raise DeviceLost(f"no frames within {timeout_ms} ms (camera unplugged, USB reset or bandwidth problem)")
        d, c = frames.get_depth_frame(), frames.get_color_frame()
        depth = np.asanyarray(d.get_data()).copy() if d else None
        color = np.asanyarray(c.get_data()).copy() if c else None
        dom = None
        try:
            dom = str(d.get_frame_timestamp_domain()).split(".")[-1] if d else None
        except Exception:
            pass
        f = Frame(self._i, depth, color,
                  float(d.get_timestamp()) if d else None, float(c.get_timestamp()) if c else None, dom,
                  int(d.get_frame_number()) if d else None, int(c.get_frame_number()) if c else None, utc_now())
        self._i += 1
        return f

    def start_recording(self, session_id: str) -> None:
        pass

    def stop_recording(self) -> dict:
        return {}

    def close(self) -> None:
        if self.pipe is not None:
            try:
                self.pipe.stop()
            except Exception:
                pass
        self.pipe = None
