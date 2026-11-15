"""Loopback HTTP + WebSocket API used by the Flutter desktop app.

Security: binds 127.0.0.1 only; every request needs the per-launch token
(Authorization: Bearer <token>, or ?token= for WebSocket/image URLs); the Host
header must be loopback (blocks DNS-rebinding from web pages). There is no
endpoint reachable from other machines: phone control goes through BLE, scan
files through zip import.

Run:  python -m fieldstation.server [--port 0] [--fixtures] [--home DIR]
On start it prints one JSON line {"event":"ready","port":..,"token":..} on stdout.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import secrets
import socket
import sys
import threading
import time
from pathlib import Path

import numpy as np
from fastapi import Body, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response

from . import APP_NAME, APP_VERSION, PIPELINE_VERSION, PROTOCOL_VERSION, SCHEMA_VERSION
from .adapters import AdapterError, PROFILES, adapter_ids
from .adapters.base import Calibration
from .bundle import BundleError, DuplicateScan, ScanStore, default_home, load_depth_png
from .capture import CaptureController
from .metrics import (distance_measurement, plane_fit, protrusion_analysis, repeatability, roi_points_from_pixels,
                      roi_points_sphere, roughness_analysis)
from .ply import read_ply, rgb_of, xyz_of
from .protocol import DesktopLink, b64, unb64
from .schema import ENVELOPE

ADAPTER_LABELS = {
    "realsense": {"label": "Intel RealSense (D435)", "is_real_sensor": True},
    "replay": {"label": "Replay a saved scan (not live)", "is_real_sensor": False},
    "synthetic": {"label": "SYNTHETIC test scene (not a sensor)", "is_real_sensor": False},
}


class Service:
    def __init__(self, home: Path, fixtures: bool, token: str, use_process: bool = True):
        self.home = Path(home)
        self.token = token
        self.fixtures = fixtures
        self.store = ScanStore(self.home / "scans")
        self.ctl = CaptureController(self.store, use_process=use_process, fixtures=fixtures)
        did_file = self.home / "desktop_id"
        if not did_file.exists():
            did_file.write_text(secrets.token_hex(8))
        self.link = DesktopLink(f"{APP_NAME} {socket.gethostname().split('.')[0]}"[:28], did_file.read_text().strip(),
                                send_cb=self._ble_send, controller=self.ctl, on_event=lambda ev: self.ctl.emit(ev.pop("type"), **ev))
        self.ctl.add_listener(self._on_ctl_event)
        self._last_state_push = 0.0
        self._stop = threading.Event()
        threading.Thread(target=self._ticker, daemon=True).start()

    # BLE plumbing: outgoing chunks are emitted as events; the Flutter app forwards them to CoreBluetooth notify.
    def _ble_send(self, central: str, chunk: bytes) -> None:
        self.ctl.emit("ble_tx", central=central, data_b64=b64(chunk))

    def _on_ctl_event(self, ev: dict) -> None:
        t = ev.get("type")
        if t in ("recording_started", "recording_stopped"):
            self.link.broadcast("capture_state", **self.ctl.capture_state())
        elif t == "scan_processed":
            self.link.broadcast("capture_complete", scan_id=ev.get("scan_id"), keyframes=None, points=ev.get("points"), bytes=ev.get("bytes"))
            self.link.broadcast("capture_state", **self.ctl.capture_state())

    def _ticker(self) -> None:
        while not self._stop.wait(1.0):
            try:
                self.link.tick()
                if self.ctl.state == "recording":
                    self.link.broadcast("capture_state", **self.ctl.capture_state())
            except Exception:
                pass


def create_app(svc: Service) -> FastAPI:
    app = FastAPI(title=f"{APP_NAME} service", version=APP_VERSION)

    @app.middleware("http")
    async def guard(request: Request, call_next):
        host = (request.headers.get("host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", "testserver"):
            return JSONResponse({"detail": "loopback only"}, status_code=403)
        tok = request.headers.get("authorization", "").removeprefix("Bearer ").strip() or request.query_params.get("token", "")
        if not secrets.compare_digest(tok, svc.token):
            return JSONResponse({"detail": "missing or bad token"}, status_code=401)
        return await call_next(request)

    def err(status: int, msg: str):
        raise HTTPException(status_code=status, detail=msg)

    def scan_dir(scan_id: str) -> Path:
        try:
            return svc.store.dir_of(scan_id)
        except (KeyError, ValueError):
            err(404, f"no scan {scan_id}")

    # ---- health / devices -------------------------------------------------------------
    @app.get("/api/health")
    def health():
        from .adapters.realsense import sdk_status
        return {"ok": True, "app": APP_NAME, "version": APP_VERSION, "schema_version": SCHEMA_VERSION,
                "protocol_version": PROTOCOL_VERSION, "pipeline_version": PIPELINE_VERSION, "fixtures": svc.fixtures,
                "realsense_sdk": sdk_status(), "home": str(svc.home), "recovered_scans": svc.store.recovered,
                "scope": "sensor capture and local geometry only; planetary analog discovery lives on the website"}

    @app.get("/api/adapters")
    def adapters():
        return {"adapters": [{"adapter_id": a, **ADAPTER_LABELS[a]} for a in adapter_ids(svc.fixtures)],
                "profiles": {k: {"label": v["label"], "depth": v["depth"], "color": v["color"], "frames": v["frames"]} for k, v in PROFILES.items()}}

    @app.get("/api/adapters/{adapter_id}/devices")
    def devices(adapter_id: str):
        if adapter_id not in adapter_ids(svc.fixtures):
            err(404, "unknown adapter")
        return svc.ctl.discover(adapter_id)

    @app.post("/api/device/open")
    def device_open(body: dict = Body(...)):
        try:
            return svc.ctl.open(body["adapter_id"], body["device_id"], body.get("profile", "field_static"))
        except (AdapterError, KeyError) as exc:
            err(409, str(exc))

    @app.post("/api/device/close")
    def device_close():
        svc.ctl.close()
        return svc.ctl.status()

    @app.get("/api/status")
    def status():
        return svc.ctl.status()

    @app.get("/api/preview/{which}.jpg")
    def preview(which: str, max_w: int = 848):
        if which not in ("color", "depth"):
            err(404, "color or depth")
        r = svc.ctl.preview_jpeg(which, max_w)
        if r is None:
            return Response(status_code=204)
        idx, data = r
        return Response(data, media_type="image/jpeg", headers={"X-Frame-Index": str(idx), "Cache-Control": "no-store"})

    # ---- capture -----------------------------------------------------------------------
    @app.post("/api/capture/start")
    def capture_start(body: dict = Body(default={})):
        try:
            return svc.ctl.start_recording(title=body.get("title", ""), feature_type=body.get("feature_type", "other"),
                                           notes=body.get("notes", ""), session_id=body.get("session_id") or None,
                                           field_site_id=body.get("field_site_id") or None, candidate_id=body.get("candidate_id") or None,
                                           frames=body.get("frames"))
        except Exception as exc:
            err(409, str(exc))

    @app.post("/api/capture/stop")
    def capture_stop():
        try:
            return svc.ctl.stop_recording()
        except AdapterError as exc:
            err(409, str(exc))

    @app.post("/api/capture/cancel")
    def capture_cancel():
        try:
            return svc.ctl.cancel_recording()
        except AdapterError as exc:
            err(409, str(exc))

    # ---- library -----------------------------------------------------------------------
    @app.get("/api/scans")
    def scans():
        return {"scans": svc.store.list()}

    @app.get("/api/scans/{scan_id}")
    def scan(scan_id: str):
        d = scan_dir(scan_id)
        man = json.loads((d / ENVELOPE).read_text())
        metrics = json.loads((d / "metrics.json").read_text()) if (d / "metrics.json").exists() else None
        log = [json.loads(l) for l in (d / "log.jsonl").read_text().splitlines()[-200:] if l.strip()] if (d / "log.jsonl").exists() else []
        clouds = {}
        for k in ("filtered", "raw", "mesh"):
            try:
                clouds[k] = svc.store.cloud_file(scan_id, k).name
            except KeyError:
                pass
        draft = json.loads((d / "catalog_draft.json").read_text()) if (d / "catalog_draft.json").exists() else None
        depth_image = None
        if (d / "depth_filtered.png").exists():
            cal = json.loads((d / "calibration.json").read_text())
            depth_image = {"width": cal["depth_intrinsics"]["width"], "height": cal["depth_intrinsics"]["height"]}
        return {"manifest": man, "metrics": metrics, "log": log, "clouds": clouds, "catalog_draft": draft, "depth_image": depth_image}

    @app.patch("/api/scans/{scan_id}")
    def scan_update(scan_id: str, body: dict = Body(...)):
        scan_dir(scan_id)
        return svc.store.update_observation(scan_id, body)

    @app.post("/api/scans/{scan_id}/reprocess")
    def reprocess(scan_id: str, body: dict = Body(default={})):
        scan_dir(scan_id)
        try:
            return svc.store.process(scan_id, body.get("params") or {})
        except BundleError as exc:
            err(409, str(exc))

    @app.get("/api/scans/{scan_id}/file/{rel:path}")
    def scan_file(scan_id: str, rel: str):
        d = scan_dir(scan_id).resolve()
        p = (d / rel).resolve()
        if d not in p.parents or not p.is_file():
            err(404, "no such file")
        return FileResponse(p)

    @app.get("/api/scans/{scan_id}/cloud.bin")
    def cloud(scan_id: str, kind: str = "filtered", max_points: int = 150000):
        """Binary for the viewer: uint32 N | N*3 float32 xyz | N*3 uint8 rgb (little-endian).
        Deterministic decimation (every k-th point) for display only; source files are untouched."""
        scan_dir(scan_id)
        try:
            p = svc.store.cloud_file(scan_id, kind)
        except KeyError as exc:
            err(404, str(exc))
        verts, comments = read_ply(p)
        xyz = xyz_of(verts).astype(np.float32)
        rgb = rgb_of(verts)
        if rgb is None:
            rgb = np.full((len(xyz), 3), 170, np.uint8)
        total = len(xyz)
        step = max(1, int(np.ceil(total / max(1, max_points))))
        xyz, rgb = xyz[::step], rgb[::step]
        body = np.uint32(len(xyz)).tobytes() + xyz.astype("<f4").tobytes() + rgb.astype(np.uint8).tobytes()
        man = svc.store.manifest(scan_id)
        return Response(body, media_type="application/octet-stream", headers={
            "X-Points-Total": str(total), "X-Points-Sent": str(len(xyz)), "X-Decimation-Step": str(step),
            "X-Source-File": p.name, "X-Frame": (man.get("coordinate_frame") or {}).get("name", "unknown"),
            "X-Origin": man.get("origin", "")})

    def _depth_and_calib(scan_id: str):
        d = scan_dir(scan_id)
        if not (d / "depth_filtered.png").exists():
            err(409, "this scan has no organised depth image (imported scans: use a sphere ROI)")
        calib = Calibration.from_dict(json.loads((d / "calibration.json").read_text()))
        depth_m = load_depth_png(d / "depth_filtered.png").astype(np.float64) * calib.depth_scale_m
        return d, calib, depth_m

    def _points_for_roi(scan_id: str, roi: dict):
        man = svc.store.manifest(scan_id)
        frame = (man.get("coordinate_frame") or {}).get("name", "unknown")
        if roi.get("kind") == "pixel_rect":
            _, calib, depth_m = _depth_and_calib(scan_id)
            pts, _ = roi_points_from_pixels(depth_m, roi["rect_px"], calib.depth)
            return pts, "depth_filtered.png", frame
        if roi.get("kind") == "sphere":
            p = svc.store.cloud_file(scan_id, "filtered")
            pts = roi_points_sphere(xyz_of(read_ply(p)[0]), roi["center"], float(roi["radius_m"]))
            return pts, p.name, frame
        err(400, "roi.kind must be pixel_rect or sphere")

    @app.get("/api/scans/{scan_id}/depth_point")
    def depth_point(scan_id: str, u: float, v: float, half: int = 2):
        """3D point (camera_optical_m) at a depth pixel: median of valid filtered depth in a (2*half+1)^2 window."""
        _, calib, depth_m = _depth_and_calib(scan_id)
        h, w = depth_m.shape
        ui, vi = int(round(u)), int(round(v))
        win = depth_m[max(0, vi - half):vi + half + 1, max(0, ui - half):ui + half + 1]
        z = win[win > 0]
        if z.size == 0:
            return {"valid": False, "reason": "no valid depth at this pixel"}
        from .camera_model import deproject
        p = deproject(calib.depth, np.array([u]), np.array([v]), np.array([float(np.median(z))]))[0]
        return {"valid": True, "point_m": p.round(6).tolist(), "n_samples": int(z.size)}

    @app.get("/api/scans/{scan_id}/depth_figure.png")
    def depth_figure(scan_id: str):
        """Filtered depth coloured with viridis over its own 2nd-98th percentile; white = no depth. Display only.
        The range used is returned in headers so the app's colour bar matches the image exactly."""
        import io

        from PIL import Image

        from .bundle import depth_colormap, depth_figure_range
        _, _, depth_m = _depth_and_calib(scan_id)
        rng = depth_figure_range(depth_m)
        if rng is None:
            err(409, "no valid depth in this scan")
        lo, hi = rng
        buf = io.BytesIO()
        Image.fromarray(depth_colormap(depth_m, lo, hi)).save(buf, format="PNG", optimize=False)
        return Response(buf.getvalue(), media_type="image/png", headers={
            "X-Range-Lo-M": f"{lo:.4f}", "X-Range-Hi-M": f"{hi:.4f}",
            "X-Valid-Fraction": f"{float((depth_m > 0).mean()):.4f}", "Cache-Control": "no-store"})

    def _gravity(scan_id: str):
        man = svc.store.manifest(scan_id)
        cf = man.get("coordinate_frame") or {}
        if cf.get("name") == "arkit_session_world":
            return [0.0, 1.0, 0.0]
        return None

    @app.post("/api/scans/{scan_id}/analyze")
    def analyze(scan_id: str, body: dict = Body(...)):
        scan_dir(scan_id)
        kind = body.get("kind")
        label = str(body.get("label") or "")
        try:
            if kind == "roughness":
                roi = body["roi"]
                pts, src, frame = _points_for_roi(scan_id, roi)
                noise = None
                if roi["kind"] == "pixel_rect":
                    _, calib, _ = _depth_and_calib(scan_id)
                    if calib.stereo_baseline_m:
                        noise = {"fx_px": calib.depth.fx, "baseline_m": calib.stereo_baseline_m}
                res = roughness_analysis(pts, roi, robust=bool(body.get("robust")), noise_model=noise, source_artifact=src,
                                         frame=frame, gravity_up=_gravity(scan_id), label=label)
            elif kind == "protrusion":
                opts, src, frame = _points_for_roi(scan_id, body["roi"])
                rpts, _, _ = _points_for_roi(scan_id, body["reference_roi"])
                res = protrusion_analysis(opts, rpts, body["roi"], body["reference_roi"], source_artifact=src, frame=frame, label=label)
            elif kind == "distance":
                man = svc.store.manifest(scan_id)
                res = {"status": "measured", "measurements": [distance_measurement(
                    body["p1"], body["p2"], source_artifact=body.get("source_artifact", ""),
                    frame=(man.get("coordinate_frame") or {}).get("name", "unknown"), label=label, note=body.get("note", ""))]}
            else:
                err(400, "kind must be roughness, protrusion or distance")
        except KeyError as exc:
            err(400, f"missing {exc}")
        if res.get("status") == "not_measured":
            return {"saved": False, **res}
        saved = svc.store.add_analysis(scan_id, {"kind": kind, "request": body, **res})
        return {"saved": True, **saved}

    @app.post("/api/repeatability")
    def repeat(body: dict = Body(...)):
        """Apply ONE roi to several scans (e.g. repeated stationary captures) and summarise the spread."""
        ids = body.get("scan_ids") or []
        roi = body.get("roi")
        if len(ids) < 2 or not roi:
            err(400, "need scan_ids (>=2) and roi")
        rows = []
        for sid in ids:
            scan_dir(sid)
            try:
                pts, _, frame = _points_for_roi(sid, roi)
            except HTTPException as exc:
                rows.append({"scan_id": sid, "error": exc.detail})
                continue
            if len(pts) < 50:
                rows.append({"scan_id": sid, "error": "too few points in roi"})
                continue
            f = plane_fit(pts, robust=bool(body.get("robust")))
            rows.append({"scan_id": sid, "n_points": f["n_points"], "rms_orthogonal_m": f["rms_orthogonal_m"],
                         "median_range_m": float(np.median(np.linalg.norm(pts, axis=1))),
                         "extent_major_m": f["extent_major_m"], "extent_minor_m": f["extent_minor_m"]})
        ok = [r for r in rows if "error" not in r]
        okids = [r["scan_id"] for r in ok]
        return {"roi": roi, "rows": rows, "summary": {
            k: repeatability([r[k] for r in ok], okids, k) for k in ("rms_orthogonal_m", "median_range_m", "extent_major_m", "n_points")},
            "note": "same ROI applied to each scan; spread is empirical repeatability at these settings, not accuracy"}

    @app.post("/api/scans/{scan_id}/export")
    def export(scan_id: str):
        scan_dir(scan_id)
        p = svc.store.export_zip(scan_id)
        return {"path": str(p), "bytes": p.stat().st_size}

    @app.post("/api/import")
    def import_(body: dict = Body(...)):
        p = Path(str(body.get("path", ""))).expanduser()
        if not p.is_file():
            err(400, "path is not a file")
        try:
            if p.suffix.lower() == ".zip":
                man = svc.store.import_zip(p)
            elif p.suffix.lower() == ".ply":
                man = svc.store.import_ply(p, body.get("title", ""))
            else:
                err(400, "import a scan bundle .zip or a .ply")
        except DuplicateScan as exc:
            err(409, str(exc))
        except (BundleError, ValueError) as exc:
            err(422, str(exc))
        svc.ctl.emit("scan_imported", scan_id=man["scan_id"], origin=man.get("origin"))
        return {"scan_id": man["scan_id"], "origin": man.get("origin"), "status": man.get("status")}

    @app.post("/api/scans/{scan_id}/catalog_draft")
    def catalog_draft(scan_id: str, body: dict = Body(default={})):
        scan_dir(scan_id)
        return svc.store.write_catalog_draft(scan_id, body)

    # ---- BLE (the Flutter runner owns the radio; this owns the protocol) -------------------------
    @app.get("/api/ble/info")
    def ble_info():
        info = svc.link.info()
        return {"info": info, "info_b64": b64(json.dumps(info, separators=(",", ":")).encode())}

    @app.post("/api/ble/pairing/open")
    def ble_pair_open():
        return svc.link.open_pairing()

    @app.post("/api/ble/pairing/close")
    def ble_pair_close():
        svc.link.close_pairing()
        return svc.link.pairing_status()

    @app.get("/api/ble/status")
    def ble_status():
        return svc.link.pairing_status()

    @app.post("/api/ble/rx")
    def ble_rx(body: dict = Body(...)):
        try:
            data = unb64(body["data_b64"])
        except Exception:
            err(400, "data_b64")
        svc.link.on_rx(str(body["central"]), data, int(body.get("max_chunk", 182)))
        return {"ok": True}

    @app.post("/api/ble/disconnected")
    def ble_disc(body: dict = Body(...)):
        svc.link.on_disconnect(str(body["central"]))
        return {"ok": True}

    @app.post("/api/ble/send")
    def ble_send(body: dict = Body(...)):
        t = body.get("type")
        if t not in ("start_capture", "stop_capture", "capture_now"):
            err(400, "type")
        try:
            msg = svc.link.send(str(body["central"]), t, target="phone",
                                **({"sensor_id": "iphone:arkit", "profile": body.get("profile", "default")} if t == "start_capture" else {}))
        except PermissionError as exc:
            err(409, str(exc))
        return {"sent": msg}

    # ---- events --------------------------------------------------------------------------
    @app.websocket("/ws/events")
    async def events(ws: WebSocket):
        host = (ws.headers.get("host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", "testserver") or not secrets.compare_digest(ws.query_params.get("token", ""), svc.token):
            await ws.close(code=4401)
            return
        await ws.accept()
        q: asyncio.Queue = asyncio.Queue(maxsize=2000)
        loop = asyncio.get_running_loop()

        def cb(ev):
            try:
                loop.call_soon_threadsafe(q.put_nowait, ev)
            except Exception:
                pass
        svc.ctl.add_listener(cb)
        try:
            await ws.send_json({"type": "status", **svc.ctl.status()})
            last = time.monotonic()
            while True:
                try:
                    ev = await asyncio.wait_for(q.get(), timeout=0.5)
                    await ws.send_json(ev)
                except asyncio.TimeoutError:
                    pass
                if time.monotonic() - last > 0.5:
                    last = time.monotonic()
                    await ws.send_json({"type": "status", **svc.ctl.status()})
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            try:
                svc.ctl._listeners.remove(cb)
            except ValueError:
                pass

    return app


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=f"{APP_NAME} local service")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--home", type=Path, default=None)
    ap.add_argument("--fixtures", action="store_true", default=os.environ.get("FIELDSTATION_FIXTURES") == "1")
    ap.add_argument("--token", default=os.environ.get("FIELDSTATION_TOKEN"))
    ap.add_argument("--exit-with-stdin", action="store_true",
                    help="shut down when stdin reaches EOF, i.e. when the app that started this service quits or crashes")
    args = ap.parse_args(argv)
    import uvicorn
    home = args.home or default_home()
    home.mkdir(parents=True, exist_ok=True)
    token = args.token or secrets.token_urlsafe(24)
    svc = Service(home, args.fixtures, token)
    app = create_app(svc)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if sys.platform == "win32":
        # On Windows SO_REUSEADDR lets a second process bind a port that is already in use (and lets others
        # bind ours). Exclusive use makes a busy --port fail loudly instead of silently sharing it.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", args.port))
    port = sock.getsockname()[1]
    print(json.dumps({"event": "ready", "port": port, "token": token, "home": str(home), "fixtures": args.fixtures}), flush=True)
    config = uvicorn.Config(app, log_level="warning", log_config=None, ws_ping_interval=20, timeout_graceful_shutdown=3)
    server = uvicorn.Server(config)
    if args.exit_with_stdin:
        # The app keeps our stdin open for its whole life. EOF means it is gone (quit, crash or force-kill),
        # so stop instead of lingering as an orphan that still holds the camera.
        def _watch_parent() -> None:
            try:
                while sys.stdin.buffer.read(4096):
                    pass
            except (OSError, ValueError):
                pass
            server.should_exit = True
            last_resort = threading.Timer(10.0, lambda: os._exit(0))  # if graceful shutdown hangs
            last_resort.daemon = True
            last_resort.start()

        threading.Thread(target=_watch_parent, name="parent-watch", daemon=True).start()
    try:
        server.run(sockets=[sock])
    finally:
        svc.ctl.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
