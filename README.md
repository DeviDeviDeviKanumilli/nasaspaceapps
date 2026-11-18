# TERRALYTX: planetary terrain analog discovery

## Current state (updated 2026-11-17)

- **Engine:** the analog discovery engine lives in [engine/](engine/); see [README_v0.3.md](README_v0.3.md).
- **Real global results:** [results_global/](results_global/) holds a run on real data (see
  `results_global/manifest_global.json`). The sources are Copernicus DEM GLO-90, ESA WorldCover 2021 v200,
  NASA GSFC PGDA LOLA `LDEM_80S_20MPP_ADJ` (plus product 78 site outlines), and USGS
  `Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2`. The run is **partial**: 19,295 of 19,433 tiles, with
  1,464,296 windows evaluated. No tiles south of 60°S are included, so Antarctica is not covered.
- **Website:** live at https://devidevidevikanumilli.github.io/nasaspaceapps/ (state: [website/STATUS.md](website/STATUS.md)).
- **Field apps:** Field Station ([desktop/](desktop/README.md)) ran live with the Intel RealSense D435 at
  Sourland Mountain on 2026-11-15. Depth and colour streams both worked, and a field scan was recorded. Field Scan ([mobile/](mobile/README.md))
  is the iPhone LiDAR app. Full state: [desktop/STATUS.md](desktop/STATUS.md).

## Validation: how we know it works

| Check | What it tests | Result | Where |
|---|---|---|---|
| **Moon-to-Moon yardstick** | Is an Earth match close in absolute terms? Earth distances are judged against how much real lunar south-pole sites differ from each other. | Real Moon sites differ by 3.66° (worst-scale slope distance, 90th percentile). The closest Earth match, Volcán Aracar (24.23°S, 67.80°W), is 0.80° from the Connecting Ridge, well inside that range. The yardstick depends on how the site boxes are drawn, and the site says so. | Record `T-M-CR-001` on the website; `engine/plot_candidates.py` |
| **Rediscovery against chance** | Without being told where analog testing happens, does the search find it? | Western South America holds 4.8% of the land searched but 42% of the 400 terrain matches (8.8× chance; 5.4× counting whole tiles). The flat InSight plains reference puts none of its 50 matches there, so the effect is specific to rugged references. Added 17 Nov, after the deadline, from the submitted results only. | [results_global/ANDES_BASELINE_2026-11-17.md](results_global/ANDES_BASELINE_2026-11-17.md), `engine/andes_baseline.py` |
| **Held-out geology test** | Do the rock-map rules work on a basin they were not tuned on? | Hartford basin (CT/MA), labels fixed before the run. First run with frozen rules: lake rocks precision 1.0, recall 0.71; basalts 1.0 / 1.0. After a bug fix and review corrections: lake rocks 1.0 / 0.86. We report 0.71 as the clean held-out figure, because the later fixes were made after seeing Hartford. Newark figures are training-set numbers. | [GEOLOGY_ENGINE_V2.md](GEOLOGY_ENGINE_V2.md), `results_test_2026-11-14/geology_v2_hartford_frozen_run.json` |
| **Independent site check** | Does the engine pick the rock a published field guide describes? | PASS. The Sourland Conservancy geology-hike guide (not an input) describes Lockatong mudstone with fossil mudcracks in the preserve, and the engine selects the Lockatong polygons there. | [GEOLOGY_ENGINE_V2.md](GEOLOGY_ENGINE_V2.md) ("Sourland validation"); featured case on the website |
| **Field measurement** | Does the kit work on real ground? | The D435 rig and iPhone LiDAR ran live at Sourland Mountain on 15 Nov 2026: 6 scans, 364 photos, depth and colour both working. The scans were shown to the local judges. The scan files are not yet in this repository. | [desktop/STATUS.md](desktop/STATUS.md) |
| **Automated tests** | Do the measurements and rules behave as designed? | `engine/tests_v03.py`: 17 checks pass. `engine/tests_geology_v2.py`: 39 checks pass. | `engine/` |

The sections below document the v0.1 and v0.2 prototypes and are kept for history. Their "evidence
boundary" and "missing" notes describe the package as it was then, before the real-data run above.

---

# Small-tile planetary terrain comparison experiment (v0.1, historical)

> **Field apps.** [desktop/](desktop/README.md) is Field Station, the D435 field-instrument workstation
> (state: [desktop/STATUS.md](desktop/STATUS.md)). [mobile/](mobile/README.md) is Field Scan, the iPhone LiDAR app.
> They share the formats in [contracts/](contracts/) (scan bundle, Bluetooth protocol, test vectors), and
> `mobile/test/interop_field_station_test.dart` runs the phone's code against the desktop service.
> Neither app contains the analog discovery engine in this repository; a scan can only carry a website
> candidate id (`web/app_bundle.json` `candidates[].id`) as an opaque reference.


**Research prototype; not global discovery, a validated analog-selection engine, or a NASA flight-safety evaluation.**

This package contains working, tested exploratory code for comparing physical terrain measurements from a **projected planetary elevation raster** with one or more **georeferenced Earth elevation rasters**. It implements the mathematical and measurement revisions identified in the research audit.

## Evidence boundary

The included `SYNTHETIC_*.tif` elevation files are artificial test fixtures. **In v0.1, no NASA elevation or Copernicus Earth elevation pixels were processed in the included results.** The execution environment at that time could browse the NASA/Copernicus source listings but could not download TIFF bytes. (Real data has since been processed; see `results_global/` and "Current state" above.) The synthetic images carry fake Earth coordinates purely to exercise georeferencing and are not discovered Earth sites.

## Improvements over Claude's proposal

- Local plane-fit **absolute slope in degrees**, separate from **detrended RMS roughness in meters**.
- Local circular physical neighborhoods, currently at 400/800/1600 m when sampled on a 100 m grid. Rejects feature scales with <4 grid samples across the diameter.
- Comparison with separate **Wasserstein-1 distances in original physical units**. No unstable normalization by inter-reference variance, no synthetic analog percentage or unvalidated 95%-cutoff.
- **Connectivity curves** for sampled slopes at thresholds 5°, 10°, 15°, 20°, 25°. These thresholds are *diagnostic sweeps*, not rover/lander engineering limits. Connectivity is not incorrectly inferred from slope histograms.
- Cropping of planetary meter-based projected rasters in their native XY frame, **not Earth lat/lon coordinates**.
- Earth cropped and reprojected to local WGS84 UTM for distance calculations. Both inputs are sampled to a target metric grid (coarse resampling is an approximation, not a guarantee of equal observational support).
- Optional NASA co-registered effective-resolution image; flags unsupported neighborhoods. Outputs file SHA-256, source metadata, candidate centers, quality status, and raw comparison details.
- Separate Pareto front for slopes vs roughness (not a physical suitability certificate).

## Install and run synthetic tests

```bash
python -m pip install -r requirements.txt
python test_experiment.py
```

You should see five passing test groups and a synthetic first-place match.

## Run one actual NASA-vs-Earth sample after obtaining the rasters

Sources:

1. NASA Goddard **LRO/LOLA, Shackleton Rim Site04**: https://pgda.gsfc.nasa.gov/products/78 and https://pgda.gsfc.nasa.gov/data/LOLA_5mpp/
2. The Copernicus **GLO-90** dataset: https://registry.opendata.aws/copernicus-dem/

Download both rasters. `fetch_real_data.sh` provides **unexecuted** suggested URLs for two files, to test on a computer with internet access. Confirm they are valid with Rasterio; do not assume every tile exists.

Then:

```bash
python experiment.py \
  --planet real_data/Site04_final_adj_5mpp_surf.tif \
  --earth real_data/Copernicus_GLO90_N40_W075.tif \
  --earth-center-lonlat -74.58 40.34 \
  --baselines 400,800,1600 \
  --pixel-m 100 --reference-size-m 4800 \
  --earth-size-m 9000 --window-size-m 4800 --stride-m 1500 \
  --output REAL_nj_experiment.json
```

This searches a ~9 km square **within one Earth tile**, NOT the globe. To compare multiple Earth raster tiles, repeat `--earth path/to/tile.tif`. Note that `--earth-center-lonlat` applies the same center to each tile; omit it for a tile-centered crop. **Earth images must have an identifiable CRS. Lunar images must already use a native planar XY coordinate system in meters.** Mars MOLA lat/lon archives require **Mars-specific georeferencing/preprocessing** before use; do not transform them with Earth's WGS84 UTM.

The NASA Site04 5m grid is heavily interpolated in places. For serious science, use the associated source observation-count and uncertainty maps and consider NASA's more recent 20m south-pole product with an effective-resolution layer. The script currently has a gate for an *aligned effective-resolution raster* (`--planet-effres`) but **does not incorporate a complete uncertainty model or per-pixel counts**. Absence of these quality layers is a material limitation, not evidence of high quality.

## Tests performed

`test_experiment.py` executes:
1. analytical plane fitting on flat and 15°/28° inclines and bumpy surfaces;
2. identical slope histograms but disconnected vs connected terrain;
3. the zero-reference-variation denominator failure in the discarded normalization;
4. rejecting too-fine baselines, poor effective-resolution support, and entirely missing data;
5. an end-to-end synthetic GeoTIFF import, local reference/candidate comparison, georeferenced output, and successful matching-region selection.

## What's still scientifically or computationally missing

*Status as of 2026-11-17: real NASA and Earth raster results now exist (`results_global/`), global tiling has
run (partial: 19,295 of 19,433 tiles; nothing south of 60°S), and the D435 has been used live in the field
(Sourland Mountain, 2026-11-15). The items below that remain open are still open.*

- ~~Real NASA and Earth raster results~~ (done; see `results_global/`).
- ~~Global tiling~~ (done, partial coverage). Unbiased geographically comprehensive candidate enumeration, nonuniform coverage accounting, independent geology pathway remain open.
- Dependable observational validity flags for interpolated LOLA regions, Copernicus canopy/structure bias, stratified / spatially correlated uncertainty, cross-tile boundary handling.
- Comparable smoothing/point-spread functions and validation of terrain estimators against instrument-scale data.
- Independent reference selection, negative controls based on real geology, spatial block cross-validation, rank uncertainty and benchmarked worldwide processing.
- Explicit planetary datum, polarity, geodetic frame verification for any new raster source; exact source footprint and reference selection must be logged.
- ~~D435 field validation~~ (done: Sourland Mountain, 2026-11-15, depth and colour). Physical accessibility remains open.

**The synthetic fixture results are not a verified NASA/terrestrial analogy.**

## v0.2: independent geological candidate pathway (November 14)

**This is a second, separate discovery pathway—not geology applied only to terrain winners.**
The new `geology_pathway.py` accepts an Earth geological polygon GeoJSON or
queries the worldwide GLiM Level-I ArcGIS FeatureServer. For now it supports
three narrow Jezero research questions motivated by NASA Perseverance science:

- `jezero_maaz_volcanic` — query **Basic volcanic rocks** as broad potential mafic
  volcanic-material candidates; this is NOT a demonstrated match to Máaz chemistry.
- `jezero_seitah_plutonic` — query **Basic plutonic rocks** as preliminary igneous
  candidates; this does NOT establish cumulate origin or olivine concentration.
- `jezero_delta_siliciclastic` — query **Siliciclastic sedimentary rocks** as very
  preliminary material candidates; this does NOT establish ancient river-delta
  deposition or comparable biosignature preservation.

The queries are based on exact source map labels, **not LLM classifications**.
The discovery pipeline refuses to infer lunar anorthosite from GLiM broad classes,
Martian dunes from unconsolidated sediment, or Martian buried-ice equivalence from
terrestrial mapped ice. These require separate, validated evidence.

Source dataset: [GLiM Level-I global polygon FeatureServer](https://services8.arcgis.com/4KhTMTZ1x0f76DSg/ArcGIS/rest/services/GLiM_Niveau_I/FeatureServer/1)
(derived from Hartmann & Moosdorf 2012; include original source attribution).
This endpoint is third-party-hosted and its live query performance, coverage, errors,
and licensing/reuse limitations have **not** been verified inside this runtime.

Run offline, on synthetic examples only:

```bash
python geology_pathway.py --geojson SYNTHETIC_geology_test.geojson \
  --target jezero_maaz_volcanic --output SYNTHETIC_geology_results.json
python geology_pathway.py --geojson SYNTHETIC_geology_test.geojson \
  --target jezero_delta_siliciclastic --output SYNTHETIC_jezero_delta_results.json
python test_geology.py
```

Run against **actual GLiM map polygons**, from a network-enabled machine:

```bash
# Small bounded test; coordinates below specify a test area, NOT a preselected analog
python geology_pathway.py --arcgis \
  --target jezero_maaz_volcanic --bbox -75 39 -73 41 \
  --max-records 3000 --output GLiM_region_maaz.json

# Independent global class search; likely many records and API pagination requests:
python geology_pathway.py --arcgis \
  --target jezero_maaz_volcanic --all-matches \
  --output GLiM_world_maaz.json
```

When no bounding box is supplied and all matching IDs are downloaded, the query
covers the provider's **global** dataset. Its *geographical distribution is a
property of the source*, not a claim that every rock unit is mapped consistently.
Limited runs explicitly say `INCOMPLETE` in the coverage_status field.
The output includes a representative location inside each map polygon, the
original feature ID/class, source link, and explicit scientific limitations.
Map polygons should be cross-checked against higher-resolution original mapping
before describing any location as a scientifically useful analog.

**As released, the v0.2 package contained no processed real NASA or GLiM observation
pixels/polygons (real NASA and Earth elevation data were processed later; see `results_global/`). Its nine local tests are controlled synthetic tests, including a
mocked ArcGIS query response.** Full-scale GLiM and planetary DEM ingestion remain
unverified; the output is NOT an independently discovered analog.
