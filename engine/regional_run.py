"""Regional terrain run (tier 2): USGS 3DEP 1/3 arc-second bare-earth DEM, 60 m grid,
baselines 240/480/960 m, 10 km windows (5 km step), within RADIUS_KM of a centre point.
Compared with the lunar references computed the same way (LOLA 20 m averaged to 60 m).

Bare-earth DEM: trees and buildings are already removed, so only open water is masked
(ESA WorldCover class 80).

Usage: python3 regional_run.py OUT_JSON [lat lon radius_km]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, math, json, time, warnings
import numpy as np
warnings.filterwarnings("ignore")
import rasterio
from rasterio.warp import reproject, Resampling
from rasterio.transform import from_origin
from pyproj import Transformer
from terrain_engine import plane_features_fast
from global_run import largest_fraction, CONN_T, QP, wc_name, ENV
from build_refs import block_mean
from compare import pareto_fronts, haversine_km

GRID = 60.0
LS2 = (240, 480, 960)
WIN, STRIDE = 167, 83          # 10.0 km, 5.0 km
CONN_L2 = 480
MIN_VALID = 0.7


def tile_profile(z, valid):
    S, R = {}, {}
    for L in LS2:
        s, r, _ = plane_features_fast(np.where(valid, z, 0.0), valid, GRID, L); S[L] = s; R[L] = r
    allv = valid.copy()
    for L in LS2:
        allv &= np.isfinite(S[L])
    return S, R, allv


def window_stats(S, R, v):
    sq = np.stack([np.quantile(S[L][v], QP) for L in LS2])
    rq = np.stack([np.quantile(np.log10(np.maximum(R[L][v], 1e-3)), QP) for L in LS2])
    cc = np.array([largest_fraction(v & (S[CONN_L2] <= t), v) for t in CONN_T])
    return sq, rq, cc


def lunar_refs():
    from build_refs import REFS
    out = {}
    for rid in ("M-CR", "M-SR", "M-DG", "M-MA"):
        z = block_mean(np.load(REFS[rid][1])["z"], 3)          # 20 m -> 60 m
        v = np.isfinite(z)
        S, R, allv = tile_profile(np.where(v, z, 0.0), v)
        out[rid] = window_stats(S, R, allv)
    # zone references: the same lunar 10 km windows chosen by build_zone_refs.py, recomputed at 60 m
    import os
    if os.path.exists("zone_windows.json"):
        from build_zone_refs import SITES, BOX
        from lolaread import read
        Lw = json.load(open("zone_windows.json"))
        pools = {}
        for site, (cx, cy) in SITES.items():
            z = block_mean(read("", cx, cy, BOX)[0], 3); v = np.isfinite(z)
            S, R, allv = tile_profile(np.where(v, z, 0.0), v)
            for w in Lw:
                if w["site"] != site or not w["zone"]:
                    continue
                j = int(round((w["x"] - (cx - BOX / 2)) / GRID - WIN / 2)); i = int(round(((cy + BOX / 2) - w["y"]) / GRID - WIN / 2))
                vv = allv[i:i + WIN, j:j + WIN]
                if vv.mean() < MIN_VALID:
                    continue
                pools.setdefault(w["zone"], []).append(({L: S[L][i:i + WIN, j:j + WIN][vv] for L in LS2},
                                                        {L: R[L][i:i + WIN, j:j + WIN][vv] for L in LS2},
                                                        [largest_fraction(vv & (S[CONN_L2][i:i + WIN, j:j + WIN] <= t), vv) for t in CONN_T]))
        for zid, P in pools.items():
            sq = np.stack([np.quantile(np.concatenate([p[0][L] for p in P]), QP) for L in LS2])
            rq = np.stack([np.quantile(np.log10(np.maximum(np.concatenate([p[1][L] for p in P]), 1e-3)), QP) for L in LS2])
            out[zid] = (sq, rq, np.mean([p[2] for p in P], axis=0))
    return out


def load_3dep(lat_top, lon_left, crs, tr, ny, nx):
    name = f"n{lat_top:02d}w{-lon_left:03d}"
    url = f"/vsicurl/https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/{name}/USGS_13_{name}.tif"
    z = np.full((ny, nx), np.nan, np.float32)
    with rasterio.Env(**ENV):
        with rasterio.open(url, OVERVIEW_LEVEL=0) as d:      # ~20 m overview, averaged to 60 m
            reproject(rasterio.band(d, 1), z, src_transform=d.transform, src_crs=d.crs, src_nodata=d.nodata,
                      dst_transform=tr, dst_crs=crs, dst_nodata=np.nan, resampling=Resampling.average)
        lab = np.zeros((ny * 3, nx * 3), np.uint8)
        try:
            tr3 = from_origin(tr.c, tr.f, GRID / 3, GRID / 3)
            with rasterio.open(f"/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/{wc_name(lat_top - 1, lon_left)}",
                               OVERVIEW_LEVEL=0) as w:
                reproject(rasterio.band(w, 1), lab, src_transform=w.transform, src_crs=w.crs,
                          dst_transform=tr3, dst_crs=crs, resampling=Resampling.nearest)
        except Exception:
            pass
    water = (lab == 80).reshape(ny, 3, nx, 3).mean((1, 3)) >= 0.5
    return z, water


def main():
    out_json = sys.argv[1]
    clat, clon, rad = (float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])) if len(sys.argv) > 4 else (40.33, -74.60, 150.0)
    refs = lunar_refs()
    print("reference profiles ready", flush=True)
    dlat = rad / 110.6; dlon = rad / (111.3 * math.cos(math.radians(clat)))
    rows = []
    t0 = time.time()
    for la in range(math.floor(clat - dlat), math.ceil(clat + dlat)):
        for lo in range(math.floor(clon - dlon), math.ceil(clon + dlon)):
            c_la, c_lo = la + 0.5, lo + 0.5
            crs = f"+proj=aeqd +lat_0={c_la} +lon_0={c_lo} +datum=WGS84 +units=m"
            nx = int(111320 * math.cos(math.radians(abs(la) + 1)) // GRID); ny = int(110574 // GRID)
            tr = from_origin(-nx * GRID / 2, ny * GRID / 2, GRID, GRID)
            try:
                z, water = load_3dep(la + 1, lo, crs, tr, ny, nx)
            except Exception as e:
                print("tile", la, lo, "unavailable:", repr(e)[:120], flush=True); continue
            valid = np.isfinite(z) & ~water
            S, R, allv = tile_profile(np.where(np.isfinite(z), z, 0.0), valid)
            inv = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
            n0 = len(rows)
            for i in range(0, ny - WIN + 1, STRIDE):
                for j in range(0, nx - WIN + 1, STRIDE):
                    v = allv[i:i + WIN, j:j + WIN]
                    if v.mean() < MIN_VALID:
                        continue
                    x = tr.c + (j + WIN / 2) * GRID; y = tr.f - (i + WIN / 2) * GRID
                    wlon, wlat = inv.transform(x, y)
                    if haversine_km(clat, clon, wlat, wlon) > rad:
                        continue
                    Sw = {L: S[L][i:i + WIN, j:j + WIN] for L in LS2}; Rw = {L: R[L][i:i + WIN, j:j + WIN] for L in LS2}
                    rows.append((wlat, wlon, float(v.mean())) + window_stats(Sw, Rw, v))
            print(f"tile n{la+1}w{-lo:03d}: {len(rows)-n0} windows, {time.time()-t0:.0f}s", flush=True)
    res = {"area": dict(centre=[clat, clon], radius_km=rad), "dem": "USGS 3DEP 1/3 arc-second (bare earth), ~20 m overview averaged to 60 m",
           "baselines_m": list(LS2), "n_windows": len(rows), "references": {}}
    for rid, (rs, rr, rc) in refs.items():
        sw = np.array([np.abs(r[3] - rs).mean(1) for r in rows]); rw = np.array([np.abs(r[4] - rr).mean(1) for r in rows])
        cd = np.array([np.abs(r[5] - rc).mean() for r in rows])
        X = np.stack([sw.max(1), rw.max(1), cd], 1)
        cand = []
        for fi, fr in enumerate(pareto_fronts(X)):
            for k in sorted(fr, key=lambda k: X[k, 0]):
                if any(haversine_km(rows[k][0], rows[k][1], rows[c][0], rows[c][1]) < 15 for c, _ in cand):
                    continue
                cand.append((int(k), fi + 1))
            if len(cand) >= 10:
                break
        recs = [dict(lat=round(rows[k][0], 4), lon=round(rows[k][1], 4), pareto_front=f,
                     worst_scale_slope_W1_deg=round(float(X[k, 0]), 2), worst_scale_log10_roughness_W1=round(float(X[k, 1]), 3),
                     connectivity_distance=round(float(X[k, 2]), 3),
                     median_slope_deg_by_baseline={str(L): round(float(rows[k][3][b, 24:26].mean()), 2) for b, L in enumerate(LS2)},
                     reference_median_slope_deg_by_baseline={str(L): round(float(rs[b, 24:26].mean()), 2) for b, L in enumerate(LS2)})
                for k, f in cand[:10]]
        res["references"][rid] = dict(best_worst_scale_slope_W1_deg=round(float(X[:, 0].min()), 2),
                                      median_over_all_windows=round(float(np.median(X[:, 0])), 2), candidates=recs)
        print(rid, "best", recs[0] if recs else None, flush=True)
    json.dump(res, open(out_json, "w"), indent=1)


if __name__ == "__main__":
    main()
