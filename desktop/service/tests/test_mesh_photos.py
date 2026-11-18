"""Viewer mesh (mesh.bin, display simplification) and the scan photos endpoints.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import io
import struct

import numpy as np
from PIL import Image

from fieldstation.mesh_io import read_mesh_ply, simplify_for_display

from conftest import wait_for
from test_server import client  # noqa: F401  (fixture)


def _grid(n):
    xs, zs = np.meshgrid(np.linspace(0, 2, n), np.linspace(0, 2, n))
    v = np.stack([xs.ravel(), np.zeros(n * n), zs.ravel()], 1).astype(np.float32)
    f = []
    for i in range(n - 1):
        for j in range(n - 1):
            a = i * n + j
            f += [[a, a + 1, a + n], [a + 1, a + n + 1, a + n]]
    return v, np.array(f, np.uint32)


def test_simplify_only_when_needed_and_keeps_bounds():
    v, f = _grid(120)                       # 28 322 triangles
    v1, f1, cell = simplify_for_display(v, f, 100000)
    assert cell == 0 and len(f1) == len(f)
    v2, f2, cell = simplify_for_display(v, f, 5000)
    assert cell > 0 and 0 < len(f2) <= 5000 and f2.max() < len(v2)
    assert np.allclose(v2.min(0), v.min(0), atol=cell) and np.allclose(v2.max(0), v.max(0), atol=cell)


def test_mesh_bin_and_photos(client):  # noqa: F811
    c, svc = client
    c.post("/api/device/open", json={"adapter_id": "synthetic", "device_id": "synthetic:scene-v1"})
    sid = c.post("/api/capture/start", json={"title": "mesh", "frames": 3}).json()["scan_id"]
    wait_for(lambda: c.get(f"/api/scans/{sid}").json()["manifest"]["status"] == "complete")
    b = c.get(f"/api/scans/{sid}/mesh.bin").content
    nv, nt = struct.unpack("<II", b[:8])
    assert nt > 0 and len(b) == 8 + nv * 12 + nt * 12
    idx = np.frombuffer(b[8 + nv * 12:], "<u4")
    assert idx.max() < nv
    v, f = read_mesh_ply(svc.store.dir_of(sid) / "mesh_grid.ply")
    r = c.get(f"/api/scans/{sid}/mesh.bin", params={"max_triangles": len(f)})
    assert struct.unpack("<II", r.content[:8])[1] == len(f) and r.headers["x-cell-m"] == "0.0000"   # fits: sent as is
    assert nt <= 150000 < len(f) and float(c.get(f"/api/scans/{sid}/mesh.bin").headers["x-cell-m"]) > 0
    ph = c.get(f"/api/scans/{sid}/photos").json()["photos"]
    assert ph and all(p["kind"] == "D435 colour frame" for p in ph)
    r = c.get(f"/api/scans/{sid}/photo/{ph[0]['path']}", params={"w": 200})
    assert r.headers["content-type"] == "image/jpeg" and Image.open(io.BytesIO(r.content)).width == 200
    assert c.get(f"/api/scans/{sid}/photo/scan.json").status_code == 404
    assert c.get(f"/api/scans/{sid}/photo/..%2F..%2Fetc%2Fpasswd").status_code == 404
    assert c.get(f"/api/scans/{sid}/photo/{ph[0]['path']}", headers={"Authorization": ""}).status_code == 401


def test_photo_url_token_for_image_widgets(client):  # noqa: F811
    c, svc = client
    c.post("/api/device/open", json={"adapter_id": "synthetic", "device_id": "synthetic:scene-v1"})
    sid = c.post("/api/capture/start", json={"title": "tok", "frames": 2}).json()["scan_id"]
    wait_for(lambda: c.get(f"/api/scans/{sid}").json()["manifest"]["status"] == "complete")
    path = c.get(f"/api/scans/{sid}/photos").json()["photos"][0]["path"]
    from fastapi.testclient import TestClient
    bare = TestClient(c.app)      # no Authorization header, like Image.network
    assert bare.get(f"/api/scans/{sid}/photo/{path}", params={"token": "t0ken"}).status_code == 200
    assert bare.get(f"/api/scans/{sid}/photo/{path}", params={"token": "wrong"}).status_code == 401
