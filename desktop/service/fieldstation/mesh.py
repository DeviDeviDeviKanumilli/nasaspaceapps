"""Bounded surface mesh from the organised (filtered) depth grid. DERIVED, never "observed".

Triangles join only neighbouring depth pixels that were all measured and whose
depths agree (max jump <= max(abs_m, rel*z)), so no gaps are bridged and no
hidden surfaces are invented. Holes stay holes. Exported as binary PLY
(scientific copy) and GLB (for viewing on other devices; colours per vertex).
"""
from __future__ import annotations

import json
import os
import struct
from pathlib import Path

import numpy as np

from .camera_model import Intrinsics, deproject


def grid_mesh(depth_m: np.ndarray, intr: Intrinsics, color_rgb: np.ndarray | None = None, step: int = 2,
              rel_jump: float = 0.03, abs_m: float = 0.01) -> dict:
    h, w = depth_m.shape
    vs, us = np.arange(0, h, step), np.arange(0, w, step)
    sub = depth_m[np.ix_(vs, us)]
    gh, gw = sub.shape
    valid = sub > 0
    idx = -np.ones((gh, gw), np.int64)
    idx[valid] = np.arange(int(valid.sum()))
    vv, uu = np.meshgrid(vs, us, indexing="ij")
    pts = deproject(intr, uu[valid].astype(float), vv[valid].astype(float), sub[valid])
    rgb = color_rgb if color_rgb is not None else np.full((len(pts), 3), 170, np.uint8)
    a, b, c, d = idx[:-1, :-1], idx[:-1, 1:], idx[1:, :-1], idx[1:, 1:]
    za, zb, zc, zd = sub[:-1, :-1], sub[:-1, 1:], sub[1:, :-1], sub[1:, 1:]

    def ok(*zs):
        zz = np.stack(zs)
        good = np.all(zz > 0, axis=0)
        jump = zz.max(axis=0) - zz.min(axis=0)
        return good & (jump <= np.maximum(abs_m, rel_jump * zz.max(axis=0)))
    t1 = ok(za, zb, zc)
    t2 = ok(zb, zd, zc)
    faces = np.concatenate([np.stack([a[t1], c[t1], b[t1]], -1), np.stack([b[t2], c[t2], d[t2]], -1)]).astype(np.uint32)
    return {"points": pts, "rgb": rgb, "faces": faces,
            "params": {"grid_step_px": step, "max_depth_jump_rel": rel_jump, "max_depth_jump_abs_m": abs_m,
                       "hole_filling": False}}


def write_mesh_ply(path: Path, pts: np.ndarray, rgb: np.ndarray, faces: np.ndarray, comments: list[str]) -> None:
    head = ["ply", "format binary_little_endian 1.0"] + [f"comment {c}" for c in comments] + [
        f"element vertex {len(pts)}", "property float x", "property float y", "property float z",
        "property uchar red", "property uchar green", "property uchar blue",
        f"element face {len(faces)}", "property list uchar uint vertex_indices", "end_header"]
    v = np.empty(len(pts), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")])
    v["x"], v["y"], v["z"] = pts[:, 0], pts[:, 1], pts[:, 2]
    v["r"], v["g"], v["b"] = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    f = np.empty(len(faces), dtype=[("n", "u1"), ("i", "<u4", (3,))])
    f["n"] = 3
    f["i"] = faces
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as fh:
        fh.write(("\n".join(head) + "\n").encode("ascii"))
        fh.write(v.tobytes())
        fh.write(f.tobytes())
    os.replace(tmp, path)


def write_glb(path: Path, pts: np.ndarray, rgb: np.ndarray, faces: np.ndarray, extras: dict) -> None:
    """Minimal glTF 2.0 binary: one mesh, POSITION + COLOR_0 (normalized uchar4) + uint32 indices.

    glTF is +Y up / -Z forward; the camera_optical_m frame (+Y down, +Z forward) is converted by a 180 degree
    rotation about X (y -> -y, z -> -z), which is recorded in asset.extras. Units stay metres.
    """
    p = pts.astype("<f4").copy()
    p[:, 1] *= -1
    p[:, 2] *= -1
    col = np.concatenate([rgb.astype(np.uint8), np.full((len(rgb), 1), 255, np.uint8)], axis=1)
    ind = faces.astype("<u4").ravel()

    def pad(b: bytes, fill=b"\x00") -> bytes:
        return b + fill * ((4 - len(b) % 4) % 4)
    bp, bc, bi = pad(p.tobytes()), pad(col.tobytes()), pad(ind.tobytes())
    bin_ = bp + bc + bi
    gltf = {
        "asset": {"version": "2.0", "generator": "Field Station", "extras": {
            **extras, "frame_conversion": "camera_optical_m -> glTF: (x, -y, -z)", "units": "m"}},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1}, "indices": 2, "mode": 4}]}],
        "buffers": [{"byteLength": len(bin_)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": p.nbytes, "target": 34962},
            {"buffer": 0, "byteOffset": len(bp), "byteLength": col.nbytes, "target": 34962},
            {"buffer": 0, "byteOffset": len(bp) + len(bc), "byteLength": ind.nbytes, "target": 34963}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(p), "type": "VEC3",
             "min": p.min(axis=0).tolist() if len(p) else [0, 0, 0], "max": p.max(axis=0).tolist() if len(p) else [0, 0, 0]},
            {"bufferView": 1, "componentType": 5121, "normalized": True, "count": len(col), "type": "VEC4"},
            {"bufferView": 2, "componentType": 5125, "count": len(ind), "type": "SCALAR"}],
    }
    js = pad(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    total = 12 + 8 + len(js) + 8 + len(bin_)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(bin_), 0x004E4942) + bin_)
    os.replace(tmp, path)


def read_glb(path: Path) -> tuple[dict, bytes]:
    data = Path(path).read_bytes()
    magic, ver, total = struct.unpack("<III", data[:12])
    if magic != 0x46546C67 or ver != 2 or total != len(data):
        raise ValueError("not a valid GLB 2.0 file")
    jl, jt = struct.unpack("<II", data[12:20])
    js = json.loads(data[20:20 + jl])
    bl, bt = struct.unpack("<II", data[20 + jl:28 + jl])
    if jt != 0x4E4F534A or bt != 0x004E4942:
        raise ValueError("bad GLB chunk types")
    return js, data[28 + jl:28 + jl + bl]
