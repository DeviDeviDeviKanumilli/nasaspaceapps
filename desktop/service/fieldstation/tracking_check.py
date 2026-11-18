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

    def speeds_of(ps, ts):
        out = []
        for i in range(1, len(ps)):
            dt = ts[i] - ts[i - 1]
            if dt > 0.05:
                out.append(math.dist(ps[i], ps[i - 1]) / dt)
        return out

    speeds = speeds_of(pos, t)
    # Field Scan builds of 15 Nov 2026 (11:50 onwards) reset tracking when a rig scan starts, and the first keyframe
    # could be a frame from before the reset, in the old coordinates: one jump at the start, then a normal track.
    # Report that one misplaced keyframe for what it is instead of calling the whole scan unreliable.
    first_offset = None
    if len(kfs) >= 4 and speeds and speeds[0] > MAX_SPEED_M_S and max(speeds_of(pos[1:], t[1:]) or [0]) <= MAX_SPEED_M_S:
        first_offset = math.dist(pos[0], pos[1])
        pos, t, speeds = pos[1:], t[1:], speeds_of(pos[1:], t[1:])
    span = max(math.dist(a, b) for a in (min(pos), max(pos)) for b in pos)
    near = []
    for k in kfs:
        h = (((k.get("depth") or {}).get("stats") or {}).get("range_hist_0_5m_bins_0p5")) or []
        if h and sum(h):
            near.append(h[0] / sum(h))
    out = {"keyframes": len(kfs), "max_speed_m_s": round(max(speeds), 2) if speeds else None,
           "track_span_m": round(span, 2), "near_fraction": round(sum(near) / len(near), 3) if near else None,
           "trustworthy": True, "warnings": [], "notes": []}
    if first_offset is not None:
        out["first_keyframe_offset_m"] = round(first_offset, 2)
        out["notes"] = [f"The first keyframe was recorded just before tracking restarted and sits {first_offset:.1f} m from the "
                        f"rest; its depth may be misplaced in the fused point cloud. The other {len(kfs) - 1} keyframes form a "
                        "consistent track, and ARKit's mesh is built after the restart."]
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
