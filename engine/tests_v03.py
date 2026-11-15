"""Regression tests for the v0.3 engine (audit, 14 Nov evening). Run: python3 tests_v03.py
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import os, sys, json, tempfile, shutil, subprocess
import numpy as np
from scipy.stats import wasserstein_distance
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terrain_engine import plane_features, plane_features_fast
import global_run as G

ok_all = True


def check(name, cond, detail=""):
    global ok_all
    ok_all &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""))


# 1. Analytic plane + noise: slope recovered within noise, fast == general
rng = np.random.default_rng(1)
n = 200; px = 100.0
yy, xx = np.mgrid[0:n, 0:n] * px
for deg in (3.0, 12.0, 25.0):
    z = np.tan(np.radians(deg)) * xx + rng.normal(0, 0.5, xx.shape)
    v = np.ones_like(z, bool)
    sf, rf, _ = plane_features_fast(z, v, px, 800)
    sg, rg, _, _ = plane_features(z, v, px, 800)
    m = np.isfinite(sf)
    check(f"plane {deg} deg + 0.5 m noise: median slope", abs(np.nanmedian(sf) - deg) < 0.05, f"{np.nanmedian(sf):.3f}")
    check(f"plane {deg} deg: roughness ~ noise sigma", abs(np.nanmedian(rf) - 0.5) < 0.05, f"{np.nanmedian(rf):.3f}")
    check(f"plane {deg} deg: fast == general", np.nanmax(np.abs(sf[m] - sg[m])) < 1e-8)

# 2. Masked cell inside a disc invalidates the fast estimate there
z = np.tan(np.radians(10)) * xx; v = np.ones_like(z, bool); v[100, 100] = False
sf, _, _ = plane_features_fast(z, v, px, 800)
check("masked cell invalidates discs that contain it", np.isnan(sf[100, 102]) and np.isfinite(sf[100, 120]))

# 3. W1 from 50 midpoint quantiles approximates the exact Wasserstein distance
errs = []
for k in range(50):
    a = rng.gamma(2 + k % 5, 4, 20000).clip(0, 89); b = rng.gamma(3 + k % 3, 3.5, 20000).clip(0, 89)
    approx = np.abs(np.quantile(a, G.QP) - np.quantile(b, G.QP)).mean()
    errs.append(abs(approx - wasserstein_distance(a, b)))
check("W1 from 50 quantiles within 0.15 deg of exact (slope-like distributions)", max(errs) < 0.15, f"max err {max(errs):.3f} deg")

# 4. Tile-name parsing
check("parse N/W tile", G.parse("Copernicus_DSM_COG_30_N36_00_W117_00_DEM") == (36, -117))
check("parse S/E tile", G.parse("Copernicus_DSM_COG_30_S78_00_E161_00_DEM") == (-78, 161))

# 5. Zone pooling counts each lunar cell once (v1 double-counted overlapping windows)
import build_zone_refs as Z
S = {L: np.full((200, 200), 5.0) for L in G.LS}; Rr = {L: np.full((200, 200), 1.0) for L in G.LS}
allv = np.ones((200, 200), bool)
wins = [(0, 0, 1.0, 0.0), (25, 25, 1.0, 0.0), (50, 50, 1.0, 0.0)]          # three overlapping flat windows
cells, w = Z.build({"A": (S, Rr, allv, wins)}, "MZ-FLAT", 0.6, 0.4)
union = np.zeros((200, 200), bool)
for i, j, _, _ in wins:
    union[i:i + Z.WIN, j:j + Z.WIN] = True
check("zone pooling uses unique cells", cells["A"][0][400].size == union.sum(), f"{cells['A'][0][400].size} vs {union.sum()}")

# 6. Geology tiers: G4 requires G2 and partner share >= threshold
import geology_sensitivity as GS
D = dict(lat=np.array([0., 1, 2, 3]), lon=np.array([0., 1, 2, 3]), f=np.array([0.9, 0.9, 0.9, 0.4]),
         ex=np.array([0.5, 0.5, 0.1, 0.9]), pf=np.array([0.2, 0.05, 0.5, 0.5]), area=np.array([10., 20, 30, 40]))
e = GS.evaluate(D, dict(g1=0.5, g2=0.25, p=0.1))
check("G4 needs mapped + exposed + partner", e["G4"] == 1 and e["G2_or_better"] == 2 and e["G1_or_better"] == 3)

# 7. compare.py never nominates snow/ice-dominated or unknown-land-cover windows
tmp = tempfile.mkdtemp()
try:
    here = os.path.dirname(os.path.abspath(__file__))
    for f in ("refs.npz", "refs_meta.json"):
        shutil.copy(os.path.join(here, f), tmp)
    q = np.stack([np.linspace(1, 30, 50)] * 4).astype(np.float16)
    def tile(name, lat, snow):
        np.savez_compressed(os.path.join(tmp, "feat", name + ".npz"), lat=np.array([lat], np.float32), lon=np.array([10.], np.float32),
                            valid=np.array([1.], np.float32), bare=np.array([0.5], np.float32), snow=np.array([snow], np.float32),
                            slope_q=q[None], lrough_q=q[None] / 30, conn=np.full((1, 7), 0.5, np.float16), meta=np.array([name, "True", "0"]))
    os.makedirs(os.path.join(tmp, "feat"))
    tile("t_ok", 10.0, 0.0); tile("t_snow", 40.0, 0.9); tile("t_unknown", -70.0, np.nan)
    subprocess.run([sys.executable, os.path.join(here, "compare.py"), os.path.join(tmp, "feat"), os.path.join(tmp, "c.json"), "5"],
                   cwd=tmp, capture_output=True, check=True)
    c = json.load(open(os.path.join(tmp, "c.json")))
    lats = {x["lat"] for r in c["references"].values() for x in r["candidates"]}
    check("snow/unknown windows never nominated", lats == {10.0}, str(lats))
    check("compare output carries run metadata and coverage", "run" in c and len(c["coverage"]) == 3)
finally:
    shutil.rmtree(tmp)

print("ALL PASS" if ok_all else "SOME TESTS FAILED")
sys.exit(0 if ok_all else 1)
