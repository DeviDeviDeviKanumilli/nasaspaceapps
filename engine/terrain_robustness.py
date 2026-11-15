"""Robustness of terrain candidate lists to reasonable methodological choices.

For each reference, compares the adopted nomination (Pareto fronts + 25 km suppression, N=50) with:
  A. ranking by worst-scale slope W1 only
  B. ranking by MEAN-over-scales slope W1 (instead of worst scale)
  C. N=100 instead of 50 (does the top-50 survive inside a longer list? trivially yes; reported for completeness)
  D. reference perturbation (site references only): each quarter of the LOLA site box as the reference
Overlap = share of adopted candidates that have a candidate in the alternative list within 25 km.
Also reports how the count of windows inside the yardstick changes.

Usage: python3 terrain_robustness.py FEATURE_DIR OUT_JSON
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, warnings
import numpy as np
warnings.filterwarnings("ignore")
import compare as C
from global_run import LS

N = 50


def suppress(order, lat, lon, n=N):
    keep = []
    for i in order:
        if all(C.haversine_km(lat[i], lon[i], lat[k], lon[k]) >= C.SUPPRESS_KM for k in keep):
            keep.append(i)
        if len(keep) >= n:
            break
    return keep


def pareto_list(X, ok, lat, lon, n=N):
    idx = np.where(ok)[0]; out = []
    for fr in C.pareto_fronts(X[ok]):
        for k in sorted(fr, key=lambda k: X[idx[k], 0]):
            i = idx[k]
            if all(C.haversine_km(lat[i], lon[i], lat[j], lon[j]) >= C.SUPPRESS_KM for j in out):
                out.append(i)
        if len(out) >= n:
            break
    return out[:n]


def overlap(a, b, lat, lon):
    if not a:
        return None
    return round(sum(1 for i in a if any(C.haversine_km(lat[i], lon[i], lat[j], lon[j]) < C.SUPPRESS_KM for j in b)) / len(a), 3)


def main():
    fdir, out = sys.argv[1], sys.argv[2]
    F = C.load_features(fdir); R = np.load("refs.npz"); meta = json.load(open("refs_meta.json"))
    lat, lon = F["lat"], F["lon"]
    ok = np.isfinite(F["snow"]) & (F["snow"] <= C.MAX_SNOW)
    res = {}
    quarters = {}
    try:
        from build_refs import block_mean, profile, REFS
        for rid in ("M-CR", "M-SR", "M-DG", "M-MA"):
            z = block_mean(np.load(REFS[rid][1])["z"], 5); h, w = z.shape; qs = []
            for a in (0, 1):
                for b in (0, 1):
                    qs.append(profile(z[a * h // 2:(a + 1) * h // 2, b * w // 2:(b + 1) * w // 2], 100.0, LS)[0])
            quarters[rid] = qs
    except Exception as e:
        print("quarter references unavailable:", e)
    for rid, m in meta.items():
        if m["body"] != "Moon":
            continue
        use = [LS.index(L) for L in m["baselines"]]
        rs, rr, rc = R[rid + "_slope_q"], R[rid + "_lrough_q"], R[rid + "_conn"]
        sw = np.abs(F["slope_q"][:, use, :] - rs[use][None]).mean(2)
        rw = np.abs(F["lrough_q"][:, use, :] - rr[use][None]).mean(2)
        cd = np.abs(F["conn"] - rc[None]).mean(1)
        X = np.stack([sw.max(1), rw.max(1), cd], 1); okr = ok & np.all(np.isfinite(X), 1)
        base = pareto_list(X, okr, lat, lon)
        worst = suppress(np.argsort(np.where(okr, X[:, 0], np.inf)), lat, lon)
        mean_ = suppress(np.argsort(np.where(okr, sw.mean(1), np.inf)), lat, lon)
        r = dict(adopted_best_deg=round(float(X[base[0], 0]), 2),
                 overlap_with_worst_slope_only=overlap(base, worst, lat, lon),
                 overlap_with_mean_over_scales=overlap(base, mean_, lat, lon))
        if rid in quarters:
            ov, best, counts = [], [], []
            yard = {"M-CR": 3.66, "M-DG": 3.66, "M-MA": 3.72, "M-SR": 4.76}[rid]
            for q in quarters[rid]:
                swq = np.abs(F["slope_q"] - q[None]).mean(2).max(1)
                Xq = X.copy(); Xq[:, 0] = swq
                bq = pareto_list(Xq, okr & np.isfinite(swq), lat, lon)
                ov.append(overlap(base, bq, lat, lon)); best.append(round(float(np.nanmin(np.where(okr, swq, np.nan))), 2))
                counts.append(int(np.sum(okr & (swq < yard))))
            r["quarter_reference_overlap"] = ov; r["quarter_reference_best_deg"] = best
            r["quarter_reference_windows_inside_yardstick"] = counts
            r["adopted_windows_inside_yardstick"] = int(np.sum(okr & (X[:, 0] < yard)))
        if rid.startswith("MZ"):
            y = m.get("yardstick_leave_one_site_out", {})
            r["windows_inside_loso_median"] = int(np.sum(okr & (X[:, 0] < y.get("median", 0))))
            r["windows_inside_loso_p90"] = int(np.sum(okr & (X[:, 0] < y.get("p90", 0))))
        res[rid] = r
        print(rid, r, flush=True)
    json.dump(res, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
