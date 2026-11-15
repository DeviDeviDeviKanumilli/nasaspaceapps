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
