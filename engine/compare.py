"""Compare every stored window against each reference and nominate terrain candidates.

Distances (never summed, never normalised):
  slope_W1[L]  = mean |Q_window(p) - Q_ref(p)| over 50 midpoint quantile levels  (degrees)
  rough_W1[L]  = same for log10 roughness                                        (decades)
  worst_slope  = max over the reference's baselines of slope_W1
  worst_rough  = max over the reference's baselines of rough_W1
  conn_dist    = mean |connectivity curve difference|                             (area fraction)
Nomination: successive non-dominated fronts on (worst_slope, worst_rough, conn_dist) until >= N,
then 25 km suppression keeping the smaller worst_slope.

Usage: python3 compare.py FEATURE_DIR OUT_JSON [N]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, os, glob, json, math, time, hashlib, datetime, subprocess
import numpy as np
from global_run import LS, QP, CONN_T

N_DEFAULT = 50
MAX_SNOW = 0.5      # windows more than half snow/ice are ice surfaces, not rock or regolith: not nominated
SUPPRESS_KM = 25.0


def load_features(d):
    parts = {k: [] for k in ("lat", "lon", "valid", "bare", "snow", "slope_q", "lrough_q", "conn")}
    tiles = []
    for f in sorted(glob.glob(os.path.join(d, "*.npz"))):
        z = np.load(f)
        if z["lat"].size == 0:
            continue
        for k in parts:
            parts[k].append(z[k])
        tiles += [os.path.basename(f)[:-4]] * z["lat"].size
    F = {k: np.concatenate(v).astype(np.float32) for k, v in parts.items()}
    F["tile"] = np.array(tiles)
    return F


def first_front(X, idx):
    """Non-dominated subset (minimisation) of rows idx of X."""
    Y = X[idx]; order = np.argsort(Y[:, 0], kind="stable"); Y = Y[order]; r = idx[order]
    alive = np.arange(len(Y)); keep = []
    while alive.size:
        i = alive[0]; keep.append(i)
        Z = Y[alive]
        dom = np.all(Y[i] <= Z, axis=1) & np.any(Y[i] < Z, axis=1)
        dom[0] = True                      # remove i itself from the alive list
        alive = alive[~dom]
    keep = np.array(keep)
    # a kept point can still be dominated by a later kept point with an equal first objective
    K = Y[keep]
    nd = np.array([not np.any(np.all(K <= K[a], 1) & np.any(K < K[a], 1)) for a in range(len(K))])
    return r[keep[nd]]


def pareto_fronts(X):
    """Yield successive non-dominated fronts."""
    rem = np.arange(len(X))
    while rem.size:
        f = first_front(X, rem); yield f
        rem = np.setdiff1d(rem, f)


def haversine_km(lat1, lon1, lat2, lon2):
    p = np.radians
    a = np.sin(p(lat2 - lat1) / 2) ** 2 + np.cos(p(lat1)) * np.cos(p(lat2)) * np.sin(p(lon2 - lon1) / 2) ** 2
    return 6371.0 * 2 * np.arcsin(np.sqrt(a))


def main():
    fdir, out_json = sys.argv[1], sys.argv[2]
    N = int(sys.argv[3]) if len(sys.argv) > 3 else N_DEFAULT
    F = load_features(fdir)
    R = np.load("refs.npz"); meta = json.load(open("refs_meta.json"))
    snow = F["snow"]
    surface_ok = np.isfinite(snow) & (snow <= MAX_SNOW)
    try:
        commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or None
    except Exception:
        commit = None
    # coverage: every tile file, with its window count or skip reason
    cov = {}
    for f in sorted(glob.glob(os.path.join(fdir, "*.npz"))):
        z = np.load(f)
        meta_t = [str(x) for x in z["meta"]] if "meta" in z.files else []
        cov[os.path.basename(f)[:-4]] = int(z["lat"].size) if z["lat"].size else (meta_t[2] if len(meta_t) > 2 else "no windows")
    res = {"run": {"created_utc": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z", "code_commit": commit,
                   "nominated_per_reference": N, "suppression_km": SUPPRESS_KM, "max_snow_ice_fraction": MAX_SNOW},
           "datasets": {"earth_dem": "Copernicus DEM GLO-90 (AWS copernicus-dem-90m)",
                        "land_cover": "ESA WorldCover 2021 v200 (20 m overview)",
                        "moon": "NASA PGDA LOLA LDEM_80S_20MPP (product 90)",
                        "mars": "USGS MOLA-HRSC blended DEM 200 m v2"},
           "n_windows": int(F["lat"].size), "n_tiles": int(len(set(F["tile"]))),
           "n_windows_not_nominated_snow_ice": int(np.sum(np.isfinite(snow) & (snow > MAX_SNOW))),
           "n_windows_not_nominated_landcover_unknown": int(np.sum(~np.isfinite(snow))),
           "coverage": cov, "references": {}}
    for rid, m in meta.items():
        use = [LS.index(L) for L in m["baselines"]]
        rs = R[rid + "_slope_q"]; rr = R[rid + "_lrough_q"]; rc = R[rid + "_conn"]
        sw = np.abs(F["slope_q"][:, use, :] - rs[use][None]).mean(2)          # (n, nb) degrees
        rw = np.abs(F["lrough_q"][:, use, :] - rr[use][None]).mean(2)         # decades
        cd = np.abs(F["conn"] - rc[None]).mean(1)
        X = np.stack([sw.max(1), rw.max(1), cd], 1)
        ok = np.all(np.isfinite(X), 1) & surface_ok
        okidx = np.where(ok)[0]
        cand = []
        for fi, fr in enumerate(pareto_fronts(X[ok])):
            for k in sorted(fr, key=lambda k: X[okidx[k], 0]):
                i = okidx[k]
                if any(haversine_km(F["lat"][i], F["lon"][i], F["lat"][c["_i"]], F["lon"][c["_i"]]) < SUPPRESS_KM for c in cand):
                    continue
                cand.append({"_i": int(i), "front": fi + 1})
            if len(cand) >= N:
                break
        recs = []
        for c in cand[:N]:
            i = c["_i"]
            recs.append({
                "lat": round(float(F["lat"][i]), 4), "lon": round(float(F["lon"][i]), 4),
                "tile": str(F["tile"][i]), "pareto_front": c["front"],
                "worst_scale_slope_W1_deg": round(float(X[i, 0]), 3),
                "worst_scale_log10_roughness_W1": round(float(X[i, 1]), 3),
                "connectivity_distance": round(float(X[i, 2]), 3),
                "slope_W1_deg_by_baseline": {str(m["baselines"][k]): round(float(sw[i, k]), 3) for k in range(len(use))},
                "median_slope_deg_by_baseline": {str(LS[j]): round(float(F["slope_q"][i, j, 24:26].mean()), 2) for j in range(len(LS))},
                "valid_fraction": round(float(F["valid"][i]), 3),
                "bare_fraction": None if not np.isfinite(F["bare"][i]) else round(float(F["bare"][i]), 3),
                "snow_ice_fraction": None if not np.isfinite(F["snow"][i]) else round(float(F["snow"][i]), 3),
            })
        res["references"][rid] = {"meta": m, "n_compared": int(ok.sum()), "candidates": recs}
        print(rid, "compared", int(ok.sum()), "nominated", len(recs),
              "best worst-slope W1 %.2f deg" % (recs[0]["worst_scale_slope_W1_deg"] if recs else float("nan")), flush=True)
    json.dump(res, open(out_json, "w"), indent=1)


if __name__ == "__main__":
    main()
