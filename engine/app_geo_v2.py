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
