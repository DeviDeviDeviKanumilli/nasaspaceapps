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
