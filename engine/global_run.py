"""Global terrain feature run over Copernicus GLO-90 + ESA WorldCover.

For every 1-degree tile: reproject to a local 100 m grid, compute plane-fit slope and
detrended roughness at 4 baselines, then for every 10 km window (5 km stride) store
50 midpoint quantiles of slope and log10 roughness per baseline, a connectivity curve,
and land-cover fractions. Reference comparison happens later (compare.py), so the run
never has to be repeated when a reference changes.

Resumable: one .npz per tile in OUT; existing files are skipped.
Usage: [SHARD=k/n] python3 global_run.py OUT_DIR [N_WORKERS] [tile_list.txt] [max_tiles]

Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
Space Apps AI policy. Reviewed and run by the team.
"""
import os, sys, math, time, traceback, warnings
warnings.filterwarnings("ignore")
import numpy as np
import rasterio
from rasterio.warp import reproject, Resampling
from rasterio.transform import from_origin
from pyproj import Transformer
from scipy import ndimage
from concurrent.futures import ProcessPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terrain_engine import plane_features_fast

GRID = 100.0
LS = (400, 800, 1600, 3200)
WIN = 100            # cells (10 km)
STRIDE = 50          # cells (5 km)
QP = np.arange(1, 100, 2) / 100.0      # 50 midpoint quantile levels
CONN_T = (5, 7.5, 10, 12.5, 15, 20, 25)
CONN_L = 800
MIN_VALID = 0.7
MASK = (10, 40, 50, 80, 90, 95)        # tree, crop, built, water, wetland, mangrove
BARE = (60, 100)                       # bare/sparse vegetation, moss and lichen
SNOW = (70,)
ENV = dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
           GDAL_HTTP_MAX_RETRY="5", GDAL_HTTP_RETRY_DELAY="2", GDAL_NUM_THREADS="1",
           GDAL_HTTP_MULTIPLEX="NO")


def parse(name):
    p = name.split("_")
    lat = int(p[4][1:]) * (1 if p[4][0] == "N" else -1)
    lon = int(p[6][1:]) * (1 if p[6][0] == "E" else -1)
    return lat, lon


def wc_name(lat, lon):
    la = math.floor(lat / 3) * 3; lo = math.floor(lon / 3) * 3
    return (f"ESA_WorldCover_10m_2021_v200_{'N' if la >= 0 else 'S'}{abs(la):02d}"
            f"{'E' if lo >= 0 else 'W'}{abs(lo):03d}_Map.tif")


def load(name):
    lat, lon = parse(name)
    clat, clon = lat + 0.5, lon + 0.5
    crs = f"+proj=aeqd +lat_0={clat} +lon_0={clon} +datum=WGS84 +units=m"
    nx = int(111320 * math.cos(math.radians(min(abs(lat), abs(lat + 1)))) // GRID)
    ny = int(110574 // GRID)
    tr = from_origin(-nx * GRID / 2, ny * GRID / 2, GRID, GRID)
    z = np.full((ny, nx), np.nan, np.float32)
    frac = {}
    with rasterio.Env(**ENV):
        wc_ok = False
        lab = np.zeros((ny * 4, nx * 4), np.uint8)   # 25 m sampling of the 20 m overview (factor-2 overview of the 10 m map)
        try:
            tr2 = from_origin(-nx * GRID / 2, ny * GRID / 2, GRID / 4, GRID / 4)
            with rasterio.open(f"/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/{wc_name(lat, lon)}",
                               OVERVIEW_LEVEL=0) as w:
                reproject(rasterio.band(w, 1), lab, src_transform=w.transform, src_crs=w.crs,
                          dst_transform=tr2, dst_crs=crs, resampling=Resampling.nearest)
            wc_ok = True
        except Exception:
            pass
        for key, cls in (("mask", MASK), ("bare", BARE), ("snow", SNOW)):
            frac[key] = np.isin(lab, cls).reshape(ny, 4, nx, 4).mean((1, 3)).astype(np.float32)
        if not wc_ok:
            if lat < -60:
                # WorldCover has no Antarctic tiles. No vegetation or buildings there, so nothing to
                # mask, but ice cover is NOT assessed: bare/snow are recorded as unknown (NaN).
                frac["mask"][:] = 0.0; frac["bare"][:] = np.nan; frac["snow"][:] = np.nan
            else:
                frac["mask"][:] = 1.0   # land cover missing -> treat as unusable, never as clean
        # Skip the DEM download when no window can reach MIN_VALID because of land cover alone.
        # (Same rule as the window test, applied early; it can only drop windows that would fail anyway.)
        ok = (frac["mask"] < 0.5).astype(np.float32)
        best = 0.0
        for i in range(0, ny - WIN + 1, STRIDE):
            for j in range(0, nx - WIN + 1, STRIDE):
                best = max(best, ok[i:i + WIN, j:j + WIN].mean())
        if best < MIN_VALID:
            return None, frac, crs, tr, wc_ok
        with rasterio.open(f"/vsicurl/https://copernicus-dem-90m.s3.amazonaws.com/{name}/{name}.tif") as ds:
            reproject(rasterio.band(ds, 1), z, src_transform=ds.transform, src_crs=ds.crs,
                      src_nodata=ds.nodata, dst_transform=tr, dst_crs=crs, dst_nodata=np.nan,
                      resampling=Resampling.average)
    return z.astype(float), frac, crs, tr, wc_ok


def largest_fraction(ok, valid):
    n = valid.sum()
    if n == 0:
        return np.nan
    lab, k = ndimage.label(ok)       # 4-connectivity by default
    if k == 0:
        return 0.0
    return float(np.bincount(lab.ravel())[1:].max() / n)


def process(name, out_dir):
    out = os.path.join(out_dir, name + ".npz")
    if os.path.exists(out):
        return name, "skip", 0.0
    t0 = time.time()
    z, frac, crs, tr, wc_ok = load(name)
    if z is None:
        np.savez_compressed(out + ".tmp.npz", lat=np.zeros(0, np.float32),
                            meta=np.array([name, str(wc_ok), "skipped_landcover"]))
        os.replace(out + ".tmp.npz", out)
        return name, "0 win (land cover rules out every window; DEM not read)", time.time() - t0
    land = np.isfinite(z)
    if not wc_ok:
        # No WorldCover (Antarctica): open sea and sea ice sit at ~0 m in the DEM and would look like
        # perfectly flat land. Treat cells at or below 1 m as water there.
        land &= z > 1.0
    valid = land & (frac["mask"] < 0.5)
    t1 = time.time()
    S, R = {}, {}
    for L in LS:
        s, r, _ = plane_features_fast(np.where(land, z, 0.0), valid, GRID, L)
        S[L] = s; R[L] = r
    t2 = time.time()
    ny, nx = z.shape
    allv = np.ones_like(valid)
    for L in LS:
        allv &= np.isfinite(S[L])
    rows = []
    for i in range(0, ny - WIN + 1, STRIDE):
        for j in range(0, nx - WIN + 1, STRIDE):
            v = allv[i:i + WIN, j:j + WIN]
            fv = v.mean()
            if fv < MIN_VALID:
                continue
            sq = np.stack([np.quantile(S[L][i:i + WIN, j:j + WIN][v], QP) for L in LS])
            rq = np.stack([np.quantile(np.log10(np.maximum(R[L][i:i + WIN, j:j + WIN][v], 1e-3)), QP) for L in LS])
            s8 = S[CONN_L][i:i + WIN, j:j + WIN]
            cc = [largest_fraction(v & (s8 <= t), v) for t in CONN_T]
            rows.append((i + WIN / 2, j + WIN / 2, fv,
                         frac["bare"][i:i + WIN, j:j + WIN].mean(),
                         frac["snow"][i:i + WIN, j:j + WIN].mean(), sq, rq, cc))
    t3 = time.time()
    if rows:
        ci = np.array([r[0] for r in rows]); cj = np.array([r[1] for r in rows])
        x = tr.c + cj * GRID; y = tr.f - ci * GRID
        lon, lat = Transformer.from_crs(crs, "EPSG:4326", always_xy=True).transform(x, y)
        np.savez_compressed(out + ".tmp.npz",
                            lat=np.array(lat, np.float32), lon=np.array(lon, np.float32),
                            valid=np.array([r[2] for r in rows], np.float32),
                            bare=np.array([r[3] for r in rows], np.float32),
                            snow=np.array([r[4] for r in rows], np.float32),
                            slope_q=np.array([r[5] for r in rows], np.float16),
                            lrough_q=np.array([r[6] for r in rows], np.float16),
                            conn=np.array([r[7] for r in rows], np.float16),
                            meta=np.array([name, str(wc_ok), f"{1 - valid[land].mean() if land.any() else 1:.3f}"]))
    else:
        np.savez_compressed(out + ".tmp.npz", lat=np.zeros(0, np.float32),
                            meta=np.array([name, str(wc_ok), "no_valid_windows"]))
    os.replace(out + ".tmp.npz", out)
    return name, f"{len(rows)} win read {t1-t0:.1f}s feat {t2-t1:.1f}s win {t3-t2:.1f}s", time.time() - t0


def main():
    out_dir = sys.argv[1]
    nw = int(sys.argv[2]) if len(sys.argv) > 2 else os.cpu_count()
    lst = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "tileList90.txt")
    mx = int(sys.argv[4]) if len(sys.argv) > 4 else None
    os.makedirs(out_dir, exist_ok=True)
    names = [l.strip() for l in open(lst) if l.strip()]
    if mx:
        names = names[:mx]
    # Antarctic tiles last: they have no land-cover data, so their windows are recorded for coverage but
    # never nominated (ice cover cannot be assessed). If time runs out, the usable part is already done.
    names = sorted(names, key=lambda n: parse(n)[0] < -60)
    shard = os.environ.get("SHARD")          # e.g. SHARD=0/3 on laptop A, 1/3 on B, 2/3 on C
    if shard:
        k, n = map(int, shard.split("/"))
        names = names[k::n]
    t0 = time.time(); done = 0
    log = open(os.path.join(out_dir, "run.log"), "a")
    with ProcessPoolExecutor(nw) as ex:
        futs = {ex.submit(process, n, out_dir): n for n in names}
        for f in as_completed(futs):
            n = futs[f]
            try:
                _, msg, dt = f.result()
            except Exception as e:
                msg, dt = "ERROR " + repr(e).replace("\n", " ")[:300], 0
            done += 1
            line = f"{done}/{len(names)} {time.time()-t0:.0f}s {n} {msg}"
            print(line, flush=True); log.write(line + "\n"); log.flush()


if __name__ == "__main__":
    main()
