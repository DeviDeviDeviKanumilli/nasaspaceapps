# Terrain Analog Lab v0.3 (engine added to the v0.2 prototype)

**Results:** the completed run is in `results_global/` (see `manifest_global.json`: 1,464,296 windows, 19,295 of 19,433 tiles). The app data format is in `SCHEMA.md`. The commands below are the ones used to produce it.

v0.2 files are unchanged. Everything new is in `engine/`. The full reasoning is in the notes doc
"Space Apps 2026 — Decisions and Research Notes (Nov 14)".

AI disclosure: the `engine/` scripts were drafted with AI assistance (Claude, Anthropic) and carry a
header comment saying so. The team reviews and runs them.

## Install

    pip install numpy scipy rasterio pyproj affine requests

Python 3.10+. Works on Windows, macOS and Linux. No accounts or keys are needed for any step below.

## Saturday-night run (all commands from inside `engine/`)

1. Moon reference boxes (LOLA, NASA PGDA), ~5 min:

       python3 lolaread.py

   Writes `lola20_*.npz`. (`refs.npz` from a test run is already included; rebuild it anyway.)

2. Reference profiles (Moon + Mars), then the zone references (flat operations, steep traverse), ~5 min:

       python3 build_refs.py
       python3 build_zone_refs.py
       python3 zone_yardstick.py

3. Global terrain features. Split the tile list across computers with `SHARD=k/n`; use about
   (CPU cores + 2) workers. Resumable: re-run the same command after any interruption.

       SHARD=0/3 python3 global_run.py features 10      # laptop A
       SHARD=1/3 python3 global_run.py features 10      # laptop B
       SHARD=2/3 python3 global_run.py features 10      # laptop C

   (Windows PowerShell: `$env:SHARD="0/3"; python global_run.py features 10`.)
   Measured: 1.2 s per tile on 2 cores with 6 workers, ~4–5 MB download per tile; 26,475 tiles.
   Progress goes to `features/run.log`.

   On a Mac, stop it sleeping: `caffeinate -i python3 global_run.py features 12`. Test first with
   `time python3 global_run.py features 12 tileList90.txt 100` and multiply by 265.
   Antarctic tiles (7,042 of 26,475) run last: they have no land-cover data, so their windows are kept
   for coverage but never nominated. If time runs short, stopping during Antarctica loses nothing usable.

4. Copy every `features/*.npz` into one folder, then nominate terrain candidates:

       python3 compare.py features terrain_candidates.json 50

5. Geology pathway:

       python3 glim_bulk.py            # GLiM polygons, ~25 min, ~1 GB
       python3 wc_bare.py 12           # global exposure raster from WorldCover, ~4 min
       python3 geology_run.py glim geology_candidates.json

   `geology_run.py` needs ~5 GB RAM.

6. Regional terrain run (150 km around Plainsboro, USGS 3DEP bare-earth, 60 m grid), ~4 min:

       python3 regional_run.py regional_terrain.json 40.33 -74.60 150
       python3 region_geology.py regional_geology.json 40.33 -74.60 150   # after geology_run.py

7. Freeze: put the git commit hash and date in the run ID, and don't edit outputs by hand.

## What each output number means

See section 5e (terrain) and 6c (geology tiers) of the notes doc. In short: distances are in degrees
(slope), decades (log10 roughness) and area fraction (connectivity); none is a percentage, none is
summed with another, and `null` always means "not measured".

## Tests

    python3 test_engine.py    # analytic planes + equivalence with the v0.2 plane_fit()

## Known limits

- Windows never cross 1° tile seams; tiles north/south of ~84.5° are too narrow for a 10 km window.
- Antarctica has no WorldCover: included, with ice cover recorded as not assessed.
- Mars references use only the 1600 and 3200 m baselines (the blended DEM's effective resolution is unknown).
- EMIT (geology tier G3) is not yet evaluated; records say so.

## Test outputs from 14 Nov

`results_test_2026-11-14/` holds the first global geology run and the regional runs. They are test runs,
not the frozen submission run. See the notes doc section 2e.

## Presentation maps (separate from the website)

    python3 plot_candidates.py features us_terrain_candidates.json figs/us basemap/states.geojson

Reads the run outputs only. One map and one scale-signature chart per reference.
`basemap/states.geojson` is a public US-states outline (PublicaMundi MappingAPI on GitHub,
derived from US Census boundaries); credit it on the slide.

Contiguous-US test run (14 Nov): `SHARD` not needed; 1,181 tiles in 17 min on 2 cores:

    python3 global_run.py features_us 6 conus.txt
    python3 compare.py features_us us_terrain_candidates.json 50
