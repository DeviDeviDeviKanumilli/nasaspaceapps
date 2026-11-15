"""Zone yardstick at the regional (60 m grid, 240/480/960 m) scale. Same idea as zone_yardstick.py.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import json, numpy as np, warnings
warnings.filterwarnings("ignore")
import regional_run as rr
from build_zone_refs import SITES, BOX
from lolaread import read
from build_refs import block_mean
refs = rr.lunar_refs(); L = json.load(open("zone_windows.json")); d = {}
for site, (cx, cy) in SITES.items():
    z = block_mean(read("", cx, cy, BOX)[0], 3); v = np.isfinite(z)
    S, R, allv = rr.tile_profile(np.where(v, z, 0.0), v)
    for w in L:
        if w["site"] != site or not w["zone"]:
            continue
        j = int(round((w["x"] - (cx - BOX / 2)) / rr.GRID - rr.WIN / 2)); i = int(round(((cy + BOX / 2) - w["y"]) / rr.GRID - rr.WIN / 2))
        vv = allv[i:i + rr.WIN, j:j + rr.WIN]
        if vv.mean() < rr.MIN_VALID:
            continue
        q = np.stack([np.quantile(S[Lb][i:i + rr.WIN, j:j + rr.WIN][vv], rr.QP) for Lb in rr.LS2])
        d.setdefault(w["zone"], []).append(float(np.abs(q - refs[w["zone"]][0]).mean(1).max()))
out = {k: dict(n=len(v), p10=round(float(np.percentile(v, 10)), 2), median=round(float(np.median(v)), 2), p90=round(float(np.percentile(v, 90)), 2)) for k, v in d.items()}
print(out); json.dump(out, open("zone_yardstick_regional.json", "w"), indent=1)
