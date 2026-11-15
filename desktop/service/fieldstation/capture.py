"""Capture controller: owns the sensor worker and the recorder.

The sensor adapter runs in its own process (multiprocessing 'spawn'), so a
USB failure or SDK crash cannot take down the service or the UI. Tests can
use the same loop in a thread (use_process=False).

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import io
import multiprocessing as mp
import os
import queue
import threading
import time
import traceback
from pathlib import Path

import numpy as np
from PIL import Image

from .adapters import AdapterError, Calibration, DeviceLost, PROFILES, make_adapter
from .adapters.base import utc_now
from .bundle import BundleError, ScanStore, depth_colormap


# ----------------------------------------------------------------------------- worker side
def _worker_loop(adapter_id: str, store_root: str | None, device_id: str, config: dict, cmd_q, out_q) -> None:
    try:
        adapter = make_adapter(adapter_id, Path(store_root) if store_root else None)
        adapter.open(device_id, config)
        out_q.put(("opened", {"calibration": adapter.get_calibration().to_dict(), "origin": adapter.origin,
                              "is_real_sensor": adapter.is_real_sensor, "label": adapter.label,
                              "replay_of": getattr(adapter, "source_manifest", None) and {
                                  "scan_id": adapter.source_manifest.get("scan_id"), "origin": adapter.source_manifest.get("origin")}}))
    except Exception as exc:
        out_q.put(("error", {"kind": "open_failed", "message": f"{type(exc).__name__}: {exc}"}))
        return
    paced = not adapter.is_real_sensor
    period = 1.0 / max(1, config.get("pace_fps") or adapter.get_calibration().depth_fps)
    dropped = 0
    try:
        while True:
            try:
                cmd = cmd_q.get_nowait()
            except queue.Empty:
                cmd = None
            if cmd == "close":
                break
            t0 = time.monotonic()
            try:
                fr = adapter.read_frame(3000)
            except DeviceLost as exc:
                out_q.put(("device_lost", {"message": str(exc)}))
                return
            except Exception as exc:
                out_q.put(("error", {"kind": "read_failed", "message": f"{type(exc).__name__}: {exc}"}))
                return
            try:
                out_q.put_nowait(("frame", fr))
            except queue.Full:
                dropped += 1
            if paced:
                time.sleep(max(0.0, period - (time.monotonic() - t0)))
    finally:
        try:
            adapter.close()
        except Exception:
            pass
        try:
            out_q.put(("closed", {"dropped_in_transport": dropped}))
        except Exception:
            pass


def _discover_worker(adapter_id: str, store_root: str | None, out_q) -> None:
    try:
        a = make_adapter(adapter_id, Path(store_root) if store_root else None)
        out_q.put(("ok", a.discover()))
    except AdapterError as exc:
        out_q.put(("error", str(exc)))
    except Exception as exc:
        out_q.put(("error", f"{type(exc).__name__}: {exc}"))
    # Deliver the answer, then leave without running destructors: after a failed open, librealsense on macOS
    # segfaults while freeing its device objects, which used to lose the result.
    out_q.close()
    out_q.join_thread()
    os._exit(0)


# ----------------------------------------------------------------------------- service side
REENUM_S = 3.0        # how long a RealSense camera takes to come back on USB after being released (macOS, root)
OPEN_ATTEMPTS = 3
_RETRYABLE = ("power state", "already opened", "no device connected", "resolve the request", "crashed", "did not open")


def _retryable(error: dict | None, exc: Exception) -> bool:
    text = f"{(error or {}).get('message', '')} {exc}".lower()
    return any(k in text for k in _RETRYABLE)


class CaptureController:
    def __init__(self, store: ScanStore, use_process: bool = True, fixtures: bool = False):
        self.store = store
        self.use_process = use_process
        self.fixtures = fixtures
        self.ctx = mp.get_context("spawn")
        self.state = "idle"
        self.error: dict | None = None
        self.adapter_id = None
        self.device_id = None
        self.profile = None
        self.origin = None
        self.is_real_sensor = False
        self.replay_of = None
        self.calib: Calibration | None = None
        self._proc = None
        self._cmd_q = None
        self._out_q = None
        self._consumer = None
        self._real_released = -1e9  # time.monotonic() when a RealSense camera was last released (see open)
        self._lock = threading.RLock()
        self.latest = None
        self.frame_times: list[float] = []
        self.writer = None
        self.rec_target = 0
        self.rec_started_mono = 0.0
        self.last_scan_id = None
        self.events: list[dict] = []
        self._ev_seq = 0
        self._listeners = []
        self._jpeg_cache = {}

    # -- events
    def emit(self, type_: str, **data) -> None:
        with self._lock:
            self._ev_seq += 1
            ev = {"seq": self._ev_seq, "t_utc": utc_now(), "type": type_, **data}
            self.events.append(ev)
            self.events = self.events[-500:]
            listeners = list(self._listeners)
        for cb in listeners:
            try:
                cb(ev)
            except Exception:
                pass

    def add_listener(self, cb) -> None:
        self._listeners.append(cb)

    # -- discovery (always in a child process for real sensors: SDK enumeration can stall or crash)
    def discover(self, adapter_id: str, timeout_s: float = 15.0) -> dict:
        if adapter_id == "synthetic" and not self.fixtures:
            return {"adapter_id": adapter_id, "devices": [], "error": "fixtures are disabled"}
        if adapter_id == "realsense" and self.adapter_id == "realsense" and self._proc is not None and self.state != "error":
            # Probing from a second process makes librealsense claim and release the camera, which on macOS resets it
            # on USB and stops the open stream ("no frames within 3000 ms"). Report the open camera instead.
            dev = dict((self.calib.device if self.calib else None) or {})
            usb = dev.get("usb_type")
            return {"adapter_id": adapter_id, "error": None, "devices": [{
                "device_id": self.device_id, "name": dev.get("name"), "serial": dev.get("serial"),
                "firmware": dev.get("firmware"), "usb_type": usb, "product_line": dev.get("product_line"),
                "is_real_sensor": True, "note": "Open now (not re-probed: that would interrupt the stream).",
                **({"recommended_profile": "usb2_fallback"} if usb and not str(usb).startswith("3") else {})}]}
        if not self.use_process or adapter_id != "realsense":
            try:
                return {"adapter_id": adapter_id, "devices": make_adapter(adapter_id, self.store.root).discover(), "error": None}
            except Exception as exc:
                return {"adapter_id": adapter_id, "devices": [], "error": f"{type(exc).__name__}: {exc}"}
        q = self.ctx.Queue()
        p = self.ctx.Process(target=_discover_worker, args=(adapter_id, str(self.store.root), q), daemon=True)
        p.start()
        try:
            kind, payload = q.get(timeout=timeout_s)
        except queue.Empty:
            p.kill()
            return {"adapter_id": adapter_id, "devices": [], "error": f"device enumeration did not finish within {timeout_s:.0f} s"}
        finally:
            p.join(timeout=2)
        return {"adapter_id": adapter_id, "devices": payload if kind == "ok" else [], "error": None if kind == "ok" else payload}

    # -- open / close
    def open(self, adapter_id: str, device_id: str, profile: str = "field_static", timeout_s: float = 20.0) -> dict:
        if adapter_id == "synthetic" and not self.fixtures:
            raise AdapterError("synthetic fixtures are disabled (start the service with --fixtures)")
        if profile not in PROFILES:
            raise AdapterError(f"unknown profile {profile}")
        was_real = self._proc is not None and self.adapter_id == "realsense"
        self.close()
        if adapter_id != "realsense":
            return self._open_once(adapter_id, device_id, profile, timeout_s)
        # RealSense on macOS as root: libusb hands the camera back to the system by re-enumerating it on USB whenever
        # librealsense releases it, so for a few seconds after a close (or a crashed worker) an open can fail with
        # "failed to set power state" / "UVC device is already opened" / a driver crash. Wait, then retry.
        if was_real or time.monotonic() - self._real_released < REENUM_S:
            time.sleep(max(0.0, REENUM_S - (time.monotonic() - self._real_released)))
        for attempt in range(1, OPEN_ATTEMPTS + 1):
            try:
                return self._open_once(adapter_id, device_id, profile, timeout_s)
            except AdapterError as exc:
                self._real_released = time.monotonic()
                if attempt == OPEN_ATTEMPTS or not _retryable(self.error, exc):
                    raise
                self.emit("device_retry", attempt=attempt, of=OPEN_ATTEMPTS, reason=str(exc)[:300])
                time.sleep(REENUM_S)
        raise AdapterError("unreachable")

    def _open_once(self, adapter_id: str, device_id: str, profile: str, timeout_s: float) -> dict:
        with self._lock:
            self.state = "opening"
            self.error = None
            self.adapter_id, self.device_id, self.profile = adapter_id, device_id, profile
        cfg = {"profile": profile}
        if self.use_process:
            self._cmd_q, self._out_q = self.ctx.Queue(), self.ctx.Queue(maxsize=6)
            self._proc = self.ctx.Process(target=_worker_loop, args=(adapter_id, str(self.store.root), device_id, cfg, self._cmd_q, self._out_q), daemon=True)
            self._proc.start()
        else:
            self._cmd_q, self._out_q = queue.Queue(), queue.Queue(maxsize=6)
            self._proc = threading.Thread(target=_worker_loop, args=(adapter_id, str(self.store.root), device_id, cfg, self._cmd_q, self._out_q), daemon=True)
            self._proc.start()
        kind = payload = None
        deadline = time.monotonic() + timeout_s
        while kind is None:
            try:
                kind, payload = self._out_q.get(timeout=0.5)
            except queue.Empty:
                code = getattr(self._proc, "exitcode", None)  # a worker process that died without answering
                if code is not None or time.monotonic() > deadline:
                    self._kill_worker()
                    self.state = "error"
                    if code is not None:
                        self.error = {"kind": "worker_crashed", "message":
                                      f"the camera driver crashed while opening the sensor (worker exit code {code}). "
                                      "Select Open again; if it keeps happening, unplug the camera for 10 s."}
                    else:
                        self.error = {"kind": "open_timeout", "message": f"sensor did not open within {timeout_s:.0f} s"}
                    self.emit("device_error", **self.error)
                    raise AdapterError(self.error["message"])
        if kind != "opened":
            self._kill_worker()
            self.state = "error"
            self.error = payload
            self.emit("device_error", **payload)
            raise AdapterError(payload.get("message", "open failed"))
        with self._lock:
            self.calib = Calibration.from_dict(payload["calibration"])
            self.origin = payload["origin"]
            self.is_real_sensor = payload["is_real_sensor"]
            self.replay_of = payload.get("replay_of")
            self.state = "streaming"
            self.frame_times = []
            self.latest = None
        self._consumer = threading.Thread(target=self._consume, daemon=True)
        self._consumer.start()
        self.emit("device_opened", adapter_id=adapter_id, device_id=device_id, profile=profile, origin=self.origin,
                  is_real_sensor=self.is_real_sensor)
        return self.status()

    def _kill_worker(self) -> None:
        p = self._proc
        self._proc = None
        if p is None:
            return
        if isinstance(p, threading.Thread):
            p.join(timeout=3)
        else:
            p.join(timeout=3)
            if p.is_alive():
                p.kill()
                p.join(timeout=2)

    def close(self) -> None:
        with self._lock:
            if self.writer is not None:
                self._stop_recording_locked("device_closed_by_user", ok=self.writer.n > 0)
            proc = self._proc
        if proc is not None:
            try:
                self._cmd_q.put("close")
            except Exception:
                pass
            self._kill_worker()
            if self.adapter_id == "realsense":
                self._real_released = time.monotonic()
            if self._consumer is not None:
                self._consumer.join(timeout=3)
        with self._lock:
            if self.state not in ("error",):
                self.state = "idle"
            self.latest = None
            self._consumer = None

    # -- frame consumption
    def _consume(self) -> None:
        out_q = self._out_q
        proc = self._proc
        while True:
            try:
                kind, payload = out_q.get(timeout=0.5)
            except queue.Empty:
                alive = proc.is_alive() if proc is not None else False
                if not alive:
                    if self.state in ("streaming", "recording"):
                        self._on_lost({"message": "sensor worker exited unexpectedly"})
                    return
                continue
            except (EOFError, OSError):
                return
            if kind == "frame":
                self._on_frame(payload)
            elif kind == "device_lost":
                self._on_lost(payload)
                return
            elif kind == "error":
                self._on_lost({"message": payload.get("message"), "kind": payload.get("kind")})
                return
            elif kind == "closed":
                return

    def _on_frame(self, fr) -> None:
        now = time.monotonic()
        stop_reason = None
        with self._lock:
            self.latest = fr
            self.frame_times.append(now)
            self.frame_times = [t for t in self.frame_times if now - t < 2.0]
            w = self.writer
        if w is not None:
            try:
                w.write_frame(fr)
            except Exception as exc:
                self.emit("recording_error", message=str(exc))
                stop_reason = ("write_error: " + str(exc), False)
            else:
                if w.n >= self.rec_target:
                    stop_reason = ("frames_requested_reached", True)
                if w.n % 5 == 0 or stop_reason:
                    self.emit("capture_state", **self.capture_state())
        if stop_reason:
            with self._lock:
                if self.writer is w:
                    self._stop_recording_locked(*stop_reason)

    def _on_lost(self, info: dict) -> None:
        with self._lock:
            self.error = {"kind": info.get("kind") or "device_lost", "message": info.get("message")}
            if self.writer is not None:
                self._stop_recording_locked("device_lost: " + str(info.get("message")), ok=False)
            self.state = "error"
            self.latest = None
            if self.adapter_id == "realsense":
                self._real_released = time.monotonic()
        self.emit("device_lost", **self.error)

    # -- recording
    def start_recording(self, *, title: str = "", feature_type: str = "other", notes: str = "", session_id: str | None = None,
                        field_site_id: str | None = None, candidate_id: str | None = None, frames: int | None = None,
                        started_by: str = "desktop_user") -> dict:
        with self._lock:
            if self.state != "streaming" or self.calib is None:
                raise AdapterError(f"cannot record while {self.state}; open a sensor first")
            if self.writer is not None:
                raise AdapterError("already recording")
            n = int(frames or PROFILES[self.profile]["frames"])
            if not 1 <= n <= 300:
                raise AdapterError("frames must be between 1 and 300")
            self.writer = self.store.new_writer(
                self.calib, origin=self.origin, is_real_sensor=self.is_real_sensor, device=self.calib.device,
                profile=self.profile, frames_requested=n, title=title, feature_type=feature_type, notes=notes,
                session_id=session_id, field_site_id=field_site_id, candidate_id=candidate_id, started_by=started_by,
                replay_of=self.replay_of)
            self.rec_target = n
            self.rec_started_mono = time.monotonic()
            self.state = "recording"
            sid = self.writer.m["scan_id"]
        self.emit("recording_started", scan_id=sid, frames_requested=n, started_by=started_by)
        return {"scan_id": sid, "session_id": self.writer.m["session_id"], "frames_requested": n}

    def stop_recording(self, reason: str = "stopped_by_user") -> dict:
        with self._lock:
            if self.writer is None:
                raise AdapterError("not recording")
            return self._stop_recording_locked(reason, ok=self.writer.n > 0)

    def cancel_recording(self) -> dict:
        return self.stop_recording("cancelled_by_user")

    def _stop_recording_locked(self, reason: str, ok: bool) -> dict:
        w = self.writer
        self.writer = None
        if reason == "cancelled_by_user":
            ok = False
        w.finish(reason, ok)
        sid = w.m["scan_id"]
        self.last_scan_id = sid
        if self.state == "recording":
            self.state = "processing" if ok else "streaming"
        n = w.n
        self.emit("recording_stopped", scan_id=sid, frames=n, reason=reason, ok=ok)
        if n > 0:
            threading.Thread(target=self._process_bg, args=(sid, ok), daemon=True).start()
        elif self.state == "processing":
            self.state = "streaming"
        return {"scan_id": sid, "frames": n, "reason": reason, "ok": ok}

    def _process_bg(self, scan_id: str, ok: bool) -> None:
        try:
            man = self.store.process(scan_id)
            self.emit("scan_processed", scan_id=scan_id, status=man["status"],
                      points=man["quality"].get("filtered_point_cloud_points"), bytes=sum(f["bytes"] for f in man["files"]))
        except (BundleError, Exception) as exc:
            self.emit("processing_error", scan_id=scan_id, message=f"{type(exc).__name__}: {exc}", trace=traceback.format_exc()[-800:])
        finally:
            with self._lock:
                if self.state == "processing":
                    self.state = "streaming"

    # -- status / preview
    def capture_state(self) -> dict:
        with self._lock:
            w = self.writer
            st = {"idle": "idle", "opening": "idle", "streaming": "idle", "recording": "recording",
                  "processing": "saving", "error": "error"}[self.state]
            return {"state": st, "elapsed_ms": int((time.monotonic() - self.rec_started_mono) * 1000) if w else 0,
                    "frames_recorded": w.n if w else 0, "frames_requested": self.rec_target if w else 0,
                    "scan_id": w.m["scan_id"] if w else self.last_scan_id}

    def status(self) -> dict:
        with self._lock:
            fps = (len(self.frame_times) - 1) / (self.frame_times[-1] - self.frame_times[0]) if len(self.frame_times) > 2 else None
            q = self.preview_stats()
            return {
                "state": self.state, "error": self.error, "adapter_id": self.adapter_id, "device_id": self.device_id,
                "profile": self.profile, "origin": self.origin, "is_real_sensor": self.is_real_sensor,
                "device": self.calib.device if self.calib else None,
                "calibration_summary": {
                    "depth": f"{self.calib.depth.width}x{self.calib.depth.height} @ {self.calib.depth_fps} fps",
                    "color": f"{self.calib.color.width}x{self.calib.color.height} @ {self.calib.color_fps} fps" if self.calib.color else None,
                    "depth_scale_m": self.calib.depth_scale_m, "stereo_baseline_m": self.calib.stereo_baseline_m,
                    "baseline_source": self.calib.baseline_source} if self.calib else None,
                "measured_fps": round(fps, 1) if fps else None, "live": q, "capture": self.capture_state(),
            }

    def preview_stats(self) -> dict | None:
        fr = self.latest
        if fr is None or fr.depth is None or self.calib is None:
            return None
        d = fr.depth
        sub = d[::4, ::4]
        v = sub > 0
        z = sub[v].astype(np.float64) * self.calib.depth_scale_m
        return {"frame_index": fr.index, "depth_valid_fraction": round(float(v.mean()), 4),
                "range_median_m": round(float(np.median(z)), 3) if z.size else None,
                "range_p05_m": round(float(np.percentile(z, 5)), 3) if z.size else None,
                "range_p95_m": round(float(np.percentile(z, 95)), 3) if z.size else None,
                "too_close_fraction": round(float((z < 0.28).mean()), 4) if z.size else None,
                "note": "computed on every 4th pixel of the latest frame, for live guidance only"}

    def preview_jpeg(self, which: str, max_w: int = 848) -> tuple[int, bytes] | None:
        fr = self.latest
        if fr is None:
            return None
        key = (which, fr.index, max_w)
        if key in self._jpeg_cache:
            return fr.index, self._jpeg_cache[key]
        if which == "color":
            if fr.color is None:
                return None
            img = Image.fromarray(fr.color)
        else:
            img = Image.fromarray(depth_colormap(fr.depth.astype(np.float64) * self.calib.depth_scale_m))
        if img.width > max_w:
            img = img.resize((max_w, int(img.height * max_w / img.width)))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=80)
        data = buf.getvalue()
        self._jpeg_cache = {k: v for k, v in self._jpeg_cache.items() if k[1] >= fr.index - 2}
        self._jpeg_cache[key] = data
        return fr.index, data
