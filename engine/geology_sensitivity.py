"""Sensitivity of the global rock-type pathway to its heuristic thresholds, and whether the
'process partner' (G4) adds information beyond plain exposed-lithology filtering (G2).

Thresholds varied one at a time around the adopted values (G1 0.50, G2 0.25, partner 0.10):
  G1 mapped share 0.30 / 0.70; G2 exposed share 0.10 / 0.50; partner share 0.05 / 0.20.
For each setting: tier counts and the top-50 list (same ordering + 25 km suppression as geology_run.py).
Overlap = share of adopted top-50 places with a place in the alternative list within 25 km.

Usage: python3 geology_sensitivity.py OUT_JSON   (needs glim_raster_001.npy, glim_codes.json, wc_bare_001.npy)
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math
import numpy as np
import geology_run as g

ADOPTED = dict(g1=0.50, g2=0.25, p=0.10)
VARIANTS = [dict(ADOPTED)] + [dict(ADOPTED, **{k: v}) for k, v in
                              (("g1", 0.30), ("g1", 0.70), ("g2", 0.10), ("g2", 0.50), ("p", 0.05), ("p", 0.20))]


def arrays(raster, inv, bare8, T):
    w = int(round(g.WIN_DEG / g.RES))
    rows_i = [i0 for i0 in range(0, g.NY - w + 1, w // 2) if abs(90 - (i0 + w / 2) * g.RES) <= 84]
    lut = np.where(np.arange(256) <= 200, np.arange(256) / 200.0, 0.0).astype(np.float32)
    st = g.lookup(inv, T["target"]); sp = g.lookup(inv, T["partner"])
    Ls = g.window_sums(lambda a, b: (raster[a:b] > 0).astype(np.float32), w, rows_i)
    WC = g.window_sums(lambda a, b: ((raster[a:b] > 0) & (bare8[a:b] != 255)).astype(np.float32), w, rows_i)
    A = g.window_sums(lambda a, b: st[raster[a:b]], w, rows_i)
    P = g.window_sums(lambda a, b: sp[raster[a:b]], w, rows_i)
    E = g.window_sums(lambda a, b: st[raster[a:b]] * lut[bare8[a:b]], w, rows_i)
    lat, lon, f, ex, pf, area = [], [], [], [], [], []
    for (i0, la, wl, js, l), (_, _, _, _, wc), (_, _, _, _, a), (_, _, _, _, p), (_, _, _, _, e) in zip(Ls, WC, A, P, E):
        ok = l >= 0.7 * w * wl
        if not ok.any():
            continue
        cell = (g.RES * 111.32) ** 2 * math.cos(math.radians(la))
        lat.append(np.full(ok.sum(), la)); lon.append(-180 + (js[ok] + wl / 2) * g.RES)
        f.append(a[ok] / l[ok]); pf.append(p[ok] / l[ok])
        ex.append(np.where(wc[ok] / l[ok] >= 0.9, e[ok] / l[ok], np.nan)); area.append(e[ok] * cell)
    c = np.concatenate
    return dict(lat=c(lat), lon=c(lon), f=c(f), ex=c(ex), pf=c(pf), area=c(area))


def evaluate(D, v):
    g1 = D["f"] >= v["g1"]
    g2 = g1 & np.nan_to_num(D["ex"] >= v["g2"])
    g4 = g2 & (D["pf"] >= v["p"])
    tier = np.where(g4, 0, np.where(g2, 1, np.where(g1, 2, 9)))
    order = np.lexsort((-D["f"], -np.nan_to_num(D["area"]), tier))
    top = []
    for i in order:
        if tier[i] == 9:
            break
        if all(g.haversine_km(D["lat"][i], D["lon"][i], D["lat"][k], D["lon"][k]) >= g.SUPPRESS_KM for k in top):
            top.append(i)
        if len(top) >= 50:
            break
    return dict(G1_or_better=int(g1.sum()), G2_or_better=int(g2.sum()), G4=int(g4.sum()), top=top,
                top_tier_counts={t: int(sum(1 for i in top if tier[i] == k)) for t, k in (("G4", 0), ("G2", 1), ("G1", 2))})


def ov(a, b, D):
    return round(sum(1 for i in a if any(g.haversine_km(D["lat"][i], D["lon"][i], D["lat"][j], D["lon"][j]) < g.SUPPRESS_KM for j in b)) / max(len(a), 1), 3)


def main():
    raster = np.load("glim_raster_001.npy", mmap_mode="r")
    inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
    bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
    out = {"adopted": ADOPTED, "references": {}}
    for rid, T in g.TARGETS.items():
        D = arrays(raster, inv, bare8, T)
        base = evaluate(D, ADOPTED)
        # 'trivial' baseline: exposed lithology only (rank G2 windows by exposed area, ignore partner)
        triv = evaluate(D, dict(ADOPTED, p=99.0))
        r = {"n_windows": int(D["lat"].size), "adopted": {k: v for k, v in base.items() if k != "top"},
             "overlap_adopted_vs_exposed_lithology_only": ov(base["top"], triv["top"], D),
             "median_partner_share_in_adopted_G4_top50": round(float(np.median([D["pf"][i] for i in base["top"]])), 3),
             "variants": []}
        for v in VARIANTS[1:]:
            e = evaluate(D, v)
            r["variants"].append(dict(params=v, **{k: e[k] for k in ("G1_or_better", "G2_or_better", "G4", "top_tier_counts")},
                                      overlap_with_adopted_top50=ov(base["top"], e["top"], D)))
        out["references"][rid] = r
        print(rid, json.dumps(r), flush=True)
    json.dump(out, open(sys.argv[1], "w"), indent=1)


if __name__ == "__main__":
    main()
