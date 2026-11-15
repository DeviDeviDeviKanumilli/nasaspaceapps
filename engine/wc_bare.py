"""Global 0.01-degree fraction of 'exposed' land cover from ESA WorldCover 2021 v200
(bare/sparse vegetation = 60, moss and lichen = 100), using each 3x3 degree tile's 320 m overview.
Output: wc_bare_001.npy, uint8 (0..200 = fraction*200; 255 = no WorldCover data).

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import math, sys, time, warnings
import numpy as np
from concurrent.futures import ThreadPoolExecutor
warnings.filterwarnings("ignore")
import rasterio
from rasterio.warp import reproject, Resampling
from affine import Affine

RES = 0.01
NY, NX = 18000, 36000
ENV = dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
           GDAL_HTTP_MAX_RETRY="4", GDAL_HTTP_RETRY_DELAY="2")


def one(la, lo):
    n = (f"ESA_WorldCover_10m_2021_v200_{'N' if la >= 0 else 'S'}{abs(la):02d}"
         f"{'E' if lo >= 0 else 'W'}{abs(lo):03d}_Map.tif")
    try:
        with rasterio.Env(**ENV):
            with rasterio.open(f"/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/{n}", OVERVIEW_LEVEL=4) as w:
                a = w.read(1)
                bare = np.isin(a, (60, 100)).astype(np.float32)
                bare[a == 0] = np.nan
                dst = np.full((300, 300), np.nan, np.float32)
                reproject(bare, dst, src_transform=w.transform, src_crs=w.crs, src_nodata=np.nan,
                          dst_transform=Affine(RES, 0, lo, 0, -RES, la + 3), dst_crs="EPSG:4326",
                          dst_nodata=np.nan, resampling=Resampling.average)
        return la, lo, dst
    except Exception:
        return la, lo, None


if __name__ == "__main__":
    out = np.full((NY, NX), 255, np.uint8)
    jobs = [(la, lo) for la in range(-60, 84, 3) for lo in range(-180, 180, 3)]
    t0 = time.time(); got = 0
    with ThreadPoolExecutor(int(sys.argv[1]) if len(sys.argv) > 1 else 12) as ex:
        for k, (la, lo, d) in enumerate(ex.map(lambda p: one(*p), jobs)):
            if d is not None:
                got += 1
                i0 = int(round((90 - (la + 3)) / RES)); j0 = int(round((lo + 180) / RES))
                v = np.where(np.isfinite(d), np.round(d * 200), 255).astype(np.uint8)
                out[i0:i0 + 300, j0:j0 + 300] = v
            if k % 200 == 0:
                print(k, "/", len(jobs), "tiles found", got, round(time.time() - t0), "s", flush=True)
    np.save("wc_bare_001.npy", out)
    print("done", got, "tiles", round(time.time() - t0), "s")
