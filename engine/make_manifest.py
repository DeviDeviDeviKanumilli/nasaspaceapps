"""Frozen run manifest: what was analysed, with what, and what failed.

Usage: python3 make_manifest.py FEATURE_DIR CANDIDATES_JSON OUT_MANIFEST_JSON [tile_list.txt] [OUT_COVERAGE_PNG]

Reports: expected vs processed tiles, tiles with windows / skipped (and why) / failed, windows
evaluated, windows excluded from nomination (snow/ice, unknown land cover), coverage by latitude band,
runtime from run.log, software versions, method parameters, input dataset versions, and SHA-256 of
every output file. Acceptance criteria for calling the run "global" are evaluated and printed.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, os, glob, json, hashlib, platform, datetime, re
import numpy as np
import global_run as G


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    fdir, cand, out = sys.argv[1:4]
    lst = sys.argv[4] if len(sys.argv) > 4 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "tileList90.txt")
    png = sys.argv[5] if len(sys.argv) > 5 else None
    expected = [l.strip() for l in open(lst) if l.strip()]
    files = {os.path.basename(f)[:-4]: f for f in glob.glob(os.path.join(fdir, "*.npz")) if not f.endswith(".tmp.npz")}
    status, nwin, lat_all, lon_all, snow_all = {}, 0, [], [], []
    for t in expected:
        if t not in files:
            status[t] = "missing (failed or not run)"; continue
        z = np.load(files[t])
        meta = [str(x) for x in z["meta"]] if "meta" in z.files else []
        if z["lat"].size:
            status[t] = "windows"; nwin += int(z["lat"].size)
            lat_all.append(z["lat"]); lon_all.append(z["lon"]); snow_all.append(z["snow"])
        else:
            status[t] = meta[2] if len(meta) > 2 else "no windows"
    counts = {}
    for s in status.values():
        counts[s] = counts.get(s, 0) + 1
    lat = np.concatenate(lat_all) if lat_all else np.zeros(0); snow = np.concatenate(snow_all) if snow_all else np.zeros(0)
    bands = {}
    for t, s in status.items():
        la = G.parse(t)[0]; b = f"{int(np.floor(la / 30) * 30):+d} to {int(np.floor(la / 30) * 30 + 30):+d}"
        d = bands.setdefault(b, {"expected": 0, "processed": 0, "with_windows": 0})
        d["expected"] += 1; d["processed"] += s != "missing (failed or not run)"; d["with_windows"] += s == "windows"
    errors, t_first, t_last = [], None, None
    logp = os.path.join(fdir, "run.log")
    if os.path.exists(logp):
        lines = open(logp).read().splitlines()
        errors = [l for l in lines if " ERROR " in l]
        secs = [int(m.group(1)) for l in lines for m in [re.match(r"\d+/\d+ (\d+)s", l)] if m]
        t_last = max(secs) if secs else None
    try:
        import scipy, rasterio, pyproj
        versions = dict(python=platform.python_version(), numpy=np.__version__, scipy=scipy.__version__,
                        rasterio=rasterio.__version__, gdal=rasterio.__gdal_version__, pyproj=pyproj.__version__,
                        platform=platform.platform(), machine=platform.machine())
    except Exception as e:
        versions = dict(error=str(e))
    processed = len(expected) - counts.get("missing (failed or not run)", 0)
    m = {
        "created_utc": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "software": versions,
        "code_sha256": {f: sha(f) for f in ("global_run.py", "terrain_engine.py", "compare.py", "build_refs.py", "build_zone_refs.py") if os.path.exists(f)},
        "parameters": dict(grid_m=G.GRID, baselines_m=list(G.LS), window_cells=G.WIN, stride_cells=G.STRIDE,
                           quantile_levels=len(G.QP), connectivity_thresholds_deg=list(G.CONN_T), connectivity_baseline_m=G.CONN_L,
                           min_valid_fraction=G.MIN_VALID, worldcover_masked_classes=list(G.MASK),
                           exposure_classes=list(G.BARE), snow_classes=list(G.SNOW),
                           antarctic_rule="no WorldCover south of 60S: cells <= 1 m treated as water; windows never nominated"),
        "datasets": {"earth_dem": "Copernicus DEM GLO-90 COG, s3://copernicus-dem-90m (release as served on run date)",
                     "land_cover": "ESA WorldCover 2021 v200, s3://esa-worldcover/v200/2021/map (20 m overview)",
                     "moon": "NASA GSFC PGDA LOLA LDEM_80S_20MPP_ADJ (product 90) + PGDA product 78 site outlines",
                     "mars": "USGS Astrogeology Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2"},
        "tiles": dict(expected=len(expected), processed=processed, by_status=counts,
                      failed_or_missing=[t for t, s in status.items() if s.startswith("missing")][:500]),
        "windows": dict(evaluated=nwin, excluded_snow_ice_gt_half=int(np.sum(np.isfinite(snow) & (snow > 0.5))),
                        excluded_landcover_unknown=int(np.sum(~np.isfinite(snow)))),
        "coverage_by_latitude_band": bands,
        "runtime_seconds_from_log": t_last, "errors_in_log": len(errors), "first_errors": errors[:20],
        "outputs_sha256": {os.path.basename(p): sha(p) for p in [cand, "refs.npz", "refs_meta.json"] if os.path.exists(p)},
        "known_coverage_limits": [
            "windows never cross 1-degree tile seams; cells within ~1.6 km of a seam have no 3.2 km-baseline slope",
            "tiles north/south of ~84.5 deg are narrower than a 10 km window",
            "cells under trees, crops, buildings, water or wetland (WorldCover) are masked; a cell's 3.2 km disc must be fully unmasked",
            "Antarctica: no land cover; recorded for coverage only"],
    }
    acc = {
        "all_tiles_processed": processed == len(expected),
        "error_rate_below_0.5pct": len(errors) <= 0.005 * len(expected),
        "every_latitude_band_processed": all(d["processed"] == d["expected"] for d in bands.values()),
    }
    m["acceptance"] = acc
    full_list = len(expected) >= 26475
    if all(acc.values()) and full_list:
        m["describe_as"] = "global: all 26,475 Copernicus GLO-90 land tiles processed (see known_coverage_limits)"
    elif all(acc.values()):
        m["describe_as"] = f"complete for the supplied tile list only ({len(expected)} tiles); NOT global"
    else:
        m["describe_as"] = f"partial: {processed} of {len(expected)} tiles in the supplied list processed; see coverage_by_latitude_band"
    json.dump(m, open(out, "w"), indent=1)
    print(json.dumps({k: m[k] for k in ("tiles", "windows", "acceptance", "describe_as")}, indent=1))
    if png:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(13, 6.5), dpi=130)
        col = {"windows": "#2a7f62", "missing (failed or not run)": "#d62728"}
        for t, s in status.items():
            la, lo = G.parse(t)
            ax.add_patch(plt.Rectangle((lo, la), 1, 1, color=col.get(s, "#bdbdbd"), lw=0))
        ax.set_xlim(-180, 180); ax.set_ylim(-90, 90); ax.set_aspect(1)
        ax.set_title("Terrain-run coverage: green = measured windows, grey = processed but no usable window "
                     "(vegetation, snow, narrow tile), red = not processed", fontsize=9)
        fig.tight_layout(); fig.savefig(png); plt.close(fig)


if __name__ == "__main__":
    main()
