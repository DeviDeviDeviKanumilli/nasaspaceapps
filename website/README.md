# TERRA — website

Interactive 3D globe of Earth-analog records for lunar and Martian reference sites, from the global terrain run.
Team Vancomycin, NASA Space Apps Challenge 2026. Drafted with AI assistance (Claude, Anthropic); disclosed in the
team's submission, per the Space Apps AI policy.

Next.js 15 + React 19 + TypeScript, CesiumJS 1.147 for the globe. The site is a **static export**: no server,
no login, no API keys.

## Run it

```bash
cd website
npm install
npm run dev          # http://localhost:3000
```

Production build (static files in `out/`):

```bash
npm run build
npx serve out        # or any static file server
```

Hosting under a sub-path (GitHub Pages serves this repo at `/nasaspaceapps`):

```bash
NEXT_PUBLIC_BASE_PATH=/nasaspaceapps npm run build
```

On Vercel: import the repository, set **Root Directory** to `website`. No other settings.

## Data

The site shows the **global terrain run** (commit `3cac280`): 19,295 one-degree tiles processed across every
continent, 1,464,296 ten-kilometre windows evaluated, and the 50 closest windows nominated for each of the eight
terrain references. With the rock-type screening boxes and the regional geology units, that is 600 records.

| File | What it is |
|---|---|
| `public/data/app_bundle.json` | The engine's results bundle (schema 1.0 + `geology_v2`), copied unmodified from `web/app_bundle.json`. |
| `public/data/derived_geometry.json` | Map outlines, made by `scripts/derive_geometry.py` from each record's centre and the engine's footprint rule (pyproj AEQD on the tile centre for terrain windows; 0.1° box for rock-type records). |

Run details the site reports from the bundle:

- Tiles: 9,572 with evaluated windows, 4,905 with no valid window, 4,818 skipped because land cover rules out
  every window. 138 listed tiles have no result (the ones checked are ocean and island tiles with no land-cover file).
- The tile list runs from 60° S to 84° N; Antarctica is not part of it.
- The run's own statement is shown verbatim on the Data & methods page.
- Cross-pathway values (rock classes under a terrain window, terrain of a rock-type box) are "not measured" in this
  bundle, because that step has not been rerun on the global results.

To load a newer run: replace `app_bundle.json`, then
`python3 scripts/derive_geometry.py public/data/app_bundle.json public/data/derived_geometry.json` (needs `pyproj`), then rebuild.
The adapter (`lib/adapter.ts`) validates the bundle at load time and lists anything missing on the Data & methods page.
Tile counts, extent and the "global" label are read from the bundle, so an older regional bundle is labelled correctly too.

## What is implemented

- Full-window CesiumJS globe: drag to pan, wheel/pinch to zoom, Shift-drag or middle-drag to tilt and orbit,
  double-click to zoom in, compass reset, tilt toggle, scale bar, cursor coordinates.
- All 600 loaded records, clustered by screen distance (cluster ring shows the Moon/Mars split). Clicking a cluster
  zooms to it; records that share a place open as a list.
- Exact footprints: 10 km terrain windows and 0.1° rock-type boxes. Mapped geologic units are shown at their
  representative point only, because unit outlines are not in the bundle.
- Find analogs: body, pathway and reference filters from the data; planetary reference detail with percentile
  bands and connectivity curve.
- Base profiles: four team-defined scenarios with measured / proxy / not-measured dimensions; they filter records
  by reference and compute no score.
- Search area: point + radius, drawn rectangle, drawn polygon; evidence filters (inside yardstick, rock tier).
- Search: coordinates (parsed locally), record IDs, unit names, references, and place names (OpenStreetMap Nominatim).
- Any location: coordinates/place/map-click fly there and report what the loaded run covers at that point
  (tile status, containing footprints, study areas). Nearest records are listed separately. No analysis is run.
- Record inspector and full "Data for this site" workspace: comparison, Earth measurements, why found,
  dataset sources, stored record (JSON), limits; JSON and CSV export of the actual record.
- Analysis-coverage layer for the global run's tile list, with the run statement verbatim.
- Data & methods page: run status, methods, dataset catalogue with licences and links, the NASA LRO/LOLA provenance
  block (PGDA Products 90 and 78, with links to the engine source), literature, limits.
- Fallbacks: if satellite imagery cannot be reached the globe falls back to NASA GIBS Blue Marble, then to the
  bundled Natural Earth map; if 3D relief cannot be reached the globe stays smooth; if WebGL is unavailable the
  page says so. Software renderers get a lower-detail mode.
- Deep links: `/?record=<id>`, `/?record=<id>&view=data`, `/?reference=<id>`.

## Not implemented

- On-demand analysis of an arbitrary location (`/api/analyze/location`). The site says so at every selected location.
- Country/state boundary filters (no boundary data in the bundle; rectangles are not offered as borders).
- 3D Moon and Mars globes; field-scan (D435) records.
- Geologic unit outlines (not in the bundle).

## Attribution

Display: Esri World Imagery and World Elevation, Esri boundaries and places, NASA GIBS Blue Marble, Natural Earth II
(bundled with CesiumJS), OpenStreetMap Nominatim for place search. Analysis inputs and references are listed with
licences on the Data & methods page (`lib/sources.ts`).
