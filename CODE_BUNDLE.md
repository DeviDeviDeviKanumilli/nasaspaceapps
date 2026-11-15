# CODE_BUNDLE — engine/*.py and app/*.dart (Space Apps 2026, drafted with AI assistance by Claude, Anthropic)

## engine/app_geo_v2.py

```python
"""Build the optional `geology_v2` block of app_bundle.json from regional_geology_v2 outputs (schema geo-2.0).

Additive: existing app_bundle fields are untouched, schema_version stays "1.0", and consumers that ignore
unknown keys keep working. Every string comes from the engine outputs or fixed templates; nothing is generated.

Usage (standalone):  python3 app_geo_v2.py OUT.json geology_v2_nj.json[:study] geology_v2_hartford.json[:held-out]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json
import sys

BLOCK_VERSION = "geo-2.0-app-1"
ROLE_LABEL = {"core": "required", "supporting": "supporting", "contradiction": "rules out", "caution": "caution",
              "earth_only": "Earth-only indicator", "not_compared": "Mars only (not compared)", "context": "context"}


def rows_for_app(rows):
    out = []
    for r in rows:
        ev = r.get("earth_evidence") or {}
        out.append(dict(property=r["property"], role=r["role"], role_label=ROLE_LABEL.get(r["role"], r["role"]), mars_site=r.get("site"),
                        mars_evidence_type=r["planetary_evidence"], mars_statement=r["planetary"], citations=r["sources"],
                        earth_status=r["earth_status"], earth_source=ev.get("source") if isinstance(ev, dict) else None,
                        earth_text=(ev.get("text") or "")[:160] if isinstance(ev, dict) else None))
    return out


def unit_cards(d, region):
    cards = {}
    for rid, cands in d["candidates"].items():
        for c in cands:
            k = (rid, c["unit_link"])
            L1 = c["layer_1_geological_evidence"]
            u = cards.setdefault(k, dict(id=f"{region}:{rid}:{c['unit_link']}", region=region, reference=rid, unit_name=c["unit_name"],
                                         unit_link=c["unit_link"], state=c["state"], unit_age=c["unit_age"], polygons=0, area_km2=0.0,
                                         nearest_distance_km=None, best=None, steep_ground_km2=0.0, public_steep_ground_km2=0.0,
                                         public_lands_with_steep_ground=[], look_here=[], exposure_checked_polygons=0))
            u["polygons"] += 1; u["area_km2"] = round(u["area_km2"] + c["area_km2"], 3)
            if u["nearest_distance_km"] is None or c["distance_km"] < u["nearest_distance_km"]:
                u["nearest_distance_km"] = c["distance_km"]; u["nearest_point"] = c["representative_point"]
            key = (L1["n_supporting_recorded"], c["area_km2"])
            if u["best"] is None or key > u["best"][0]:
                u["best"] = (key, c)
            if "layer_2_exposure" in c:
                u["exposure_checked_polygons"] += 1
                u["steep_ground_km2"] = round(u["steep_ground_km2"] + (c["layer_2_exposure"]["steep_ground_km2"] or 0), 3)
                u["public_steep_ground_km2"] = round(u["public_steep_ground_km2"] + (c["layer_3_access"]["public_steep_ground_km2"] or 0), 3)
                for n in c["layer_3_access"]["public_lands_with_steep_ground"]:
                    if n and n not in u["public_lands_with_steep_ground"]:
                        u["public_lands_with_steep_ground"].append(n)
                u["look_here"] += c["layer_4_d435"].get("look_here", [])
    out = []
    for (rid, link), u in cards.items():
        c = u.pop("best")[1]; L1 = c["layer_1_geological_evidence"]
        ms = L1.get("macrostrat") or {}
        u.update(how_core_was_established=[dict(property=r["property"], earth_status=r["earth_status"])
                                           for r in L1["comparison"] if r["role"] == "core"],
                 supporting_recorded=L1["supporting_properties_recorded"], supporting_total=L1["n_supporting_total"],
                 conflicts=L1["conflicts"], spatial_context=L1["spatial_context"],
                 macrostrat=dict(name_matches=ms.get("name_matches"), accepted=len(ms.get("accepted", [])), rejected=ms.get("rejected", [])),
                 map_source=L1["source"], comparison=rows_for_app(L1["comparison"]), representative_polygon=c["polygon_index"],
                 look_here=sorted(u["look_here"], key=lambda x: -x["steep_public_m2"])[:3],
                 exposure_note="steep ground >= 25 deg on ~20 m DEM is an outcrop proxy, not confirmed rock; checked on the "
                               f"{u['exposure_checked_polygons']} highest-ranked polygons of this unit only",
                 not_comparable=c["not_comparable"], unmeasured=c["unmeasured"])
        out.append(u)
    out.sort(key=lambda u: (u["region"], u["reference"], -len(u["supporting_recorded"]), -u["area_km2"]))
    return out


def featured(d, region):
    """Featured cases come only from independent validations recorded in the engine output."""
    out = []
    for vid, v in (d.get("validation") or {}).items():
        if "mars_lake_candidates_overlapping_preserve" not in v:
            continue
        idx = {c["polygon_index"]: c for c in d["candidates"]["MARS-LAKE"]}
        hits = [h for h in v["mars_lake_candidates_overlapping_preserve"] if h.get("polygon_index") in idx]
        named = [h for h in hits if "Lockatong" in h["unit"]] if v["outcome"].startswith("PASS") else hits
        h = max(named, key=lambda h: len(h["supporting"]), default=None)
        if h is None:
            continue
        c = idx[h["polygon_index"]]
        out.append(dict(id=f"{region}:{vid}", region=region, reference="MARS-LAKE", title="Independent check: " + v["guide"],
                        outcome=v["outcome"], preserve_area_km2=v["preserve_area_km2"], units_mapped_in_preserve=v["units_mapped_in_preserve"],
                        unit_name=c["unit_name"], unit_link=c["unit_link"], polygon_area_km2=c["area_km2"],
                        share_within_500m_of_intrusive_contact=h["within_500m_of_intrusion"],
                        comparison=rows_for_app(c["layer_1_geological_evidence"]["comparison"]),
                        conflicts=c["layer_1_geological_evidence"]["conflicts"],
                        note="the guide was not an input; the engine selected this polygon from map data alone"))
    return out


def controls(d, region):
    out = []
    for rid, c in d.get("controls", {}).items():
        for method, r in c["results"].items():
            if "precision" in r or "recall" in r:
                out.append(dict(region=region, reference=rid, method=method, precision=r.get("precision"), recall=r.get("recall"),
                                false_positives=r.get("false_positives", []), missed=r.get("missed_positives", [])))
    return out


def geo_v2_block(specs):
    """specs: list of (path, role) where role is 'study area' or 'held-out test'."""
    regions, refs, units, feats, ctrl, lims = [], {}, [], [], [], []
    for path, role in specs:
        d = json.load(open(path)); region = d.get("region", "newark")
        assert d["schema_version"] == "geo-2.0", path
        regions.append(dict(id=region, role=role, centre=d["study_area"]["centre"], radius_km=d["study_area"]["radius_km"],
                            created=d["created"], n_polygons=d["n_polygons"], n_units=d["n_units"], datasets=d["datasets"]))
        for rid, r in d["planetary_references"].items():
            refs.setdefault(rid, dict(id=rid, name=r["name"], site_note=r.get("site_note"), locations=r["location"],
                                      not_comparable=r["not_comparable"],
                                      properties=[dict(code=p["code"], role=p["role"], role_label=ROLE_LABEL.get(p["role"], p["role"]),
                                                       mars_site=p.get("site"), evidence_type=p["evidence_type"], statement=p["statement"],
                                                       citations=p["src"]) for p in r["properties"]]))
        units += unit_cards(d, region); feats += featured(d, region); ctrl += controls(d, region)
        lims += [l for l in d["limitations"] if l not in lims]
        sources = d["sources"]
    return dict(block_version=BLOCK_VERSION, regions=regions, references=list(refs.values()), featured=feats, units=units,
                controls=ctrl, citations=sources, limitations=lims,
                display_rules=["show role_label and mars_evidence_type next to every property",
                               "never show a score or percentage match; there is none",
                               "show earth_status verbatim; 'inferred' means derived from sedimentology plus basin context"])


def parse_specs(args):
    out = []
    for a in args:
        p, _, role = a.partition(":")
        out.append((p, role or "study area"))
    return out


if __name__ == "__main__":
    blk = geo_v2_block(parse_specs(sys.argv[2:]))
    json.dump(blk, open(sys.argv[1], "w"), indent=1)
    print("units", len(blk["units"]), "featured", len(blk["featured"]), "controls", len(blk["controls"]))

```

## engine/build_refs.py

```python
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

```

## engine/build_zone_refs.py

```python
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

```

## engine/compare.py

```python
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

```

## engine/cross_characterize.py

```python
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

```

## engine/export_app_json.py

```python
"""Assemble ONE app-ready JSON (schema v1, see SCHEMA.md) from the run outputs.
Every sentence-like field is built from fixed templates/vocabulary; no generated prose.

Usage: python3 export_app_json.py MANIFEST TERRAIN_JSON GEOLOGY_JSON CROSS_JSON OUT_JSON [STATE_GEOLOGY_JSON] [--geo2 FILE[:ROLE] ...]
  --geo2 adds the optional `geology_v2` block (geo-2.0 evidence; see SCHEMA.md). Without it the output is unchanged.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json
import numpy as np
from global_run import LS, CONN_T

SCHEMA_VERSION = "1.0"
VOCAB = ("inside middle half", "inside 10-90% range", "outside range", "not measured", "not comparable")
NOT_COMPARABLE = {
    "Moon": ["vacuum", "1/6 gravity", "polar illumination and permanently shadowed cold traps", "lunar regolith (agglutinates, sharp grains)",
             "radiation environment", "water-ice in cold traps"],
    "Mars": ["thin CO2 atmosphere", "3/8 gravity", "radiation environment", "global dust storms",
             "Martian mineral chemistry (e.g. Fe-rich olivine)", "buried mid-latitude ice"],
}
PURPOSE = {  # which exploration concern each reference speaks to (internal base profiles kept internal)
    "M-CR": "Moon south pole: terrain of a candidate landing/base region (Blue Moon Mark 1 target area)",
    "M-SR": "Moon south pole: rim and crater-wall terrain (heterogeneous reference; not a headline)",
    "M-DG": "Moon south pole: rim terrain of a candidate base region",
    "M-MA": "Moon south pole: massif terrain with scale-persistent slopes",
    "MZ-FLAT": "Moon: flat-terrain context (surface operations); team-defined class, not a NASA landing classification",
    "MZ-STEEP": "Moon: steep-terrain context (mobility and terrain hazards); team-defined class",
    "R-JZ": "Mars: geological investigation (Jezero-type igneous rock and water-lain sediment)",
    "R-IS": "Mars: landing and surface operations on flat basaltic plains (terrain weakly discriminating)",
    "R-AE": "Mars: mobility across wind-blown sand (dune-crossing)",
}


def band(qs):
    q = np.asarray(qs)       # 50 midpoint quantiles (1,3,...,99 %)
    return dict(p10=round(float(q[4:6].mean()), 2), p25=round(float(q[12]), 2), p50=round(float(q[24:26].mean()), 2),
                p75=round(float(q[37]), 2), p90=round(float(q[44:46].mean()), 2))


def outcome(v, b):
    if v is None:
        return "not measured"
    if b["p25"] <= v <= b["p75"]:
        return "inside middle half"
    if b["p10"] <= v <= b["p90"]:
        return "inside 10-90% range"
    return "outside range"


def main():
    argv = list(sys.argv[1:]); geo2 = []
    while "--geo2" in argv:
        i = argv.index("--geo2"); geo2.append(argv[i + 1]); del argv[i:i + 2]
    man, tj, gj, cj, out = argv[0:5]
    sg = argv[5] if len(argv) > 5 else None
    M = json.load(open(man)); T = json.load(open(tj)); Gd = json.load(open(gj)); X = json.load(open(cj))
    R = np.load("refs.npz"); meta = json.load(open("refs_meta.json"))
    refs = {}
    for rid, m in meta.items():
        r = dict(id=rid, body=m["body"], ref_type=m.get("ref_type", "site box"), description=m["desc"],
                 exploration_purpose=PURPOSE.get(rid, ""), baselines_m=m["baselines"], grid_m=m["grid_m"],
                 slope_bands_deg={str(L): band(R[rid + "_slope_q"][LS.index(L)]) for L in m["baselines"]},
                 connectivity_curve={str(t): round(float(c), 3) for t, c in zip(CONN_T, R[rid + "_conn"])},
                 not_comparable=NOT_COMPARABLE[m["body"]], warnings=[w for w in [m.get("warning")] if w],
                 yardstick=m.get("yardstick_leave_one_site_out"))
        if m["body"] == "Moon" and rid.startswith("M-"):
            others = [o for o in meta if o.startswith("M-") and o != rid]
            d = min(float(np.abs(R[rid + "_slope_q"] - R[o + "_slope_q"]).mean(1).max()) for o in others)
            r["yardstick"] = dict(kind="nearest other lunar site (worst-scale slope W1)", p90=round(d, 2),
                                  caveat="depends strongly on how the site box is drawn (quarter-box tests: 0 to 2,223 US windows inside)")
        refs[rid] = r
    for rid, desc in (("R-AE", "Mars dune-crossing zone (rock-type pathway only)"),):
        refs.setdefault(rid, dict(id=rid, body="Mars", ref_type="process (rock-type pathway only)", description=desc,
                                  exploration_purpose=PURPOSE[rid], not_comparable=NOT_COMPARABLE["Mars"], warnings=[]))
    cand = []
    for rid, r in T["references"].items():
        ref = refs[rid]; xc = {(c["lat"], c["lon"]): c for c in X["terrain_candidates"].get(rid, [])}
        for k, c in enumerate(r["candidates"]):
            props = []
            for L in ref["baselines_m"]:
                v = c["median_slope_deg_by_baseline"].get(str(L)); b = ref["slope_bands_deg"][str(L)]
                props.append(dict(property=f"median slope at {L} m", unit="deg", value=v, reference_band=b, outcome=outcome(v, b)))
            sup = [p["property"] for p in props if p["outcome"] == "inside middle half"]
            con = [p["property"] for p in props if p["outcome"] == "outside range"]
            if c.get("snow_ice_fraction") and c["snow_ice_fraction"] > 0.1:
                con.append(f"snow/ice covers {c['snow_ice_fraction']:.0%} of the window")
            geo = xc.get((c["lat"], c["lon"]), {}).get("geology", {"status": "not measured"})
            cand.append(dict(
                id=f"T-{rid}-{k+1:03d}", pathway="terrain", reference=rid, rank_rule="Pareto front, then worst-scale slope distance",
                pareto_front=c["pareto_front"], position=dict(lat=c["lat"], lon=c["lon"]),
                footprint=dict(shape="square", size_km=10, projection="local azimuthal equidistant", step_km=5),
                distances=dict(worst_scale_slope_W1_deg=c["worst_scale_slope_W1_deg"],
                               worst_scale_log10_roughness_W1=c["worst_scale_log10_roughness_W1"],
                               connectivity_distance=c["connectivity_distance"], by_baseline_deg=c["slope_W1_deg_by_baseline"]),
                inside_yardstick=(None if not ref.get("yardstick") else c["worst_scale_slope_W1_deg"] <= ref["yardstick"]["p90"]),
                properties=props,
                land_cover=dict(valid_fraction=c["valid_fraction"], bare_fraction=c["bare_fraction"], snow_ice_fraction=c["snow_ice_fraction"]),
                cross_pathway=dict(geology=geo),
                evidence=dict(supporting=sup, contradicting=con,
                              unmeasured=["mineralogy", "rock abundance at metre scale", "regolith properties"],
                              not_comparable=ref["not_comparable"])))
    for rid, r in Gd["references"].items():
        xc = {(c["lat"], c["lon"]): c for c in X["geology_candidates"].get(rid, [])}
        for k, c in enumerate(r["candidates"]):
            tier = c["tier"].split(" ")[0]
            cand.append(dict(
                id=f"G-{rid}-{k+1:03d}", pathway="rock type", reference=rid, rank_rule="highest tier, then exposed target area",
                position=dict(lat=c["lat"], lon=c["lon"]),
                footprint=dict(shape="geographic box", size_deg=[0.1, "0.1/cos(lat)"], size_km_approx=11.1, step="half box"),
                evidence_ladder=dict(G1_mapped=c["mapped_target_fraction"] >= Gd["thresholds"]["G1_min_mapped"],
                                     G2_exposed=None if c["exposed_target_fraction"] is None else c["exposed_target_fraction"] >= Gd["thresholds"]["G2_min_exposed"],
                                     G3_spectral="not evaluated",
                                     G4_colocated_partner=tier == "G4"),
                tier=tier, values=dict(mapped_target_fraction=c["mapped_target_fraction"], exposed_target_fraction=c["exposed_target_fraction"],
                                       exposed_target_area_km2=c["exposed_target_area_km2"], partner_fraction=c["partner_fraction"]),
                cross_pathway=dict(terrain=xc.get((c["lat"], c["lon"]), {}).get("terrain", {"status": "not measured"})),
                evidence=dict(supporting=[s for s, ok in (("target rock mapped", True), ("target rock exposed", tier in ("G2", "G4")),
                                                          ("partner unit co-located (process plausible, not established)", tier == "G4")) if ok],
                              contradicting=[], unmeasured=["mineral spectra (EMIT not evaluated)", "outcrop-scale lithology"],
                              not_comparable=NOT_COMPARABLE["Mars"])))
    bundle = dict(schema_version=SCHEMA_VERSION, outcome_vocabulary=list(VOCAB),
                  run=dict(manifest_describe_as=M.get("describe_as"), created_utc=M.get("created_utc"), tiles=M.get("tiles", {}).get("by_status"),
                           windows=M.get("windows"), software=M.get("software"), parameters=M.get("parameters"), datasets=M.get("datasets"),
                           known_coverage_limits=M.get("known_coverage_limits")),
                  geology_run=dict(thresholds=Gd.get("thresholds"), emit=Gd.get("emit"), source="GLiM (Hartmann & Moosdorf 2012), rasterised 0.01 deg"),
                  references=list(refs.values()), candidates=cand,
                  coverage=T.get("coverage"),
                  regional_state_geology=(json.load(open(sg)) if sg else None),
                  limitations=["distances are relative measures, not suitability scores",
                               "terrain lists depend on the nomination rule (34-52% overlap with simpler rules); show regions, not fine ranks",
                               "counts inside the site-level yardstick depend strongly on how the lunar box is drawn",
                               "rock-type partner co-location does not establish a shared geological process",
                               "field measurements (D435) document a site and check lidar; they do not validate the planetary comparison"])
    if geo2:
        from app_geo_v2 import geo_v2_block, parse_specs
        bundle["geology_v2"] = geo_v2_block(parse_specs(geo2))   # additive optional block
    json.dump(bundle, open(out, "w"), indent=1, default=float)
    print("candidates", len(cand), "references", len(refs))


if __name__ == "__main__":
    main()

```

## engine/field_prep.py

```python
"""Field preparation for Nottingham County Park: pre-registered station transect + lidar reference values.

Rule (fixed before the visit):
  Transect T: the straight line through the park's main parking area toward the NEAREST point of the
  mapped contact of the ultramafic/serpentinite unit (PA Geological Survey Map 1, 1:250,000, via
  Macrostrat map_id 3748450). Stations every 100 m from 400 m on the unit side of the parking to 400 m
  beyond the contact. A 1:250,000 boundary can be off by a few hundred metres, so only the stations far
  from the line (>= 300 m) are treated as clearly "on" or "off" the unit; the middle ones are "near contact".
  Exposure stations E (decided ON SITE, rule fixed now): walking the park's marked trails through the
  barrens (Chrome Trail starts below the parking; Doe Trail runs along the barrens' eastern edge), the
  first 4 places where bare rock or bare greenish soil is visible from the trail, at least 100 m apart.
  (Satellite land cover cannot tell barrens grassland from mowed lawn, so E stations are not pre-computed.)
  Skip any planned station that is outside the park or not reachable on a trail; record it as "not accessible". In the field, use the nearest safely accessible point to each planned station and
record its actual GPS position. Stations on both sides of the mapped contact let the visit test
whether the map boundary corresponds to a visible change in rock, soil, vegetation or surface shape.

For each planned station this computes, from USGS 3DEP 1 m lidar (PA_17County_D24):
  slope over 3 m and 6 m plane-fit discs, roughness (RMS residual) at 6 m, and ESA WorldCover class.
These are the reference values the D435 measurements will be compared with.

Usage: python3 field_prep.py OUT_PREFIX
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, csv, warnings
import numpy as np
warnings.filterwarnings("ignore")
import rasterio
from rasterio.merge import merge
from rasterio.windows import from_bounds
from pyproj import Transformer
import geopandas as gpd
from shapely.geometry import Point, LineString
from shapely.ops import nearest_points
from terrain_engine import plane_features_fast
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PARKING = (39.739873, -76.037153)          # main parking area (uncoveringpa.com); park entrance ~39.7409, -76.0388
HALF = 1500.0
TILES = ["x40y440", "x41y440", "x41y441", "x40y441"]
URL = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m/Projects/PA_17County_D24/TIFF/USGS_1M_18_{}_PA_17County_D24.tif"
WC = "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_N39W078_Map.tif"
WC_NAMES = {10: "tree cover", 20: "shrubland", 30: "grassland", 40: "cropland", 50: "built-up", 60: "bare/sparse", 80: "water", 90: "wetland", 100: "moss/lichen"}


def main():
    pre = sys.argv[1]
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:26918", always_xy=True)
    to_ll = Transformer.from_crs("EPSG:26918", "EPSG:4326", always_xy=True)
    px, py = to_utm.transform(PARKING[1], PARKING[0])
    bounds = (px - HALF, py - HALF, px + HALF, py + HALF)
    srcs = []
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
        for t in TILES:
            try:
                srcs.append(rasterio.open("/vsicurl/" + URL.format(t)))
            except Exception as e:
                print("tile", t, "unavailable", e)
        z, tr = merge(srcs, bounds=bounds, res=1.0, nodata=np.nan)
        for s in srcs:
            s.close()
    z = z[0].astype(float); v = np.isfinite(z)
    s3, _, _ = plane_features_fast(np.where(v, z, 0), v, 1.0, 3.0)
    s6, r6, _ = plane_features_fast(np.where(v, z, 0), v, 1.0, 6.0)
    g = gpd.read_file("ms_region.geojson")
    um = g[g.map_id == 3748450].to_crs(26918).geometry.iloc[0]
    nb = g[g.geometry.intersects(gpd.GeoSeries([um], crs=26918).to_crs(4326).iloc[0].buffer(0.001))]
    p0 = Point(px, py)
    inside = um.contains(p0)
    contact = nearest_points(um.boundary if inside else um, p0)[0]
    d = p0.distance(contact); ux, uy = (contact.x - px) / d, (contact.y - py) / d
    steps = np.arange(-400.0, d + 400 + 1e-6, 100.0)
    rows = []
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR"):
        with rasterio.open("/vsicurl/" + WC) as w:
            wct = Transformer.from_crs("EPSG:26918", w.crs, always_xy=True)
            for k, sdist in enumerate(steps):
                x, y = px + ux * sdist, py + uy * sdist
                c = int((x - tr.c) / tr.a); r_ = int((y - tr.f) / tr.e)
                lon, lat = to_ll.transform(x, y)
                wx, wy = wct.transform(x, y)
                cls = int(next(w.sample([(wx, wy)]))[0])
                win = lambda a: float(np.nanmedian(a[max(r_ - 2, 0):r_ + 3, max(c - 2, 0):c + 3]))
                near = abs(sdist - d) < 300
                rows.append(dict(station=f"T{k + 1}", planned_lat=round(lat, 6), planned_lon=round(lon, 6), distance_from_parking_m=int(sdist),
                                 mapped_unit=("near mapped contact (ambiguous at 1:250k)" if near else
                                              "ultramafic/serpentinite" if um.contains(Point(x, y)) else "neighbouring unit (schist/gneiss)"),
                                 lidar_slope_3m_deg=round(win(s3), 1), lidar_slope_6m_deg=round(win(s6), 1),
                                 lidar_roughness_6m_m=round(win(r6), 3), worldcover_class=WC_NAMES.get(cls, str(cls))))
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR"):
        with rasterio.open("/vsicurl/" + WC) as w:
            lo0, la0 = to_ll.transform(px - 1000, py - 1000); lo1, la1 = to_ll.transform(px + 1000, py + 1000)
            win_ = from_bounds(lo0, la0, lo1, la1, w.transform)
            a = w.read(1, window=win_); wt = w.window_transform(win_)
    score = np.where(a == 60, 2, np.where(a == 30, 1, 0))
    cand = []
    for (ri, ci) in zip(*np.where(score > 0)):
        lon, lat = wt * (ci + 0.5, ri + 0.5)
        x, y = to_utm.transform(lon, lat)
        if (x - px) ** 2 + (y - py) ** 2 <= 1000 ** 2 and um.contains(Point(x, y)):
            cand.append((score[ri, ci], -((x - px) ** 2 + (y - py) ** 2), x, y, lat, lon))
    cand.sort(reverse=True); picked = []
    for sc, _, x, y, lat, lon in cand:
        if all((x - p[0]) ** 2 + (y - p[1]) ** 2 >= 100 ** 2 for p in picked):
            picked.append((x, y, lat, lon, sc))
        if len(picked) >= 4:
            break
    for k, (x, y, lat, lon, sc) in enumerate(picked):
        c = int((x - tr.c) / tr.a); r_ = int((y - tr.f) / tr.e)
        win = lambda a_: float(np.nanmedian(a_[max(r_ - 2, 0):r_ + 3, max(c - 2, 0):c + 3]))
        rows.append(dict(station=f"E{k + 1}", planned_lat=round(lat, 6), planned_lon=round(lon, 6),
                         distance_from_parking_m=int(np.hypot(x - px, y - py)), mapped_unit="ultramafic/serpentinite (exposure station)",
                         lidar_slope_3m_deg=round(win(s3), 1), lidar_slope_6m_deg=round(win(s6), 1), lidar_roughness_6m_m=round(win(r6), 3),
                         worldcover_class="bare/sparse" if sc == 2 else "grassland"))
    rows = [r for r in rows if r["station"].startswith("T")]
    with open(pre + "_stations.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(rows[0])); wr.writeheader(); wr.writerows(rows)
    json.dump(dict(rule=__doc__.split("Usage")[0].strip(), parking=PARKING, contact_distance_m=round(d), parking_inside_unit=bool(inside),
                   lidar="USGS 3DEP 1 m, project PA_17County_D24", geology="PA Geological Survey Map 1 (1980, 1:250,000) via Macrostrat, CC-BY 4.0",
                   stations=rows), open(pre + "_stations.json", "w"), indent=1)
    # map
    ls = np.gradient(np.where(v, z, np.nan), 1.0)
    hs = np.cos(np.arctan(np.hypot(*ls)))
    fig, ax = plt.subplots(figsize=(10, 10), dpi=140)
    ext = (tr.c, tr.c + z.shape[1], tr.f - z.shape[0], tr.f)
    ax.imshow(hs, cmap="gray", extent=ext, alpha=0.6)
    im = ax.imshow(s6, cmap="magma_r", extent=ext, vmin=0, vmax=30, alpha=0.55)
    ax.plot([], [], " ", label="lidar slope at 1 m resolution, 6 m disc")
    fig.colorbar(im, ax=ax, shrink=0.6, label="lidar slope over 6 m disc (deg)")
    gpd.GeoSeries([um], crs=26918).boundary.plot(ax=ax, color="cyan", lw=2, label="mapped ultramafic/serpentinite unit boundary")
    xs = [px + ux * s for s in steps]; ys = [py + uy * s for s in steps]
    ax.plot(xs, ys, "w-", lw=1)
    for r in rows:
        x, y = to_utm.transform(r["planned_lon"], r["planned_lat"])
        col = "deepskyblue" if r["station"].startswith("E") else ("yellow" if r["mapped_unit"].startswith("near") else
              "lime" if r["mapped_unit"].startswith("ultramafic") else "orange")
        ax.plot(x, y, "o", color=col, ms=8, mec="k")
        ax.annotate(r["station"], (x, y), xytext=(5, 5), textcoords="offset points", color="black", fontsize=9, weight="bold")
    ax.plot(px, py, "c*", ms=14, mec="k", label="parking (start)")
    ax.set_xlim(bounds[0], bounds[2]); ax.set_ylim(bounds[1], bounds[3])
    ax.set_title("Nottingham County Park: pre-registered stations. T = transect (green on unit, yellow near mapped contact, orange off unit); E = exposure stations\n"
                 "USGS 3DEP 1 m lidar slope; geology: PA Geol. Survey Map 1 (1:250k) via Macrostrat; UTM 18N", fontsize=9)
    ax.legend(loc="lower left", fontsize=8)
    fig.tight_layout(); fig.savefig(pre + "_map.png"); plt.close(fig)
    for r in rows:
        print(r)


if __name__ == "__main__":
    main()

```

## engine/geo_v2.py

```python
"""Process-aware geological evidence engine (geo-2.0) — 14/15 Nov 2026.

What is new compared with the v0.3 rock-type pathway (keyword / class lookup):
  1. Planetary references are structured lists of OBSERVED or INTERPRETED properties from published
     rover/orbital studies (each with source and evidence type). The Earth search investigates exactly
     those properties; nothing else is compared.
  2. Earth evidence is extracted per map unit into separate dimensions with a controlled vocabulary:
     lithology (from the STRUCTURED lithology hierarchy of the USGS State Geologic Map Compilation,
     ranked major/minor), emplacement (volcanic vs intrusive, from the lithology hierarchy and text),
     depositional environment, sedimentary structures, minerals and alteration (from the state-survey
     unit descriptions, with negation guards). Every hit keeps its source field and the matched text.
  3. Independent corroboration from Macrostrat stratigraphic columns (lithology and depositional
     environment). Source disagreements are recorded, and database defaults ("inferred ...") are not
     treated as observations.
  4. Measured spatial context from the map polygons: perimeter shared with lava flows, intrusions,
     marine units; area within 500 m of an intrusive contact (thermal overprint risk).
  5. A candidate must show every CORE property of the reference and no CORE contradiction; all other
     properties are reported individually as recorded / corroborated / contradicted / not recorded.
     No scores, weights or percentages.
  6. Source scale -> positional uncertainty of mapped contacts.
No LLM is involved at run time: interpretations come only from the rules below.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import re, json, math
from functools import lru_cache

# ---------------------------------------------------------------- controlled vocabulary
NEG = re.compile(r"\b(no|not|without|absent|lacking|lacks|rare|unlike)\b[^.;]{0,30}$", re.I)

TEXT_VOCAB = {
    # dimension: {code: regex}
    "environment": {
        "LACUSTRINE": r"lacustrine|\bplaya\b|lake[- ](deposits?|beds?|sediments?|sequences?|cycles?|mudflat|level)|deposited in (an? |the )?(\w+ )?lakes?\b",
        "FLUVIAL": r"\bfluvial|alluvial|braided|meandering|channel[- ]?fill|stream[- ]deposit",
        "DELTAIC": r"\bdelta(ic)?\b",
        "MARINE": r"(?<!non-)(?<!non )(?<!non)\bmarine\b|turbidite|\bshelf\b|glauconit|\bforaminifer|\bshallow[- ]sea|\bnearshore|\boffshore",
        "EOLIAN": r"eolian|aeolian|wind[- ]blown|\bdunes?\b",
        "GLACIAL": r"glacial|\btill\b|outwash|moraine|varve",
    },
    "emplacement": {
        "EXTRUSIVE": r"\blava|\bflows?\b|pillow|vesicul|amygdal|pahoehoe|extrusive",
        "INTRUSIVE": r"\bsill\b|\bdikes?\b|\bdykes?\b|intrusi(ve|on)|pluton",
    },
    "structure": {
        "DESICCATION": r"mud[- ]?cracks?|desiccation|shrinkage cracks",
        "CYCLIC": r"\bcycl(ic|es?)\b|rhythmic|van houten",
        "LAMINATED": r"laminat|varve",
        "PILLOWS": r"pillow",
        "RIPPLES": r"ripple",
        "DARK_LAMINATED": r"microlaminat|black[^.;]{0,60}(laminat|shale|siltstone|mudstone|argillite)",
        "AQUATIC_FOSSILS": r"\bfish\b|ostracod|conchostracan|clam shrimp",
    },
    "mineral": {
        "CARBONATE": r"dolomit|calcite|calcare|carbonate|magnesite",
        "EVAPORITE": r"evaporit|gypsum|anhydrite|glauberite|halite|salt[- ]crystal|pseudomorph",
        "CLAY": r"\bclay|smectite|illite|kaolin",
        "ANALCIME": r"analcime|zeolite",
        "SERPENTINE": r"serpentin|antigorite|chrysotile",
        "OLIVINE": r"olivine|dunite|peridotite|harzburgite",
        "MAGNETITE": r"magnetite",
    },
    "alteration": {
        "SERPENTINIZATION": r"serpentiniz|alteration of peridotite|altered (dunite|peridotite)|products of alteration",
        "CONTACT_METAMORPHISM": r"hornfels|baked|contact[- ]metamorph|thermally metamorphos",
        "HYDROTHERMAL": r"hydrothermal",
    },
}

LITH_RULES = [  # (code, test on the structured TOTAL_LITH hierarchy string)
    ("FINE_CLASTIC", lambda t: re.search(r"Mudstone|Shale|Siltstone|Argillite|Claystone|Fine-detrital|\bClay\b|\bSilt\b", t)),
    ("COARSE_CLASTIC", lambda t: re.search(r"Sandstone|Conglomerate|Arkose|Coarse-detrital|\bSand\b|Gravel", t)),
    ("CARBONATE_ROCK", lambda t: re.search(r"Carbonate|Limestone|Dolostone|Marble", t)),
    ("EVAPORITE_ROCK", lambda t: re.search(r"Evaporite", t)),
    ("MAFIC_VOLCANIC", lambda t: re.search(r"Igneous - Volcanic - Mafic|Basalt", t) and "Plutonic" not in t and "Hypabyssal" not in t),
    ("MAFIC_INTRUSIVE", lambda t: re.search(r"Gabbro|Diabase|Dolerite|Norite|Igneous - Hypabyssal - Mafic|Igneous - Plutonic - Gabbroic", t)),
    ("ULTRAMAFIC", lambda t: re.search(r"Ultramafic|Serpentinite|Peridotite|Dunite|Pyroxenite|Metaultramafic", t)),
    ("OLIVINE_RICH_ULTRAMAFIC", lambda t: re.search(r"Serpentinite|Peridotite|Dunite|Harzburgite|Wehrlite", t)),
]

# ---------------------------------------------------------------- planetary references (published observations)
SRC = {
    "Grotzinger2014": "Grotzinger J.P. et al. (2014) A habitable fluvio-lacustrine environment at Yellowknife Bay, Gale crater, Mars. Science 343, 1242777. doi:10.1126/science.1242777",
    "Grotzinger2015": "Grotzinger J.P. et al. (2015) Deposition, exhumation, and paleoclimate of an ancient lake deposit, Gale crater, Mars. Science 350, aac7575. doi:10.1126/science.aac7575",
    "Vaniman2014": "Vaniman D.T. et al. (2014) Mineralogy of a mudstone at Yellowknife Bay, Gale crater, Mars. Science 343, 1243480. doi:10.1126/science.1243480",
    "Stein2018": "Stein N. et al. (2018) Desiccation cracks provide evidence of lake drying on Mars, Sutton Island member, Murray formation, Gale crater. Geology 46, 515-518. doi:10.1130/G40005.1",
    "Rapin2023": "Rapin W. et al. (2023) Sustained wet-dry cycling on early Mars. Nature 620, 299-302. doi:10.1038/s41586-023-06220-3",
    "Nachon2014": "Nachon M. et al. (2014) Calcium sulfate veins characterized by ChemCam/Curiosity at Gale crater, Mars. JGR Planets 119, 1991-2016.",
    "Mangold2021": "Mangold N. et al. (2021) Perseverance rover reveals an ancient delta-lake system and flood deposits at Jezero crater, Mars. Science 374, 711-717. doi:10.1126/science.abl4051",
    "Farley2022": "Farley K.A. et al. (2022) Aqueously altered igneous rocks sampled on the floor of Jezero crater, Mars. Science 377, eabo2196. doi:10.1126/science.abo2196",
    "Liu2022": "Liu Y. et al. (2022) An olivine cumulate outcrop on the floor of Jezero crater, Mars. Science 377, 1513-1519. doi:10.1126/science.abo2756",
    "Tosca2025": "Tosca N.J. et al. (2025) In situ evidence for serpentinization within the Maaz formation, Jezero crater, Mars. Science Advances 11, eadr8793. doi:10.1126/sciadv.adr8793",
    "Beyssac2023": "Beyssac O. et al. (2023) Petrological traverse of the olivine cumulate Seitah formation at Jezero crater, Mars. JGR Planets 128, e2022JE007638. doi:10.1029/2022JE007638",
    "Tutolo2023": "Tutolo B.M. & Tosca N.J. (2023) Observational constraints on the process and products of Martian serpentinization. Science Advances 9, eadd8472. doi:10.1126/sciadv.add8472",
    "Clave2023": "Clave E. et al. (2023) Carbonate detection with SuperCam in igneous rocks on the floor of Jezero crater, Mars. JGR Planets 128, e2022JE007463. doi:10.1029/2022JE007463",
    "Golombek2020": "Golombek M. et al. (2020) Geology of the InSight landing site on Mars. Nature Communications 11, 1014. doi:10.1038/s41467-020-14679-1",
}

# role: core (must be recorded on Earth) | supporting | contradiction (core counter-evidence) | caution (flag only)
# evidence_type: observed (rover/orbiter measurement) | interpreted (published interpretation of observations)
#                | inferred (a consequence derived from an interpretation, not measured, e.g. H2 production)
# site: the Mars location an observation comes from, when a reference combines more than one
PLANETARY = {
    "MARS-LAKE": dict(
        name="Martian crater-lake mudstones (Gale crater; Jezero crater delta-lake system)",
        location=[dict(site="Gale crater, Murray formation / Yellowknife Bay", lat=-4.6, lon=137.4),
                  dict(site="Jezero crater western delta", lat=18.4, lon=77.4)],
        properties=[
            dict(dim="lithology", code="FINE_CLASTIC", role="core", evidence_type="observed", src=["Grotzinger2014", "Grotzinger2015"],
                 statement="fine-grained mudstone and siltstone"),
            dict(dim="environment", code="LACUSTRINE", role="core", evidence_type="interpreted", src=["Grotzinger2014", "Grotzinger2015", "Mangold2021"],
                 statement="deposited in long-lived crater lakes"),
            dict(dim="environment", code="MARINE", role="contradiction", evidence_type="interpreted", src=["Grotzinger2015"],
                 statement="no ocean-margin setting in these crater lakes: marine deposits are a different process"),
            dict(dim="structure", code="DESICCATION", role="supporting", evidence_type="observed", src=["Stein2018"],
                 statement="desiccation cracks recording lake drying"),
            dict(dim="structure", code="CYCLIC", role="supporting", evidence_type="observed", src=["Rapin2023"],
                 statement="repeated wet-dry cycles (polygonal salt-enriched patterns)"),
            dict(dim="structure", code="LAMINATED", role="supporting", evidence_type="observed", src=["Grotzinger2015"],
                 statement="finely laminated mudstone"),
            dict(dim="mineral", code="CLAY", role="supporting", evidence_type="observed", src=["Vaniman2014"],
                 statement="clay minerals (smectite) in mudstone (CheMin XRD)"),
            dict(dim="mineral", code="EVAPORITE", role="supporting", evidence_type="observed", src=["Nachon2014"],
                 statement="calcium-sulfate veins (later diagenetic, not primary lake salts)"),
            dict(dim="context", code="VOLCANIC_NEIGHBOUR", role="supporting", evidence_type="observed", src=["Farley2022", "Mangold2021"],
                 statement="at Jezero the lake-delta deposits sit on igneous crater-floor units"),
            dict(dim="alteration", code="CONTACT_METAMORPHISM", role="caution", evidence_type="not_applicable", src=[],
                 statement="Earth-only check: heating by nearby intrusions changes mudstones; not reported at Gale/Jezero lake beds"),
        ],
        not_comparable=["age (~3.5-3.8 billion years)", "impact-crater basin setting", "Martian atmospheric and fluid chemistry",
                        "Fe-rich Martian mineral compositions", "burial and diagenesis history", "biology (Earth lake beds contain fossils)"]),
    "MARS-SERP": dict(
        name="Jezero crater floor: olivine cumulate (Seitah formation) and serpentinized igneous rock (Maaz formation)",
        location=[dict(site="Seitah formation, Jezero", lat=18.44, lon=77.45), dict(site="Maaz formation, Jezero", lat=18.44, lon=77.45)],
        site_note=("Two different Mars rocks. Seitah is an olivine cumulate, weakly altered, with small amounts of Mg-Fe carbonate. "
                   "The in situ serpentinization evidence (Tosca 2025) is from the overlying Maaz formation, a pyroxene-plagioclase igneous unit, "
                   "not from the Seitah cumulate. An Earth serpentinite combines the Seitah rock type with the Maaz process; "
                   "no single Mars site in these sources shows both."),
        properties=[
            dict(dim="lithology", code="OLIVINE_RICH_ULTRAMAFIC", role="core", evidence_type="observed", site="Seitah", src=["Liu2022", "Beyssac2023"],
                 statement="olivine cumulate (olivine-rich ultramafic rock); pyroxenite/hornblendite/gabbro are different rocks"),
            dict(dim="mineral", code="OLIVINE", role="supporting", evidence_type="observed", site="Seitah", src=["Liu2022", "Beyssac2023"],
                 statement="abundant millimetre olivine"),
            dict(dim="mineral", code="CARBONATE", role="supporting", evidence_type="observed", site="Seitah", src=["Clave2023"],
                 statement="Mg-Fe carbonate (magnesite-siderite), low abundance, detected with olivine"),
            dict(dim="mineral", code="SERPENTINE", role="supporting", evidence_type="observed", site="Maaz", src=["Tosca2025"],
                 statement="Fe-rich serpentine in Maaz igneous rocks (not in the Seitah cumulate)"),
            dict(dim="alteration", code="SERPENTINIZATION", role="supporting", evidence_type="interpreted", site="Maaz", src=["Tosca2025"],
                 statement="serpentinization of olivine in Maaz rocks, interpreted from in situ mineralogy and chemistry"),
            dict(dim="process", code="H2_PRODUCTION", role="not_compared", evidence_type="inferred", site="Maaz", src=["Tosca2025", "Tutolo2023"],
                 statement="hydrogen production is inferred from the serpentinization reaction; it was not measured"),
        ],
        not_comparable=["Fe-rich (Mars) vs Mg-rich (Earth mantle) olivine and serpentine: Fe-olivine yields Fe-serpentine and about five times "
                        "more H2 than terrestrial peridotite (Tutolo2023)", "tectonic setting (Earth: mountain belt)",
                        "age and fluid chemistry", "humid weathering and vegetation on Earth"]),
    "MARS-LAVA": dict(
        name="Basaltic lava plains and crater-floor lavas (InSight landing site; Jezero Maaz formation)",
        location=[dict(site="InSight, Elysium Planitia", lat=4.502, lon=135.623), dict(site="Jezero Maaz formation", lat=18.44, lon=77.45)],
        properties=[
            dict(dim="lithology", code="MAFIC_VOLCANIC", role="core", evidence_type="observed", src=["Farley2022", "Golombek2020"],
                 statement="basaltic igneous rock"),
            dict(dim="emplacement", code="EXTRUSIVE", role="core", evidence_type="interpreted", src=["Golombek2020", "Farley2022"],
                 statement="erupted as lava flows at the surface"),
            dict(dim="emplacement", code="INTRUSIVE", role="contradiction", evidence_type="interpreted", src=["Golombek2020"],
                 statement="an intrusion (sill/dike) cooled underground: a different emplacement process"),
            dict(dim="structure", code="PILLOWS", role="earth_only", evidence_type="not_applicable", src=[],
                 statement="Earth-side indicator of lava meeting water (relevant to Jezero's later lake); not observed on Mars"),
            dict(dim="context", code="LAKE_NEIGHBOUR", role="supporting", evidence_type="observed", src=["Mangold2021"],
                 statement="at Jezero, lake-delta sediments overlie the crater-floor igneous units"),
        ],
        not_comparable=["regolith and dust cover", "impact gardening", "age", "Martian basalt chemistry"]),
}


def text_hits(text, field):
    """Controlled-vocabulary hits with negation guard. Returns list of (dim, code, field, snippet)."""
    out = []
    if not text:
        return out
    for dim, voc in TEXT_VOCAB.items():
        for code, rx in voc.items():
            for m in re.finditer(rx, text, re.I):
                pre = text[max(0, m.start() - 40):m.start()]
                if NEG.search(pre):
                    continue
                out.append((dim, code, field, text[max(0, m.start() - 50):m.end() + 50].replace("\n", " ")))
                break
    return out


def lith_codes(lith_rows):
    """lith_rows: list of (rank, total_lith). Returns {code: 'major'|'minor'}."""
    out = {}
    for rank, t in lith_rows:
        for code, f in LITH_RULES:
            if t and f(t):
                r = "major" if "major" in str(rank).lower() else "minor"   # includes "Indeterminate, major"
                if out.get(code) != "major":
                    out[code] = r
    return out


def scale_from_reference(ref):
    m = re.search(r"1:\s*([\d,]{4,})", ref or "")
    return int(m.group(1).replace(",", "")) if m else None


# ---------------------------------------------------------------- Macrostrat corroboration
@lru_cache(maxsize=None)
def macrostrat(name):
    """Name query only. Returns every Macrostrat unit with this stratigraphic name, with its column position and age,
    so that the caller can reject homonyms far away or of a different age (see macrostrat_match)."""
    import requests
    base = re.sub(r"\b(Formation|Fm|Group|Member|Basalt|undivided)\b.*$", "", name or "").strip(" ,-")
    if not base or len(base) < 4:
        return None
    try:
        d = requests.get("https://macrostrat.org/api/v2/units", params=dict(strat_name=base, response="long"), timeout=40).json()["success"]["data"]
    except Exception:
        return None
    units = [dict(col_id=u.get("col_id"), strat_name=u.get("strat_name_long"), clat=u.get("clat"), clng=u.get("clng"),
                  t_age=u.get("t_age"), b_age=u.get("b_age"), lith=sorted({l["name"] for l in u.get("lith", [])}),
                  environ=sorted({e["name"] for e in u.get("environ", []) if not e["name"].startswith("inferred")}),
                  environ_database_default=sorted({e["name"] for e in u.get("environ", []) if e["name"].startswith("inferred")}))
             for u in d]
    return dict(query=base, units=units)


# geologic time names -> (young, old) Ma, ICS 2023 boundaries (rounded); used only for an age-overlap check
PERIODS = [("Quaternary", 0, 2.6), ("Tertiary", 2.6, 66), ("Neogene", 2.6, 23), ("Paleogene", 23, 66), ("Cenozoic", 0, 66),
           ("Cretaceous", 66, 145), ("Jurassic", 145, 201.4), ("Triassic", 201.4, 251.9), ("Mesozoic", 66, 251.9),
           ("Permian", 251.9, 298.9), ("Pennsylvanian", 298.9, 323.2), ("Mississippian", 323.2, 358.9), ("Carboniferous", 298.9, 358.9),
           ("Devonian", 358.9, 419.2), ("Silurian", 419.2, 443.8), ("Ordovician", 443.8, 485.4), ("Cambrian", 485.4, 538.8),
           ("Paleozoic", 251.9, 538.8), ("Neoproterozoic", 538.8, 1000), ("Mesoproterozoic", 1000, 1600), ("Paleoproterozoic", 1600, 2500),
           ("Proterozoic", 538.8, 2500), ("Precambrian", 538.8, 4000), ("Archean", 2500, 4000)]


def age_range(unit_age):
    hits = [(y, o) for n, y, o in PERIODS if re.search(n, unit_age or "", re.I)]
    return (min(h[0] for h in hits), max(h[1] for h in hits)) if hits else None


def macrostrat_match(ms, lat=None, lon=None, unit_age=None, max_km=150.0, age_tol_ma=10.0):
    """Keep only Macrostrat units whose column lies within max_km of the map unit AND whose age overlaps the map unit's age.
    Without a location, nothing is accepted (an unconstrained name match is never used as evidence)."""
    if not ms or not ms.get("units"):
        return dict(query=ms and ms.get("query"), name_matches=0, accepted=[], rejected=[])
    ar = age_range(unit_age); acc, rej = [], []
    for u in ms["units"]:
        why = []
        if lat is None or u["clat"] is None:
            why.append("no location to check")
        else:
            km = 6371 * math.acos(min(1, math.sin(math.radians(lat)) * math.sin(math.radians(u["clat"])) +
                                      math.cos(math.radians(lat)) * math.cos(math.radians(u["clat"])) * math.cos(math.radians(lon - u["clng"]))))
            if km > max_km:
                why.append(f"column {km:.0f} km away")
        if ar and u["t_age"] is not None and not (u["t_age"] <= ar[1] + age_tol_ma and u["b_age"] >= ar[0] - age_tol_ma):
            why.append(f"age {u['t_age']:.0f}-{u['b_age']:.0f} Ma outside map age {ar[0]:.0f}-{ar[1]:.0f} Ma")
        (rej if why else acc).append(dict(col_id=u["col_id"], strat_name=u["strat_name"], **({"reason": "; ".join(why)} if why else {})))
    keep = [u for u in ms["units"] if any(a["col_id"] == u["col_id"] and a["strat_name"] == u["strat_name"] for a in acc)]
    return dict(query=ms["query"], name_matches=len(ms["units"]), age_checked=ar is not None, accepted=acc, rejected=rej,
                lith=sorted({l for u in keep for l in u["lith"]}), environ=sorted({e for u in keep for e in u["environ"]}),
                environ_database_default=sorted({e for u in keep for e in u["environ_database_default"]}))


MS_ENV = {"LACUSTRINE": r"lacustrine|lake|playa", "FLUVIAL": r"fluvial|alluvial", "MARINE": r"(?<!non-)(?<!non )(?<!non)marine|offshore|shelf|subtidal|lagoon|shoreface",
          "DELTAIC": r"delta", "EOLIAN": r"eolian|dune", "GLACIAL": r"glacial"}
MS_LITH = {"FINE_CLASTIC": r"mudstone|shale|siltstone|argillite|claystone|^clay$|^silt$", "MAFIC_VOLCANIC": r"basalt",
           "ULTRAMAFIC": r"serpentinite|peridotite|dunite|ultramafic", "MAFIC_INTRUSIVE": r"gabbro|diabase|dolerite"}


def evidence_profile(unit_name, unitdesc, lith_com, lith_rows, reference, use_macrostrat=True, location=None, unit_age=None):
    """All evidence for one map unit, with provenance. Pure function of the inputs (plus Macrostrat)."""
    prof = dict(lithology={}, environment={}, emplacement={}, structure={}, mineral={}, alteration={}, conflicts=[], traces=[],
                macrostrat_only={})
    for code, rank in lith_codes(lith_rows).items():
        prof["lithology"][code] = dict(source="SGMC structured lithology", rank=rank)
    if "EVAPORITE_ROCK" in prof["lithology"]:
        prof["mineral"].setdefault("EVAPORITE", dict(source="SGMC structured lithology (Evaporite)"))
    alltext = " ".join(filter(None, [unit_name, unitdesc, lith_com]))
    name_is_pyx = bool(re.search(r"pyroxenite|hornblendite", unit_name or "", re.I)) and not re.search(r"serpentin|peridot|dunite", unit_name or "", re.I)
    if "ULTRAMAFIC" in prof["lithology"] and "OLIVINE_RICH_ULTRAMAFIC" not in prof["lithology"] and not name_is_pyx and \
            re.search(r"serpentin|peridotite|dunite", alltext, re.I) and prof["lithology"]["ULTRAMAFIC"]["rank"] == "major":
        prof["lithology"]["OLIVINE_RICH_ULTRAMAFIC"] = dict(source="SGMC structured lithology (Ultramafic, major) + description names serpentinite/peridotite/dunite", rank="major")
    # emplacement from structured lithology
    if "MAFIC_VOLCANIC" in prof["lithology"]:
        prof["emplacement"]["EXTRUSIVE"] = dict(source="SGMC structured lithology (Igneous-Volcanic)")
    if "MAFIC_INTRUSIVE" in prof["lithology"] and "MAFIC_VOLCANIC" not in prof["lithology"]:
        prof["emplacement"]["INTRUSIVE"] = dict(source="SGMC structured lithology (Plutonic/Hypabyssal)")
    for field, text in (("unit description", unitdesc), ("lithology comment", lith_com), ("unit name", unit_name)):
        for dim, code, f, snip in text_hits(text, field):
            if code not in prof[dim]:
                prof[dim][code] = dict(source=f"SGMC {f}", text=snip)
            prof["traces"].append(dict(dim=dim, code=code, field=f, text=snip))
    # rock names that are intrusive by definition: judged from the UNIT NAME only (descriptions of thick lava flows
    # often say "grading to gabbro in the interior", which is not an intrusion)
    m = re.search(r"diabase|dolerite|gabbro|\bsills?\b|\bdikes?\b", unit_name or "", re.I)
    if m and "INTRUSIVE" not in prof["emplacement"]:
        prof["emplacement"]["INTRUSIVE"] = dict(source="SGMC unit name", text=unit_name)
    if "EXTRUSIVE" in prof["emplacement"] and "INTRUSIVE" in prof["emplacement"]:
        prof["conflicts"].append("structured lithology says volcanic, but the unit name/description indicates an intrusion "
                                 "(e.g. 'diabase', 'sill'); intrusive evidence is kept as a contradiction")
    ms = macrostrat_match(macrostrat(unit_name), *(location or (None, None)), unit_age=unit_age) if use_macrostrat else None
    prof["macrostrat"] = ms
    if ms and ms.get("accepted"):        # only geographically and stratigraphically matched units are used
        for code, rx in MS_ENV.items():
            if any(re.search(rx, e, re.I) for e in ms["environ"]):
                if code in prof["environment"]:
                    prof["environment"][code]["corroborated_by"] = "Macrostrat environ"
                else:   # Macrostrat alone never establishes a core property or a contradiction: kept apart, shown, not used
                    prof["macrostrat_only"].setdefault(code, dict(source="Macrostrat environ only (matched by name, place and age)"))
        for code, rx in MS_LITH.items():
            if any(re.search(rx, l, re.I) for l in ms["lith"]) and code in prof["lithology"]:
                prof["lithology"][code]["corroborated_by"] = "Macrostrat lith"
        if "LACUSTRINE" in prof["environment"] and any(re.search(MS_ENV["MARINE"], e, re.I) for e in ms.get("environ_database_default", [])):
            prof["conflicts"].append("Macrostrat database default environment 'inferred marine' disagrees with the state map; "
                                     "treated as a database default, not an observation")
        envs = [c for c in ("LACUSTRINE", "MARINE") if c in prof["environment"]]
        if len(envs) == 2:
            prof["conflicts"].append("both lacustrine and marine environments recorded")
    scale = scale_from_reference(reference)
    prof["source"] = dict(reference=reference, scale=scale,
                          contact_position_uncertainty_m=None if not scale else round(0.0005 * scale))
    return prof


def is_lava_unit(profile):
    """A lava-flow unit for neighbour context: volcanic lithology and NOT identified as an intrusion
    (SGMC codes Palisade Diabase as Volcanic-Basalt; its name identifies it as an intrusion)."""
    return "MAFIC_VOLCANIC" in profile["lithology"] and "INTRUSIVE" not in profile["emplacement"]


LAKE_FEATURES = [("structure", "DESICCATION"), ("structure", "CYCLIC"), ("structure", "DARK_LAMINATED"),
                 ("mineral", "EVAPORITE"), ("structure", "AQUATIC_FOSSILS")]


def infer_lacustrine(profile, context):
    """Process inference (not a keyword): a unit whose MAJOR lithology is fine-grained clastic (and not a major carbonate) with >= 2 independent standing-water /
    lake-drying indicators, no marine evidence, inside a continental basin context (shares a boundary with
    a mapped lake unit or with lava flows, or lies within 10 km of a mapped lake unit). Returns evidence or None."""
    if "LACUSTRINE" in profile["environment"] or "MARINE" in profile["environment"]:
        return None
    if profile["lithology"].get("FINE_CLASTIC", {}).get("rank") != "major":      # mudrock must be a major lithology
        return None
    if profile["lithology"].get("CARBONATE_ROCK", {}).get("rank") == "major":    # carbonate platforms (e.g. tidal-flat dolomite) excluded
        return None
    feats = [c for d, c in LAKE_FEATURES if profile[d].get(c)]
    basin = context.get("LAKE_NEIGHBOUR") or context.get("VOLCANIC_NEIGHBOUR") or context.get("within_10km_of_mapped_lake_unit")
    if len(feats) >= 2 and basin:
        return dict(source="inferred: sedimentology + basin context", indicators=feats,
                    basin_context=[k for k in ("LAKE_NEIGHBOUR", "VOLCANIC_NEIGHBOUR", "within_10km_of_mapped_lake_unit") if context.get(k)])
    return None


def compare(profile, context, ref_id):
    """Property-by-property comparison with a planetary reference. Returns (qualifies, rows)."""
    ref = PLANETARY[ref_id]; rows = []; core_ok = True; core_contra = False
    for p in ref["properties"]:
        if p["dim"] == "context":
            v = context.get(p["code"])
            status = "not computed" if v is None else ("recorded (measured spatial relationship)" if v else "not recorded")
            rows.append(dict(property=p["code"], dimension="context", role=p["role"], planetary=p["statement"],
                             planetary_evidence=p["evidence_type"], sources=p["src"], earth_status=status, earth_value=v))
            continue
        if p["role"] == "not_compared":
            rows.append(dict(property=p["code"], dimension=p["dim"], role=p["role"], planetary=p["statement"], site=p.get("site"),
                             planetary_evidence=p["evidence_type"], sources=p["src"], earth_status="not compared (no Earth map property)",
                             earth_evidence=None))
            continue
        e = profile[p["dim"]].get(p["code"])
        if p["role"] == "contradiction":
            status = "CONTRADICTION recorded" if e else "no contradiction recorded"
            core_contra |= bool(e)
        elif p["role"] == "caution":
            share = context.get("share_within_500m_of_intrusive_contact")
            status = ("recorded in map text" if e else "not in map text") + (f"; {share:.0%} of area within 500 m of an intrusive contact" if share is not None else "")
        else:
            if e:
                status = "corroborated (2 sources)" if e.get("corroborated_by") else f"recorded ({e['source']})"
            else:
                status = ("not recorded (Macrostrat alone lists it; not used)" if profile.get("macrostrat_only", {}).get(p["code"])
                          else "not recorded")
            if p["role"] == "core" and not e:
                core_ok = False
        rows.append(dict(property=p["code"], dimension=p["dim"], role=p["role"], planetary=p["statement"], site=p.get("site"),
                         planetary_evidence=p["evidence_type"], sources=p["src"], earth_status=status,
                         earth_evidence=e))
    return core_ok and not core_contra, rows


TEMPLATES = {
    "qualifies": "Meets every core property of {ref} ({cores}) with no core contradiction.",
    "fails_core": "Does not meet core properties of {ref}: missing {missing}.",
    "contradiction": "Core contradiction for {ref}: {contra}.",
}

```

## engine/geology_run.py

```python
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

```

## engine/geology_sensitivity.py

```python
"""Sensitivity of the global rock-type pathway to its heuristic thresholds, and whether the
'process partner' (G4) adds information beyond plain exposed-lithology filtering (G2).

Thresholds varied one at a time around the adopted values (G1 0.50, G2 0.25, partner 0.10):
  G1 mapped share 0.30 / 0.70; G2 exposed share 0.10 / 0.50; partner share 0.05 / 0.20.
For each setting: tier counts and the top-50 list (same ordering + 25 km suppression as geology_run.py).
Overlap = share of adopted top-50 places with a place in the alternative list within 25 km.

Usage: python3 geology_sensitivity.py OUT_JSON   (needs glim_raster_001.npy, glim_codes.json, wc_bare_001.npy)
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math
import numpy as np
import geology_run as g

ADOPTED = dict(g1=0.50, g2=0.25, p=0.10)
VARIANTS = [dict(ADOPTED)] + [dict(ADOPTED, **{k: v}) for k, v in
                              (("g1", 0.30), ("g1", 0.70), ("g2", 0.10), ("g2", 0.50), ("p", 0.05), ("p", 0.20))]


def arrays(raster, inv, bare8, T):
    w = int(round(g.WIN_DEG / g.RES))
    rows_i = [i0 for i0 in range(0, g.NY - w + 1, w // 2) if abs(90 - (i0 + w / 2) * g.RES) <= 84]
    lut = np.where(np.arange(256) <= 200, np.arange(256) / 200.0, 0.0).astype(np.float32)
    st = g.lookup(inv, T["target"]); sp = g.lookup(inv, T["partner"])
    Ls = g.window_sums(lambda a, b: (raster[a:b] > 0).astype(np.float32), w, rows_i)
    WC = g.window_sums(lambda a, b: ((raster[a:b] > 0) & (bare8[a:b] != 255)).astype(np.float32), w, rows_i)
    A = g.window_sums(lambda a, b: st[raster[a:b]], w, rows_i)
    P = g.window_sums(lambda a, b: sp[raster[a:b]], w, rows_i)
    E = g.window_sums(lambda a, b: st[raster[a:b]] * lut[bare8[a:b]], w, rows_i)
    lat, lon, f, ex, pf, area = [], [], [], [], [], []
    for (i0, la, wl, js, l), (_, _, _, _, wc), (_, _, _, _, a), (_, _, _, _, p), (_, _, _, _, e) in zip(Ls, WC, A, P, E):
        ok = l >= 0.7 * w * wl
        if not ok.any():
            continue
        cell = (g.RES * 111.32) ** 2 * math.cos(math.radians(la))
        lat.append(np.full(ok.sum(), la)); lon.append(-180 + (js[ok] + wl / 2) * g.RES)
        f.append(a[ok] / l[ok]); pf.append(p[ok] / l[ok])
        ex.append(np.where(wc[ok] / l[ok] >= 0.9, e[ok] / l[ok], np.nan)); area.append(e[ok] * cell)
    c = np.concatenate
    return dict(lat=c(lat), lon=c(lon), f=c(f), ex=c(ex), pf=c(pf), area=c(area))


def evaluate(D, v):
    g1 = D["f"] >= v["g1"]
    g2 = g1 & np.nan_to_num(D["ex"] >= v["g2"])
    g4 = g2 & (D["pf"] >= v["p"])
    tier = np.where(g4, 0, np.where(g2, 1, np.where(g1, 2, 9)))
    order = np.lexsort((-D["f"], -np.nan_to_num(D["area"]), tier))
    top = []
    for i in order:
        if tier[i] == 9:
            break
        if all(g.haversine_km(D["lat"][i], D["lon"][i], D["lat"][k], D["lon"][k]) >= g.SUPPRESS_KM for k in top):
            top.append(i)
        if len(top) >= 50:
            break
    return dict(G1_or_better=int(g1.sum()), G2_or_better=int(g2.sum()), G4=int(g4.sum()), top=top,
                top_tier_counts={t: int(sum(1 for i in top if tier[i] == k)) for t, k in (("G4", 0), ("G2", 1), ("G1", 2))})


def ov(a, b, D):
    return round(sum(1 for i in a if any(g.haversine_km(D["lat"][i], D["lon"][i], D["lat"][j], D["lon"][j]) < g.SUPPRESS_KM for j in b)) / max(len(a), 1), 3)


def main():
    raster = np.load("glim_raster_001.npy", mmap_mode="r")
    inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
    bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
    out = {"adopted": ADOPTED, "references": {}}
    for rid, T in g.TARGETS.items():
        D = arrays(raster, inv, bare8, T)
        base = evaluate(D, ADOPTED)
        # 'trivial' baseline: exposed lithology only (rank G2 windows by exposed area, ignore partner)
        triv = evaluate(D, dict(ADOPTED, p=99.0))
        r = {"n_windows": int(D["lat"].size), "adopted": {k: v for k, v in base.items() if k != "top"},
             "overlap_adopted_vs_exposed_lithology_only": ov(base["top"], triv["top"], D),
             "median_partner_share_in_adopted_G4_top50": round(float(np.median([D["pf"][i] for i in base["top"]])), 3),
             "variants": []}
        for v in VARIANTS[1:]:
            e = evaluate(D, v)
            r["variants"].append(dict(params=v, **{k: e[k] for k in ("G1_or_better", "G2_or_better", "G4", "top_tier_counts")},
                                      overlap_with_adopted_top50=ov(base["top"], e["top"], D)))
        out["references"][rid] = r
        print(rid, json.dumps(r), flush=True)
    json.dump(out, open(sys.argv[1], "w"), indent=1)


if __name__ == "__main__":
    main()

```

## engine/glim_bulk.py

```python
# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import requests, json, time, os, sys
U="https://services8.arcgis.com/4KhTMTZ1x0f76DSg/ArcGIS/rest/services/GLiM_Niveau_I/FeatureServer/1/query"
s=requests.Session(); s.verify=os.environ.get("REQUESTS_CA_BUNDLE",True)
N=1235259; page=2000; t0=time.time(); fails=0
for off in range(0,N,page):
    fn=f"glim/p{off:07d}.geojson"; os.makedirs("glim", exist_ok=True)
    if os.path.exists(fn): continue
    for attempt in range(5):
        try:
            r=s.get(U,params=dict(where="1=1",outFields="Litho",returnGeometry="true",outSR=4326,geometryPrecision=4,maxAllowableOffset=0.001,resultOffset=off,resultRecordCount=page,orderByFields="OBJECTID",f="geojson"),timeout=120)
            d=r.json(); assert "features" in d, str(d)[:200]
            json.dump(d,open(fn,"w")); break
        except Exception as e:
            time.sleep(5*(attempt+1)); err=e
    else:
        fails+=1; print("FAIL",off,err,flush=True)
    if off % 100000==0: print(off, round(time.time()-t0), "s", flush=True)
print("done", round(time.time()-t0),"s fails",fails, flush=True)

```

## engine/global_run.py

```python
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

```

## engine/lolaread.py

```python
# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import rasterio, numpy as np, time
from rasterio.windows import from_bounds
ENV=dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".TIF", GDAL_HTTP_MULTIPLEX="NO", GDAL_HTTP_MULTIRANGE="SINGLE", GDAL_NUM_THREADS="1", GDAL_HTTP_MAX_RETRY="6", GDAL_HTTP_RETRY_DELAY="4", GDAL_HTTP_RETRY_CODES="403,429,500,502,503")
def read(layer,cx,cy,w,base="https://pgda.gsfc.nasa.gov/data/LOLA_20mpp/LDEM_80S_20MPP_ADJ"):
    with rasterio.Env(**ENV):
        with rasterio.open(f"/vsicurl/{base}{layer}.TIF") as d:
            win=from_bounds(cx-w/2,cy-w/2,cx+w/2,cy+w/2,d.transform)
            return d.read(1,window=win).astype(float), d.window_transform(win), d.crs
if __name__=="__main__":
    sites={"Site01_connecting_ridge":(-11000,-12000,16000),"Site04_shackleton_rim":(-1000,-7000,16000),"Site23_malapert":(-500,121500,21000),"Site11_degerlache_rim":(-37000,15000,16000)}
    for name,(cx,cy,w) in sites.items():
        t=time.time()
        z,_,_=read("",cx,cy,w); e,_,_=read("_EFFRES",cx,cy,w); r,_,_=read("_ERR",cx,cy,w)
        np.savez_compressed(f"lola20_{name}.npz",z=z,effres=e,err=r)
        print(name,z.shape,"EFFRES m p10/50/90=%.0f/%.0f/%.0f"%tuple(np.nanpercentile(e,[10,50,90])),"ERR m p10/50/90=%.2f/%.2f/%.2f"%tuple(np.nanpercentile(r,[10,50,90])),"t=%.0fs"%(time.time()-t),flush=True)

```

## engine/make_manifest.py

```python
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

```

## engine/ms_region.py

```python
"""Download detailed ('large'-scale, mostly state-survey) geologic map polygons from Macrostrat
for a circle around a centre point, by sampling a 1 km point grid and skipping points already
covered by a fetched polygon.

Usage: python3 ms_region.py OUT_GEOJSON [lat lon radius_km spacing_km]
Data licence: Macrostrat, CC-BY 4.0 (cite Macrostrat and each map's source).
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math, time, random
import numpy as np, requests
from concurrent.futures import ThreadPoolExecutor
from shapely.geometry import shape, Point
from shapely.strtree import STRtree

lat0, lon0, rad, sp = (float(a) for a in sys.argv[2:6]) if len(sys.argv) > 5 else (40.33, -74.60, 150.0, 1.0)
out = sys.argv[1]
S = requests.Session()


def q(p):
    la, lo = p
    for k in range(4):
        try:
            r = S.get("https://macrostrat.org/api/v2/geologic_units/map",
                      params=dict(lat=f"{la:.5f}", lng=f"{lo:.5f}", scale="large", format="geojson"), timeout=40)
            if r.status_code == 200:
                d = r.json()
                return p, d.get("success", {}).get("data", {}).get("features", []) if "success" in d else d.get("features", [])
        except Exception:
            pass
        time.sleep(1 + 2 * k)
    return p, None


pts = []
n = int(rad / sp)
for i in range(-n, n + 1):
    for j in range(-n, n + 1):
        if (i * sp) ** 2 + (j * sp) ** 2 <= rad ** 2:
            pts.append((lat0 + i * sp / 110.6, lon0 + j * sp / (111.3 * math.cos(math.radians(lat0)))))
random.seed(0); random.shuffle(pts)
print("grid points", len(pts), flush=True)
polys, geoms, seen = [], [], set()
pending = pts; t0 = time.time(); nq = 0; failed = 0
tree = None
with ThreadPoolExecutor(8) as ex:
    while pending:
        batch, pending = pending[:64], pending[64:]
        for p, feats in ex.map(q, batch):
            nq += 1
            if feats is None:
                failed += 1; continue
            for f in feats:
                mid = f["properties"].get("map_id")
                if mid in seen or not f.get("geometry"):
                    continue
                seen.add(mid); polys.append(f); geoms.append(shape(f["geometry"]))
        if geoms:
            tree = STRtree(geoms)
            keep = []
            for p in pending:
                pt = Point(p[1], p[0])
                if not any(geoms[k].covers(pt) for k in tree.query(pt)):
                    keep.append(p)
            pending = keep
        if nq % 640 < 64:
            print(f"queries {nq} polygons {len(polys)} pending {len(pending)} failed {failed} {time.time()-t0:.0f}s", flush=True)
json.dump({"type": "FeatureCollection", "features": polys,
           "properties": dict(source="Macrostrat geologic_units/map scale=large, CC-BY 4.0", centre=[lat0, lon0],
                              radius_km=rad, spacing_km=sp, queries=nq, failed=failed)}, open(out, "w"))
print("done", len(polys), "polygons", nq, "queries", failed, "failed", round(time.time() - t0), "s")

```

## engine/plot_candidates.py

```python
"""Presentation maps from run outputs (not part of the website).

Draws, for each reference, every window the run could measure (grey), the nominated
candidates coloured by worst-scale slope distance (degrees), and a dashed line in the colour bar
at the distance between two lunar references (the yardstick). Also draws the scale signature
(median slope vs baseline) of the five closest candidates against the reference.

Usage: python3 plot_candidates.py FEATURE_DIR CANDIDATES_JSON OUT_PREFIX [states.geojson]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, glob, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from global_run import LS

YARDSTICK = {"M-CR": ("de Gerlache rim", 3.66), "M-DG": ("Connecting ridge", 3.66),
             "M-MA": ("de Gerlache rim", 3.72), "M-SR": ("Malapert", 4.76),
             "MZ-FLAT": ("a typical real lunar flat-zone window (median)", 1.16),
             "MZ-STEEP": ("a typical real lunar steep-zone window (median)", 2.95)}


def outlines(ax, path):
    if not path or not os.path.exists(path):
        return
    for f in json.load(open(path))["features"]:
        g = f["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for p in polys:
            r = np.array(p[0]); ax.plot(r[:, 0], r[:, 1], color="#9a9a9a", lw=0.5, zorder=1)


def main():
    fdir, cj, pre = sys.argv[1:4]
    states = sys.argv[4] if len(sys.argv) > 4 else None
    lat, lon = [], []
    for f in glob.glob(os.path.join(fdir, "*.npz")):
        z = np.load(f)
        if z["lat"].size:
            lat.append(z["lat"]); lon.append(z["lon"])
    lat = np.concatenate(lat); lon = np.concatenate(lon)
    res = json.load(open(cj))
    for rid, r in res["references"].items():
        c = r["candidates"]
        if not c:
            continue
        fig, ax = plt.subplots(figsize=(12, 7), dpi=150)
        outlines(ax, states)
        ax.scatter(lon, lat, s=0.6, c="#d6d6d6", lw=0, zorder=2, label=f"measured windows ({lat.size:,})")
        cl = np.array([[x["lon"], x["lat"], x["worst_scale_slope_W1_deg"]] for x in c])
        sc = ax.scatter(cl[:, 0], cl[:, 1], c=cl[:, 2], cmap="viridis_r", s=40, edgecolor="black", lw=0.5, zorder=3,
                        label=f"nominated candidates ({len(c)})")
        for k in range(min(5, len(c))):
            ax.annotate(str(k + 1), (cl[k, 0], cl[k, 1]), xytext=(4, 4), textcoords="offset points", fontsize=9, weight="bold", zorder=4)
        cb = fig.colorbar(sc, ax=ax, shrink=0.7)
        cb.set_label("worst-scale slope distance to reference (degrees; lower = closer)")
        if rid in YARDSTICK:
            name, d = YARDSTICK[rid]
            lo, hi = cb.vmin, cb.vmax
            if lo <= d <= hi:
                cb.ax.axhline(d, color="red", ls="--", lw=1.5)
            ax.plot([], [], color="red", ls="--", label=f"yardstick: {name} vs this reference = {d}° (colour-bar line)")
        ax.set_xlim(lon.min() - 1, lon.max() + 1); ax.set_ylim(lat.min() - 1, lat.max() + 1)
        ax.set_aspect(1 / np.cos(np.radians(np.mean(lat))))
        ax.set_xlabel("longitude"); ax.set_ylabel("latitude")
        ax.set_title(f"Earth windows closest in multiscale terrain to {r['meta']['desc'].split(',')[0]}\n"
                     f"Copernicus GLO-90 + ESA WorldCover vs NASA LOLA; 10 km windows; run on {res['n_tiles']} tiles", fontsize=11)
        ax.legend(loc="lower left", fontsize=8)
        fig.tight_layout(); fig.savefig(f"{pre}_{rid}_map.png"); plt.close(fig)

        # scale signature: reference vs five closest candidates
        R = np.load("refs.npz")[rid + "_slope_q"]
        use = [LS.index(L) for L in r["meta"]["baselines"]]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=150)
        ax.plot([LS[i] for i in use], [R[i, 24:26].mean() for i in use], "k-o", lw=2.5, label="reference (Moon)")
        for k, x in enumerate(c[:5]):
            m = x["median_slope_deg_by_baseline"]
            ax.plot(LS, [m[str(L)] for L in LS], "-o", lw=1.2, alpha=0.8, label=f"candidate {k+1} ({x['lat']:.2f}, {x['lon']:.2f})")
        ax.set_xscale("log"); ax.minorticks_off(); ax.set_xticks(LS); ax.set_xticklabels([f"{L} m" for L in LS])
        ax.set_xlabel("baseline (plane-fit disc diameter)"); ax.set_ylabel("median slope (degrees)")
        ax.set_title(f"Scale signature: {r['meta']['desc'].split(',')[0]}", fontsize=10)
        ax.legend(fontsize=7); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(f"{pre}_{rid}_signature.png"); plt.close(fig)
        print("wrote", rid)


if __name__ == "__main__":
    main()

```

## engine/region_geology.py

```python
"""Geology pathway restricted to windows within RADIUS_KM of a centre (same rules as geology_run.py).
Usage: python3 region_geology.py OUT_JSON [lat lon radius_km]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import sys, json, math
import numpy as np
import geology_run as g
clat, clon, rad = (float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])) if len(sys.argv) > 4 else (40.33, -74.60, 150.0)
raster = np.load("glim_raster_001.npy", mmap_mode="r")
inv = {int(k): v for k, v in json.load(open("glim_codes.json")).items()}
bare8 = np.load("wc_bare_001.npy", mmap_mode="r")
lut = np.where(np.arange(256) <= 200, np.arange(256) / 200.0, 0.0).astype(np.float32)
w = int(round(g.WIN_DEG / g.RES))
rows_i = [i0 for i0 in range(0, g.NY - w + 1, w // 2) if abs(90 - (i0 + w / 2) * g.RES - clat) <= rad / 110.6 + 0.1]
L = g.window_sums(lambda a, b: (raster[a:b] > 0).astype(np.float32), w, rows_i)
WC = g.window_sums(lambda a, b: ((raster[a:b] > 0) & (bare8[a:b] != 255)).astype(np.float32), w, rows_i)
out = {"area": dict(centre=[clat, clon], radius_km=rad), "references": {}}
for rid, T in g.TARGETS.items():
    st = g.lookup(inv, T["target"]); sp = g.lookup(inv, T["partner"])
    A = g.window_sums(lambda a, b: st[raster[a:b]], w, rows_i)
    P = g.window_sums(lambda a, b: sp[raster[a:b]], w, rows_i)
    E = g.window_sums(lambda a, b: st[raster[a:b]] * lut[bare8[a:b]], w, rows_i)
    recs = []
    for (i0, lat, wl, js, ls), (_, _, _, _, a), (_, _, _, _, p), (_, _, _, _, e), (_, _, _, _, wc) in zip(L, A, P, E, WC):
        lons = -180 + (js + wl / 2) * g.RES
        d = g.haversine_km(clat, clon, lat, lons)
        for k in np.where((d <= rad) & (ls >= 0.7 * w * wl))[0]:
            f = a[k] / ls[k]
            if f < 0.05:
                continue
            expo = e[k] / ls[k] if wc[k] / ls[k] >= 0.9 else None
            tier = "below G1"
            if f >= g.G1_MIN:
                tier = "G1"
                if expo is not None and expo >= g.G2_MIN:
                    tier = "G4 (co-located partner unit; shared process not established; G3 not evaluated)" if p[k] / ls[k] >= g.PARTNER_MIN else "G2"
            recs.append(dict(lat=round(lat, 3), lon=round(float(lons[k]), 3), distance_km=round(float(d[k]), 1), tier=tier,
                             mapped_target_fraction=round(float(f), 3),
                             exposed_target_fraction=None if expo is None else round(float(expo), 4),
                             partner_fraction=round(float(p[k] / ls[k]), 3)))
    recs.sort(key=lambda r: -r["mapped_target_fraction"])
    tiers = {}
    for r in recs:
        tiers[r["tier"]] = tiers.get(r["tier"], 0) + 1
    out["references"][rid] = dict(target=T["desc"], windows_with_target_over_5pct=len(recs), tiers=tiers, top=recs[:15])
    print(rid, tiers)
    for r in recs[:6]:
        print("  ", r)
json.dump(out, open(sys.argv[1], "w"), indent=1)

```

## engine/regional_geology_v2.py

```python
"""Regional geological discovery v2 (geo-2.0): process-aware evidence engine over a study area.

Pipeline (no site-specific rules; the same code runs for any circle):
  1. USGS SGMC v1.1 polygons inside the study circle, CLIPPED to it.
  2. Evidence profile per map unit (geo_v2.evidence_profile): structured lithology, emplacement,
     environment, structures, minerals, alteration, Macrostrat corroboration, source scale.
  3. Measured spatial context per polygon: perimeter shared with lava flows / lake units,
     share of area within 500 m of an intrusive contact.
  4. Comparison with each planetary reference (geo_v2.PLANETARY); candidates = all core properties,
     no core contradiction.
  5. Separate layers for candidates: (a) geological existence, (b) surface exposure (steep ground,
     USGS 3DEP 1/3" ~20 m), (c) legal public access (PAD-US 'Open access' INTERSECTED with steep
     cells, not with the polygon), (d) D435 suitability (what can/cannot be judged remotely).
  6. Positive/negative controls (labelled from published formation descriptions) for the old and new rules.
  7. Independent validation against the Sourland Conservancy geology guide (never used as input).

Usage: python3 regional_geology_v2.py SGMC_GDB OUT_JSON [lat lon radius_km]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math, datetime, warnings, re
import numpy as np, pandas as pd, requests
warnings.filterwarnings("ignore")
import geopandas as gpd, pyogrio, rasterio
from rasterio.mask import mask as rmask
from rasterio.features import geometry_mask
from scipy import ndimage
from shapely.geometry import Point, shape
from shapely.strtree import STRtree
from concurrent.futures import ThreadPoolExecutor
import geo_v2 as G

PADUS = "https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/PADUS_Public_Access/FeatureServer/0/query"
DEM = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/{n}/USGS_13_{n}.tif"
STEEP_DEG = 25.0

# Controls: labels assigned from published formation descriptions (Newark Basin: Olsen 1980 and NJGS
# map descriptions; Coastal Plain marine units; Martinsburg turbidites). Used ONLY for evaluation.
CONTROLS = {
    "MARS-LAKE": dict(positive=["Lockatong Formation", "Passaic Formation gray bed", "Towaco Formation", "Feltville Formation", "Boonton Formation"],
                      negative=["Martinsburg Formation", "Stockton Formation", "Hammer Creek Formation", "Woodbury Formation", "Navesink Formation",
                                "Marshalltown Formation", "Merchantville Formation", "Englishtown Formation", "Shark River Formation",
                                "Magothy Formation", "Raritan Formation", "Diabase", "Orange Mountain Basalt"]),
    "MARS-LAVA": dict(positive=["Orange Mountain Basalt", "Preakness Basalt"],
                      negative=["Diabase", "Palisade Diabase", "Lockatong Formation", "Serpentinite"]),
    "MARS-SERP": dict(positive=["Serpentinite", "Serpentine", "Ultramafic rocks", "Ultramafic Rocks"],
                      negative=["Diabase", "Palisade Diabase", "Orange Mountain Basalt", "Lockatong Formation"]),
}
# Held-out test region (Hartford basin, CT/MA). Labels fixed BEFORE the engine was run there, from published
# formation descriptions (Olsen 1980; Hubert et al. 1978; Robinson & Luttrell 1985 as quoted in SGMC). Scored per map unit
# (UNIT_LINK) because conglomerate facies share formation names with the lake beds. Portland Fm left out (mixed fluvial/lake).
CONTROLS_HARTFORD = {
    "MARS-LAKE": dict(positive_links=["CTJeb;0", "CTJsm;0", "MAJe;0", "MAJsm;0", "MAJm;0", "MAJs;0", "MAJt;0"],
                      negative_links=["CTTRnh;0", "MAJn;0", "MATRn;0", "MAJec;0", "MAJsmc;0", "MAJmc;0", "MAJsc;0", "MAJtc;0",
                                      "CTJb;0", "CTJwr;0", "CTJho;0", "MAJhb;0"]),
    "MARS-LAVA": dict(positive_links=["CTJta;0", "CTJho;0", "CTJha;0", "MAJdb;0", "MAJhb;0", "MAJhab;0"],
                      negative_links=["CTJb;0", "CTJwr;0", "MAJd;0", "CTJeb;0", "CTTRnh;0"]),
}
# Map units excluded from scoring with a stated reason (label error found while checking, not a rule change)
LINK_LABEL_FIXES = {"NJJps;5": "siltstone interbed mapped under the Preakness Basalt name; it is not a lava flow"}

OLD_RULES = {  # what the v0.3 methods would have accepted (for the comparison)
    "keyword 'lake' (v1 regional)": ("MARS-LAKE", lambda u: bool(re.search(r"lacustrine|\blakes?\b|playa", u["text"], re.I))),
    "regex lake deposits (v2 regional)": ("MARS-LAKE", lambda u: bool(re.search(r"lacustrine|playa|\blake[- ](deposits?|beds?|sediments?|sequences?|cycles?|mudflat)", u["text"], re.I))),
    "GLiM-style basic volcanic OR plutonic (v0.3 global)": ("MARS-LAVA", lambda u: bool({"MAFIC_VOLCANIC", "MAFIC_INTRUSIVE"} & set(u["lith"]))),
    "GLiM-style basic plutonic (v0.3 global, Jezero target)": ("MARS-SERP", lambda u: bool({"MAFIC_INTRUSIVE", "ULTRAMAFIC"} & set(u["lith"]))),
}


def padus_open(geom4326):
    b = geom4326.bounds
    r = requests.get(PADUS, params=dict(geometry=f"{b[0]},{b[1]},{b[2]},{b[3]}", geometryType="esriGeometryEnvelope", inSR=4326,
                                        spatialRel="esriSpatialRelIntersects", outFields="Unit_Nm,Pub_Access", where="Pub_Access='OA'",
                                        returnGeometry="true", outSR=4326, f="geojson"), timeout=60)
    return [(f["properties"].get("Unit_Nm"), shape(f["geometry"]).buffer(0)) for f in r.json().get("features", []) if f.get("geometry")]


def exposure_access(geom4326):
    """Separate layers: steep (exposure proxy) cells, and steep cells inside open-access public land."""
    b = geom4326.bounds; out = dict(steep_km2=0.0, public_steep_km2=0.0, public_lands_with_steep_ground=[], look_here=[])
    try:
        lands = padus_open(geom4326)
    except Exception as e:
        lands = None; out["access_error"] = str(e)[:80]
    for la in range(math.floor(b[1]), math.ceil(b[3])):
        for lo in range(math.floor(b[0]), math.ceil(b[2])):
            n = f"n{la + 1:02d}w{-lo:03d}"
            try:
                with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
                    with rasterio.open("/vsicurl/" + DEM.format(n=n), OVERVIEW_LEVEL=0) as d:
                        a, tr = rmask(d, [geom4326.__geo_interface__], crop=True, nodata=np.nan, filled=True)
            except Exception:
                continue
            z = a[0].astype(float); lat = (b[1] + b[3]) / 2
            dx = abs(tr.a) * 111320 * math.cos(math.radians(lat)); dy = abs(tr.e) * 110574
            gy, gx = np.gradient(z, dy, dx); s = np.degrees(np.arctan(np.hypot(gx, gy)))
            steep = np.isfinite(s) & (s >= STEEP_DEG); cell_km2 = dx * dy / 1e6
            out["steep_km2"] += float(steep.sum() * cell_km2)
            if lands:
                pub = np.zeros_like(steep)
                for name, gm in lands:
                    inside = ~geometry_mask([gm.__geo_interface__], out_shape=steep.shape, transform=tr, all_touched=False)
                    hit = steep & inside
                    if hit.any() and name and name not in out["public_lands_with_steep_ground"]:
                        out["public_lands_with_steep_ground"].append(name)
                    pub |= inside
                ps = steep & pub
                out["public_steep_km2"] += float(ps.sum() * cell_km2)
                lab, k = ndimage.label(ps, structure=np.ones((3, 3)))
                if k:
                    sizes = np.bincount(lab.ravel())[1:]
                    for idx in np.argsort(sizes)[::-1][:3]:
                        rr, cc = np.where(lab == idx + 1)
                        lon_, lat_ = tr * (cc.mean() + 0.5, rr.mean() + 0.5)
                        out["look_here"].append(dict(lat=round(lat_, 5), lon=round(lon_, 5), steep_public_m2=int(sizes[idx] * cell_km2 * 1e6)))
    out["steep_km2"] = round(out["steep_km2"], 3); out["public_steep_km2"] = round(out["public_steep_km2"], 4)
    out["look_here"] = sorted(out["look_here"], key=lambda x: -x["steep_public_m2"])[:3]
    if lands is None:
        out["public_steep_km2"] = None
    return out


def make_context(g, prof):
    """Measured spatial relationships for polygon i of g (EPSG:5070). Lava neighbours are units that are volcanic
    AND not identified as intrusions (G.is_lava_unit); a diabase sill coded as basalt is not a lava neighbour."""
    is_volc = g.UNIT_LINK.map(lambda l: G.is_lava_unit(prof[l])).values
    is_intr = g.UNIT_LINK.map(lambda l: "INTRUSIVE" in prof[l]["emplacement"]).values
    is_lake = g.UNIT_LINK.map(lambda l: "LACUSTRINE" in prof[l]["environment"]).values
    tree = STRtree(list(g.geometry))
    intr_union = g[is_intr].geometry.buffer(500).unary_union if is_intr.any() else None
    lake_union10 = g[is_lake].geometry.buffer(10000).unary_union if is_lake.any() else None

    def context(i):
        geom = g.geometry.iloc[i]; bd = geom.boundary
        near = [j for j in tree.query(geom.buffer(30)) if j != i]
        def shared(mask):
            L = 0.0
            for j in near:
                if mask[j]:
                    L += bd.intersection(g.geometry.iloc[j].buffer(30)).length
            return round(L / 1000, 2)
        v, lk = shared(is_volc), shared(is_lake)
        share = (geom.intersection(intr_union).area / geom.area) if (intr_union is not None and geom.area > 0) else 0.0
        return dict(VOLCANIC_NEIGHBOUR=v > 0, LAKE_NEIGHBOUR=lk > 0,
                    within_10km_of_mapped_lake_unit=bool(lake_union10 is not None and geom.intersects(lake_union10)),
                    shared_perimeter_with_lava_flows_km=v, shared_perimeter_with_lake_units_km=lk,
                    share_within_500m_of_intrusive_contact=round(share, 3))
    return context


def main():
    gdb, out_json = sys.argv[1], sys.argv[2]
    clat, clon, rad = (float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])) if len(sys.argv) > 5 else (40.33, -74.60, 150.0)
    region = sys.argv[6] if len(sys.argv) > 6 else "newark"
    n_detail = int(sys.argv[7]) if len(sys.argv) > 7 else 60          # candidates per reference that get exposure/access
    t0 = datetime.datetime.now()
    circle = gpd.GeoSeries([Point(clon, clat)], crs=4326).to_crs(5070).buffer(rad * 1000).iloc[0]
    bb = gpd.GeoSeries([circle], crs=5070).to_crs("ESRI:102039").total_bounds
    g = pyogrio.read_dataframe(gdb, layer="SGMC_Geology", bbox=tuple(bb)).set_crs("ESRI:102039", allow_override=True).to_crs(5070)
    g = g[g.intersects(circle)].copy()
    g["geometry"] = g.geometry.intersection(circle)                       # clip to the study area
    g = g[~g.geometry.is_empty].reset_index(drop=True)
    units = pyogrio.read_dataframe(gdb, layer="Units", read_geometry=False)[["UNIT_LINK", "UNITDESC", "UNIT_AGE"]]
    lith = pyogrio.read_dataframe(gdb, layer="Lithology", read_geometry=False)
    refs = pyogrio.read_dataframe(gdb, layer="Unit_Ref_Link", read_geometry=False)[["UNIT_LINK", "REFERENCE"]]
    links = set(g.UNIT_LINK)
    lith = lith[lith.UNIT_LINK.isin(links)]; units = units[units.UNIT_LINK.isin(links)]
    refmap = refs[refs.UNIT_LINK.isin(links)].groupby("UNIT_LINK").REFERENCE.first().to_dict()
    lrows = lith.groupby("UNIT_LINK").apply(lambda d: list(zip(d.LITH_RANK, d.TOTAL_LITH))).to_dict()
    lcom = lith.groupby("UNIT_LINK").LITH_COM.apply(lambda s: " ".join(s.dropna().astype(str))).to_dict()
    udesc = units.set_index("UNIT_LINK").UNITDESC.to_dict(); uage = units.set_index("UNIT_LINK").UNIT_AGE.to_dict()
    uname = g.groupby("UNIT_LINK").UNIT_NAME.first().to_dict()
    # Macrostrat only for units whose structured lithology is relevant to some reference (+ controls)
    relevant = {l for l in links if set(G.lith_codes(lrows.get(l, []))) & {"FINE_CLASTIC", "MAFIC_VOLCANIC", "MAFIC_INTRUSIVE", "ULTRAMAFIC"}}
    ctrl_names = {n for c in CONTROLS.values() for k in ("positive", "negative") for n in c[k]}
    ctrl_links = {l for c in CONTROLS_HARTFORD.values() for k in c for l in c[k]}
    relevant |= {l for l in links if uname.get(l) in ctrl_names or l in ctrl_links}
    with ThreadPoolExecutor(8) as ex:
        list(ex.map(lambda n: G.macrostrat(n), sorted({uname[l] for l in relevant})))
    # one location per map unit (largest polygon's representative point) for the Macrostrat place/age check
    big = g.assign(_a=g.geometry.area).sort_values("_a", ascending=False).drop_duplicates("UNIT_LINK")
    rp = gpd.GeoSeries(big.geometry.representative_point().values, crs=5070).to_crs(4326)
    loc = {l: (round(p.y, 4), round(p.x, 4)) for l, p in zip(big.UNIT_LINK, rp)}
    prof = {l: G.evidence_profile(uname[l], udesc.get(l), lcom.get(l), lrows.get(l, []), refmap.get(l), use_macrostrat=l in relevant,
                                  location=loc[l], unit_age=uage.get(l)) for l in links}
    print("profiles", len(prof), "macrostrat queried", len({uname[l] for l in relevant}), flush=True)
    context = make_context(g, prof)
    res = dict(schema_version="geo-2.0", label="Regional refinement of the global method (geology engine v2)", region=region,
               created=t0.isoformat(timespec="seconds"), study_area=dict(centre=[clat, clon], radius_km=rad, clipped=True),
               n_polygons=int(len(g)), n_units=len(links),
               datasets=dict(geology="USGS State Geologic Map Compilation v1.1 (public domain); unit descriptions and lithology from the state surveys",
                             corroboration="Macrostrat API v2 units (CC-BY 4.0)", dem="USGS 3DEP 1/3 arc-second (public domain), ~20 m overview",
                             access="USGS PAD-US Public Access (Open access only)"),
               planetary_references={k: dict(name=v["name"], location=v["location"], site_note=v.get("site_note"), not_comparable=v["not_comparable"],
                                             properties=v["properties"]) for k, v in G.PLANETARY.items()},
               sources=G.SRC, candidates={}, controls={}, validation={}, limitations=[
                   "evidence comes from map text and structured lithology at map scale (1:100,000 to 1:250,000 here); it is not field observation",
                   "minerals named in map descriptions are recorded as 'mapped mention', not as measured mineralogy",
                   "steep ground (>= 25 deg on ~20 m DEM) is a proxy for possible outcrop; it is not confirmed rock",
                   "public access means PAD-US 'Open access' land; trails may not reach the steep cells",
                   "D435 suitability cannot be judged remotely beyond 'steep public ground exists'",
                   "Macrostrat environment entries marked 'inferred' are database defaults and are not used as evidence"])
    for rid in G.PLANETARY:
        cands = []
        core = [x for x in G.PLANETARY[rid]["properties"] if x["role"] == "core"]
        for i, row in g.iterrows():
            p = prof[row.UNIT_LINK]
            lith_ok = all(p[x["dim"]].get(x["code"]) for x in core if x["dim"] == "lithology")
            if not lith_ok:
                continue
            ctx = context(i)
            if rid == "MARS-LAKE" and "LACUSTRINE" not in p["environment"]:
                inf = G.infer_lacustrine(p, ctx)
                if inf is None:
                    continue
                p = json.loads(json.dumps(p)); p["environment"]["LACUSTRINE"] = inf
            if not all(p[x["dim"]].get(x["code"]) for x in core):
                continue
            ok, rows = G.compare(p, ctx, rid)
            if not ok:
                continue
            geom4326 = gpd.GeoSeries([row.geometry], crs=5070).to_crs(4326).iloc[0]
            sup = [r["property"] for r in rows if r["role"] == "supporting" and not r["earth_status"].startswith("not")]
            cands.append(dict(polygon_index=int(i), unit_name=row.UNIT_NAME, unit_link=row.UNIT_LINK, state=row.STATE,
                              unit_age=uage.get(row.UNIT_LINK), area_km2=round(row.geometry.area / 1e6, 3),
                              representative_point=[round(geom4326.representative_point().y, 5), round(geom4326.representative_point().x, 5)],
                              distance_km=round(row.geometry.distance(gpd.GeoSeries([Point(clon, clat)], crs=4326).to_crs(5070).iloc[0]) / 1e3, 1),
                              layer_1_geological_evidence=dict(comparison=rows, supporting_properties_recorded=sup,
                                                               n_supporting_recorded=len(sup),
                                                               n_supporting_total=sum(1 for x in G.PLANETARY[rid]["properties"] if x["role"] == "supporting"),
                                                               spatial_context=ctx, conflicts=p["conflicts"], source=p["source"],
                                                               macrostrat=p["macrostrat"], macrostrat_only_not_used=p["macrostrat_only"]),
                              explanation=G.TEMPLATES["qualifies"].format(ref=rid, cores=", ".join(x["code"] for x in core)),
                              not_comparable=G.PLANETARY[rid]["not_comparable"],
                              unmeasured=["outcrop-scale lithology", "measured mineralogy (no spectra used)", "sedimentary structures at the site"]))
        # separate layers for the strongest candidates: order by supporting properties recorded, then area
        cands.sort(key=lambda c: (-c["layer_1_geological_evidence"]["n_supporting_recorded"], -c["area_km2"]))
        for c in cands[:n_detail]:
            gm = gpd.GeoSeries([g.geometry.iloc[c["polygon_index"]]], crs=5070).to_crs(4326).iloc[0].buffer(0)
            ea = exposure_access(gm)
            c["layer_2_exposure"] = dict(steep_ground_km2=ea["steep_km2"], method=f"slope >= {STEEP_DEG} deg on ~20 m DEM (geometry only)")
            c["layer_3_access"] = dict(public_steep_ground_km2=ea["public_steep_km2"], public_lands_with_steep_ground=ea["public_lands_with_steep_ground"][:10])
            c["layer_4_d435"] = dict(remote_assessment=("candidate surfaces exist: steep public ground" if (ea["public_steep_km2"] or 0) > 0 else
                                                        "no steep public ground found"), look_here=ea["look_here"],
                                     cannot_judge_remotely=["vegetation cover on the face", "rock vs soil", "safe standing distance 0.5-3 m"])
        res["candidates"][rid] = cands
        units_sel = sorted({c["unit_name"] for c in cands})
        print(rid, len(cands), "candidate polygons; units:", units_sel[:15], flush=True)
    # controls: compare old rules and new engine at unit level
    unit_info = {}
    for l in sorted(links):              # deterministic; a unit's text = all of its map-sheet descriptions
        unit_info.setdefault(uname[l], dict(text="", lith=set(), links=[]))
        unit_info[uname[l]]["text"] += " " + " ".join(filter(None, [uname[l], udesc.get(l), lcom.get(l)]))
        unit_info[uname[l]]["lith"] |= set(prof[l]["lithology"]); unit_info[uname[l]]["links"].append(l)
    sel_units = {rid: {c["unit_name"] for c in res["candidates"][rid]} for rid in G.PLANETARY}
    sel_links_all = {rid: {c["unit_link"] for c in res["candidates"][rid]} for rid in G.PLANETARY}
    if region == "hartford":
        for rid, ctl in CONTROLS_HARTFORD.items():
            pl = [l for l in ctl["positive_links"] if l in links]; nl = [l for l in ctl["negative_links"] if l in links]
            S = sel_links_all[rid]; tp = [l for l in pl if l in S]; fp = [l for l in nl if l in S]
            out = {"geo-2.0 engine (per map unit, held-out region)": dict(
                true_positives=[(l, uname[l]) for l in tp], false_positives=[(l, uname[l]) for l in fp],
                missed_positives=[(l, uname[l]) for l in pl if l not in S],
                how_lake_was_established={l: next((c["layer_1_geological_evidence"]["comparison"][1]["earth_status"]
                                                   for c in res["candidates"][rid] if c["unit_link"] == l), None) for l in tp} if rid == "MARS-LAKE" else None,
                precision=None if not (tp or fp) else round(len(tp) / (len(tp) + len(fp)), 2), recall=None if not pl else round(len(tp) / len(pl), 2))}
            for nm, (r2, f) in OLD_RULES.items():
                if r2 == rid:
                    sel = {l for l in links if f(dict(text=" ".join(filter(None, [uname[l], udesc.get(l), lcom.get(l)])), lith=set(prof[l]["lithology"])))}
                    tp2 = [l for l in pl if l in sel]; fp2 = [l for l in nl if l in sel]
                    out[nm] = dict(true_positives=tp2, false_positives=fp2, precision=None if not (tp2 or fp2) else round(len(tp2) / (len(tp2) + len(fp2)), 2),
                                   recall=None if not pl else round(len(tp2) / len(pl), 2))
            res["controls"][rid] = dict(positives_present=pl, negatives_present=nl, results=out,
                                        label_source="held-out labels fixed before running; published formation descriptions")
            print("controls", rid, json.dumps(out, default=str)[:900], flush=True)
    for rid, ctl in (CONTROLS.items() if region == "newark" else []):
        pos = [n for n in ctl["positive"] if n in unit_info]; neg = [n for n in ctl["negative"] if n in unit_info]
        def score(sel):
            tp = [n for n in pos if n in sel]; fp = [n for n in neg if n in sel]; fn = [n for n in pos if n not in sel]
            return dict(true_positives=tp, false_positives=fp, missed_positives=fn,
                        precision=None if not (tp or fp) else round(len(tp) / (len(tp) + len(fp)), 2),
                        recall=None if not pos else round(len(tp) / len(pos), 2))
        out = {"geo-2.0 engine": score(sel_units[rid])}
        sel_links = {c["unit_link"] for c in res["candidates"][rid]}
        pos_l = [l for n in pos for l in unit_info[n]["links"] if l not in LINK_LABEL_FIXES]; neg_l = [l for n in neg for l in unit_info[n]["links"]]
        out["geo-2.0 engine (per map-sheet unit)"] = dict(selected_positive_units=sorted(l for l in pos_l if l in sel_links),
                                                         missed_positive_units=sorted(l for l in pos_l if l not in sel_links),
                                                         selected_negative_units=sorted(l for l in neg_l if l in sel_links))
        for nm, (r2, f) in OLD_RULES.items():
            if r2 == rid:
                out[nm] = score({n for n, u in unit_info.items() if f(u)})
        res["controls"][rid] = dict(positives_present=pos, negatives_present=neg, results=out, label_fixes=LINK_LABEL_FIXES,
                                    label_source="labels from published formation descriptions; used only for evaluation")
        print("controls", rid, json.dumps(out)[:600], flush=True)
    # independent validation: Sourland Conservancy geology guide (Lockatong argillite with fossil mudcracks
    # in Sourland Mountain Preserve). Not used as an input.
    try:
        # Sourland Mountain Preserve lies near 40.47 N, 74.70 W; skip (without a network call) when outside the circle
        if 6371 * math.radians(math.hypot(clat - 40.47, (clon + 74.70) * math.cos(math.radians(clat)))) > rad:
            raise RuntimeError("Sourland Mountain Preserve is outside this study area")
        r = requests.get(PADUS, params=dict(where="Unit_Nm='Sourland Mountain Preserve'", outFields="Unit_Nm,Pub_Access", returnGeometry="true",
                                            outSR=4326, f="geojson"), timeout=60).json()
        pres = gpd.GeoSeries([shape(f["geometry"]).buffer(0) for f in r["features"]], crs=4326).unary_union
        pres5070 = gpd.GeoSeries([pres], crs=4326).to_crs(5070).iloc[0]
        inside = g[g.intersects(pres5070)]
        units_in = sorted({(u, l) for u, l in zip(inside.UNIT_NAME, inside.UNIT_LINK)})
        if inside.empty:
            raise RuntimeError("Sourland Mountain Preserve is outside this study area")
        lake_c = [c for c in res["candidates"]["MARS-LAKE"] if g.geometry.iloc[c["polygon_index"]].intersects(pres5070)]
        res["validation"]["sourland_guide"] = dict(
            guide="Sourland Conservancy, Sourland Geology Hike (rev.), describes Lockatong argillite with fossil mudcracks along the Ridge Trail",
            preserve_area_km2=round(pres5070.area / 1e6, 2), units_mapped_in_preserve=units_in,
            mars_lake_candidates_overlapping_preserve=[dict(unit=c["unit_name"], unit_link=c["unit_link"], polygon_index=c["polygon_index"],
                                                            supporting=c["layer_1_geological_evidence"]["supporting_properties_recorded"],
                                                            within_500m_of_intrusion=c["layer_1_geological_evidence"]["spatial_context"]["share_within_500m_of_intrusive_contact"])
                                                       for c in lake_c],
            outcome=("PASS: the engine selects the Lockatong (the unit the guide describes) inside the preserve"
                     if any("Lockatong" in c["unit_name"] for c in lake_c) else
                     "PARTIAL: lake candidates overlap the preserve, but not the unit the guide describes" if lake_c else
                     "NOT SELECTED: no MARS-LAKE candidate overlaps the preserve"))
        print("validation", json.dumps(res["validation"])[:900], flush=True)
    except Exception as e:
        res["validation"]["sourland_guide"] = dict(not_run=str(e)[:200])
    res["runtime_s"] = round((datetime.datetime.now() - t0).total_seconds())
    json.dump(res, open(out_json, "w"), indent=1, default=str)


if __name__ == "__main__":
    main()

```

## engine/regional_lake_search.py

```python
"""Regional refinement of the global method: ancient lake-deposit units near Plainsboro (Jezero/Gale analog).

DISCLOSURE (also written into the output): this search was added on 14 Nov 2026 ~23:15 ET after the
team asked whether New Jersey has Mars-relevant geology that the coarse global search missed. The
hypothesis (Newark Basin rift-lake deposits such as the Lockatong Formation) came from Claude's prior
geological knowledge and the team's interest in the Sourland Mountain area. The rule below was written
BEFORE running it and is applied identically to every polygon in the study area. It is a regional
refinement, not an output of the global search.

PRE-REGISTERED RULE
  Study area: 150 km circle around Plainsboro, NJ (40.33 N, 74.60 W), same as earlier regional runs.
  Data: USGS State Geologic Map Compilation v1.1 (polygons, unit names, state-survey unit descriptions,
        lithology comments).
  Class A "ancient lake deposits": unit name/description/lithology text matches
        lacustrine | lake | lakes | playa   AND the unit is older than the Quaternary.
  Class B "Quaternary lake deposits": same text, Quaternary age (reported separately).
  Supporting attributes (reported, NOT used for selection): mentions of mudcracks/desiccation,
        evaporite/salt/gypsum/glauberite crystals or casts, and cycles/cyclic beds.
  Field criteria, reported SEPARATELY and never combined into a score:
    exposure proxy  = area of the polygon with slope >= 25 deg on USGS 3DEP 1/3" DEM (~20 m overview):
                      ledges, cliffs and stream cuts where bedrock is likely visible; plus WorldCover
                      bare/sparse share
    accessibility   = polygon area inside PAD-US "Public Access = Open" land, with the land names
    distance        = straight line from Plainsboro
  Ranking: Class A polygons by exposure-proxy area (km2). Field shortlist = the same ranking restricted
  to polygons with open-access public land.
  Sourland check: report whether any Class A polygon lies within 5 km of the Sourland Mountain ridge
  reference points, and what the state map shows on the ridge itself.

Usage: python3 regional_lake_search.py SGMC_GDB OUT_JSON OUT_PNG [states.geojson]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math, re, datetime, warnings
import numpy as np, pandas as pd, requests
warnings.filterwarnings("ignore")
import geopandas as gpd, pyogrio
import rasterio
from rasterio.mask import mask as rmask
from shapely.geometry import Point, shape, box
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from state_geology_targets import landcover

CENTRE = (40.33, -74.60); RADIUS_KM = 150.0
LAKE_V1 = r"lacustrine|\blakes?\b|playa"     # pre-registered; matched place names ("Greenwood Lake", "Peach Lake")
LAKE = r"lacustrine|playa|\blake[- ](deposits?|beds?|sediments?|sequences?|cycles?|mudflat)"   # v2: same intent, place names excluded
SUPPORT = {"mudcracks/desiccation": r"mud ?cracks?|desiccation", "evaporite/salt crystals or casts": r"evaporit|gypsum|glauberite|halite|salt",
           "cycles/cyclic beds": r"\bcycl"}
QUAT = r"quaternary|holocene|pleistocene"
SOURLAND_PTS = [(40.474, -74.693), (40.445, -74.770), (40.418, -74.830)]   # along the Sourland Mountain ridge
PADUS = "https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/PADUS_Public_Access/FeatureServer/0/query"
DEM = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/{n}/USGS_13_{n}.tif"


def padus(geom4326):
    b = geom4326.bounds
    r = requests.get(PADUS, params=dict(geometry=f"{b[0]},{b[1]},{b[2]},{b[3]}", geometryType="esriGeometryEnvelope", inSR=4326,
                                        spatialRel="esriSpatialRelIntersects", outFields="Unit_Nm,Pub_Access,MngNm_Desc",
                                        returnGeometry="true", outSR=4326, f="geojson"), timeout=60)
    feats = r.json().get("features", [])
    out = []
    for f in feats:
        if not f.get("geometry"):
            continue
        inter = shape(f["geometry"]).buffer(0).intersection(geom4326)
        if not inter.is_empty:
            out.append((f["properties"].get("Unit_Nm"), f["properties"].get("Pub_Access"), f["properties"].get("MngNm_Desc"), inter))
    return out


def steep_share(geom4326):
    b = geom4326.bounds; tot = steep = 0
    for la in range(math.floor(b[1]), math.ceil(b[3])):
        for lo in range(math.floor(b[0]), math.ceil(b[2])):
            n = f"n{la + 1:02d}w{-lo:03d}"
            try:
                with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
                    with rasterio.open("/vsicurl/" + DEM.format(n=n), OVERVIEW_LEVEL=0) as d:
                        a, tr = rmask(d, [geom4326.__geo_interface__], crop=True, nodata=np.nan, filled=True)
            except Exception:
                continue
            z = a[0].astype(float); lat = (b[1] + b[3]) / 2
            dx = abs(tr.a) * 111320 * math.cos(math.radians(lat)); dy = abs(tr.e) * 110574
            gy, gx = np.gradient(z, dy, dx); s = np.degrees(np.arctan(np.hypot(gx, gy)))
            v = np.isfinite(s); tot += v.sum(); steep += (s[v] >= 25).sum()
    return None if tot == 0 else steep / tot


def main():
    gdb, out_json, out_png = sys.argv[1:4]
    states = sys.argv[4] if len(sys.argv) > 4 else None
    started = datetime.datetime.now().isoformat(timespec="seconds")
    c = gpd.GeoSeries([Point(CENTRE[1], CENTRE[0])], crs=4326)
    circle = c.to_crs(5070).buffer(RADIUS_KM * 1000)
    bb = circle.to_crs("ESRI:102039").total_bounds
    g = pyogrio.read_dataframe(gdb, layer="SGMC_Geology", bbox=tuple(bb))
    g = g.set_crs("ESRI:102039", allow_override=True).to_crs(5070)
    g = g[g.intersects(circle.iloc[0])].copy()
    units = pyogrio.read_dataframe(gdb, layer="Units", read_geometry=False)[["UNIT_LINK", "UNITDESC", "UNIT_AGE"]]
    lith = pyogrio.read_dataframe(gdb, layer="Lithology", read_geometry=False)
    lc = lith.groupby("UNIT_LINK")["LITH_COM"].apply(lambda s: " ".join(s.dropna().astype(str))).reset_index()
    g = g.merge(units, on="UNIT_LINK", how="left").merge(lc, on="UNIT_LINK", how="left")
    txt = (g.UNIT_NAME.fillna("") + " | " + g.UNITDESC.fillna("") + " | " + g.LITH_COM.fillna("")).str.lower()
    age = (g.UNIT_AGE.fillna("") + " " + g.AGE_MIN.fillna("").astype(str) + " " + g.AGE_MAX.fillna("").astype(str)).str.lower()
    lake_v1 = txt.str.contains(LAKE_V1, regex=True)
    lake = txt.str.contains(LAKE, regex=True)
    quat = age.str.contains(QUAT, regex=True)
    g["cls"] = np.where(lake & ~quat, "A ancient lake deposits", np.where(lake & quat, "B Quaternary lake deposits", ""))
    centre5070 = c.to_crs(5070).iloc[0]
    sour5070 = list(gpd.GeoSeries([Point(lo, la) for la, lo in SOURLAND_PTS], crs=4326).to_crs(5070))
    res = {"label": "Regional refinement of the global method (not an output of the global search)",
           "disclosure": __doc__.split("PRE-REGISTERED RULE")[0].strip(), "rule": "PRE-REGISTERED RULE" + __doc__.split("PRE-REGISTERED RULE")[1].split("Usage:")[0],
           "run_started": started, "n_polygons_in_study_area": int(len(g)),
           "states_in_study_area": sorted(g.STATE.dropna().unique().tolist()), "classes": {},
           "rule_revision": dict(note=("v1 keyword 'lake' matched geographic names in unit descriptions (e.g. 'Greenwood Lake', "
                                       "'Peach Lake', 'Halcyon Lake Dolostone'). v2 keeps the same intent and excludes place names: "
                                       "lacustrine | playa | 'lake' followed by deposits/beds/sediments/sequences/cycles/mudflat. "
                                       "Applied identically to every polygon. Both versions are reported."),
                                 v1_units=sorted(set(g[lake_v1 & ~quat].UNIT_NAME.dropna())), v1_polygons=int((lake_v1 & ~quat).sum()),
                                 v2_units=sorted(set(g[lake & ~quat].UNIT_NAME.dropna())), v2_polygons=int((lake & ~quat).sum()))}
    for cls in ("A ancient lake deposits", "B Quaternary lake deposits"):
        sub = g[g.cls == cls]
        recs = []
        for idx, row in sub.iterrows():
            geom = gpd.GeoSeries([row.geometry], crs=5070).to_crs(4326).iloc[0]
            t = txt.loc[idx]
            rec = dict(unit_name=row.UNIT_NAME, state=row.STATE, unit_link=row.UNIT_LINK, unit_age=row.UNIT_AGE,
                       source=row.REFERENCE, area_km2=round(row.geometry.area / 1e6, 2),
                       distance_km=round(row.geometry.distance(centre5070) / 1e3, 1),
                       representative_point=[round(geom.representative_point().y, 4), round(geom.representative_point().x, 4)],
                       description_excerpt=(row.UNITDESC or "")[:400],
                       supporting_mentions=[k for k, rx in SUPPORT.items() if re.search(rx, t)],
                       distance_to_sourland_points_km=round(min(row.geometry.distance(p) for p in sour5070) / 1e3, 2))
            if cls.startswith("A"):
                ss = steep_share(geom); lcv = landcover(geom) if row.geometry.area < 3e9 else None
                rec["exposure_proxy"] = dict(steep_share_ge25deg=None if ss is None else round(float(ss), 4),
                                             steep_area_km2=None if ss is None else round(float(ss) * rec["area_km2"], 3),
                                             worldcover_bare_share=None if lcv is None else lcv["bare"],
                                             worldcover_tree_share=None if lcv is None else lcv["tree"])
                try:
                    pl = padus(geom.buffer(0))
                except Exception as e:
                    pl = None; rec["accessibility_error"] = str(e)[:100]
                if pl is not None:
                    oa = [p for p in pl if p[1] == "OA"]
                    area = lambda ps: round(float(gpd.GeoSeries([p[3] for p in ps], crs=4326).to_crs(5070).area.sum() / 1e6), 3) if ps else 0.0
                    rec["accessibility"] = dict(open_access_area_km2=area(oa),
                                                open_access_lands=sorted({p[0] for p in oa if p[0]})[:12],
                                                restricted_or_unknown_lands=sorted({p[0] for p in pl if p[1] != "OA" and p[0]})[:8])
            recs.append(rec)
        if cls.startswith("A"):
            recs.sort(key=lambda r: -((r.get("exposure_proxy") or {}).get("steep_area_km2") or 0))
            for k, r in enumerate(recs):
                r["rank_by_exposure_proxy"] = k + 1
            short = [r for r in recs if (r.get("accessibility") or {}).get("open_access_area_km2", 0) > 0]
            res["field_shortlist_open_access"] = [dict(rank_by_exposure_proxy=r["rank_by_exposure_proxy"], unit=r["unit_name"],
                                                       distance_km=r["distance_km"], steep_area_km2=r["exposure_proxy"]["steep_area_km2"],
                                                       open_access_lands=r["accessibility"]["open_access_lands"]) for r in short[:15]]
        res["classes"][cls] = dict(n_polygons=len(recs), total_area_km2=round(sum(r["area_km2"] for r in recs), 1),
                                   units=sorted({r["unit_name"] for r in recs}), polygons=recs)
        print(cls, len(recs), "polygons", sorted({r["unit_name"] for r in recs})[:12], flush=True)
    # Sourland check
    sp = gpd.GeoSeries([Point(lo, la) for la, lo in SOURLAND_PTS], crs=4326).to_crs(5070)
    on_ridge = []
    for p, (la, lo) in zip(sp, SOURLAND_PTS):
        hit = g[g.contains(p)]
        on_ridge.append(dict(point=[la, lo], units=hit.UNIT_NAME.tolist(), classes=[x for x in hit.cls.tolist()]))
    A = g[g.cls == "A ancient lake deposits"]
    near = A[A.geometry.distance(sp.unary_union) <= 5000]
    res["sourland_check"] = dict(reference_points=SOURLAND_PTS, units_on_ridge_points=on_ridge,
                                 class_A_polygons_within_5km=int(len(near)),
                                 class_A_units_within_5km=sorted(set(near.UNIT_NAME.tolist())),
                                 ranks_of_class_A_polygons_within_5km=[r["rank_by_exposure_proxy"] for r in res["classes"]["A ancient lake deposits"]["polygons"]
                                                                        if r["distance_to_sourland_points_km"] <= 5],
                                 ranked_polygons_touching_sourland_mountain_preserve=[r["rank_by_exposure_proxy"] for r in res["classes"]["A ancient lake deposits"]["polygons"]
                                                                                      if "Sourland Mountain Preserve" in ((r.get("accessibility") or {}).get("open_access_lands") or [])],
                                 note="The Sourland ridge itself is mapped as Diabase (an intrusive igneous sill), which is not a lake deposit; "
                                      "lake-deposit units (Lockatong, Passaic gray beds) flank it.")
    print("sourland", json.dumps(res["sourland_check"])[:800], flush=True)
    json.dump(res, open(out_json, "w"), indent=1, default=str)
    # map
    fig, ax = plt.subplots(figsize=(11, 11), dpi=140)
    g.boundary.plot(ax=ax, color="#e6e6e6", lw=0.2)
    g[g.cls == "A ancient lake deposits"].plot(ax=ax, color="#1f77b4", alpha=0.85, label="A ancient lake deposits")
    g[g.cls == "B Quaternary lake deposits"].plot(ax=ax, color="#9edae5", alpha=0.85)
    if states:
        gpd.read_file(states).to_crs(5070).boundary.plot(ax=ax, color="#777777", lw=0.6)
    ax.plot(centre5070.x, centre5070.y, "k*", ms=14)
    for p in sp:
        ax.plot(p.x, p.y, "r^", ms=7)
    ax.add_patch(plt.Circle((centre5070.x, centre5070.y), RADIUS_KM * 1e3, fill=False, ls="--", color="#555555"))
    b = circle.total_bounds; ax.set_xlim(b[0], b[2]); ax.set_ylim(b[1], b[3]); ax.set_axis_off()
    ax.plot([], [], "s", color="#1f77b4", label="A: ancient lake deposits (pre-Quaternary)")
    ax.plot([], [], "s", color="#9edae5", label="B: Quaternary lake deposits")
    ax.plot([], [], "k*", label="Plainsboro"); ax.plot([], [], "r^", label="Sourland ridge check points")
    ax.legend(loc="lower right", fontsize=8)
    ax.set_title("Regional refinement: lake-deposit units within 150 km of Plainsboro\nUSGS State Geologic Map Compilation v1.1 (state-survey unit descriptions); rule fixed before running", fontsize=10)
    fig.tight_layout(); fig.savefig(out_png); plt.close(fig)


if __name__ == "__main__":
    main()

```

## engine/regional_run.py

```python
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

```

## engine/state_geology_targets.py

```python
"""Regional process-analog targets from detailed (state-survey) geologic maps.

Reads the Macrostrat large-scale polygons fetched by ms_region.py, applies fixed keyword rules
(written before looking at the results) to find units that record a Mars-relevant process, then
measures for every matching polygon: area, distance from the centre, and land cover from ESA
WorldCover 2021 (20 m overview), i.e. how much of it is bare, open (grass/shrub/bare/moss) or tree.

Usage: python3 state_geology_targets.py POLYGONS_GEOJSON OUT_JSON OUT_PNG [states.geojson]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, math, re, warnings
import numpy as np
warnings.filterwarnings("ignore")
import geopandas as gpd
import rasterio
from rasterio.mask import mask as rmask
from shapely.geometry import Point
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CENTRE = (40.33, -74.60)
# Fixed rules: target -> (Mars reference/zone it speaks to, regex over name + strat_name + lith + descrip)
RULES = {
    "ultramafic / serpentinite": ("Jezero science region: olivine-rich rock altered by water to serpentine and carbonate",
                                  r"serpentin|ultramafic|peridotite|dunite|harzburgite"),
    "basalt (incl. pillow lava)": ("InSight plains / Jezero floor: basaltic lava; pillows = lava that met water",
                                   r"^[^|]*basalt[^|]*\|"),   # 'basalt' must be in the unit NAME (avoids schists listing minor metabasalt)
    "lake sediments": ("Jezero science region: sediments laid down in a lake",
                       r"lacustrine|\blake[- ]?(bed|deposit|sediment)"),
    "evaporite / salt-crystal casts": ("Mars sulfate/chloride deposits: minerals left by evaporating water",
                                       r"evaporit|gypsum|halite|glauberite|salt[- ]crystal"),
    "wind-blown sand": ("Mars dune-crossing zone: wind-blown sand",
                        r"eolian|aeolian|\bdunes?\b|wind-blown"),
    "glacial deposits": ("Mars mid-latitude glaciers: landforms and debris left by ice (no ice today)",
                         r"glacial|\btill\b|moraine|outwash|glaciolacustrine"),
}
WC = "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_{}_Map.tif"
ENV = dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif", GDAL_HTTP_MAX_RETRY="4")


def wc_name(lat, lon):
    la = math.floor(lat / 3) * 3; lo = math.floor(lon / 3) * 3
    return f"{'N' if la >= 0 else 'S'}{abs(la):02d}{'E' if lo >= 0 else 'W'}{abs(lo):03d}"


def landcover(geom):
    """Shares of tree (10), open (20 shrub, 30 grass, 60 bare, 100 moss/lichen) and bare (60) inside geom (EPSG:4326)."""
    c = geom.representative_point()
    counts = np.zeros(256)
    with rasterio.Env(**ENV):
        tiles = {wc_name(y, x) for x, y in [(geom.bounds[0], geom.bounds[1]), (geom.bounds[2], geom.bounds[3]),
                                            (geom.bounds[0], geom.bounds[3]), (geom.bounds[2], geom.bounds[1])]}
        for t in tiles:
            try:
                with rasterio.open("/vsicurl/" + WC.format(t), OVERVIEW_LEVEL=0) as d:
                    a, _ = rmask(d, [geom.__geo_interface__], crop=True, nodata=0, filled=True)
                    counts += np.bincount(a.ravel(), minlength=256)[:256]
            except Exception:
                pass
    n = counts[1:].sum()
    if n == 0:
        return None
    return dict(tree=round(counts[10] / n, 3), open=round((counts[20] + counts[30] + counts[60] + counts[100]) / n, 3),
                bare=round(counts[60] / n, 4), built=round(counts[50] / n, 3), crop=round(counts[40] / n, 3))


def main():
    src, out_json, out_png = sys.argv[1:4]
    states = sys.argv[4] if len(sys.argv) > 4 else None
    g = gpd.read_file(src).set_crs(4326, allow_override=True)
    txt = (g.get("name", "").fillna("") + " | " + g.get("strat_name", "").fillna("") + " | " +
           g.get("lith", "").fillna("") + " | " + g.get("descrip", "").fillna("")).str.lower()
    ga = g.to_crs(5070)                                   # equal-area (CONUS Albers) for areas and distances
    centre = gpd.GeoSeries([Point(CENTRE[1], CENTRE[0])], crs=4326).to_crs(5070).iloc[0]
    res = {"source": "Macrostrat large-scale geologic maps (state surveys), CC-BY 4.0; land cover ESA WorldCover 2021 v200 (20 m overview)",
           "centre": CENTRE, "n_polygons": int(len(g)), "rules": {k: v[1] for k, v in RULES.items()}, "targets": {}}
    fig, ax = plt.subplots(figsize=(11, 11), dpi=150)
    ga.boundary.plot(ax=ax, color="#e3e3e3", lw=0.2)
    cols = plt.cm.tab10(np.arange(len(RULES)))
    for (tname, (why, rx)), col in zip(RULES.items(), cols):
        m = txt.str.contains(rx, regex=True)
        sub = ga[m]
        recs = []
        for idx, row in sub.iterrows():
            geom4326 = g.loc[idx, "geometry"]
            lc = landcover(geom4326) if row.geometry.area < 5e9 else None   # skip land cover for > 5000 km2 polygons
            recs.append(dict(name=g.loc[idx].get("name"), map_id=int(g.loc[idx].get("map_id", -1)),
                             source_id=int(g.loc[idx].get("source_id", -1)),
                             lith=g.loc[idx].get("lith"), description=(g.loc[idx].get("descrip") or "")[:300],
                             area_km2=round(row.geometry.area / 1e6, 2), distance_km=round(row.geometry.distance(centre) / 1e3, 1),
                             representative_point=[round(geom4326.representative_point().y, 4), round(geom4326.representative_point().x, 4)],
                             landcover=lc,
                             open_area_km2=None if lc is None else round(row.geometry.area / 1e6 * lc["open"], 3)))
        recs.sort(key=lambda r: -(r["open_area_km2"] or 0))
        res["targets"][tname] = dict(why=why, n_polygons=len(recs), total_area_km2=round(sum(r["area_km2"] for r in recs), 1),
                                     polygons=recs)
        if len(sub):
            sub.plot(ax=ax, color=col, alpha=0.85, lw=0)
        ax.plot([], [], "s", color=col, label=f"{tname} ({len(recs)} polygons)")
        print(tname, len(recs), "polygons; top by open area:",
              [(r["name"], r["distance_km"], r["open_area_km2"]) for r in recs[:4]], flush=True)
    if states:
        gpd.read_file(states).to_crs(5070).boundary.plot(ax=ax, color="#777777", lw=0.6)
    ax.plot(centre.x, centre.y, "k*", ms=14, label="Plainsboro")
    for r_km in (75, 150):
        ax.add_patch(plt.Circle((centre.x, centre.y), r_km * 1e3, fill=False, ls="--", color="#555555", lw=0.8))
    b = ga.total_bounds; ax.set_xlim(b[0], b[2]); ax.set_ylim(b[1], b[3]); ax.set_axis_off()
    ax.set_title("Mars-relevant process units within 150 km of Plainsboro\nstate-survey geologic maps via Macrostrat (CC-BY 4.0); circles at 75 and 150 km", fontsize=11)
    ax.legend(loc="lower right", fontsize=8)
    fig.tight_layout(); fig.savefig(out_png); plt.close(fig)
    json.dump(res, open(out_json, "w"), indent=1, default=str)


if __name__ == "__main__":
    main()

```

## engine/terrain_engine.py

```python
"""Vectorised local plane-fit terrain features (research engine, v0.3 draft).

For every pixel, fit z = a*x + b*y + c by least squares over a circular
neighbourhood of diameter L (metres), using only valid pixels.
Outputs per pixel:
  slope_deg  = degrees(arctan(hypot(a, b)))        (absolute slope of fitted plane)
  rough_m    = sqrt(mean squared residual)          (detrended RMS roughness, metres)
  frac_valid = valid pixels / disc pixels
Exact same estimator as the v0.2 prototype's plane_fit(), but computed for all
pixels at once with FFT convolutions of weighted moments.

Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
Space Apps AI policy. Reviewed and run by the team.
"""
from __future__ import annotations
import numpy as np
from scipy.signal import fftconvolve


def disc_kernel(r: int):
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    k = ((xx ** 2 + yy ** 2) <= r * r).astype(float)
    return k, xx.astype(float), yy.astype(float)


def _corr(a, k):
    # correlation = convolution with flipped kernel
    return fftconvolve(a, k[::-1, ::-1], mode="same")


def plane_features(z: np.ndarray, valid: np.ndarray, pixel_m: float, L_m: float,
                   min_frac: float = 0.8):
    r = int(round(L_m / (2 * pixel_m)))
    if r < 2:
        raise ValueError("baseline below 5 grid samples across")
    k, kx, ky = disc_kernel(r)
    kx = kx * pixel_m
    ky = ky * pixel_m  # metres; image row index increases downward, sign irrelevant for |grad|
    m = valid.astype(float)
    zz = np.where(valid, z - np.nanmean(z[valid]), 0.0)  # de-mean for numerical stability
    # moments
    S0 = _corr(m, k)
    Sx = _corr(m, k * kx); Sy = _corr(m, k * ky)
    Sxx = _corr(m, k * kx * kx); Syy = _corr(m, k * ky * ky); Sxy = _corr(m, k * kx * ky)
    Sz = _corr(zz, k); Sxz = _corr(zz, k * kx); Syz = _corr(zz, k * ky); Szz = _corr(zz * zz, k)
    A = np.stack([np.stack([Sxx, Sxy, Sx], -1), np.stack([Sxy, Syy, Sy], -1), np.stack([Sx, Sy, S0], -1)], -2)
    bvec = np.stack([Sxz, Syz, Sz], -1)
    frac = S0 / k.sum()
    ok = (frac >= min_frac) & valid
    out_slope = np.full(z.shape, np.nan); out_rough = np.full(z.shape, np.nan)
    idx = np.nonzero(ok)
    Ai = A[idx]; bi = bvec[idx]
    sol = np.linalg.solve(Ai, bi[..., None])[..., 0]
    a, b, c = sol[:, 0], sol[:, 1], sol[:, 2]
    ssr = Szz[idx] - (sol * bi).sum(-1)
    ssr = np.maximum(ssr, 0.0)
    out_slope[idx] = np.degrees(np.arctan(np.hypot(a, b)))
    out_rough[idx] = np.sqrt(ssr / S0[idx])
    # edges: discs that extend past the array are not valid estimates
    out_slope[:r, :] = out_slope[-r:, :] = out_slope[:, :r] = out_slope[:, -r:] = np.nan
    out_rough[:r, :] = out_rough[-r:, :] = out_rough[:, :r] = out_rough[:, -r:] = np.nan
    return out_slope, out_rough, frac, r


def connectivity_curve(slope: np.ndarray, thresholds=(5, 10, 15, 20, 25), stride: int = 1):
    """Largest 4-connected component of cells with slope <= t, as a fraction of all
    valid cells (not of passable cells), so a fully passable window scores 1.0.
    Diagnostic only; thresholds are sweeps, not vehicle limits."""
    from scipy.ndimage import label
    s = slope[::stride, ::stride]
    v = np.isfinite(s); n = v.sum()
    out = {}
    for t in thresholds:
        ok = v & (s <= t)
        if n == 0:
            out[t] = None; continue
        lab, num = label(ok, structure=[[0, 1, 0], [1, 1, 1], [0, 1, 0]])
        out[t] = float(np.bincount(lab[ok]).max() / n) if num else 0.0
    return out


def plane_features_fast(z: np.ndarray, valid: np.ndarray, pixel_m: float, L_m: float):
    """Closed form for COMPLETE discs only (any missing pixel in the disc -> NaN).
    For a full symmetric disc: Sx=Sy=Sxy=0 and Sxx=Syy, so
      a = sum(k*x*z)/Sxx, b = sum(k*y*z)/Syy, c = mean(z),
      SSR = sum(k*z^2) - n*c^2 - a^2*Sxx - b^2*Syy.
    Every term is a convolution with a FIXED kernel, so the identical estimator can
    run in Google Earth Engine with ee.Kernel.fixed + ee.Image.convolve."""
    r = int(round(L_m / (2 * pixel_m)))
    if r < 2:
        raise ValueError("baseline below 5 grid samples across")
    k, kx, ky = disc_kernel(r)
    kx = kx * pixel_m; ky = ky * pixel_m
    n = k.sum(); Sxx = (k * kx * kx).sum(); Syy = (k * ky * ky).sum()
    zz = np.where(valid, z - np.nanmean(z[valid]), 0.0)
    full = _corr(valid.astype(float), k) > n - 0.5
    a = _corr(zz, k * kx) / Sxx
    b = _corr(zz, k * ky) / Syy
    c = _corr(zz, k) / n
    ssr = _corr(zz * zz, k) - n * c * c - a * a * Sxx - b * b * Syy
    slope = np.degrees(np.arctan(np.hypot(a, b)))
    rough = np.sqrt(np.maximum(ssr, 0) / n)
    bad = ~full
    bad[:r, :] = bad[-r:, :] = True; bad[:, :r] = True; bad[:, -r:] = True
    slope[bad] = np.nan; rough[bad] = np.nan
    return slope, rough, r

```

## engine/terrain_robustness.py

```python
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

```

## engine/test_engine.py

```python
# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import sys, numpy as np, time
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from experiment import plane_fit           # team prototype estimator (reference)
from terrain_engine import plane_features, disc_kernel
rng=np.random.default_rng(0)
# 1) analytic incline 15 deg + flat
for ang in [0,15,28]:
    n=200;p=30.0
    y,x=np.mgrid[0:n,0:n]*p
    z=np.tan(np.radians(ang))*x+1000
    s,r,_,_=plane_features(z,np.ones_like(z,bool),p,600)
    print("incline",ang,"-> median slope %.4f rough %.2e"%(np.nanmedian(s),np.nanmedian(r)))
# 2) real-ish random surface with holes: compare to prototype at random pixels
n=160;p=60.0
z=np.cumsum(np.cumsum(rng.normal(size=(n,n)),0),1)*0.5+rng.normal(size=(n,n))*2
valid=rng.random((n,n))>0.05
for L in [240,480,960]:
    s,r,frac,rad=plane_features(z,valid,p,L)
    k,kx,ky=disc_kernel(rad)
    errs=[]
    for _ in range(200):
        i,j=rng.integers(rad,n-rad,2)
        if not np.isfinite(s[i,j]):continue
        sl=(slice(i-rad,i+rad+1),slice(j-rad,j+rad+1))
        res=plane_fit(kx*p,ky*p,z[sl],valid[sl]&(k>0),minimum=12)
        if res is None:continue
        errs.append((abs(res[0]-s[i,j]),abs(res[1]-r[i,j])))
    e=np.array(errs);print("L",L,"n",len(e),"max |dslope| %.2e deg, max |drough| %.2e m"%tuple(e.max(0)))
# 3) speed: 4000x4000 at 30 m (one GLO-30 1x1 deg tile is 3600x3600)
z=np.cumsum(np.cumsum(rng.normal(size=(3600,3600)),0),1).astype(float)
t=time.time(); s,r,_,_=plane_features(z,np.ones_like(z,bool),30.0,480); print("3600^2 tile, one baseline: %.1fs"%(time.time()-t))

```

## engine/tests_geology_v2.py

```python
"""Unit tests for the geology engine geo-2.0 (geo_v2.py). Offline: Macrostrat is disabled.
Run:  python3 tests_geology_v2.py            (pure-function tests)
      python3 tests_geology_v2.py OUT.json   (also checks a regional_geology_v2 output file)
"""
import json
import sys

import geo_v2 as G

FAILS = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def prof(name, desc, rows, com=""):
    return G.evidence_profile(name, desc, com, rows, "Drake et al., 1996, 1:100,000", use_macrostrat=False)


# 1 negation guard: "no evidence of lake deposits" must not record LACUSTRINE
p = prof("Test Fm", "Red sandstone; no evidence of lacustrine deposition.", [("Major", "Sedimentary - Clastic - Sandstone")])
check("negation guard blocks 'no evidence of lacustrine'", "LACUSTRINE" not in p["environment"])
p = prof("Test Fm", "Black shale deposited in a lake; mudcracks.", [("Major", "Sedimentary - Clastic - Mudstone - Shale")])
check("positive lake text is recorded", "LACUSTRINE" in p["environment"])

# 2 intrusive vs extrusive on real SGMC wording
palisade = prof("Palisade Diabase", "Medium- to coarse-grained, dark-gray to grayish-black diabase.", [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
check("Palisade Diabase (coded Volcanic-Basalt in SGMC) gets INTRUSIVE from its name", "INTRUSIVE" in palisade["emplacement"])
check("Palisade Diabase conflict is recorded", any("intrusion" in c for c in palisade["conflicts"]))
ok, _ = G.compare(palisade, {}, "MARS-LAVA")
check("Palisade Diabase does not qualify as MARS-LAVA", not ok)
holyoke = prof("Holyoke Basalt", "Greenish-gray to black, fine- to coarse-grained, grading from basalt near contacts to gabbro in the interior.",
               [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
ok, _ = G.compare(holyoke, {}, "MARS-LAVA")
check("thick lava flow that mentions 'gabbro in the interior' still qualifies as MARS-LAVA", ok)
orange = prof("Orange Mountain Basalt", "Three major lava-flow sequences; lower flow pillowed.", [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
ok, rows = G.compare(orange, {}, "MARS-LAVA")
check("Orange Mountain Basalt qualifies as MARS-LAVA", ok)
check("pillows recorded (Earth-only indicator, not counted as Mars support)",
      any(r["property"] == "PILLOWS" and r["role"] == "earth_only" and not r["earth_status"].startswith("not") for r in rows))

# 3 serpentinite vs pyroxenite
serp = prof("Serpentinite", "Chiefly serpentinite with altered dunite and peridotite; magnesite veins.", [("Major", "Igneous - Plutonic - Ultramafic - Serpentinite")])
check("serpentinite is OLIVINE_RICH_ULTRAMAFIC", "OLIVINE_RICH_ULTRAMAFIC" in serp["lithology"])
check("serpentinite qualifies as MARS-SERP", G.compare(serp, {}, "MARS-SERP")[0])
pyx = prof("Olivine pyroxenite", "Olivine pyroxenite; peridotite inclusions.", [("Major", "Igneous - Plutonic - Ultramafic")])
check("unit named pyroxenite is not OLIVINE_RICH_ULTRAMAFIC", "OLIVINE_RICH_ULTRAMAFIC" not in pyx["lithology"])
gab = prof("Gabbro", "Hornblende gabbro.", [("Major", "Igneous - Plutonic - Gabbroic - Gabbro")])
check("gabbro does not qualify as MARS-SERP", not G.compare(gab, {}, "MARS-SERP")[0])

# 4 lacustrine inference (sedimentology + basin context), no lake word in the text
lock = prof("Lockatong Formation", "Cyclically deposited sequences of laminated black mudstone and argillite with desiccation cracks.",
            [("Major", "Sedimentary - Clastic - Mudstone"), ("Minor", "Metamorphic - Metasedimentary - Metaclastic - Argillite")])
check("Lockatong text has no lake word", "LACUSTRINE" not in lock["environment"])
check("inferred lacustrine with basin context", G.infer_lacustrine(lock, {"VOLCANIC_NEIGHBOUR": True}) is not None)
check("no inference without basin context", G.infer_lacustrine(lock, {}) is None)
dolo = prof("Allentown Dolomite", "Dolomite with minor shale; mud cracks, ripple marks, rhythmically bedded.",
            [("Major", "Sedimentary - Carbonate - Dolostone"), ("Minor", "Sedimentary - Clastic - Mudstone - Shale")])
check("tidal-flat dolomite with mudcracks is not inferred lacustrine", G.infer_lacustrine(dolo, {"LAKE_NEIGHBOUR": True}) is None)
marine = prof("Navesink Formation", "Glauconitic marine clay and silt, laminated, with cycles.", [("Major", "Sedimentary - Clastic - Mudstone")])
check("marine evidence blocks the inference", G.infer_lacustrine(marine, {"LAKE_NEIGHBOUR": True}) is None)
one = prof("Some Shale", "Black laminated shale.", [("Major", "Sedimentary - Clastic - Mudstone - Shale")])
check("one indicator is not enough", G.infer_lacustrine(one, {"LAKE_NEIGHBOUR": True}) is None)
evap = prof("Boonton Formation", "Siltstone with mudcracks and gypsum pseudomorphs.",
            [("Major", "Sedimentary - Clastic - Siltstone"), ("Minor", "Sedimentary - Chemical - Evaporite - Gypsum")])
check("structured Evaporite lithology becomes EVAPORITE mineral evidence", "EVAPORITE" in evap["mineral"])

import re
check("Macrostrat 'non-marine' is not MARINE (bug found by the held-out Hartford test)", not re.search(G.MS_ENV["MARINE"], "non-marine", re.I))
check("'nonmarine' in map text is not MARINE", "MARINE" not in prof("X", "Nonmarine red beds; non-marine shale.", [("Major", "Sedimentary - Clastic - Mudstone")])["environment"])
check("'marine' still recorded", "MARINE" in prof("X", "Shallow marine shale.", [("Major", "Sedimentary - Clastic - Mudstone")])["environment"])

# 5 scale parsing / positional uncertainty
check("scale 1:100,000 parsed", G.scale_from_reference("Drake et al., 1996, Bedrock geologic map, 1:100,000") == 100000)
check("scale 1:250000 parsed", G.scale_from_reference("Berg 1980 scale 1:250000") == 250000)
check("no scale -> None", G.scale_from_reference("Unpublished compilation") is None)

# 6 every planetary property has a role, evidence type and a citation that exists
for rid, ref in G.PLANETARY.items():
    for x in ref["properties"]:
        planetary_claim = x["role"] in ("core", "supporting", "contradiction")
        if x["role"] == "not_compared":
            ok = x["evidence_type"] in ("observed", "interpreted", "inferred") and x["src"] and all(s in G.SRC for s in x["src"])
        else:
            ok = (x["evidence_type"] in ("observed", "interpreted", "inferred") and x["src"] and all(s in G.SRC for s in x["src"])) if planetary_claim \
                else (x["role"] in ("caution", "earth_only") and x["evidence_type"] == "not_applicable" and "Earth" in x["statement"])
        if not ok:
            check(f"{rid}/{x['code']} provenance complete", False)
check("all planetary properties carry role, evidence type and resolvable citations", True)

# 7 review corrections (15 Nov)
# 7a Palisade Diabase is not a lava neighbour (regression): toy map, mudstone polygon touching a diabase sill coded as basalt
import geopandas as gpd
from shapely.geometry import box
import regional_geology_v2 as RG
mud = prof("Test Mudstone", "Laminated black mudstone with desiccation cracks; cyclic.", [("Major", "Sedimentary - Clastic - Mudstone")])
profs = {"MUD": mud, "PAL": palisade, "ORG": orange}
toy = gpd.GeoDataFrame(dict(UNIT_LINK=["MUD", "PAL"]), geometry=[box(0, 0, 1000, 1000), box(1000, 0, 2000, 1000)], crs=5070)
ctx = RG.make_context(toy, profs)(0)
check("Palisade Diabase (coded basalt) is not a lava neighbour", ctx["VOLCANIC_NEIGHBOUR"] is False)
check("...so the mudstone is not inferred lacustrine from it", G.infer_lacustrine(mud, ctx) is None)
toy2 = gpd.GeoDataFrame(dict(UNIT_LINK=["MUD", "ORG"]), geometry=[box(0, 0, 1000, 1000), box(1000, 0, 2000, 1000)], crs=5070)
check("Orange Mountain Basalt is a lava neighbour", RG.make_context(toy2, profs)(0)["VOLCANIC_NEIGHBOUR"] is True)
check("is_lava_unit: Palisade False, Orange Mountain True", not G.is_lava_unit(palisade) and G.is_lava_unit(orange))

# 7b Macrostrat: homonyms rejected by place/age; name-only matches never establish core properties
fake = dict(query="Sugarloaf", units=[
    dict(col_id=1, strat_name="Sugarloaf Formation", clat=42.5, clng=-72.6, t_age=195, b_age=222, lith=["shale"], environ=["lacustrine"], environ_database_default=[]),
    dict(col_id=2, strat_name="Sugarloaf Quartzite", clat=34.2, clng=-116.9, t_age=596, b_age=617, lith=["quartzite"], environ=["marine"], environ_database_default=[])])
m = G.macrostrat_match(fake, 42.45, -72.6, "Lower Jurassic")
check("same-name unit 3,900 km away and 400 Myr older is rejected", [a["col_id"] for a in m["accepted"]] == [1] and m["rejected"][0]["col_id"] == 2)
check("nothing accepted without a location", G.macrostrat_match(fake, unit_age="Lower Jurassic")["accepted"] == [])
G.macrostrat.cache_clear()
_orig = G.macrostrat
G.macrostrat = lambda name: fake
p_ms = G.evidence_profile("Sugarloaf Formation", "Red arkose and siltstone.", "", [("Major", "Sedimentary - Clastic - Siltstone")], None,
                          use_macrostrat=True, location=(42.45, -72.6), unit_age="Lower Jurassic")
G.macrostrat = _orig
check("Macrostrat-only 'lacustrine' is kept apart and does not set the environment",
      "LACUSTRINE" not in p_ms["environment"] and "LACUSTRINE" in p_ms["macrostrat_only"])
check("...so it cannot satisfy the MARS-LAKE core", not G.compare(p_ms, {}, "MARS-LAKE")[0])

# 7c MARS-SERP keeps Seitah and Maaz apart; H2 is inferred, minerals observed
sp = {x["code"]: x for x in G.PLANETARY["MARS-SERP"]["properties"]}
check("olivine cumulate is Seitah, observed", sp["OLIVINE_RICH_ULTRAMAFIC"]["site"] == "Seitah" and sp["OLIVINE_RICH_ULTRAMAFIC"]["evidence_type"] == "observed")
check("serpentine is Maaz, observed (Tosca 2025)", sp["SERPENTINE"]["site"] == "Maaz" and sp["SERPENTINE"]["evidence_type"] == "observed"
      and sp["SERPENTINE"]["src"] == ["Tosca2025"])
check("serpentinization is Maaz, interpreted", sp["SERPENTINIZATION"]["site"] == "Maaz" and sp["SERPENTINIZATION"]["evidence_type"] == "interpreted")
check("H2 production is inferred and not compared", sp["H2_PRODUCTION"]["evidence_type"] == "inferred" and sp["H2_PRODUCTION"]["role"] == "not_compared")
check("Tosca 2025 is cited only for Maaz properties", all(x.get("site") == "Maaz" for x in G.PLANETARY["MARS-SERP"]["properties"] if "Tosca2025" in x["src"]))

# 8 optional: checks on a regional output file
if len(sys.argv) > 1:
    d = json.load(open(sys.argv[1]))
    check("schema version geo-2.0", d["schema_version"] == "geo-2.0")
    check("study area is clipped", d["study_area"]["clipped"] is True)
    lim = d["study_area"]["radius_km"]
    check("all candidates inside the study radius", all(c["distance_km"] <= lim + 0.01 for v in d["candidates"].values() for c in v))
    check("no candidate with a recorded core contradiction",
          all(not any(r["role"] == "contradiction" and r["earth_status"] == "CONTRADICTION recorded"
                      for r in c["layer_1_geological_evidence"]["comparison"]) for v in d["candidates"].values() for c in v))
    s = json.dumps(d["candidates"]).lower()
    check("no match scores, confidence levels or match percentages in candidates",
          not any(k in s for k in ('"score"', '"confidence"', "match_percent", "% match", "similarity")))

print(f"\n{len(FAILS)} failed" if FAILS else "\nall tests passed")
sys.exit(1 if FAILS else 0)

```

## engine/tests_v03.py

```python
"""Regression tests for the v0.3 engine (audit, 14 Nov evening). Run: python3 tests_v03.py
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import os, sys, json, tempfile, shutil, subprocess
import numpy as np
from scipy.stats import wasserstein_distance
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terrain_engine import plane_features, plane_features_fast
import global_run as G

ok_all = True


def check(name, cond, detail=""):
    global ok_all
    ok_all &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""))


# 1. Analytic plane + noise: slope recovered within noise, fast == general
rng = np.random.default_rng(1)
n = 200; px = 100.0
yy, xx = np.mgrid[0:n, 0:n] * px
for deg in (3.0, 12.0, 25.0):
    z = np.tan(np.radians(deg)) * xx + rng.normal(0, 0.5, xx.shape)
    v = np.ones_like(z, bool)
    sf, rf, _ = plane_features_fast(z, v, px, 800)
    sg, rg, _, _ = plane_features(z, v, px, 800)
    m = np.isfinite(sf)
    check(f"plane {deg} deg + 0.5 m noise: median slope", abs(np.nanmedian(sf) - deg) < 0.05, f"{np.nanmedian(sf):.3f}")
    check(f"plane {deg} deg: roughness ~ noise sigma", abs(np.nanmedian(rf) - 0.5) < 0.05, f"{np.nanmedian(rf):.3f}")
    check(f"plane {deg} deg: fast == general", np.nanmax(np.abs(sf[m] - sg[m])) < 1e-8)

# 2. Masked cell inside a disc invalidates the fast estimate there
z = np.tan(np.radians(10)) * xx; v = np.ones_like(z, bool); v[100, 100] = False
sf, _, _ = plane_features_fast(z, v, px, 800)
check("masked cell invalidates discs that contain it", np.isnan(sf[100, 102]) and np.isfinite(sf[100, 120]))

# 3. W1 from 50 midpoint quantiles approximates the exact Wasserstein distance
errs = []
for k in range(50):
    a = rng.gamma(2 + k % 5, 4, 20000).clip(0, 89); b = rng.gamma(3 + k % 3, 3.5, 20000).clip(0, 89)
    approx = np.abs(np.quantile(a, G.QP) - np.quantile(b, G.QP)).mean()
    errs.append(abs(approx - wasserstein_distance(a, b)))
check("W1 from 50 quantiles within 0.15 deg of exact (slope-like distributions)", max(errs) < 0.15, f"max err {max(errs):.3f} deg")

# 4. Tile-name parsing
check("parse N/W tile", G.parse("Copernicus_DSM_COG_30_N36_00_W117_00_DEM") == (36, -117))
check("parse S/E tile", G.parse("Copernicus_DSM_COG_30_S78_00_E161_00_DEM") == (-78, 161))

# 5. Zone pooling counts each lunar cell once (v1 double-counted overlapping windows)
import build_zone_refs as Z
S = {L: np.full((200, 200), 5.0) for L in G.LS}; Rr = {L: np.full((200, 200), 1.0) for L in G.LS}
allv = np.ones((200, 200), bool)
wins = [(0, 0, 1.0, 0.0), (25, 25, 1.0, 0.0), (50, 50, 1.0, 0.0)]          # three overlapping flat windows
cells, w = Z.build({"A": (S, Rr, allv, wins)}, "MZ-FLAT", 0.6, 0.4)
union = np.zeros((200, 200), bool)
for i, j, _, _ in wins:
    union[i:i + Z.WIN, j:j + Z.WIN] = True
check("zone pooling uses unique cells", cells["A"][0][400].size == union.sum(), f"{cells['A'][0][400].size} vs {union.sum()}")

# 6. Geology tiers: G4 requires G2 and partner share >= threshold
import geology_sensitivity as GS
D = dict(lat=np.array([0., 1, 2, 3]), lon=np.array([0., 1, 2, 3]), f=np.array([0.9, 0.9, 0.9, 0.4]),
         ex=np.array([0.5, 0.5, 0.1, 0.9]), pf=np.array([0.2, 0.05, 0.5, 0.5]), area=np.array([10., 20, 30, 40]))
e = GS.evaluate(D, dict(g1=0.5, g2=0.25, p=0.1))
check("G4 needs mapped + exposed + partner", e["G4"] == 1 and e["G2_or_better"] == 2 and e["G1_or_better"] == 3)

# 7. compare.py never nominates snow/ice-dominated or unknown-land-cover windows
tmp = tempfile.mkdtemp()
try:
    here = os.path.dirname(os.path.abspath(__file__))
    for f in ("refs.npz", "refs_meta.json"):
        shutil.copy(os.path.join(here, f), tmp)
    q = np.stack([np.linspace(1, 30, 50)] * 4).astype(np.float16)
    def tile(name, lat, snow):
        np.savez_compressed(os.path.join(tmp, "feat", name + ".npz"), lat=np.array([lat], np.float32), lon=np.array([10.], np.float32),
                            valid=np.array([1.], np.float32), bare=np.array([0.5], np.float32), snow=np.array([snow], np.float32),
                            slope_q=q[None], lrough_q=q[None] / 30, conn=np.full((1, 7), 0.5, np.float16), meta=np.array([name, "True", "0"]))
    os.makedirs(os.path.join(tmp, "feat"))
    tile("t_ok", 10.0, 0.0); tile("t_snow", 40.0, 0.9); tile("t_unknown", -70.0, np.nan)
    subprocess.run([sys.executable, os.path.join(here, "compare.py"), os.path.join(tmp, "feat"), os.path.join(tmp, "c.json"), "5"],
                   cwd=tmp, capture_output=True, check=True)
    c = json.load(open(os.path.join(tmp, "c.json")))
    lats = {x["lat"] for r in c["references"].values() for x in r["candidates"]}
    check("snow/unknown windows never nominated", lats == {10.0}, str(lats))
    check("compare output carries run metadata and coverage", "run" in c and len(c["coverage"]) == 3)
finally:
    shutil.rmtree(tmp)

print("ALL PASS" if ok_all else "SOME TESTS FAILED")
sys.exit(0 if ok_all else 1)

```

## engine/wc_bare.py

```python
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

```

## engine/zone_yardstick.py

```python
"""Yardstick for zone references: distance (worst-scale slope W1) from each real lunar 10 km window
in a zone to that zone's pooled reference. An Earth window closer than the lunar median is as close
to the zone profile as a typical real lunar window of that zone is.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import json, numpy as np, warnings
warnings.filterwarnings("ignore")
from build_zone_refs import SITES, BOX, WIN, features
from lolaread import read
from build_refs import block_mean
from global_run import LS, QP
R = np.load("refs.npz"); L = json.load(open("zone_windows.json"))
d = {"MZ-FLAT": [], "MZ-STEEP": []}
for site, (cx, cy) in SITES.items():
    z = block_mean(read("", cx, cy, BOX)[0], 5); S, _, allv = features(z)
    for w in L:
        if w["site"] != site or not w["zone"]:
            continue
        j = int(round((w["x"] - (cx - BOX / 2)) / 100 - WIN / 2)); i = int(round(((cy + BOX / 2) - w["y"]) / 100 - WIN / 2))
        v = allv[i:i + WIN, j:j + WIN]
        q = np.stack([np.quantile(S[Lb][i:i + WIN, j:j + WIN][v], QP) for Lb in LS])
        d[w["zone"]].append(float(np.abs(q - R[w["zone"] + "_slope_q"]).mean(1).max()))
out = {k: dict(n=len(v), p10=round(float(np.percentile(v, 10)), 2), median=round(float(np.median(v)), 2), p90=round(float(np.percentile(v, 90)), 2)) for k, v in d.items()}
print(out); json.dump(out, open("zone_yardstick.json", "w"), indent=1)

```

## engine/zone_yardstick_regional.py

```python
"""Zone yardstick at the regional (60 m grid, 240/480/960 m) scale. Same idea as zone_yardstick.py.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy."""
import json, numpy as np, warnings
warnings.filterwarnings("ignore")
import regional_run as rr
from build_zone_refs import SITES, BOX
from lolaread import read
from build_refs import block_mean
refs = rr.lunar_refs(); L = json.load(open("zone_windows.json")); d = {}
for site, (cx, cy) in SITES.items():
    z = block_mean(read("", cx, cy, BOX)[0], 3); v = np.isfinite(z)
    S, R, allv = rr.tile_profile(np.where(v, z, 0.0), v)
    for w in L:
        if w["site"] != site or not w["zone"]:
            continue
        j = int(round((w["x"] - (cx - BOX / 2)) / rr.GRID - rr.WIN / 2)); i = int(round(((cy + BOX / 2) - w["y"]) / rr.GRID - rr.WIN / 2))
        vv = allv[i:i + rr.WIN, j:j + rr.WIN]
        if vv.mean() < rr.MIN_VALID:
            continue
        q = np.stack([np.quantile(S[Lb][i:i + rr.WIN, j:j + rr.WIN][vv], rr.QP) for Lb in rr.LS2])
        d.setdefault(w["zone"], []).append(float(np.abs(q - refs[w["zone"]][0]).mean(1).max()))
out = {k: dict(n=len(v), p10=round(float(np.percentile(v, 10)), 2), median=round(float(np.median(v)), 2), p90=round(float(np.percentile(v, 90)), 2)) for k, v in d.items()}
print(out); json.dump(out, open("zone_yardstick_regional.json", "w"), indent=1)

```

## app/geology_v2.dart

```dart
// Data model for the optional `geology_v2` block of app_bundle.json (block_version geo-2.0-app-1).
// Pure Dart (no Flutter import) so it can be unit-tested with `dart run`. Unknown keys are ignored;
// a bundle without `geology_v2` parses to null, so older bundles keep working.
// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

List<T> _list<T>(dynamic v, T Function(dynamic) f) => v == null ? <T>[] : (v as List).map(f).toList();
List<String> _strs(dynamic v) => _list(v, (e) => e.toString());
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

class ComparisonRow {
  final String property, role, roleLabel, marsEvidenceType, marsStatement, earthStatus;
  final String? marsSite, earthSource, earthText;
  final List<String> citations;
  ComparisonRow.fromJson(Map<String, dynamic> j)
      : property = j['property'] as String,
        role = j['role'] as String,
        roleLabel = (j['role_label'] ?? j['role']) as String,
        marsSite = j['mars_site'] as String?,
        marsEvidenceType = j['mars_evidence_type'] as String,
        marsStatement = j['mars_statement'] as String,
        citations = _strs(j['citations']),
        earthStatus = j['earth_status'] as String,
        earthSource = j['earth_source'] as String?,
        earthText = j['earth_text'] as String?;
  /// True when the Earth side has evidence for this property (no scores involved).
  bool get earthRecorded => earthStatus.startsWith('recorded') || earthStatus.startsWith('corroborated');
}

class GeoProperty {
  final String code, role, roleLabel, evidenceType, statement;
  final String? marsSite;
  final List<String> citations;
  GeoProperty.fromJson(Map<String, dynamic> j)
      : code = j['code'] as String,
        role = j['role'] as String,
        roleLabel = (j['role_label'] ?? j['role']) as String,
        marsSite = j['mars_site'] as String?,
        evidenceType = j['evidence_type'] as String,
        statement = j['statement'] as String,
        citations = _strs(j['citations']);
}

class GeoReference {
  final String id, name;
  final String? siteNote;
  final List<String> notComparable;
  final List<GeoProperty> properties;
  GeoReference.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        siteNote = j['site_note'] as String?,
        notComparable = _strs(j['not_comparable']),
        properties = _list(j['properties'], (e) => GeoProperty.fromJson(e as Map<String, dynamic>));
}

class FeaturedCase {
  final String id, region, reference, title, outcome, unitName, unitLink, note;
  final double? preserveAreaKm2, shareWithin500mOfIntrusion;
  final List<ComparisonRow> comparison;
  final List<String> conflicts;
  FeaturedCase.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        region = j['region'] as String,
        reference = j['reference'] as String,
        title = j['title'] as String,
        outcome = j['outcome'] as String,
        unitName = j['unit_name'] as String,
        unitLink = j['unit_link'] as String,
        note = (j['note'] ?? '') as String,
        preserveAreaKm2 = _num(j['preserve_area_km2']),
        shareWithin500mOfIntrusion = _num(j['share_within_500m_of_intrusive_contact']),
        comparison = _list(j['comparison'], (e) => ComparisonRow.fromJson(e as Map<String, dynamic>)),
        conflicts = _strs(j['conflicts']);
}

class GeoUnitCard {
  final String id, region, reference, unitName, unitLink, state, exposureNote;
  final String? unitAge;
  final int polygons;
  final double areaKm2, steepGroundKm2, publicSteepGroundKm2;
  final double? nearestDistanceKm;
  final List<double>? nearestPoint;
  final List<String> supportingRecorded, conflicts, publicLandsWithSteepGround, notComparable, unmeasured;
  final int supportingTotal;
  final List<ComparisonRow> comparison;
  GeoUnitCard.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        region = j['region'] as String,
        reference = j['reference'] as String,
        unitName = j['unit_name'] as String,
        unitLink = j['unit_link'] as String,
        state = (j['state'] ?? '') as String,
        unitAge = j['unit_age'] as String?,
        polygons = j['polygons'] as int,
        areaKm2 = _num(j['area_km2'])!,
        nearestDistanceKm = _num(j['nearest_distance_km']),
        nearestPoint = j['nearest_point'] == null ? null : _list(j['nearest_point'], (e) => (e as num).toDouble()),
        steepGroundKm2 = _num(j['steep_ground_km2']) ?? 0,
        publicSteepGroundKm2 = _num(j['public_steep_ground_km2']) ?? 0,
        publicLandsWithSteepGround = _strs(j['public_lands_with_steep_ground']),
        exposureNote = (j['exposure_note'] ?? '') as String,
        supportingRecorded = _strs(j['supporting_recorded']),
        supportingTotal = j['supporting_total'] as int,
        conflicts = _strs(j['conflicts']),
        notComparable = _strs(j['not_comparable']),
        unmeasured = _strs(j['unmeasured']),
        comparison = _list(j['comparison'], (e) => ComparisonRow.fromJson(e as Map<String, dynamic>));
}

class ControlResult {
  final String region, reference, method;
  final double? precision, recall;
  ControlResult.fromJson(Map<String, dynamic> j)
      : region = j['region'] as String,
        reference = j['reference'] as String,
        method = j['method'] as String,
        precision = _num(j['precision']),
        recall = _num(j['recall']);
}

class GeologyV2Block {
  final String blockVersion;
  final List<GeoReference> references;
  final List<FeaturedCase> featured;
  final List<GeoUnitCard> units;
  final List<ControlResult> controls;
  final Map<String, String> citations;
  final List<String> limitations;
  GeologyV2Block.fromJson(Map<String, dynamic> j)
      : blockVersion = j['block_version'] as String,
        references = _list(j['references'], (e) => GeoReference.fromJson(e as Map<String, dynamic>)),
        featured = _list(j['featured'], (e) => FeaturedCase.fromJson(e as Map<String, dynamic>)),
        units = _list(j['units'], (e) => GeoUnitCard.fromJson(e as Map<String, dynamic>)),
        controls = _list(j['controls'], (e) => ControlResult.fromJson(e as Map<String, dynamic>)),
        citations = ((j['citations'] ?? {}) as Map<String, dynamic>).map((k, v) => MapEntry(k, v.toString())),
        limitations = _strs(j['limitations']);

  /// Returns null for bundles that do not carry the block (older exports).
  static GeologyV2Block? fromBundle(Map<String, dynamic> bundle) =>
      bundle['geology_v2'] == null ? null : GeologyV2Block.fromJson(bundle['geology_v2'] as Map<String, dynamic>);

  List<GeoUnitCard> unitsFor(String region, String reference) =>
      units.where((u) => u.region == region && u.reference == reference).toList();
}

```

## app/geology_v2_check.dart

```dart
// Parse an app_bundle.json with the geology_v2 model and print the featured case as the app would list it.
// Usage: dart run geology_v2_check.dart app_bundle.json
import 'dart:convert';
import 'dart:io';
import 'geology_v2.dart';

void main(List<String> args) {
  final bundle = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final g = GeologyV2Block.fromBundle(bundle);
  if (g == null) { print('no geology_v2 block (older bundle): app shows nothing new'); return; }
  print('block ${g.blockVersion}: ${g.references.length} references, ${g.units.length} unit cards, '
      '${g.featured.length} featured, ${g.controls.length} control rows');
  for (final f in g.featured) {
    print('\n${f.title}\n  ${f.outcome}\n  ${f.unitName} (${f.unitLink}); '
        '${((f.shareWithin500mOfIntrusion ?? 0) * 100).round()}% of polygon within 500 m of an intrusion');
    for (final r in f.comparison) {
      print('  [${r.roleLabel}] ${r.property}  Mars: ${r.marsEvidenceType}'
          '${r.marsSite == null ? '' : ' @${r.marsSite}'} (${r.citations.join(', ')})  Earth: ${r.earthStatus}');
    }
  }
  final serp = g.references.firstWhere((r) => r.id == 'MARS-SERP');
  print('\nMARS-SERP site note: ${serp.siteNote}');
  for (final c in g.controls) {
    print('control ${c.region} ${c.reference} ${c.method}: precision ${c.precision}, recall ${c.recall}');
  }
}

```

## app/geology_v2_widgets.dart

```dart
// Flutter widgets for the geology_v2 block. Drop into the team app next to geology_v2.dart.
// NOTE: written against the stable Material API but NOT compiled here (no Flutter SDK in this environment);
// the data model in geology_v2.dart is tested with `dart run geology_v2_check.dart`.
// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
import 'package:flutter/material.dart';
import 'geology_v2.dart';

/// One row: Mars property (with evidence type, site and citations) beside the Earth record.
class ComparisonRowTile extends StatelessWidget {
  final ComparisonRow row;
  const ComparisonRowTile(this.row, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final icon = row.role == 'not_compared'
        ? Icons.remove_circle_outline
        : row.earthRecorded
            ? Icons.check_circle_outline
            : (row.earthStatus.startsWith('CONTRADICTION') ? Icons.block : Icons.radio_button_unchecked);
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text('${row.property}  ·  ${row.roleLabel}', style: t.titleSmall),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mars (${row.marsEvidenceType}${row.marsSite == null ? '' : ', ${row.marsSite}'}): ${row.marsStatement}'),
        Text('Sources: ${row.citations.join(', ')}', style: t.bodySmall),
        Text('Earth: ${row.earthStatus}${row.earthText == null || row.earthText!.isEmpty ? '' : ' — "${row.earthText}"'}'),
      ]),
    );
  }
}

/// The featured independent-validation case (e.g. Lockatong in Sourland Mountain Preserve).
class FeaturedCaseCard extends StatelessWidget {
  final FeaturedCase f;
  const FeaturedCaseCard(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final share = f.shareWithin500mOfIntrusion;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.title, style: t.titleMedium),
          const SizedBox(height: 4),
          Text(f.outcome, style: t.bodyMedium),
          Text('${f.unitName} (${f.unitLink}) · reference ${f.reference}', style: t.bodySmall),
          if (share != null)
            Text('Caution: ${(share * 100).round()}% of this polygon lies within 500 m of an intrusive contact (possible heat alteration).',
                style: t.bodySmall),
          for (final c in f.conflicts) Text('Recorded conflict: $c', style: t.bodySmall),
          Text(f.note, style: t.bodySmall),
          const Divider(),
          for (final r in f.comparison) ComparisonRowTile(r),
        ]),
      ),
    );
  }
}

/// Compact card for one candidate map unit. No score is shown because none exists.
class GeoUnitCardView extends StatelessWidget {
  final GeoUnitCard u;
  const GeoUnitCardView(this.u, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ExpansionTile(
      title: Text('${u.unitName} (${u.state})'),
      subtitle: Text('${u.reference} · supporting recorded ${u.supportingRecorded.length} of ${u.supportingTotal} · '
          '${u.areaKm2.toStringAsFixed(1)} km² · nearest ${u.nearestDistanceKm?.toStringAsFixed(0) ?? '-'} km'),
      children: [
        if (u.publicLandsWithSteepGround.isNotEmpty)
          Text('Steep public ground in: ${u.publicLandsWithSteepGround.join(', ')}', style: t.bodySmall),
        Text(u.exposureNote, style: t.bodySmall),
        for (final r in u.comparison) ComparisonRowTile(r),
        Text('Not comparable: ${u.notComparable.join('; ')}', style: t.bodySmall),
      ],
    );
  }
}

/// Section to place on a page: featured case first, then unit cards for one region/reference.
class GeologyV2Section extends StatelessWidget {
  final GeologyV2Block block;
  final String region, reference;
  const GeologyV2Section(this.block, {super.key, this.region = 'newark', this.reference = 'MARS-LAKE'});

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      for (final f in block.featured.where((f) => f.reference == reference)) FeaturedCaseCard(f),
      for (final u in block.unitsFor(region, reference)) GeoUnitCardView(u),
      for (final l in block.limitations) Padding(padding: const EdgeInsets.all(8), child: Text('Limitation: $l')),
    ]);
  }
}

```
