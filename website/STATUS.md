# TERRALYTX website — status, 15 Nov 2026

Live: https://devidevidevikanumilli.github.io/nasaspaceapps/ (GitHub Pages, `gh-pages` branch; no login).
Source: `website/` on the `website` branch. Local run: `cd website && npm install && npm run dev`.

Tested in headless Chrome 153 with a software renderer (no GPU) at 1440×900, 1280×800 and 390×844, against both
the local build and the live URL. **It has not been viewed on a real GPU or a physical phone**; imagery sharpness
and frame rate there are expected to be better than in the test screenshots, but that is not verified.

## Update: visual redesign

The interface was restyled without changing any record, filter or comparison: paper top bar and drawers, a compact
record inspector, a light evidence workspace, smaller map symbols, and a phone layout with one bottom sheet.

Imagery defect ("beige patches"): no tile request was failing. The globe stopped drawing when the camera stopped,
which left half-loaded tiles on screen above a flat tan fallback map. It now keeps drawing until tiles have loaded
and uses NASA Blue Marble underneath Esri imagery. In the test browser (software renderer, two CPU cores, about
one frame every three seconds when zoomed in on 3D relief) a close-up view still takes several minutes to sharpen
fully; no request fails during that time. On a real GPU this should take seconds, but that is not verified here.

Scripted checks on the redesigned build (headless Chrome, 1440x900 unless noted): pathway filters give
600 / 400 / 150 / 50 records; a terrain record opens and the camera flies to it; JSON and CSV export download;
the planetary reference page opens from the record; Escape closes the workspace, then the record; the 2D/3D
toggle changes pitch; the Lockatong record opens and its five source links resolve; a base scenario filters the
list; a coordinate search shows "No analysis for this exact location"; rectangle drawing starts and cancels;
a 150 km circle filters the list; map attribution is visible; the layer panel names the imagery stack; a focus
ring is drawn on keyboard focus; no horizontal overflow at 1440 or 390 px; no console errors.
Screenshots: `screenshots/`.

## Update: global terrain run loaded

The site now reads the bundle from commit `3cac280` (`web/app_bundle.json`): terrain run "partial: 19295 of 19433 tiles
in the supplied list processed", 1,464,296 windows evaluated, no tile south of 60° S. It still holds 600 records
(50 per reference), now nominated from the global run instead of the US test tiles. Cross-pathway values
are "not measured" in this bundle (`results_global/cross_global_pending.json` is empty). Re-tested on this bundle:
globe, coverage layer and legend, a terrain record, a far-south location, and the Data & methods page.
The P0 table below was run on the earlier US test bundle; the filter counts quoted there belong to that bundle.

## P0 gates

| ID | Status | Evidence |
|---|---|---|
| UX-01 globe first | PASS | First frame is the CesiumJS globe. Scripted: cluster click 15,500 km → 3,168 km; double-click → 1,426 km; heading 70° → compass → 0°; tilt toggle −60° → −90°. |
| UX-02 600 records, clustered | PASS | 400 terrain + 150 rock-type + 50 geo-2.0 = 600, labelled as records. Clusters split on zoom; hover shows the pathway mix. |
| UX-03 camera continuity | PASS | Camera identical before/after switching Find → Base profiles → Search area and applying a reference filter. |
| UX-04 base profiles | PASS | Four team-defined scenarios with measured / proxy / not-measured lists; "View 50 related Earth records" filters by reference. |
| UX-05 filters | PASS | Radius counts match an independent Python count: NJ 150 km = 24, Death Valley 100 km = 62, mid-Pacific 50 km = 0 (zero state), reset = 600. Drawn rectangle and polygon work. |
| UX-06 fly to record | PASS | Terrain record shows its exact 10 km window; geo-2.0 unit shows its representative point only. |
| UX-07 navigation ≠ analysis | PASS | `40, -74` and `-30, 20` fly there and say "No analysis for this exact location"; nearest records are listed under a separate heading. |
| SCI-01 manifest | PASS | Verbatim on Data & methods, in the coverage legend and in every terrain record's run line. |
| SCI-02 quantitative comparison | PASS | T-M-CR-001: 11.36° at 400 m against reference p10–p90 4.54–18.86°, with band plot and table. |
| SCI-03 geology evidence | PASS | Lockatong record: lithology, lake evidence, conflict with Macrostrat default, not-comparable list, citations with DOI links, cross-check caveats. |
| SCI-04 no fake scores | PASS | No percentage match or suitability value exists in the UI; source scanned. |
| SRC-01 Data for this site | PASS | Sources tab links products; exported JSON record is byte-identical to the bundle record; CSV has one row per property. |
| SRC-02 dataset catalogue | PASS | 16 entries with licence and role; every link resolved on 15 Nov (publisher pages that block bots resolve via DOI). The Sourland guide has no link because none was supplied. |
| ENG-01 build | PASS | `npm run build` and `tsc --noEmit` clean; no console or HTTP errors on the live URL. |
| ENG-02 public, error handling | PARTIAL | Public URL works. Imagery fallback (satellite → NASA Blue Marble → bundled Natural Earth) was exercised when the test browser had no network. WebGL-unavailable message and keyboard focus styles exist but were not tested with assistive technology. |
| VIS-01 visual audit | PARTIAL | Reviewed in screenshots at three sizes and several defects fixed. Not reviewed on a real GPU or by the team. |

## Not built

- On-demand analysis of an arbitrary location (the site states this at every selected location).
- Country/state boundary filters; 3D Moon/Mars globes; geologic unit outlines; field-scan records.

## Known rough edges

- The first keyboard Tab stop is the map attribution link, before the top bar.
- In the record inspector a long reference name is cut with an ellipsis; the full name is in the tooltip and on the reference page.

- Place-name labels come from a raster overlay and can look soft at some zoom levels.
- On a software renderer the globe drops to a lower-detail mode automatically.
- Updating to a newer results bundle needs `scripts/derive_geometry.py` to be rerun (see README).
