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
