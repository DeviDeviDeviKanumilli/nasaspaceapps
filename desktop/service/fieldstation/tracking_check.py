"""Plausibility check of an iPhone (ARKit) scan's camera track, from the phone's own keyframes.jsonl.

ARKit places every depth frame using its visual-inertial tracking. If the camera sees only a blank surface a few
centimetres away (phone face-down, mounted facing a wall or the laptop lid), tracking can drift by hundreds of metres
while still reporting "normal", and the fused cloud is then scattered (seen 15 Nov 2026: a desk scan "moved" 340 m in
78 s). Nothing here corrects the data; it only says when the positions cannot be trusted and why.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

MAX_SPEED_M_S = 3.0      # a hand-held or rig-mounted phone does not move faster between keyframes
MAX_TRACK_SPAN_M = 30.0  # a close-range scan does not cover this much ground
NEAR_FRACTION = 0.8      # mean share of depth pixels closer than 0.5 m


def check(scan_dir: Path) -> dict | None:
    """None when the scan has no ARKit keyframes; otherwise the numbers and plain-language warnings."""
    p = Path(scan_dir) / "keyframes.jsonl"
    if not p.is_file():
        return None
    kfs = []
    for line in p.read_text().splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        m = r.get("camera_to_world")
        if r.get("type") == "keyframe" and isinstance(m, list) and len(m) == 16:
            kfs.append(r)
    if len(kfs) < 2:
        return None
    pos = [(k["camera_to_world"][12], k["camera_to_world"][13], k["camera_to_world"][14]) for k in kfs]
    t = [float(k.get("t_since_start_s") or 0.0) for k in kfs]
    speeds = []
    for i in range(1, len(kfs)):
        dt = t[i] - t[i - 1]
        if dt > 0.05:
            speeds.append(math.dist(pos[i], pos[i - 1]) / dt)
    span = max(math.dist(a, b) for a in (min(pos), max(pos)) for b in pos)
    near = []
    for k in kfs:
        h = (((k.get("depth") or {}).get("stats") or {}).get("range_hist_0_5m_bins_0p5")) or []
        if h and sum(h):
            near.append(h[0] / sum(h))
    out = {"keyframes": len(kfs), "max_speed_m_s": round(max(speeds), 2) if speeds else None,
           "track_span_m": round(span, 2), "near_fraction": round(sum(near) / len(near), 3) if near else None,
           "trustworthy": True, "warnings": []}
    if (speeds and max(speeds) > MAX_SPEED_M_S) or span > MAX_TRACK_SPAN_M:
        out["trustworthy"] = False
        out["warnings"].append(
            f"The phone's position tracking drifted: the camera appears to move {span:.0f} m"
            + (f" and up to {max(speeds):.0f} m/s" if speeds else "")
            + " during the scan, which a hand-held or mounted phone does not do. Point positions in this scan are not "
              "reliable; the geometry is scattered. Rescan with the phone pointed at the scene from 0.5–3 m.")
    if out["near_fraction"] is not None and out["near_fraction"] > NEAR_FRACTION:
        out["warnings"].append(
            f"On average {out['near_fraction'] * 100:.0f}% of the LiDAR depth was closer than 0.5 m: the phone was facing "
            "something right in front of it (a surface, the mount, a hand?). Tracking needs a view of the scene.")
    return out
