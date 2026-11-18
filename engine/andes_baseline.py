"""How strongly do the terrain candidates concentrate in the Andes, compared with chance?

Post-submission check (17 Nov 2026) on the frozen results only; no new data and no re-run.
Reads web/app_bundle.json (the same file the website loads):
  - coverage: windows evaluated per 1-degree Copernicus tile (the search area actually covered)
  - candidates: the 400 terrain records (50 per reference)

Region: a simple box over western South America, lat -56..12, lon -82..-62. It is deliberately
cruder than a geological definition of the Andes and is fixed here so anyone can rerun it.

Baseline: if candidates fell where windows were evaluated, without preference, the expected
share in the box equals the box's share of evaluated windows. Three views are reported:
  1. records: all 400 terrain records against the window share (binomial tail);
  2. distinct places: records rounded to 0.1 degree, so one place nominated for several
     references counts once;
  3. tiles: 1-degree tiles holding at least one candidate, against the box's share of tiles
     with evaluated windows. Tiles are coarser units, so this is the most conservative view.
Neighbouring windows are not independent, so the binomial p-values are optimistic; the
enrichment ratios are the robust result.

Usage: python3 engine/andes_baseline.py [web/app_bundle.json]
AI disclosure: drafted with AI assistance (Claude, Anthropic).
"""
import json
import re
import sys
from math import comb

BOX = {"lat": (-56.0, 12.0), "lon": (-82.0, -62.0)}


def inbox(lat, lon):
    return BOX["lat"][0] <= lat <= BOX["lat"][1] and BOX["lon"][0] <= lon < BOX["lon"][1]


def tile_sw(name):
    m = re.search(r"_([NS])(\d+)_00_([EW])(\d+)_00_", name)
    lat = int(m[2]) * (1 if m[1] == "N" else -1)
    lon = int(m[4]) * (1 if m[3] == "E" else -1)
    return lat, lon


def tail(k, n, p):
    """P(X >= k) for X ~ Binomial(n, p)."""
    return sum(comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(k, n + 1))


def report(label, k, n, p):
    print(f"{label:16s} {k:4d} of {n:4d} in box ({k / n:6.1%}); expected by chance {n * p:6.1f} ({p:5.1%}); "
          f"enrichment {k / n / p:4.1f}x; P(>= {k}) = {tail(k, n, p):.1e}")


def main(path):
    b = json.load(open(path))
    windows = {k: v for k, v in b["coverage"].items() if isinstance(v, int) and v > 0}
    total = sum(windows.values())
    in_box = sum(v for k, v in windows.items() if inbox(*tile_sw(k)))
    p_win = in_box / total
    tiles_in_box = sum(1 for k in windows if inbox(*tile_sw(k)))
    p_tile = tiles_in_box / len(windows)
    print(f"Search area: {total:,} windows in {len(windows):,} tiles; box holds {in_box:,} windows "
          f"({p_win:.1%}) in {tiles_in_box} tiles ({p_tile:.1%}).")

    terr = [c for c in b["candidates"] if c["pathway"] == "terrain"]
    pos = [(c["position"]["lat"], c["position"]["lon"]) for c in terr]
    report("records", sum(inbox(*q) for q in pos), len(pos), p_win)

    places = {(round(la, 1), round(lo, 1)) for la, lo in pos}
    report("distinct places", sum(inbox(*q) for q in places), len(places), p_win)

    cand_tiles = {(int(la // 1), int(lo // 1)) for la, lo in pos}
    report("tiles", sum(inbox(la + 0.5, lo + 0.5) for la, lo in cand_tiles), len(cand_tiles), p_tile)

    print("\nBy reference (records in box of 50):")
    for ref in sorted({c["reference"] for c in terr}):
        rows = [c for c in terr if c["reference"] == ref]
        k = sum(inbox(c["position"]["lat"], c["position"]["lon"]) for c in rows)
        print(f"  {ref:9s} {k:3d} / {len(rows)}   expected {len(rows) * p_win:4.1f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "web/app_bundle.json")
