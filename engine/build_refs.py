"""Build reference profiles in exactly the same representation as global_run.py windows.

Moon: LOLA 20 m south-pole DEM boxes (lola20_*.npz from lolaread.py), averaged to 100 m.
Mars: USGS MOLA-HRSC blended 200 m DEM, 1-degree boxes; only baselines >= 1600 m are used.
Output: refs.npz with, per reference, slope/log-roughness quantiles per baseline + connectivity.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, math, json, warnings
import numpy as np
from scipy import ndimage
warnings.filterwarnings("ignore")
from terrain_engine import plane_features_fast
from global_run import LS, QP, CONN_T, CONN_L, largest_fraction


def block_mean(a, f):
    h, w = (a.shape[0] // f) * f, (a.shape[1] // f) * f; a = a[:h, :w]
    v = np.isfinite(a)
    s = np.where(v, a, 0).reshape(h // f, f, w // f, f).sum((1, 3))
    n = v.reshape(h // f, f, w // f, f).sum((1, 3))
    out = s / np.maximum(n, 1); out[n < f * f] = np.nan
    return out


def profile(z, grid, Ls):
    v = np.isfinite(z)
    S, R = {}, {}
    for L in Ls:
        s, r, _ = plane_features_fast(np.where(v, z, 0.0), v, grid, L); S[L] = s; R[L] = r
    allv = np.ones_like(v)
    for L in Ls:
        allv &= np.isfinite(S[L])
    sq = np.full((len(LS), len(QP)), np.nan); rq = np.full((len(LS), len(QP)), np.nan)
    for k, L in enumerate(LS):
        if L in S:
            sq[k] = np.quantile(S[L][allv], QP)
            rq[k] = np.quantile(np.log10(np.maximum(R[L][allv], 1e-3)), QP)
    cl = CONN_L if CONN_L in S else min(Ls)
    cc = [largest_fraction(allv & (S[cl] <= t), allv) for t in CONN_T]
    return sq, rq, np.array(cc), int(allv.sum()), cl


def mars_box(lat, lon, half=0.5):
    import rasterio
    from rasterio.windows import from_bounds
    from scipy.ndimage import zoom
    URL = "/vsicurl/https://planetarymaps.usgs.gov/mosaic/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif"
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        with rasterio.open(URL) as d:
            lon180 = lon - 360 if lon > 180 else lon
            w = from_bounds(lon180 - half, lat - half, lon180 + half, lat + half, d.transform)
            z = d.read(1, window=w).astype(float); z[z == d.nodata] = np.nan
            res = d.res[0]
    dy = res * math.pi / 180 * 3396190.0; dx = dy * math.cos(math.radians(lat))
    z = zoom(z, (1, dx / dy), order=1)   # square pixels of size dy (~213 m)
    return z, dy


REFS = {
    # id: (body, source, description)
    "M-CR": ("Moon", "lola20_Site01_connecting_ridge.npz", "Connecting ridge (PGDA Site01)"),
    "M-SR": ("Moon", "lola20_Site04_shackleton_rim.npz", "Shackleton rim (PGDA Site04)"),
    "M-DG": ("Moon", "lola20_Site11_degerlache_rim.npz", "de Gerlache rim (PGDA Site11)"),
    "M-MA": ("Moon", "lola20_Site23_malapert.npz", "Malapert massif (PGDA Site23)"),
    "R-JZ": ("Mars", (18.44, 77.45), "Jezero crater, 1 degree box"),
    "R-IS": ("Mars", (4.502, 135.623), "InSight landing site, Elysium Planitia, 1 degree box"),
}

if __name__ == "__main__":
    out = {}
    meta = {}
    for rid, (body, src, desc) in REFS.items():
        if body == "Moon":
            z = block_mean(np.load(src)["z"], 5); grid = 100.0; Ls = LS
        else:
            z, grid = mars_box(*src); Ls = (1600, 3200)
        sq, rq, cc, n, cl = profile(z, grid, Ls)
        out[rid + "_slope_q"] = sq; out[rid + "_lrough_q"] = rq; out[rid + "_conn"] = cc
        meta[rid] = dict(body=body, desc=desc, grid_m=grid, baselines=list(Ls), conn_baseline=cl, n_cells=n)
        print(rid, desc, "median slope by baseline:", np.round(sq[:, 24:26].mean(1), 2), "conn:", np.round(cc, 2), flush=True)
    np.savez("refs.npz", **out)
    json.dump(meta, open("refs_meta.json", "w"), indent=1)
