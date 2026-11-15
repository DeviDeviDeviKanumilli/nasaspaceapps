"""Geology pathway restricted to windows within RADIUS_KM of a centre (same rules as geology_run.py).
Usage: python3 region_geology.py OUT_JSON [lat lon radius_km]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import sys, json, math
import numpy as np
import geology_run as g
clat, clon, rad = (float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])) if len(sys.argv) > 4 else (40.33, -74.60, 150.0)
raster = np.load("glim_raster_001.npy", mmap_mode="r")
inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
lut = np.where(np.arange(256) <= 200, np.arange(256) / 200.0, 0.0).astype(np.float32)
w = int(round(g.WIN_DEG / g.RES))
rows_i = [i0 for i0 in range(0, g.NY - w + 1, w // 2) if abs(90 - (i0 + w / 2) * g.RES - clat) <= rad / 110.6 + 0.1]
L = g.window_sums(lambda a, b: (raster[a:b] > 0).astype(np.float32), w, rows_i)
WC = g.window_sums(lambda a, b: ((raster[a:b] > 0) & (bare8[a:b] != 255)).astype(np.float32), w, rows_i)
out = {"area": dict(centre=[clat, clon], radius_km=rad), "references": {}}
for rid, T in g.TARGETS.items():
    st = g.lookup(inv, T["target"]); sp = g.lookup(inv, T["partner"])
    A = g.window_sums(lambda a, b: st[raster[a:b]], w, rows_i)
    P = g.window_sums(lambda a, b: sp[raster[a:b]], w, rows_i)
    E = g.window_sums(lambda a, b: st[raster[a:b]] * lut[bare8[a:b]], w, rows_i)
    recs = []
    for (i0, lat, wl, js, ls), (_, _, _, _, a), (_, _, _, _, p), (_, _, _, _, e), (_, _, _, _, wc) in zip(L, A, P, E, WC):
        lons = -180 + (js + wl / 2) * g.RES
        d = g.haversine_km(clat, clon, lat, lons)
        for k in np.where((d <= rad) & (ls >= 0.7 * w * wl))[0]:
            f = a[k] / ls[k]
            if f < 0.05:
                continue
            expo = e[k] / ls[k] if wc[k] / ls[k] >= 0.9 else None
            tier = "below G1"
            if f >= g.G1_MIN:
                tier = "G1"
                if expo is not None and expo >= g.G2_MIN:
                    tier = "G4 (co-located partner unit; shared process not established; G3 not evaluated)" if p[k] / ls[k] >= g.PARTNER_MIN else "G2"
            recs.append(dict(lat=round(lat, 3), lon=round(float(lons[k]), 3), distance_km=round(float(d[k]), 1), tier=tier,
                             mapped_target_fraction=round(float(f), 3),
                             exposed_target_fraction=None if expo is None else round(float(expo), 4),
                             partner_fraction=round(float(p[k] / ls[k]), 3)))
    recs.sort(key=lambda r: -r["mapped_target_fraction"])
    tiers = {}
    for r in recs:
        tiers[r["tier"]] = tiers.get(r["tier"], 0) + 1
    out["references"][rid] = dict(target=T["desc"], windows_with_target_over_5pct=len(recs), tiers=tiers, top=recs[:15])
    print(rid, tiers)
    for r in recs[:6]:
        print("  ", r)
json.dump(out, open(sys.argv[1], "w"), indent=1)
