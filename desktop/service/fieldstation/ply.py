"""Binary little-endian PLY reading/writing with provenance comments.

Vertices always carry x, y, z as float32 metres. Extra per-vertex properties
(colour, flags) are written from a numpy structured array. Header comments
record units, frame and provenance so a PLY separated from its bundle still
says what it is.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import os
from pathlib import Path

import numpy as np

_PLY_TYPES = {
    "f4": "float", "f8": "double", "u1": "uchar", "i1": "char",
    "u2": "ushort", "i2": "short", "u4": "uint", "i4": "int",
}
_NP_TYPES = {v: k for k, v in _PLY_TYPES.items()}
_NP_TYPES.update({"float32": "f4", "float64": "f8", "uint8": "u1", "int8": "i1", "uint16": "u2",
                  "int16": "i2", "uint32": "u4", "int32": "i4"})


def make_vertices(xyz: np.ndarray, rgb: np.ndarray | None = None, **extra: np.ndarray) -> np.ndarray:
    fields = [("x", "<f4"), ("y", "<f4"), ("z", "<f4")]
    if rgb is not None:
        fields += [("red", "u1"), ("green", "u1"), ("blue", "u1")]
    for name, arr in extra.items():
        fields.append((name, np.asarray(arr).dtype.newbyteorder("<").str))
    out = np.empty(len(xyz), dtype=fields)
    out["x"], out["y"], out["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    if rgb is not None:
        out["red"], out["green"], out["blue"] = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    for name, arr in extra.items():
        out[name] = arr
    return out


def write_ply(path: str | os.PathLike, vertices: np.ndarray, comments: list[str] | None = None) -> None:
    """Atomic write: to a temporary file in the same folder, then rename."""
    path = Path(path)
    lines = ["ply", "format binary_little_endian 1.0"]
    for c in comments or []:
        lines.append("comment " + str(c).replace("\n", " "))
    lines.append(f"element vertex {len(vertices)}")
    for name in vertices.dtype.names:
        code = vertices.dtype[name].str[1:]
        lines.append(f"property {_PLY_TYPES[code]} {name}")
    lines.append("end_header")
    header = ("\n".join(lines) + "\n").encode("ascii")
    le = vertices.astype(vertices.dtype.newbyteorder("<"), copy=False)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(header)
        f.write(le.tobytes())
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_ply(path: str | os.PathLike) -> tuple[np.ndarray, list[str]]:
    """Read vertices of a binary_little_endian or ascii PLY. Faces and other elements are skipped
    for binary files only if they follow the vertex element. Returns (structured array, comments)."""
    data = Path(path).read_bytes()
    end = data.find(b"end_header")
    if not data.startswith(b"ply") or end < 0:
        raise ValueError("not a PLY file")
    nl = data.find(b"\n", end)
    header = data[:nl].decode("ascii", "replace").splitlines()
    body = data[nl + 1:]
    fmt, comments, elements = None, [], []
    for ln in header:
        p = ln.strip().split()
        if not p:
            continue
        if p[0] == "format":
            fmt = p[1]
        elif p[0] == "comment":
            comments.append(ln.strip()[8:])
        elif p[0] == "element":
            elements.append([p[1], int(p[2]), []])
        elif p[0] == "property":
            if p[1] == "list":
                elements[-1][2].append((p[4], "list", p[2], p[3]))
            else:
                elements[-1][2].append((p[2], p[1]))
    if not elements or elements[0][0] != "vertex":
        raise ValueError("first PLY element must be 'vertex'")
    name, count, props = elements[0]   # only the vertex element is read; faces after it are ignored
    if fmt == "binary_little_endian":
        dt = np.dtype([(n, "<" + _NP_TYPES[t]) for n, t in props])
        need = dt.itemsize * count
        if len(body) < need:
            raise ValueError(f"PLY truncated: need {need} bytes of vertex data, have {len(body)}")
        verts = np.frombuffer(body[:need], dtype=dt).copy()
    elif fmt == "ascii":
        dt = np.dtype([(n, _NP_TYPES[t]) for n, t in props])
        rows = body.decode("ascii").split("\n")[:count]
        verts = np.array([tuple(r.split()[: len(props)]) for r in rows], dtype=dt)
    else:
        raise ValueError(f"unsupported PLY format {fmt!r}")
    return verts, comments


def xyz_of(vertices: np.ndarray) -> np.ndarray:
    return np.stack([vertices["x"], vertices["y"], vertices["z"]], axis=-1).astype(np.float64)


def rgb_of(vertices: np.ndarray) -> np.ndarray | None:
    names = vertices.dtype.names
    if all(c in names for c in ("red", "green", "blue")):
        return np.stack([vertices["red"], vertices["green"], vertices["blue"]], axis=-1).astype(np.uint8)
    return None
