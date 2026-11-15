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
