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
