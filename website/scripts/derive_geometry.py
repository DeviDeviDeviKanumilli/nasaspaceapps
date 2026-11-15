"""Derive map geometry for the website from the engine's app bundle. No scientific values are created here.

For every terrain candidate the engine records a centre and the footprint rule
("square, 10 km, local azimuthal equidistant"). The engine's windows are axis-aligned squares in the
azimuthal-equidistant projection centred on the middle of the candidate's 1-degree DEM tile
(global_run.py: +proj=aeqd +lat_0=tile_lat+0.5 +lon_0=tile_lon+0.5, WGS84). This script reproduces that
projection with pyproj and writes the square's outline in longitude/latitude.

Rock-type candidates are geographic boxes: 0.1 deg latitude x 0.1/cos(lat) deg longitude (geology_run.py).
geo-2.0 units carry only a representative point; no outline is derived for them.

Usage: python3 scripts/derive_geometry.py public/data/app_bundle.json public/data/derived_geometry.json
"""
import json, math, sys
from pyproj import Transformer

bundle = json.load(open(sys.argv[1]))
out = {"note": "outlines derived from each record's centre and the engine's documented footprint rule; "
               "not an outcrop or site boundary", "terrain_method": "pyproj AEQD centred on the 1-degree tile centre, WGS84; "
               "square of footprint.size_km, 8 points per side", "rock_method": "0.1 deg latitude x 0.1/cos(lat) deg longitude box",
       "footprints": {}}
for c in bundle["candidates"]:
    lat, lon = c["position"]["lat"], c["position"]["lon"]
    fp = c.get("footprint", {})
    if c["pathway"] == "terrain" and fp.get("shape") == "square" and "size_km" in fp:
        tlat, tlon = math.floor(lat) + 0.5, math.floor(lon) + 0.5
        crs = f"+proj=aeqd +lat_0={tlat} +lon_0={tlon} +datum=WGS84 +units=m"
        fwd = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
        inv = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
        x, y = fwd.transform(lon, lat)
        h = fp["size_km"] * 500.0
        n = 8
        ring = []
        for (x0, y0, x1, y1) in ((-h, -h, h, -h), (h, -h, h, h), (h, h, -h, h), (-h, h, -h, -h)):
            for k in range(n):
                t = k / n
                lo, la = inv.transform(x + x0 + (x1 - x0) * t, y + y0 + (y1 - y0) * t)
                ring.append([round(lo, 5), round(la, 5)])
        ring.append(ring[0])
        out["footprints"][c["id"]] = {"kind": "terrain window", "ring": ring}
    elif c["pathway"] == "rock type" and fp.get("shape") == "geographic box":
        dlat = 0.05
        dlon = 0.05 / math.cos(math.radians(lat))
        ring = [[round(lon - dlon, 5), round(lat - dlat, 5)], [round(lon + dlon, 5), round(lat - dlat, 5)],
                [round(lon + dlon, 5), round(lat + dlat, 5)], [round(lon - dlon, 5), round(lat + dlat, 5)]]
        ring.append(ring[0])
        out["footprints"][c["id"]] = {"kind": "rock-type screening box", "ring": ring}
json.dump(out, open(sys.argv[2], "w"), separators=(",", ":"))
print(len(out["footprints"]), "footprints written")
