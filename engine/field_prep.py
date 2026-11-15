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
