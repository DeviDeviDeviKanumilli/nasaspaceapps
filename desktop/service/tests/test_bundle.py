"""Bundles: hashes, raw immutability, recovery, export/import, duplicates, tampering, iPhone import.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json
import os
import shutil
import uuid
import zipfile

import numpy as np
import pytest

from fieldstation.bundle import BundleError, DuplicateScan, ScanStore, atomic_write_json
from fieldstation.metrics import roi_points_sphere, roughness_analysis
from fieldstation.ply import make_vertices, read_ply, write_ply, xyz_of
from fieldstation.schema import sha256_file, validate_manifest


def test_ply_roundtrip_metres(tmp_path):
    xyz = np.array([[0.0, 0.0, 1.0], [0.25, -0.1, 2.5], [1e-3, 2e-3, 0.3]])
    rgb = np.array([[1, 2, 3], [4, 5, 6], [7, 8, 9]], np.uint8)
    write_ply(tmp_path / "a.ply", make_vertices(xyz, rgb, color_valid=np.array([1, 0, 1], np.uint8)), ["units m"])
    v, comments = read_ply(tmp_path / "a.ply")
    assert np.allclose(xyz_of(v), xyz, atol=1e-7) and "units m" in comments
    assert list(v["color_valid"]) == [1, 0, 1]
    data = (tmp_path / "a.ply").read_bytes()
    (tmp_path / "b.ply").write_bytes(data[:-5])
    with pytest.raises(ValueError, match="truncated"):
        read_ply(tmp_path / "b.ply")


def test_complete_bundle_layout_and_hashes(synthetic_scan, store):
    d = store.dir_of(synthetic_scan)
    m = store.manifest(synthetic_scan)
    assert m["status"] == "complete" and m["origin"] == "synthetic_fixture" and m["is_real_sensor"] is False
    assert any("SYNTHETIC" in x for x in m["limitations"])
    assert validate_manifest(m) == []
    for f in m["files"]:
        assert sha256_file(d / f["path"]) == f["sha256"], f["path"]
    roles = {f["role"] for f in m["files"]}
    assert {"raw_depth", "raw_color", "calibration", "raw_point_cloud", "derived_point_cloud", "analysis", "thumbnail"} <= roles
    # raw evidence is read-only
    raw = d / "frames" / "depth_00000.png"
    assert not os.access(raw, os.W_OK)
    comments = read_ply(d / "point_cloud_filtered.ply")[1]
    assert any("NOT A LIVE SENSOR CAPTURE" in c for c in comments)
    metrics = json.loads((d / "metrics.json").read_text())
    assert metrics["gravity_referenced_slope"]["status"] == "not_measured"
    assert metrics["raw_capture_preserved"] is True


def test_reprocess_changes_derived_only(synthetic_scan, store):
    d = store.dir_of(synthetic_scan)
    raw_before = {p.name: sha256_file(p) for p in (d / "frames").glob("*.png")}
    m = store.process(synthetic_scan, {"voxel_m": 0.01})
    assert {p.name: sha256_file(p) for p in (d / "frames").glob("*.png")} == raw_before
    assert m["processing"]["params"]["voxel_m"] == 0.01 and len(m["processing"]["runs"]) == 2


def test_recovery_marks_interrupted_scans_incomplete(tmp_path):
    root = tmp_path / "scans"
    d = root / f"scan-{uuid.uuid4()}"
    d.mkdir(parents=True)
    atomic_write_json(d / "scan.json", {"scan_id": d.name[5:], "status": "recording"})
    (d / "junk.tmp").write_text("x")
    st = ScanStore(root)
    assert st.recovered == [d.name[5:]]
    assert json.loads((d / "scan.json").read_text())["status"] == "incomplete"
    assert not (d / "junk.tmp").exists()


def test_export_import_roundtrip_duplicate_and_tamper(synthetic_scan, store, tmp_path):
    z = store.export_zip(synthetic_scan)
    other = ScanStore(tmp_path / "other" / "scans")
    m = other.import_zip(z)
    assert m["scan_id"] == synthetic_scan
    with pytest.raises(DuplicateScan, match="identical"):
        other.import_zip(z)
    # tamper with one raw frame
    bad = tmp_path / "bad.zip"
    with zipfile.ZipFile(z) as src, zipfile.ZipFile(bad, "w") as dst:
        for i in src.infolist():
            data = src.read(i)
            if i.filename.endswith("depth_00001.png"):
                data = data[:-10] + b"0123456789"
            dst.writestr(i, data)
    third = ScanStore(tmp_path / "third" / "scans")
    with pytest.raises(BundleError, match="checksum mismatch"):
        third.import_zip(bad)
    assert third.list() == []          # nothing half-imported
    # path traversal
    evil = tmp_path / "evil.zip"
    with zipfile.ZipFile(evil, "w") as e:
        e.writestr("../../escape.txt", "x")
        e.writestr("scan.json", "{}")
    with pytest.raises(BundleError, match="unsafe path"):
        third.import_zip(evil)


def _iphone_bundle(tmp_path) -> tuple:
    """A minimal bundle shaped like contracts/SCAN_BUNDLE_V1.md from the iPhone app. TEST FIXTURE, not a real scan:
    a 40 cm patch tilted 20 degrees from horizontal in arkit_session_world (+Y up)."""
    sid = str(uuid.uuid4())
    d = tmp_path / f"scan-{sid}"
    d.mkdir()
    rng = np.random.default_rng(5)
    a, b = rng.uniform(-0.2, 0.2, 5000), rng.uniform(-0.2, 0.2, 5000)
    t = np.radians(20)
    pts = np.column_stack([a, b * np.sin(t), -1.0 + b * np.cos(t)]) + rng.normal(0, 0.001, (5000, 3))
    write_ply(d / "point_cloud_fused.ply", make_vertices(pts, np.full((5000, 3), 120, np.uint8)), ["frame arkit_session_world"])
    man = {"schema_version": "1.0", "scan_id": sid, "session_id": str(uuid.uuid4()), "origin": "iphone_arkit_lidar",
           "device": {"manufacturer": "Apple", "model": "iPhone 17 Pro"},
           "captured_at_utc": {"start": "2026-11-15T12:00:00Z", "end": "2026-11-15T12:01:00Z"},
           "capture": {"depth_type": "sceneDepth", "depth_units": "m", "keyframes": 12},
           "coordinate_frame": {"name": "arkit_session_world", "units": "m", "handedness": "right", "up": "+Y gravity"},
           "location": {"sharing": "hidden"}, "observation": {"title": "fixture patch"},
           "measurements": [], "files": [{"path": "point_cloud_fused.ply", "role": "derived_point_cloud", "mime": "application/x-ply",
                                          "bytes": (d / "point_cloud_fused.ply").stat().st_size, "sha256": sha256_file(d / "point_cloud_fused.ply"),
                                          "lineage": "fixture"}],
           "processing": {}, "publication": {"status": "local_private"}, "limitations": ["TEST FIXTURE"]}
    (d / "scan.json").write_text(json.dumps(man))
    z = tmp_path / f"scan-{sid}.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for p in d.rglob("*"):
            zf.write(p, f"scan-{sid}/{p.relative_to(d)}")
    return sid, z


def test_iphone_bundle_import_keeps_provenance_and_uses_gravity(store, tmp_path):
    sid, z = _iphone_bundle(tmp_path)
    m = store.import_zip(z)
    assert m["origin"] == "iphone_arkit_lidar" and m["device"]["model"] == "iPhone 17 Pro"
    assert store.cloud_file(sid).name == "point_cloud_fused.ply"
    pts = roi_points_sphere(xyz_of(read_ply(store.cloud_file(sid))[0]), [0, 0, -1.0], 0.15)
    res = roughness_analysis(pts, {"kind": "sphere", "center": [0, 0, -1.0], "radius_m": 0.15},
                             frame="arkit_session_world", gravity_up=[0, 1, 0])
    ms = {x["name"]: x for x in res["measurements"]}
    assert abs(ms["plane_tilt_from_horizontal"]["value"] - 20.0) < 0.5   # patch rises 20 deg from horizontal
    assert ms["plane_tilt_from_horizontal"]["frame"] == "arkit_session_world"
    store.add_analysis(sid, {"kind": "roughness", **res})
    m2 = store.manifest(sid)
    assert m2["origin"] == "iphone_arkit_lidar" and len(m2["measurements"]) == len(res["measurements"])


def test_bare_ply_import_flags_provenance(store, tmp_path):
    write_ply(tmp_path / "x.ply", make_vertices(np.zeros((5, 3)) + [0, 0, 1]), [])
    m = store.import_ply(tmp_path / "x.ply")
    assert m["origin"] == "unknown_import" and "provenance" in m["status_reason"]


def test_catalog_draft_is_local_only(synthetic_scan, store):
    dr = store.write_catalog_draft(synthetic_scan, {"license": "CC BY 4.0", "consent_obtained": True})
    assert dr["status"] == "draft_local" and dr["visibility"] == "private" and dr["location_precision"] == "hidden"
    m = store.manifest(synthetic_scan)
    assert m["publication"]["status"] == "draft_local"
    assert any(f["path"] == "catalog_draft.json" for f in m["files"])


def test_grid_mesh_ply_and_glb(synthetic_scan, store):
    from fieldstation.mesh import read_glb
    d = store.dir_of(synthetic_scan)
    js, binary = read_glb(d / "mesh_grid.glb")
    n_idx = js["accessors"][2]["count"]
    assert n_idx % 3 == 0 and n_idx > 0 and js["asset"]["extras"]["hole_filling"] is False
    idx = np.frombuffer(binary[js["bufferViews"][2]["byteOffset"]:][:n_idx * 4], "<u4")
    assert idx.max() < js["accessors"][0]["count"]
    v, comments = read_ply(d / "mesh_grid.ply")       # vertices readable even with a face element after them
    assert len(v) == js["accessors"][0]["count"] and any("no hole filling" in c for c in comments)
    # glTF positions are the PLY vertices with y,z flipped
    pos = np.frombuffer(binary[:len(v) * 12], "<f4").reshape(-1, 3)
    assert np.allclose(pos[:, 0], v["x"]) and np.allclose(pos[:, 1], -v["y"]) and np.allclose(pos[:, 2], -v["z"])
    assert store.cloud_file(synthetic_scan, "mesh").name == "mesh_grid.ply"


def test_ply_extra_vertex_props_read_by_name(tmp_path):
    """The iPhone fused PLY carries uchar confidence + ushort samples after rgb; readers must go by name."""
    xyz = np.array([[0.0, 1.0, -1.0], [0.1, 1.0, -1.1]])
    write_ply(tmp_path / "f.ply", make_vertices(xyz, np.array([[9, 8, 7], [6, 5, 4]], np.uint8),
                                                confidence=np.array([2, 1], np.uint8), samples=np.array([300, 7], np.uint16)), [])
    v, _ = read_ply(tmp_path / "f.ply")
    assert np.allclose(xyz_of(v), xyz) and list(v["samples"]) == [300, 7] and list(v["red"]) == [9, 6]
