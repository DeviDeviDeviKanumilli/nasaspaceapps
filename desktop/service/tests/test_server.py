"""Local API: auth, host check, capture -> analyse -> export through HTTP, cloud.bin format, scope."""
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
