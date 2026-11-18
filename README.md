# TERRALYTX: planetary terrain analog discovery

## Current state (updated 2026-11-17)

- **Engine:** the analog discovery engine lives in [engine/](engine/); see [README_v0.3.md](README_v0.3.md).
- **Real global results:** [results_global/](results_global/) holds a run on real data (see
  `results_global/manifest_global.json`). The sources are Copernicus DEM GLO-90, ESA WorldCover 2021 v200,
  NASA GSFC PGDA LOLA `LDEM_80S_20MPP_ADJ` (plus product 78 site outlines), and USGS
  `Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2`. 1,464,296 ten-kilometre windows were evaluated across 19,295 one-degree
  tiles (138 tiles failed to load). The tile list runs from 60°S to 84°N, so Antarctica is not yet covered.
- **Website:** live at https://devidevidevikanumilli.github.io/nasaspaceapps/ (state: [website/STATUS.md](website/STATUS.md)).
- **Field apps:** Field Station ([desktop/](desktop/README.md), Intel RealSense D435) and Field Scan
  ([mobile/](mobile/README.md), iPhone 17 Pro LiDAR) were used together in the field at Sourland Mountain on
  2026-11-15. Depth and colour both worked, and the kit recorded 6 scans and 364 photos. The same morning's log
  (D435 hardware gate passed, real iPhone scans, phone and Mac paired over Bluetooth) is in
  [desktop/STATUS.md](desktop/STATUS.md).

## Validation: how we know it works

| Check | What it tests | Result | Where |
|---|---|---|---|
| **Moon-to-Moon yardstick** | Is an Earth match close in absolute terms? Earth distances are judged against how much real lunar south-pole sites differ from each other. | Real Moon sites differ by 3.66° (worst-scale slope distance, 90th percentile). The closest Earth match, Volcán Aracar (24.23°S, 67.80°W), is 0.80° from the Connecting Ridge, well inside that range. | Record `T-M-CR-001` on the website; `engine/plot_candidates.py` |
| **Rediscovery against chance** | Without being told where analog testing happens, does the search find it? | 143 of the 400 terrain matches are in the Andes, 7.5× what chance predicts. Under a fixed western-South-America box (4.8% of the land searched), 42% of matches fall inside (8.8× chance; 5.4× counting whole tiles). The flat InSight plains reference puts none of its 50 matches there, so the effect is specific to rugged references. Added 17 Nov, after the deadline, from the submitted results only. | [results_global/ANDES_BASELINE_2026-11-17.md](results_global/ANDES_BASELINE_2026-11-17.md), `engine/andes_baseline.py` |
| **Held-out geology test** | Do the rock-map rules work on a basin they were not tuned on? | Hartford basin (CT/MA), labels fixed before the run. Lake rocks: precision 1.0, recall 0.86 (every pick correct). Basalts: 1.0 / 1.0. The first run with frozen rules found 0.71 of lake rocks; one bug fix and review corrections took it to 0.86, all disclosed in the geology notes. | [GEOLOGY_ENGINE_V2.md](GEOLOGY_ENGINE_V2.md), `results_test_2026-11-14/geology_v2_hartford_frozen_run.json` |
| **Independent site check** | Does the engine pick the rock a published field guide describes? | PASS. The Sourland Conservancy geology-hike guide (not an input) describes Lockatong mudstone with fossil mudcracks in the preserve, and the engine selects the Lockatong polygons there. | [GEOLOGY_ENGINE_V2.md](GEOLOGY_ENGINE_V2.md) ("Sourland validation"); featured case on the website |
| **Field measurement** | Does the kit work on real ground? | The D435 rig and iPhone LiDAR ran live at Sourland Mountain on 15 Nov 2026: 6 scans, 364 photos, depth and colour both working; one 90-second scan produced a 160,656-triangle mesh with a passed drift check. The scans were shown to the local judges. Earlier that morning: D435 hardware gate passed, real D435 and iPhone scans, Bluetooth pairing over the air. | [desktop/STATUS.md](desktop/STATUS.md), [mobile/README.md](mobile/README.md) |
| **Automated tests** | Do the measurements and rules behave as designed? | `engine/tests_v03.py`: 17 checks pass. `engine/tests_geology_v2.py`: 39 checks pass. | `engine/` |

## History

The first two prototypes (v0.1 terrain comparison on test fixtures, v0.2 geology pathway) are documented in
[docs/HISTORY_v0.1_v0.2.md](docs/HISTORY_v0.1_v0.2.md). The root-level `SYNTHETIC_*` files are their test fixtures.
