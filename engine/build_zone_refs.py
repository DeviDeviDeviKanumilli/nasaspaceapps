"""Zone reference profiles for the lunar south-pole base region (v2, 14 Nov evening).

Team-defined terrain-context classes, NOT NASA landing/habitat classifications:
  MZ-FLAT   "flat-terrain context": 10 km lunar windows where >= FLAT_MIN of the ground has slope
            <= 10 deg measured over a 400 m plane fit. (10 deg is the HLS landing-slope limit, but that
            requirement applies at lander-footprint scale, tens of metres; a 400 m slope does not
            certify a landing site.)
  MZ-STEEP  "steep-terrain context": windows where >= STEEP_MIN of the ground has 400 m slope in
            15-30 deg (crater walls, massif flanks; 20 deg appears in suit-walking requirements, again
            at a much smaller scale).
Power-ridge zone not built: polar illumination is not reproducible on Earth.

v2 fixes (audit):
  * Cells are pooled ONCE per site (union of qualifying windows). v1 concatenated overlapping
    windows (2.5 km step, 10 km windows), counting interior cells up to 16 times.
  * Yardstick is leave-one-site-out: each lunar zone window is compared with a reference pooled
    from the OTHER three sites. v1 compared windows with a reference containing themselves
    (optimistic). Both are reported.
  * Threshold sensitivity is reported (FLAT_MIN 0.5/0.6/0.7, STEEP_MIN 0.3/0.4/0.5).

Outputs: adds MZ-FLAT, MZ-STEEP to refs.npz / refs_meta.json; zone_windows.json; zone_report.json.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json, warnings
import numpy as np
warnings.filterwarnings("ignore")
from build_refs import block_mean
from terrain_engine import plane_features_fast
from global_run import LS, QP, CONN_T, CONN_L, largest_fraction

SITES = {"Connecting ridge": (-11000, -12000), "Shackleton rim": (-1000, -7000),
         "de Gerlache rim": (-37000, 15000), "Malapert": (-500, 121500)}
BOX = 40000
WIN, STEP = 100, 25            # cells at 100 m: 10 km windows, 2.5 km step
FLAT_MIN, STEEP_MIN = 0.60, 0.40
SENS = {"MZ-FLAT": (0.5, 0.6, 0.7), "MZ-STEEP": (0.3, 0.4, 0.5)}
MIN_VALID = 0.7


def features(z):
    v = np.isfinite(z); S, R = {}, {}
    for L in LS:
        s, r, _ = plane_features_fast(np.where(v, z, 0.0), v, 100.0, L); S[L] = s; R[L] = r
    allv = v.copy()
    for L in LS:
        allv &= np.isfinite(S[L])
    return S, R, allv


def classify(flat, steep, fmin=FLAT_MIN, smin=STEEP_MIN):
    return "MZ-FLAT" if flat >= fmin else ("MZ-STEEP" if steep >= smin else None)


def site_windows(S, allv):
    n = allv.shape[0]; out = []
    for i in range(0, n - WIN + 1, STEP):
        for j in range(0, n - WIN + 1, STEP):
            v = allv[i:i + WIN, j:j + WIN]
            if v.mean() < MIN_VALID:
                continue
            s4 = S[400][i:i + WIN, j:j + WIN][v]
            out.append((i, j, float((s4 <= 10).mean()), float(((s4 >= 15) & (s4 <= 30)).mean())))
    return out


def pooled(cells_by_site, sites):
    s = {L: np.concatenate([cells_by_site[x][0][L] for x in sites if x in cells_by_site]) for L in LS}
    r = {L: np.concatenate([cells_by_site[x][1][L] for x in sites if x in cells_by_site]) for L in LS}
    sq = np.stack([np.quantile(s[L], QP) for L in LS])
    rq = np.stack([np.quantile(np.log10(np.maximum(r[L], 1e-3)), QP) for L in LS])
    return sq, rq


def build(data, zone, fmin, smin):
    """Pool unique cells of qualifying windows per site; per-window quantiles; connectivity curves."""
    cells, wins = {}, []
    for site, (S, R, allv, W) in data.items():
        union = np.zeros_like(allv)
        for (i, j, flat, steep) in W:
            if classify(flat, steep, fmin, smin) != zone:
                continue
            union[i:i + WIN, j:j + WIN] = True
            v = allv[i:i + WIN, j:j + WIN]
            q = np.stack([np.quantile(S[L][i:i + WIN, j:j + WIN][v], QP) for L in LS])
            cc = [largest_fraction(v & (S[CONN_L][i:i + WIN, j:j + WIN] <= t), v) for t in CONN_T]
            wins.append(dict(site=site, i=i, j=j, q=q, cc=cc))
        m = union & allv
        if m.any():
            cells[site] = ({L: S[L][m] for L in LS}, {L: R[L][m] for L in LS})
    return cells, wins


def w1max(q, ref):
    return float(np.abs(q - ref).mean(1).max())


def main():
    from lolaread import read
    data = {}
    for site, (cx, cy) in SITES.items():
        z = block_mean(read("", cx, cy, BOX)[0], 5)
        S, R, allv = features(z)
        data[site] = (S, R, allv, site_windows(S, allv))
        print(site, "windows", len(data[site][3]), flush=True)
    refs = dict(np.load("refs.npz")); meta = json.load(open("refs_meta.json"))
    report = {"note": "team-defined terrain-context classes; not NASA landing/habitat classifications",
              "rules": {"MZ-FLAT": f"share of 400 m slope <= 10 deg >= {FLAT_MIN}",
                        "MZ-STEEP": f"share of 400 m slope in 15-30 deg >= {STEEP_MIN} (and not MZ-FLAT)"},
              "zones": {}, "sensitivity": {}}
    listing = []
    for site, (S, R, allv, W) in data.items():
        cx, cy = SITES[site]
        for (i, j, flat, steep) in W:
            listing.append(dict(site=site, x=cx - BOX / 2 + (j + WIN / 2) * 100, y=cy + BOX / 2 - (i + WIN / 2) * 100,
                                share_le10=round(flat, 3), share_15_30=round(steep, 3), zone=classify(flat, steep)))
    for zone in ("MZ-FLAT", "MZ-STEEP"):
        cells, wins = build(data, zone, FLAT_MIN, STEEP_MIN)
        sq, rq = pooled(cells, list(cells))
        cc = np.mean([w["cc"] for w in wins], axis=0)
        refs[zone + "_slope_q"] = sq; refs[zone + "_lrough_q"] = rq; refs[zone + "_conn"] = cc
        n_cells = int(sum(cells[s][0][400].size for s in cells))
        in_sample = [w1max(w["q"], sq) for w in wins]
        loso = []
        for w in wins:
            others = [s for s in cells if s != w["site"]]
            if others:
                loso.append(w1max(w["q"], pooled(cells, others)[0]))
        per_site = {s: sum(1 for w in wins if w["site"] == s) for s in SITES}
        stats = lambda v: dict(n=len(v), p10=round(float(np.percentile(v, 10)), 2), median=round(float(np.median(v)), 2),
                               p90=round(float(np.percentile(v, 90)), 2))
        report["zones"][zone] = dict(n_windows=len(wins), windows_per_site=per_site, n_unique_cells=n_cells,
                                     median_slope_by_baseline={str(L): round(float(sq[k, 24:26].mean()), 2) for k, L in enumerate(LS)},
                                     yardstick_in_sample=stats(in_sample), yardstick_leave_one_site_out=stats(loso))
        meta[zone] = dict(body="Moon", ref_type="zone (team-defined terrain context)",
                          desc=("Moon flat-terrain context, pooled from 4 south-pole sites" if zone == "MZ-FLAT"
                                else "Moon steep-terrain context, pooled from 4 south-pole sites"),
                          grid_m=100.0, baselines=list(LS), conn_baseline=CONN_L, n_windows=len(wins),
                          rule=report["rules"][zone], yardstick_leave_one_site_out=report["zones"][zone]["yardstick_leave_one_site_out"])
        print(zone, json.dumps(report["zones"][zone]), flush=True)
        sens = {}
        for th in SENS[zone]:
            c2, w2 = build(data, zone, th if zone == "MZ-FLAT" else FLAT_MIN, th if zone == "MZ-STEEP" else STEEP_MIN)
            if not c2:
                sens[str(th)] = dict(n_windows=0); continue
            sq2, _ = pooled(c2, list(c2))
            sens[str(th)] = dict(n_windows=len(w2), median_slope_by_baseline=[round(float(sq2[k, 24:26].mean()), 2) for k in range(len(LS))],
                                 w1_to_adopted_reference_deg=round(w1max(sq2, sq), 2))
        report["sensitivity"][zone] = sens
        print(" sensitivity", json.dumps(sens), flush=True)
    for rid in ("M-CR", "M-SR", "M-DG", "M-MA"):
        meta[rid]["ref_type"] = "site box (whole PGDA site outline)"
    meta["M-SR"]["warning"] = ("heterogeneous: box mixes rim and steep crater wall; quarter-to-whole distances 7.7-13 deg; "
                               "do not use as a headline reference")
    np.savez("refs.npz", **refs); json.dump(meta, open("refs_meta.json", "w"), indent=1)
    json.dump(listing, open("zone_windows.json", "w"), indent=1)
    json.dump(report, open("zone_report.json", "w"), indent=1)


if __name__ == "__main__":
    main()
