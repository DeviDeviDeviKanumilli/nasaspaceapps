"""Yardstick for zone references: distance (worst-scale slope W1) from each real lunar 10 km window
in a zone to that zone's pooled reference. An Earth window closer than the lunar median is as close
to the zone profile as a typical real lunar window of that zone is.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import json, numpy as np, warnings
warnings.filterwarnings("ignore")
from build_zone_refs import SITES, BOX, WIN, features
from lolaread import read
from build_refs import block_mean
from global_run import LS, QP
R = np.load("refs.npz"); L = json.load(open("zone_windows.json"))
d = {"MZ-FLAT": [], "MZ-STEEP": []}
for site, (cx, cy) in SITES.items():
    z = block_mean(read("", cx, cy, BOX)[0], 5); S, _, allv = features(z)
    for w in L:
        if w["site"] != site or not w["zone"]:
            continue
        j = int(round((w["x"] - (cx - BOX / 2)) / 100 - WIN / 2)); i = int(round(((cy + BOX / 2) - w["y"]) / 100 - WIN / 2))
        v = allv[i:i + WIN, j:j + WIN]
        q = np.stack([np.quantile(S[Lb][i:i + WIN, j:j + WIN][v], QP) for Lb in LS])
        d[w["zone"]].append(float(np.abs(q - R[w["zone"] + "_slope_q"]).mean(1).max()))
out = {k: dict(n=len(v), p10=round(float(np.percentile(v, 10)), 2), median=round(float(np.median(v)), 2), p90=round(float(np.percentile(v, 90)), 2)) for k, v in d.items()}
print(out); json.dump(out, open("zone_yardstick.json", "w"), indent=1)
