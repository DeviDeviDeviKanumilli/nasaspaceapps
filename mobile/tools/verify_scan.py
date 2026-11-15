#!/usr/bin/env python3
"""Check a Field Scan bundle on a computer, independently of the phone code.

  python3 verify_scan.py path/to/scan-<id>[.zip]          hashes, contents, re-fusion from raw keyframes
  python3 verify_scan.py --selftest                        synthetic bundle with known geometry (no phone needed)

What it does:
 1. Verifies every file in scan.json (size + SHA-256).
 2. Re-projects the raw keyframe depth (keyframes/*.f32 + *.u8, poses and intrinsics from keyframes.jsonl) with the
    conventions in contracts/SCAN_BUNDLE_V1.md and voxel-averages it, written as point_cloud_from_keyframes.ply
    (derived; this also recovers a scan whose fused cloud was never written).
 3. Compares that cloud with the phone's point_cloud_fused.ply (nearest-neighbour distances). The phone fuses
    more frames than it keeps as keyframes, so the clouds differ in coverage; matching surfaces should agree to
    about a voxel. A convention error (axis flip, wrong intrinsics scaling) shows up as decimetres.
Needs numpy and scipy. Written with AI assistance (Claude, Anthropic).
"""
import hashlib
import json
import os
import struct
import sys
import tempfile
import zipfile

import numpy as np


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read_ply_xyz(path):
    with open(path, "rb") as f:
        data = f.read()
    end = data.index(b"end_header") + len(b"end_header")
    end = data.index(b"\n", end) + 1
    header = data[:end].decode("latin1").splitlines()
    n, props, in_vertex = 0, [], False
    for line in header:
        p = line.split()
        if p[:2] == ["element", "vertex"]:
            n, in_vertex = int(p[2]), True
        elif p and p[0] == "element":
            in_vertex = False
        elif p and p[0] == "property" and in_vertex:
            props.append((p[2], p[1]))
    types = {"float": "<f4", "uchar": "u1", "ushort": "<u2", "uint": "<u4", "int": "<i4", "double": "<f8"}
    dt = np.dtype([(name, types[t]) for name, t in props])
    v = np.frombuffer(data, dtype=dt, count=n, offset=end)
    return np.stack([v["x"], v["y"], v["z"]], axis=1).astype(np.float64), v


def write_ply(path, xyz, rgb=None, comments=()):
    n = len(xyz)
    head = "ply\nformat binary_little_endian 1.0\n" + "".join(f"comment {c}\n" for c in comments)
    head += f"element vertex {n}\nproperty float x\nproperty float y\nproperty float z\n"
    fields = [("x", "<f4"), ("y", "<f4"), ("z", "<f4")]
    if rgb is not None:
        head += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        fields += [("red", "u1"), ("green", "u1"), ("blue", "u1")]
    head += "end_header\n"
    a = np.zeros(n, dtype=fields)
    a["x"], a["y"], a["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    if rgb is not None:
        a["red"], a["green"], a["blue"] = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    with open(path, "wb") as f:
        f.write(head.encode())
        f.write(a.tobytes())


def backproject(depth, conf, K, image_w, pose_colmajor, min_conf, rmin, rmax):
    """Depth (h, w) metres -> world points, ARKit conventions (contracts/SCAN_BUNDLE_V1.md)."""
    h, w = depth.shape
    s = image_w / w
    jj, ii = np.mgrid[0:h, 0:w]
    u = (ii + 0.5) * s - 0.5
    v = (jj + 0.5) * s - 0.5
    z = depth
    ok = np.isfinite(z) & (z >= rmin) & (z <= rmax)
    if conf is not None:
        ok &= conf >= min_conf
    x = (u - K["cx"]) * z / K["fx"]
    y = -(v - K["cy"]) * z / K["fy"]
    pc = np.stack([x[ok], y[ok], -z[ok], np.ones(ok.sum())], axis=0)
    T = np.array(pose_colmajor, dtype=np.float64).reshape(4, 4).T  # column-major -> row-major matrix
    return (T @ pc)[:3].T


def voxel_mean(pts, voxel, min_samples):
    if len(pts) == 0:
        return pts
    keys = np.floor(pts / voxel).astype(np.int64)
    _, inv, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    inv = inv.ravel()
    sums = np.zeros((counts.size, 3))
    np.add.at(sums, inv, pts)
    mean = sums / counts[:, None]
    return mean[counts >= min_samples]


def refuse(folder, env):
    params = {}
    for op in env.get("processing", {}).get("operations", []):
        if op.get("op") == "voxel_fuse":
            params = op.get("params", {})
    voxel = float(params.get("voxel_m", 0.01))
    min_conf = int(params.get("min_confidence", 1))
    rmin, rmax = float(params.get("min_range_m", 0.15)), float(params.get("max_range_m", 5.0))
    pts, used = [], 0
    with open(os.path.join(folder, "keyframes.jsonl")) as f:
        for line in f:
            k = json.loads(line)
            if k.get("type") != "keyframe" or "depth" not in k or k.get("tracking") != "normal":
                continue
            d = k["depth"]
            depth = np.fromfile(os.path.join(folder, d["file"]), dtype="<f4").reshape(d["height"], d["width"])
            conf = None
            if d.get("confidence_file"):
                conf = np.fromfile(os.path.join(folder, d["confidence_file"]), dtype="u1").reshape(d["height"], d["width"])
            pts.append(backproject(depth, conf, k["intrinsics"], k["intrinsics"]["for_width"], k["camera_to_world"], min_conf, rmin, rmax))
            used += 1
    allp = np.concatenate(pts) if pts else np.zeros((0, 3))
    return voxel_mean(allp, voxel, 1), used, voxel


def verify(path):
    tmp = None
    if path.endswith(".zip"):
        tmp = tempfile.mkdtemp()
        with zipfile.ZipFile(path) as z:
            z.extractall(tmp)
        subs = [os.path.join(tmp, d) for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
        path = subs[0] if subs and not os.path.exists(os.path.join(tmp, "scan.json")) else tmp
    env = json.load(open(os.path.join(path, "scan.json")))
    print(f"scan {env['scan_id']}  origin {env.get('origin')}  schema {env.get('schema_version')}  status {env.get('status')}")
    bad = 0
    for f in env.get("files", []):
        p = os.path.join(path, f["path"])
        if not os.path.exists(p):
            print("  MISSING", f["path"]); bad += 1; continue
        if os.path.getsize(p) != f["bytes"] or sha256(p) != f["sha256"]:
            print("  HASH/SIZE MISMATCH", f["path"]); bad += 1
    print(f"  files: {len(env.get('files', []))} listed, {bad} problems")
    result = {"hash_problems": bad}
    if os.path.exists(os.path.join(path, "keyframes.jsonl")):
        cloud, used, voxel = refuse(path, env)
        print(f"  re-fused {len(cloud)} points from {used} raw keyframes (voxel {voxel} m)")
        result["refused_points"] = int(len(cloud))
        if len(cloud):
            out = os.path.join(path, "point_cloud_from_keyframes.ply")
            write_ply(out, cloud, comments=["DERIVED by verify_scan.py from keyframes/*.f32 (not listed in scan.json)", f"voxel_m {voxel}"])
            print(f"  wrote {out}")
        fused = os.path.join(path, "point_cloud_fused.ply")
        if len(cloud) and os.path.exists(fused):
            from scipy.spatial import cKDTree
            phone, _ = read_ply_xyz(fused)
            dist, _ = cKDTree(phone).query(cloud, k=1)
            med, p90 = float(np.median(dist)), float(np.percentile(dist, 90))
            print(f"  re-fused vs phone cloud: median NN distance {med*1000:.1f} mm, 90th pct {p90*1000:.1f} mm")
            result.update(nn_median_m=med, nn_p90_m=p90)
    return result


def selftest():
    """Synthesise a bundle exactly as the phone writes it: a 0.4 m cube on a floor (y = 0), seen from 6 poses."""
    tmp = tempfile.mkdtemp()
    os.makedirs(os.path.join(tmp, "keyframes"))
    fx = fy = 1450.0; cx, cy = 959.5, 719.5; iw, ih, dw, dh = 1920, 1440, 256, 192
    s = iw / dw
    jj, ii = np.mgrid[0:dh, 0:dw]
    u, v = (ii + 0.5) * s - 0.5, (jj + 0.5) * s - 0.5
    lines, files = [], []

    def look_at(eye, target):
        f = np.array(target, float) - eye; f /= np.linalg.norm(f)
        r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r)
        up = np.cross(r, f)
        T = np.eye(4); T[:3, 0], T[:3, 1], T[:3, 2], T[:3, 3] = r, up, -f, eye
        return T

    def raycast(T):
        # rays in camera frame for z-depth 1, then world
        d_cam = np.stack([(u - cx) / fx, -(v - cy) / fy, -np.ones_like(u)], -1)
        d_w = d_cam @ T[:3, :3].T
        o = T[:3, 3]
        best = np.full(u.shape, np.inf)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = (0 - o[1]) / d_w[..., 1]                         # floor y = 0
            p = o + t[..., None] * d_w
            ok = (t > 0) & (np.abs(p[..., 0]) < 2) & (np.abs(p[..., 2]) < 2)
            best = np.where(ok, t, best)
            for axis, val in [(0, -0.2), (0, 0.2), (2, -0.2), (2, 0.2), (1, 0.4)]:  # cube faces
                t = (val - o[axis]) / d_w[..., axis]
                p = o + t[..., None] * d_w
                lim = [abs(p[..., a] - (0.2 if a == 1 else 0)) <= 0.2 + 1e-9 for a in range(3) if a != axis]
                ok = (t > 0) & lim[0] & lim[1] & (t < best)
                best = np.where(ok, t, best)
        return best.astype("<f4")   # z-depth because rays have camera-z = -1

    for n, ang in enumerate(np.linspace(0, 2 * np.pi, 6, endpoint=False), start=1):
        eye = np.array([1.5 * np.sin(ang), 1.0, 1.5 * np.cos(ang)])
        T = look_at(eye, [0, 0.2, 0])
        depth = raycast(T)
        conf = np.full(depth.shape, 2, dtype="u1")
        name = f"keyframes/kf_{n:05d}"
        depth.tofile(os.path.join(tmp, name + ".f32")); conf.tofile(os.path.join(tmp, name + ".u8"))
        for ext in (".f32", ".u8"):
            p = os.path.join(tmp, name + ext)
            files.append({"path": name + ext, "bytes": os.path.getsize(p), "sha256": sha256(p), "role": "keyframe_depth"})
        lines.append(json.dumps({"type": "keyframe", "index": n, "tracking": "normal",
                                 "intrinsics": {"fx": fx, "fy": fy, "cx": cx, "cy": cy, "for_width": iw, "for_height": ih},
                                 "camera_to_world": T.T.ravel().tolist(),
                                 "depth": {"file": name + ".f32", "confidence_file": name + ".u8", "width": dw, "height": dh}}))
    with open(os.path.join(tmp, "keyframes.jsonl"), "w") as f:
        f.write("\n".join(lines) + "\n")
    env = {"schema_version": "1.0", "scan_id": "selftest", "origin": "synthetic_fixture", "status": "complete", "files": files,
           "processing": {"operations": [{"op": "voxel_fuse", "params": {"voxel_m": 0.01, "min_confidence": 1, "min_range_m": 0.1, "max_range_m": 5}}]}}
    json.dump(env, open(os.path.join(tmp, "scan.json"), "w"))
    r = verify(tmp)
    cloud, _ = read_ply_xyz(os.path.join(tmp, "point_cloud_from_keyframes.ply"))
    floor = cloud[(np.abs(cloud[:, 0]) > 0.5) | (np.abs(cloud[:, 2]) > 0.5)]
    top = cloud[(np.abs(cloud[:, 0]) < 0.15) & (np.abs(cloud[:, 2]) < 0.15) & (cloud[:, 1] > 0.3)]
    checks = [
        ("hashes", r["hash_problems"] == 0),
        (f"floor at y=0 (mean {floor[:, 1].mean()*1000:.2f} mm, sd {floor[:, 1].std()*1000:.2f} mm)", abs(floor[:, 1].mean()) < 0.002),
        (f"cube top at 0.40 m (mean {top[:, 1].mean():.4f} m)", abs(top[:, 1].mean() - 0.40) < 0.006),
        (f"cube width 0.40 m (x span of top {np.ptp(cloud[cloud[:, 1] > 0.39][:, 0]):.3f} m)",
         abs(np.ptp(cloud[cloud[:, 1] > 0.39][:, 0]) - 0.40) < 0.02),
    ]
    ok = True
    for name, passed in checks:
        print(("ok   " if passed else "FAIL ") + name)
        ok &= passed
    print("SELFTEST PASSED" if ok else "SELFTEST FAILED")
    return ok


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(0 if selftest() else 1)
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    verify(sys.argv[1])
