"""Geology / process pathway, global (GLiM polygons + ESA WorldCover exposure).

Stage 1  rasterise GLiM lithology codes to a 0.01 degree global grid (cell areas handled with cos(lat);
         GLiM's Shape__Area field, which is Web Mercator, is never used).
Stage 2  window fractions on a grid of ~11 km windows (0.1 deg in latitude, 0.1/cos(lat) deg in
         longitude) stepping half a window, for each reference's target definition.
Stage 3  exposure: for windows passing tier G1, fraction of the window that is target lithology AND
         WorldCover bare/sparse (60) or moss/lichen (100), from the 320 m WorldCover overview.
EMIT (tier G3) is not evaluated in this script; every record says so.

Usage: python3 geology_run.py GLIM_DIR OUT_JSON
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, os, glob, json, math, time, warnings
import numpy as np
warnings.filterwarnings("ignore")

RES = 0.01
NY, NX = int(180 / RES), int(360 / RES)
WIN_DEG = 0.1
G1_MIN = 0.50      # mapped target fraction for tier G1
G2_MIN = 0.25      # exposed target fraction for tier G2
PARTNER_MIN = 0.10 # process partner must cover at least this share of the window's mapped land for G4
N_PER_REF = 50
SUPPRESS_KM = 25.0

# Target definitions, fixed before the run. Each is a function of the code arrays (xx, yy, zz).
TARGETS = {
    "R-JZ": dict(
        desc="basic volcanic or basic plutonic rock, in a window that also contains alluvial sediment",
        target=lambda xx, yy, zz: np.isin(xx, ["vb", "pb"]),
        partner=lambda xx, yy, zz: np.isin(xx, ["su", "ss"]) & (yy == "ad"),
        partner_desc="unconsolidated or siliciclastic sediment with alluvial-deposit subclass"),
    "R-IS": dict(
        desc="basic volcanic rock",
        target=lambda xx, yy, zz: xx == "vb",
        partner=lambda xx, yy, zz: np.isin(yy, ["ds", "lo"]),
        partner_desc="dune sands or loess (wind-blown cover)"),
    "R-AE": dict(
        desc="Mars dune-crossing zone: wind-blown dune sand",
        target=lambda xx, yy, zz: yy == "ds",
        partner=lambda xx, yy, zz: np.isin(xx, ["vb", "pb"]),
        partner_desc="basic volcanic or plutonic rock in the same window (a possible dark basaltic sand source, as on Mars)"),
}


def load_codes(gdir):
    import rasterio.features
    from affine import Affine
    tr = Affine(RES, 0, -180, 0, -RES, 90)
    codes = {}
    out = np.zeros((NY, NX), np.uint16)
    files = sorted(glob.glob(os.path.join(gdir, "p*.geojson")))
    t0 = time.time()
    for k, f in enumerate(files):
        d = json.load(open(f))
        shapes = []
        for ft in d["features"]:
            c = ft["properties"].get("Litho") or "______"
            i = codes.setdefault(c, len(codes) + 1)
            if ft["geometry"]:
                shapes.append((ft["geometry"], i))
        if shapes:
            rasterio.features.rasterize(shapes, out=out, transform=tr, merge_alg=rasterio.enums.MergeAlg.replace)
        if k % 50 == 0:
            print("rasterised", k, "/", len(files), round(time.time() - t0), "s", flush=True)
    inv = {v: k for k, v in codes.items()}
    return out, inv


def indicator(raster, inv, fn):
    ids = np.array(sorted(inv)); c = [inv[i] for i in ids]
    xx = np.array([s[0:2] for s in c]); yy = np.array([s[2:4] for s in c]); zz = np.array([s[4:6] for s in c])
    sel = np.zeros(max(inv) + 1, bool); sel[ids[fn(xx, yy, zz)]] = True
    return sel[raster]


def window_sums(rowfn, w, lat_rows):
    """Sum of rowfn(i0, i1) over each window (w rows x w/cos(lat) cols), stepping half a window.
    rowfn returns a 2-D float32 array for rows i0..i1, so no global float array is ever held."""
    out = []
    for i0 in lat_rows:
        lat = 90 - (i0 + w / 2) * RES
        wl = max(w, int(round(w / math.cos(math.radians(lat)))))
        c = np.concatenate([[0.0], np.cumsum(rowfn(i0, i0 + w).sum(0, dtype=np.float64))])
        js = np.arange(0, NX - wl + 1, max(1, wl // 2))
        out.append((i0, lat, wl, js, c[js + wl] - c[js]))
    return out


def lookup(inv, fn):
    ids = np.array(sorted(inv)); c = [inv[i] for i in ids]
    xx = np.array([s[0:2] for s in c]); yy = np.array([s[2:4] for s in c]); zz = np.array([s[4:6] for s in c])
    sel = np.zeros(max(inv) + 1, np.float32); sel[ids[fn(xx, yy, zz)]] = 1.0
    return sel


def haversine_km(a, b, c, d):
    p = np.radians
    x = np.sin(p(c - a) / 2) ** 2 + np.cos(p(a)) * np.cos(p(c)) * np.sin(p(d - b) / 2) ** 2
    return 6371.0 * 2 * np.arcsin(np.sqrt(x))


def main():
    gdir, out_json = sys.argv[1], sys.argv[2]
    if os.path.exists("glim_raster_001.npy"):
        raster = np.load("glim_raster_001.npy", mmap_mode="r")
        inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
    else:
        raster, inv = load_codes(gdir)
        np.save("glim_raster_001.npy", raster); json.dump(inv, open("glim_codes.json", "w"))
    bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
    print("unique codes", len(inv), flush=True)
    bare_lut = np.where(np.arange(256) <= 200, np.arange(256) / 200.0, 0.0).astype(np.float32)
    land_f = lambda i0, i1: (raster[i0:i1] > 0).astype(np.float32)
    landwc_f = lambda i0, i1: ((raster[i0:i1] > 0) & (bare8[i0:i1] != 255)).astype(np.float32)
    w = int(round(WIN_DEG / RES))
    rows_i = [i0 for i0 in range(0, NY - w + 1, w // 2) if abs(90 - (i0 + w / 2) * RES) <= 84]
    L = window_sums(land_f, w, rows_i)
    WC = window_sums(landwc_f, w, rows_i)
    res = {"glim_codes": len(inv), "window": "0.1 deg latitude x 0.1/cos(lat) deg longitude, half-window step",
           "thresholds": dict(G1_min_mapped=G1_MIN, G2_min_exposed=G2_MIN, min_mapped_land=0.7),
           "emit": "not evaluated in this run", "references": {}}
    tier_name = {0: "G4 (co-located partner unit; shared process not established; G3 not evaluated)", 1: "G2", 2: "G1"}
    for rid, T in TARGETS.items():
        st = lookup(inv, T["target"]); sp = lookup(inv, T["partner"])
        A = window_sums(lambda i0, i1: st[raster[i0:i1]], w, rows_i)
        P = window_sums(lambda i0, i1: sp[raster[i0:i1]], w, rows_i)
        E = window_sums(lambda i0, i1: st[raster[i0:i1]] * bare_lut[bare8[i0:i1]], w, rows_i)
        recs = []; nwin = 0; ng1 = 0
        for (i0, lat, wl, js, lsum), (_, _, _, _, asum), (_, _, _, _, psum), (_, _, _, _, esum), (_, _, _, _, wcs) in zip(L, A, P, E, WC):
            ok = lsum >= 0.7 * w * wl
            nwin += int(ok.sum())
            f = np.where(ok, asum / np.maximum(lsum, 1), 0)
            g1 = ok & (f >= G1_MIN)
            ng1 += int(g1.sum())
            cell_km2 = (RES * 111.32) ** 2 * math.cos(math.radians(lat))
            for k in np.where(g1)[0]:
                wc_cover = wcs[k] / lsum[k]
                expo = esum[k] / lsum[k] if wc_cover >= 0.9 else None
                pf = psum[k] / lsum[k]
                t = 2
                if expo is not None and expo >= G2_MIN:
                    t = 0 if pf >= PARTNER_MIN else 1
                recs.append(dict(lat=round(lat, 3), lon=round(-180 + (js[k] + wl / 2) * RES, 3),
                                 mapped_target_fraction=round(float(f[k]), 3),
                                 exposed_target_fraction=None if expo is None else round(float(expo), 3),
                                 exposed_target_area_km2=None if expo is None else round(float(esum[k] * cell_km2), 1),
                                 partner_fraction=round(float(pf), 3), _t=t))
        recs.sort(key=lambda r: (r["_t"], -(r["exposed_target_area_km2"] or 0), -r["mapped_target_fraction"]))
        cand = []
        for r in recs:
            if any(haversine_km(r["lat"], r["lon"], c["lat"], c["lon"]) < SUPPRESS_KM for c in cand):
                continue
            cand.append(r)
            if len(cand) >= N_PER_REF:
                break
        counts = {tier_name[t]: sum(1 for r in recs if r["_t"] == t) for t in (0, 1, 2)}
        for c in cand:
            c["tier"] = tier_name[c.pop("_t")]
        res["references"][rid] = dict(target=T["desc"], partner=T["partner_desc"], n_windows=nwin,
                                      n_G1_or_better=ng1, windows_by_tier=counts, candidates=cand)
        print(rid, "windows", nwin, "tiers", counts, flush=True)
        for c in cand[:8]:
            print("   ", c, flush=True)
    json.dump(res, open(out_json, "w"), indent=1)


if __name__ == "__main__":
    main()
