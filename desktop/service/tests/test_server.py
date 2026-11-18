"""Local API: auth, host check, capture -> analyse -> export through HTTP, cloud.bin format, scope.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import struct
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from fieldstation.server import Service, create_app

from conftest import wait_for

TOKEN = "t0ken"


@pytest.fixture
def client(tmp_path):
    svc = Service(tmp_path / "home", fixtures=True, token=TOKEN, use_process=False)
    c = TestClient(create_app(svc))
    c.headers["Authorization"] = f"Bearer {TOKEN}"
    yield c, svc
    svc.ctl.close()
    svc._stop.set()


def test_auth_and_host(client):
    c, _ = client
    assert TestClient(c.app).get("/api/health").status_code == 401
    assert c.get("/api/health", headers={"host": "evil.example"}).status_code == 403
    h = c.get("/api/health").json()
    assert h["ok"] and "website" in h["scope"]


def test_full_flow_over_http(client, tmp_path):
    c, svc = client
    assert c.get("/api/adapters/synthetic/devices").json()["devices"]
    assert c.post("/api/device/open", json={"adapter_id": "synthetic", "device_id": "synthetic:scene-v1"}).json()["state"] == "streaming"
    wait_for(lambda: c.get("/api/preview/color.jpg").status_code == 200)
    r = c.post("/api/capture/start", json={"title": "http flow", "feature_type": "boulder", "frames": 5}).json()
    sid = r["scan_id"]
    wait_for(lambda: c.get(f"/api/scans/{sid}").json()["manifest"]["status"] == "complete")
    detail = c.get(f"/api/scans/{sid}").json()
    assert detail["clouds"]["filtered"] == "point_cloud_filtered.ply" and detail["depth_image"]["width"] == 848
    # cloud.bin
    b = c.get(f"/api/scans/{sid}/cloud.bin", params={"max_points": 1000})
    n = struct.unpack("<I", b.content[:4])[0]
    assert len(b.content) == 4 + n * 12 + n * 3 and b.headers["x-origin"] == "synthetic_fixture"
    xyz = np.frombuffer(b.content[4:4 + n * 12], "<f4").reshape(-1, 3)
    assert 0.5 < np.median(xyz[:, 2]) < 2.0
    # analyses
    rough = c.post(f"/api/scans/{sid}/analyze", json={"kind": "roughness", "roi": {"kind": "pixel_rect", "rect_px": [500, 200, 560, 260]}}).json()
    assert rough["saved"] and rough["measurements"][0]["name"] == "plane_fit_roughness"
    p = c.get(f"/api/scans/{sid}/depth_point", params={"u": 424, "v": 240}).json()
    q = c.get(f"/api/scans/{sid}/depth_point", params={"u": 470, "v": 240}).json()
    dist = c.post(f"/api/scans/{sid}/analyze", json={"kind": "distance", "p1": p["point_m"], "p2": q["point_m"]}).json()
    assert dist["measurements"][0]["unit"] == "m"
    sph = c.post(f"/api/scans/{sid}/analyze", json={"kind": "roughness", "roi": {"kind": "sphere", "center": p["point_m"], "radius_m": 0.1}}).json()
    assert sph["saved"]
    # depth figure: viridis over the scan's own percentile range, range reported in headers
    import io

    from PIL import Image
    fig = c.get(f"/api/scans/{sid}/depth_figure.png")
    assert fig.status_code == 200 and fig.headers["content-type"] == "image/png"
    lo, hi = float(fig.headers["x-range-lo-m"]), float(fig.headers["x-range-hi-m"])
    assert 0.3 < lo < hi < 3.0
    assert Image.open(io.BytesIO(fig.content)).size == (848, 480)
    # path traversal on the file endpoint
    assert c.get(f"/api/scans/{sid}/file/../../desktop_id").status_code == 404
    # repeatability over two scans of the same session
    r2 = c.post("/api/capture/start", json={"frames": 5, "session_id": detail["manifest"]["session_id"]}).json()
    wait_for(lambda: c.get(f"/api/scans/{r2['scan_id']}").json()["manifest"]["status"] == "complete")
    rep = c.post("/api/repeatability", json={"scan_ids": [sid, r2["scan_id"]], "roi": {"kind": "pixel_rect", "rect_px": [500, 200, 560, 260]}}).json()
    assert rep["summary"]["rms_orthogonal_m"]["n"] == 2
    # export -> import into the same store is a duplicate
    zp = c.post(f"/api/scans/{sid}/export").json()["path"]
    assert c.post("/api/import", json={"path": zp}).status_code == 409


def test_scope_no_analog_discovery_in_desktop():
    """The desktop must not contain or import the website's planetary analog discovery engine."""
    root = Path(__file__).resolve().parents[1] / "fieldstation"
    banned = ["wasserstein", "pareto", "glim", "copernicus", "lola", "analog_score", "match_percent", "terrain_engine", "geo_v2"]
    for py in root.rglob("*.py"):
        src = py.read_text().lower()
        code = "\n".join(l for l in src.splitlines() if not l.strip().startswith("#"))
        for b in banned:
            assert f"import {b}" not in code and f"def {b}" not in code, f"{py.name}: {b}"
        assert "from engine" not in code and "import engine" not in code



def test_depth_colormap_is_viridis_with_white_holes():
    """Near end is viridis purple, far end yellow, pixels without depth are white."""
    from fieldstation.bundle import depth_colormap, viridis
    rgb = depth_colormap(np.array([[0.2, 4.0, 0.0]]))
    assert tuple(rgb[0, 0]) == tuple((viridis(np.array(0.0)) * 255).round().astype(int))
    assert rgb[0, 1, 0] > 200 and rgb[0, 1, 2] < 80
    assert tuple(rgb[0, 2]) == (255, 255, 255)


def test_parent_watch_fires_only_after_the_parent_exits():
    """--parent-pid: the service notices when the app that started it is gone (quit, crash, force-kill)."""
    import subprocess
    import sys
    import threading
    import time

    from fieldstation.server import _watch_process
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(2)"])
    gone = threading.Event()
    threading.Thread(target=_watch_process, args=(child.pid, gone.set, 0.1), daemon=True).start()
    assert not gone.wait(0.8), "fired while the watched process was still running"
    child.wait(10)
    assert gone.wait(5), "did not fire after the watched process exited"


def test_shutdown_releases_the_sensor(tmp_path):
    """The camera worker is stopped during the server's own shutdown, not only in main()'s finally."""
    svc = Service(tmp_path / "home", fixtures=True, token=TOKEN, use_process=False)
    with TestClient(create_app(svc)) as c:
        c.headers["Authorization"] = f"Bearer {TOKEN}"
        assert c.post("/api/device/open", json={"adapter_id": "synthetic", "device_id": "synthetic:scene-v1"}).json()["state"] == "streaming"
    assert svc.ctl.state == "idle"
    svc._stop.set()


def test_usb_phone_import_with_stubbed_devicectl(client, tmp_path, monkeypatch):
    """The USB path end to end, with Apple's devicectl replaced: list -> pull -> verified import -> duplicate refused."""
    import shutil
    from test_bundle import _iphone_bundle
    from fieldstation import usb_phone

    c, svc = client
    sid, _zip = _iphone_bundle(tmp_path)
    phone_folder = tmp_path / f"scan-{sid}"
    monkeypatch.setattr(usb_phone, "availability", lambda: {"available": True, "reason": None})
    monkeypatch.setattr(usb_phone, "devices", lambda: [{"device_id": "DEV1", "name": "Test iPhone", "model": "iPhone 17 Pro",
                                                       "transport": "wired", "os_version": "27.2"}])
    monkeypatch.setattr(usb_phone, "list_scans", lambda dev: [{"scan_id": sid, "title": "fixture patch"}])

    def pull(dev, scan_id, work):
        dest = Path(work) / f"scan-{scan_id}"
        shutil.copytree(phone_folder, dest)
        return dest
    monkeypatch.setattr(usb_phone, "pull_scan", pull)

    assert c.get("/api/usb/phone").json()["devices"][0]["device_id"] == "DEV1"
    rows = c.get("/api/usb/phone/DEV1/scans").json()["scans"]
    assert rows[0]["scan_id"] == sid and rows[0]["already_imported"] is False
    r = c.post("/api/usb/phone/DEV1/import", json={"scan_ids": [sid]}).json()["results"][0]
    assert r["ok"] and r["origin"] == "iphone_arkit_lidar"
    man = c.get(f"/api/scans/{sid}").json()["manifest"]
    assert man["desktop_import"]["source"].startswith("iPhone over USB") and man["desktop_import"]["verified_sha256_files"] == 1
    assert c.get("/api/usb/phone/DEV1/scans").json()["scans"][0]["already_imported"] is True
    again = c.post("/api/usb/phone/DEV1/import", json={"scan_ids": [sid]}).json()["results"][0]
    assert again["ok"] is False and again["duplicate"] is True
    # tampered copy on the phone side is refused
    (phone_folder / "point_cloud_fused.ply").write_bytes(b"tampered")
    import json as _json
    m = _json.loads((phone_folder / "scan.json").read_text())
    import uuid as _uuid
    m["scan_id"] = str(_uuid.uuid4())
    (phone_folder / "scan.json").write_text(_json.dumps(m))
    bad = c.post("/api/usb/phone/DEV1/import", json={"scan_ids": [m["scan_id"]]}).json()["results"][0]
    assert bad["ok"] is False and "checksum mismatch" in bad["error"]
    assert not any((svc.home / "usb_import_tmp").iterdir())     # temporary copies cleaned up


def test_import_scan_folder_over_http(client, tmp_path):
    from test_bundle import _iphone_bundle
    c, _ = client
    sid, _zip = _iphone_bundle(tmp_path)
    r = c.post("/api/import", json={"path": str(tmp_path / f"scan-{sid}")})
    assert r.status_code == 200 and r.json()["scan_id"] == sid


def test_usb_unavailable_is_reported_not_raised(client, monkeypatch):
    from fieldstation import usb_phone
    c, _ = client
    monkeypatch.setattr(usb_phone, "availability", lambda: {"available": False, "reason": "needs Xcode"})
    assert c.get("/api/usb/phone").json() == {"available": False, "reason": "needs Xcode", "devices": []}


def test_usb_auto_sync_imports_finished_scans_and_skips_recording_ones(tmp_path, monkeypatch):
    import shutil
    from test_bundle import _iphone_bundle
    from fieldstation import usb_phone
    from fieldstation.bundle import ScanStore
    from fieldstation.usb_sync import UsbAutoSync

    store = ScanStore(tmp_path / "home" / "scans")
    sid, _ = _iphone_bundle(tmp_path)
    recording = "11111111-2222-4333-8444-555555555555"      # folder exists on the phone, no scan.json yet
    events = []
    monkeypatch.setattr(usb_phone, "devices", lambda: [{"device_id": "DEV1", "name": "Test iPhone", "transport": "wired"},
                                                       {"device_id": "NET", "name": "Wi-Fi iPhone", "transport": "localNetwork"}])
    listed = []
    monkeypatch.setattr(usb_phone, "list_scan_ids", lambda dev: listed.append(dev) or [sid, recording])
    monkeypatch.setattr(usb_phone, "read_scan_json", lambda dev, s: None if s == recording else {"scan_id": s})
    monkeypatch.setattr(usb_phone, "pull_scan", lambda dev, s, work: Path(shutil.copytree(tmp_path / f"scan-{s}", Path(work) / f"scan-{s}")))
    sync = UsbAutoSync(store, tmp_path / "home", lambda t, **kw: events.append({"type": t, **kw}), enabled=True)

    first = sync.sync_once()
    assert [r["scan_id"] for r in first] == [sid] and first[0]["ok"]
    assert listed == ["DEV1"]                                  # cable only
    assert store.manifest(sid)["desktop_import"]["source"] == "Test iPhone over USB (automatic)"
    assert any(e["type"] == "scan_imported" and e.get("via") == "usb_auto" for e in events)
    assert sync.sync_once() == []                              # already imported, recording one still skipped
    sync.set_enabled(False)
    assert sync.status()["enabled"] is False


def test_ble_send_passes_title_and_feature_to_the_phone(client, monkeypatch):
    c, svc = client
    sent = {}
    monkeypatch.setattr(svc.link, "send", lambda central, t, **kw: sent.update(central=central, type=t, **kw) or {"type": t, **kw})
    r = c.post("/api/ble/send", json={"central": "C1", "type": "start_capture", "title": "  Boulder A  ", "feature_type": "boulder"})
    assert r.status_code == 200
    assert sent == {"central": "C1", "type": "start_capture", "target": "phone", "sensor_id": "iphone:arkit", "profile": "default",
                    "title": "Boulder A", "feature_type": "boulder"}
    sent.clear()
    c.post("/api/ble/send", json={"central": "C1", "type": "start_capture", "feature_type": "not-a-type"})
    assert "feature_type" not in sent and "title" not in sent
