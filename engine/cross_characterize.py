"""Cross-characterise candidates with the OTHER pathway, accounting for footprints and scales.

The two pathways deliberately use different grids:
  terrain: 10 x 10 km squares in a local azimuthal-equidistant projection, 5 km step, 100 m cells
  geology: 0.1 deg (lat) x 0.1/cos(lat) deg (lon) boxes (~11.1 x 11.1 km), half-box step, 0.01 deg cells
A measurement from the other pathway is attached ONLY with its own footprint and the overlap:
  * terrain candidate -> geology shares computed over the terrain candidate's exact 10 km square
    (GLiM cells whose centres fall inside it; ~1 km cells from 1:1M-1:5M source maps).
  * geology candidate -> the terrain window with the largest footprint overlap; attached only if
    >= 50% of that terrain window lies inside the geology box, else "not measured".

Usage: python3 cross_characterize.py FEATURE_DIR TERRAIN_JSON GEOLOGY_JSON OUT_JSON
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math
import numpy as np
from pyproj import Transformer
import compare as C
import geology_run as g
from global_run import LS

MIN_OVERLAP = 0.5


def geology_over_square(lat, lon, raster, inv, bare8, half_m=5000.0):
    crs = f"+proj=aeqd +lat_0={lat} +lon_0={lon} +datum=WGS84 +units=m"
    dlat = half_m / 110574 + 0.02; dlon = half_m / (111320 * math.cos(math.radians(lat))) + 0.02
    i0 = int((90 - (lat + dlat)) / g.RES); i1 = int((90 - (lat - dlat)) / g.RES) + 1
    j0 = int((lon - dlon + 180) / g.RES); j1 = int((lon + dlon + 180) / g.RES) + 1
    la = 90 - (np.arange(i0, i1) + 0.5) * g.RES; lo = -180 + (np.arange(j0, j1) + 0.5) * g.RES
    LO, LA = np.meshgrid(lo, la)
    x, y = Transformer.from_crs("EPSG:4326", crs, always_xy=True).transform(LO, LA)
    inside = (np.abs(x) <= half_m) & (np.abs(y) <= half_m)
    codes = np.asarray(raster[i0:i1, j0:j1])[inside]; b = np.asarray(bare8[i0:i1, j0:j1])[inside]
    land = codes > 0
    if land.sum() == 0:
        return dict(status="not measured (no mapped land in GLiM)")
    names = {}
    for c in codes[land]:
        xx = inv[int(c)][0:2]; names[xx] = names.get(xx, 0) + 1
    shares = {k: round(v / land.sum(), 3) for k, v in sorted(names.items(), key=lambda t: -t[1])[:6]}
    wc = b[land] != 255
    out = dict(status="measured", footprint="terrain window: 10 x 10 km square (local AEQD)",
               geology_cells=int(land.sum()), cell_size="0.01 deg (~1 km); GLiM source maps ~1:1M-1:5M",
               rock_class_shares=shares,
               exposed_share=None if wc.mean() < 0.9 else round(float(np.where(b[land] <= 200, b[land], 0).mean() / 200), 3))
    for rid, T in g.TARGETS.items():
        st = g.lookup(inv, T["target"]); sp = g.lookup(inv, T["partner"])
        out[f"{rid}_target_share"] = round(float(st[codes[land]].mean()), 3)
        out[f"{rid}_partner_share"] = round(float(sp[codes[land]].mean()), 3)
    return out


def square_overlap(clat, clon, half_lat_deg, half_lon_deg, tlat, tlon):
    """Share of a 10 km terrain square (centre tlat,tlon) inside a geographic box (approximate, local plane)."""
    kx = 111320 * math.cos(math.radians(clat)); ky = 110574
    bx0, bx1 = (clon - half_lon_deg) * kx, (clon + half_lon_deg) * kx
    by0, by1 = (clat - half_lat_deg) * ky, (clat + half_lat_deg) * ky
    tx, ty = tlon * kx, tlat * ky
    ox = max(0.0, min(bx1, tx + 5000) - max(bx0, tx - 5000)); oy = max(0.0, min(by1, ty + 5000) - max(by0, ty - 5000))
    return ox * oy / 1e8


def main():
    fdir, tj, gj, out = sys.argv[1:5]
    raster = np.load("glim_raster_001.npy", mmap_mode="r")
    inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
    bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
    T = json.load(open(tj)); Gd = json.load(open(gj))
    F = C.load_features(fdir); R = np.load("refs.npz"); meta = json.load(open("refs_meta.json"))
    from scipy.spatial import cKDTree
    xyz = lambda la, lo: np.c_[np.cos(np.radians(la)) * np.cos(np.radians(lo)), np.cos(np.radians(la)) * np.sin(np.radians(lo)), np.sin(np.radians(la))]
    tree = cKDTree(xyz(F["lat"], F["lon"]))
    res = {"rules": {"terrain_to_geology": "GLiM over the exact terrain square", "geology_to_terrain": f"best-overlap terrain window, attached if overlap >= {MIN_OVERLAP}"},
           "terrain_candidates": {}, "geology_candidates": {}}
    for rid, r in T["references"].items():
        res["terrain_candidates"][rid] = [dict(lat=float(c["lat"]), lon=float(c["lon"]), geology=geology_over_square(c["lat"], c["lon"], raster, inv, bare8))
                                          for c in r["candidates"][:20]]
    for rid, r in Gd["references"].items():
        lst = []
        for c in r["candidates"]:
            half_lat = g.WIN_DEG / 2; wl = max(10, int(round(10 / math.cos(math.radians(c["lat"]))))); half_lon = wl * g.RES / 2
            d, idx = tree.query(xyz([c["lat"]], [c["lon"]])[0], k=8, distance_upper_bound=12 / 6371)
            best, bo = None, 0.0
            for dd, ii in zip(np.atleast_1d(d), np.atleast_1d(idx)):
                if np.isfinite(dd):
                    o = square_overlap(c["lat"], c["lon"], half_lat, half_lon, F["lat"][ii], F["lon"][ii])
                    if o > bo:
                        best, bo = ii, o
            if best is None or bo < MIN_OVERLAP:
                lst.append(dict(lat=c["lat"], lon=c["lon"], terrain=dict(status="not measured (no terrain window with >= 50% overlap; tile not processed, masked, or snow)")))
                continue
            terr = dict(status="measured", footprint="terrain window: 10 x 10 km square", overlap_with_geology_box=round(bo, 2),
                        window_centre=[round(float(F["lat"][best]), 4), round(float(F["lon"][best]), 4)],
                        median_slope_deg_by_baseline={str(L): round(float(F["slope_q"][best, k, 24:26].mean()), 2) for k, L in enumerate(LS)},
                        worst_scale_slope_W1_deg={})
            for ref, m in meta.items():
                use = [LS.index(L) for L in m["baselines"]]
                terr["worst_scale_slope_W1_deg"][ref] = round(float(np.abs(F["slope_q"][best, use, :] - R[ref + "_slope_q"][use]).mean(1).max()), 2)
            lst.append(dict(lat=c["lat"], lon=c["lon"], terrain=terr))
        res["geology_candidates"][rid] = lst
        print(rid, sum(1 for x in lst if x["terrain"]["status"] == "measured"), "of", len(lst), "geology candidates have terrain measured", flush=True)
    json.dump(res, open(out, "w"), indent=1, default=float)


if __name__ == "__main__":
    main()
