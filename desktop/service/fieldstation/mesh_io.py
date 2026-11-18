"""Triangle meshes for viewing: read a scan's mesh PLY and, only when it is too big to draw smoothly, simplify it
for display by vertex clustering. The file on disk is never changed.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np


def read_mesh_ply(p: Path) -> tuple[np.ndarray, np.ndarray]:
    """Vertices (N,3 float32) and triangles (M,3 uint32) from a binary little-endian or ASCII PLY."""
    raw = p.read_bytes()
    end = raw.index(b"end_header") + len(b"end_header")
    end = raw.index(b"\n", end) + 1
    header = raw[:end].decode("ascii", "replace").splitlines()
    fmt = next(line.split()[1] for line in header if line.startswith("format"))
    elements, cur = [], None
    for line in header:
        t = line.split()
        if t[:1] == ["element"]:
            cur = {"name": t[1], "count": int(t[2]), "props": []}
            elements.append(cur)
        elif t[:1] == ["property"] and cur is not None:
            cur["props"].append(t[1:])
    sizes = {"char": "i1", "uchar": "u1", "int8": "i1", "uint8": "u1", "short": "i2", "ushort": "u2", "int16": "i2",
             "uint16": "u2", "int": "i4", "uint": "u4", "int32": "i4", "uint32": "u4", "float": "f4", "float32": "f4",
             "double": "f8", "float64": "f8"}
    if fmt == "ascii":
        lines = raw[end:].decode("ascii").split("\n")
        i = 0
        verts = faces = None
        for el in elements:
            if el["name"] == "vertex":
                names = [pr[-1] for pr in el["props"]]
                arr = np.array([[float(x) for x in lines[i + k].split()] for k in range(el["count"])])
                verts = arr[:, [names.index("x"), names.index("y"), names.index("z")]].astype(np.float32)
            elif el["name"] == "face":
                faces = np.array([[int(x) for x in lines[i + k].split()[1:4]] for k in range(el["count"])], np.uint32)
            i += el["count"]
        return verts, faces
    if fmt != "binary_little_endian":
        raise SystemExit(f"unsupported PLY format {fmt}")
    off = end
    verts = faces = None
    for el in elements:
        if el["name"] == "face" and el["props"] and el["props"][0][0] == "list":
            cnt_t, idx_t = sizes[el["props"][0][1]], sizes[el["props"][0][2]]
            extra = [(f"p{i}", "<" + sizes[pr[0]]) for i, pr in enumerate(el["props"][1:])]
            # every face in these files is a triangle: fixed-size records
            dt = np.dtype([("n", "<" + cnt_t), ("v", "<" + idx_t, (3,))] + extra)
            rec = np.frombuffer(raw, dt, el["count"], off)
            if not (rec["n"] == 3).all():
                raise SystemExit("mesh has non-triangle faces; not supported here")
            faces = rec["v"].astype(np.uint32)
            off += dt.itemsize * el["count"]
        else:
            dt = np.dtype([(pr[-1], "<" + sizes[pr[0]]) for pr in el["props"]])
            rec = np.frombuffer(raw, dt, el["count"], off)
            off += dt.itemsize * el["count"]
            if el["name"] == "vertex":
                verts = np.stack([rec["x"], rec["y"], rec["z"]], 1).astype(np.float32)
    if verts is None or faces is None:
        raise SystemExit("no vertex/face elements in the mesh")
    return verts, faces


def simplify_for_display(v: np.ndarray, f: np.ndarray, max_triangles: int) -> tuple[np.ndarray, np.ndarray, float]:
    """Merge vertices that share a grid cell (cell grows until the mesh fits max_triangles). Returns the vertices,
    triangles and the cell size in metres (0 when nothing was merged). Display only: shapes smaller than the cell
    are smoothed away, and the caller must say so."""
    used = np.unique(f)
    remap = np.full(len(v), -1, np.int64)
    remap[used] = np.arange(len(used))
    v, f = v[used], remap[f]
    if len(f) <= max_triangles:
        return v.astype(np.float32), f.astype(np.uint32), 0.0
    lo = v.min(0)
    cell = 0.01
    while True:
        key = np.floor((v - lo) / cell).astype(np.int64)
        _, cl, counts = np.unique(key, axis=0, return_inverse=True, return_counts=True)
        cl = cl.reshape(-1)
        nf = cl[f]
        keep = (nf[:, 0] != nf[:, 1]) & (nf[:, 1] != nf[:, 2]) & (nf[:, 0] != nf[:, 2])
        nf = np.unique(np.sort(nf[keep], 1), axis=0) if keep.any() else nf[keep]
        if len(nf) <= max_triangles or cell > 1.0:
            break
        cell *= 1.3
    nv = np.zeros((len(counts), 3), np.float64)
    np.add.at(nv, cl, v)
    nv /= counts[:, None]
    # np.unique sorted each triangle's indices, which can flip its winding; the viewer lights both sides, so
    # orientation does not matter for display.
    return nv.astype(np.float32), nf.astype(np.uint32), cell
