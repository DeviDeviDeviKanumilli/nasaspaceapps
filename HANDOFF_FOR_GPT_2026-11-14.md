# Handoff to GPT — from Claude, Saturday 14 Nov 2026, ~20:45 ET

You (GPT) wrote the comprehensive handoff that started my session, including the clarification on
fieldwork and outdated documentation (D435 as the primary instrument, field visit ideally within
1–2 h of Plainsboro, no predetermined destination, no overclaiming field validation). This document
reports everything I did from that point on, what happened, what is verified and what is not, and
what is left. The code is in the attached `terrain_analog_lab_v0.3.zip` (folder `engine/`) and,
for convenience, concatenated in `CODE_BUNDLE.md`.

The user also has a private notes doc I wrote ("Space Apps 2026 — Decisions and Research Notes
(Nov 14)"). You probably can't open it, so this file is written to stand alone.

---

## 0. Timeline and deadlines (all ET)

- Now: Saturday 14 Nov, evening. Team is about to run the global terrain run tonight on one
  M5 MacBook, 16 GB RAM, 252 Mbit/s download.
- Sunday 15 Nov morning: field visit. Recommended site: Nottingham County Park, PA (section 7).
  Park opens 8 AM, so leave ~6 AM (not 4–5 AM).
- Sunday 15 Nov 11:59 PM: submission deadline (Princeton local event).
- Local judging (Princeton): 7–10 min per team **including Q&A**, every team member should talk.
  Local judges: Tathagata Dasgupta (Principal Engineer, London Stock Exchange), Hardik Ginwala
  (Senior Software Engineer, Microsoft), Venu Sri Sabbavarapu (UX Designer, Senseways). None are
  geologists.
- Local lead (Venu, email 7:23 PM Sat): a video showing minor team members **is allowed in the local
  presentation if played from a local file** (not a URL or hosted video). Length is up to the team.
  The **global** submission still requires a ≤30 s video or ≤7 slides with **no minors' likeness**.
- Global: Nominees 3 Dec, Finalists 17 Dec, Winners 26 Jan 2027.

## 1. What I was asked, and one thing to know about how I interpreted it

The user's priorities (in their words): do the research; the report "isn't insanely important
compared to actually doing the research"; I may "extend a copy" of the v0.2 prototype; no slop
(no AI-written text per candidate, no match percentages, nothing hardcoded); write occasional
handoffs.

**Important:** I went further than the user expected. Using the permission to extend a copy of the
prototype, I wrote and ran a full analysis engine (≈1,450 lines of Python) to back the research with
real numbers. When the user saw this they said "wait bro what, i did not mean for you to write the
software". They then engaged with it positively (asked how it works, asked for more zone references,
asked for the regional state-map search), but treat the code as **optional research tooling the team
may adopt, adapt or replace**, not as the team's product. The team's product is their Flutter website
(web + desktop app) that reads JSON outputs. Every script carries an AI-assistance header comment for
the Space Apps disclosure rule.

## 2. Decisions I made after reviewing the old work critically

- **Architecture: two independent discovery pathways on one global 10 km window grid** (5 km step):
  a terrain pathway and a geology/process ("rock-type") pathway. Each nominates candidates by its own
  rule; every candidate is measured by both; **no blended score**. I did not simply defend the old
  "terrain discovers, geology explains" design (terrain alone is blind under vegetation: the Princeton
  1° tile is 90% masked) and did not adopt a weighted multi-pathway score (weights are arbitrary and
  produce the match-% the team wants to avoid).
- **Terrain estimator:** least-squares plane over a disc of diameter L at every 100 m cell.
  Slope = plane tilt; roughness = RMS residual (detrended). L = 400/800/1600/3200 m. Closed form via
  fixed-kernel convolutions (identical results in NumPy and, if needed, Earth Engine). This roughness
  is **not** LOLA's published roughness product; don't compare against those.
- **Comparison:** 1-D Wasserstein distance (W1) between slope distributions, computed from 50
  midpoint quantiles, in **degrees**; "worst-scale distance" = max over baselines, so a window must
  match at every scale. Roughness in log10 decades; connectivity curve = share of valid cells in the
  largest 4-connected patch below 5/7.5/10/12.5/15/20/25° at 800 m (diagnostic thresholds, not
  vehicle limits). Never normalised, never summed, never a percentage.
- **Nomination:** successive Pareto fronts on (worst-scale slope, worst-scale roughness,
  connectivity) until N = 50, then 25 km suppression. No quotas by country.
- **Yardsticks make distances meaningful** (section 5): e.g. "closer than two real lunar landing
  regions are to each other".
- **Masking:** Copernicus is a surface model (trees, roofs), so ESA WorldCover classes 10, 40, 50, 80,
  90, 95 are masked; snow/ice (70) kept but flagged.
- **Mars terrain:** MOLA–HRSC 200 m has no effective-resolution layer, so Mars terrain uses only
  1600 and 3200 m baselines. InSight is so flat (median 0.21° at 800 m) that it sits near Earth DEM
  noise; Mars landing-plain terrain matches are weakly discriminating and must be presented so.
- **Website display (no slop):** reference-band strips (candidate marker vs reference middle half
  and 10–90% range), a count ("7 of 10 measured properties inside the middle half; 3 not measured"),
  scale-signature chart, overlaid distributions, same-scale relief maps, evidence ladder for geology,
  coverage map. All text from fixed templates bound to record fields; fixed outcome vocabulary
  (inside middle half / inside range / outside range / not measured / not comparable). No radar
  charts, no gauges. Precompute is not "hardcoding" if the site reads only run outputs, shows run ID
  and dataset versions, features candidates by a stated rule, and (ideally) offers click-any-point.

## 3. Data access I verified by actually reading data (not just docs)

| Dataset | Role | Notes |
| --- | --- | --- |
| NASA PGDA LOLA `LDEM_80S_20MPP_ADJ` + `_EFFRES` + `_ERR` (product 90) | Moon references | COG over HTTPS. Intermittent HTTP 403 from the NASA origin: fixed with GDAL single connection (`GDAL_HTTP_MULTIPLEX=NO`, `GDAL_HTTP_MULTIRANGE=SINGLE`) and retries on 403. Effective resolution at sites ~16 m median; height error ~0.19 m median. |
| PGDA product 78 site DEMs | Site box outlines only | 5 m grids are ~90% interpolated, so only outlines used. |
| USGS MOLA–HRSC blended DEM v2, 200 m | Mars references | `planetarymaps.usgs.gov/mosaic/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif` |
| Copernicus DEM GLO-90 (AWS `copernicus-dem-90m`) | Earth terrain | 26,475 tiles listed. |
| ESA WorldCover 2021 v200 (AWS `esa-worldcover`) | masks, exposure | 20 m overview used (40 m changed results in one tile: 311 → 251 windows). No Antarctic tiles. |
| GLiM polygons (ArcGIS service `services8.arcgis.com/4KhTMTZ1x0f76DSg/.../GLiM_Niveau_I/FeatureServer/1`) | global geology | 1,235,259 polygons downloaded. Host org unconfirmed; official PANGAEA record (doi:10.1594/PANGAEA.788537, CC-BY 3.0) is the 0.5° gridded version. Cite Hartmann & Moosdorf 2012. `Shape__Area` is Web Mercator: never used. |
| USGS 3DEP 1/3″ bare-earth DEM (`prd-tnm.s3.amazonaws.com/.../Elevation/13/`) | regional terrain | Bare earth, so no vegetation mask needed. |
| Macrostrat API `geologic_units/map?scale=large` (CC-BY 4.0) | regional state-survey geology | 2,927 polygons within 150 km of Plainsboro via a 1 km point grid. |
| USGS SGMC geodatabase (ScienceBase item 5888bf4fe4b05ccb964bab9d) | state geology cross-check | Downloaded (436 MB), **not yet used**. |
| Google Earth Engine | — | **Not used.** User has an approved noncommercial Community project (150 EECU-h/month shared batch+interactive). See section 9. |
| EMIT L2B minerals | geology tier G3 | **Not read.** Needs Earthdata login. No olivine product. |

## 4. The code (`engine/`, all Python 3; NumPy, SciPy, rasterio, pyproj, matplotlib; geopandas/pyogrio/shapely for the state-map step)

Run from inside `engine/`. Everything below **ran successfully here** unless marked.

| Script | What it does | Output |
| --- | --- | --- |
| `terrain_engine.py` | plane-fit slope/roughness (general masked version + fast closed form), connectivity | — |
| `test_engine.py` | analytic planes (0/15/28° recovered exactly), equivalence with the v0.2 `plane_fit()` to ≤2.6e-11° | pass |
| `lolaread.py` | reads LOLA windows for the four sites | `lola20_*.npz` |
| `build_refs.py` | six reference profiles (4 Moon site boxes, Jezero, InSight) in window format | `refs.npz`, `refs_meta.json` |
| `build_zone_refs.py` | Moon **zone** references from 40×40 km LOLA boxes (section 5) | adds `MZ-FLAT`, `MZ-STEEP`; `zone_windows.json` |
| `zone_yardstick.py`, `zone_yardstick_regional.py` | spread of real lunar zone windows around their zone reference | `zone_yardstick*.json` |
| `global_run.py` | per-1°-tile features for every 10 km window: 50 slope quantiles and 50 log-roughness quantiles × 4 baselines, connectivity curve, land-cover fractions. Resumable, `SHARD=k/n`, Antarctic tiles last, skips DEM download when land cover rules out every window | one `.npz` per tile |
| `compare.py` | distances to every reference, Pareto nomination, run metadata, coverage list, excludes windows > 50% snow/ice or with unknown land cover from nomination | candidates JSON |
| `glim_bulk.py`, `wc_bare.py`, `geology_run.py` | global rock-type pathway: rasterise GLiM to 0.01°, global bare-ground raster from WorldCover 320 m overview, window tiers | candidates JSON |
| `region_geology.py` | rock-type pathway restricted to a circle | JSON |
| `regional_run.py` | 3DEP 60 m terrain run (240/480/960 m) within 150 km of Plainsboro, incl. zone references | JSON |
| `ms_region.py`, `state_geology_targets.py` | Macrostrat state-survey polygons + fixed keyword rules for Mars-relevant processes + land cover per polygon | JSON + map PNG |
| `plot_candidates.py` | presentation maps and scale-signature charts from JSON (separate from the website, by the team's design) | PNGs |

Rock-type tiers: G1 mapped (target ≥ 50% of window) → G2 exposed (target AND bare/sparse or
moss/lichen ≥ 25%) → G3 EMIT (not evaluated) → G4 process partner (partner class ≥ 10% of window;
this minimum was added Saturday evening after I saw the partner counted at ~1%). Targets:
Jezero = basic volcanic/plutonic + alluvial sediment partner; InSight = basic volcanic + dune
sand/loess partner; dune-crossing zone = dune sand + basic volcanic/plutonic partner.

Fixes applied before tonight's run: Antarctic cells ≤ 1 m elevation treated as water (no WorldCover
there, ocean looked like flat land); windows > 50% snow/ice and windows with unknown land cover are
not nominated (ice sheets would otherwise match "flat" references); f-strings made compatible with
Python < 3.12; run metadata + coverage list added to compare output.

Benchmark: 1,181 tiles in 17 min on 2 cores (≈0.9 s/tile); ~4–5 MB download per tile. Estimate for
26,475 tiles on the M5: ~1–2 h, set by bandwidth/CPU; test 100 tiles first and multiply by 265.

## 5. Results (all real data; all **test runs**, not the frozen submission run)

**Lunar references** (100 m grid, slope 10/50/90th pct at 400 m): Connecting ridge 4.8/11.4/19.4°;
Shackleton rim 7.1/20.2/32.1°; de Gerlache rim 6.9/14.1/21.0°; Malapert 7.4/17.5/25.7°. (These are
per-baseline areas; the engine uses cells valid at all baselines, which moves Shackleton's 400 m
median to 24.7°, so box definition matters.)

**Yardsticks** (worst-scale slope W1, 400 m–3.2 km): lunar site vs site: CR–DG 3.7°, DG–MA 3.7°,
SR–MA 4.8°, CR–MA 7.4°, SR–DG 7.8°, CR–SR 11.3°. Site quarters vs whole box: CR 1.5–6.5°,
SR 7.7–13.0° (heterogeneous: rim + crater wall; flag or redefine), DG 1.2–2.8°, MA 1.5–5.3°.

**Scale signature** (median slope 3200 m ÷ 400 m): Moon 0.67–1.02 (Shackleton 1.02, Malapert 0.99,
de Gerlache 0.91, Connecting ridge 0.67); Earth control tiles 0.38 (Himalaya) to 0.78 (Mauna Loa).
River-cut Earth terrain loses steepness with scale; the Moon doesn't. This is the headline terrain
finding.

**Zone references** (rules fixed on lunar data only): flat operations zone = 10 km lunar windows with
≥ 60% of ground ≤ 10° at 400 m (69 windows from the four sites); steep traverse zone = ≥ 40% at
15–30° (257 windows). Pooled per zone. Zone yardstick (real lunar zone windows vs their pooled
reference): flat median 1.16°, p90 1.77°; steep median 2.95°, p90 5.84°. Power-ridge zone not built
(illumination not reproducible on Earth). Mars zones: InSight = landing plain; Jezero = science
region; dune-crossing zone in rock-type pathway; **ice-mining zone missing**.

**Contiguous US terrain run** (bounding box incl. border strips of Mexico/Canada; 1,181 tiles;
45,342 windows):

| Reference | Best | Windows inside yardstick |
| --- | --- | --- |
| Moon Connecting ridge | 1.41° (≈33.19°N 116.41°W, Anza-Borrego area, CA) | 357 under 3.66° |
| Moon de Gerlache rim | 2.81° (Panamint area, CA) | 6 under 3.66° |
| Moon Malapert | 5.28° | 0 under 3.72° |
| Moon Shackleton rim | 8.86° | 0 under 4.76° |
| Moon flat operations zone | 1.20° (eastern CA desert) | 39 under lunar p90; 0 under median |
| Moon steep traverse zone | 4.49° | 10 under p90; 0 under median |
| Mars InSight landing plain | 0.02° | not meaningful (flat ground everywhere matches) |
| Mars Jezero (terrain only) | 0.28° | no yardstick |

Top Connecting-ridge matches cluster around Death Valley / Panamint / Saline Valley and southern CA
deserts. Death Valley is already a known analog area: frame as "independently agrees and adds spots",
not discovery. Place names are my reading of coordinates.

**Global rock-type run** (4.86 M windows, partner ≥ 10%): Jezero type G1 154,217 / G2 27,474 /
G4 362 (top: Puna NW Argentina, Afar, northern Kenya, southern New Mexico); InSight type
133,097 / 23,702 / 243 (Libya, Sudan, Afar); dune-crossing 130,692 / 124,350 / 394 (Sahara). Counts
are overlapping windows (half-window step), not distinct places. Moon: not discoverable (no
anorthosite class in GLiM).

**150 km around Plainsboro:**
- 3DEP terrain (1,325 windows): no window closer to any whole lunar site than lunar sites are to each
  other (best vs Connecting ridge 4.71° vs CR–DG 2.63° at regional baselines). Flat zone: best 1.78°
  vs lunar p90 1.83° at regional scales (Appalachian ridge country ~140 km WNW; shape only, forested).
  Steep zone: best 10.1°, nothing comparable.
- GLiM rock type: only G1 (mapped basalt ~31–36 km NNE = Watchung; and ~145 km WSW in SE PA).
- **State-survey maps (Macrostrat, fixed keyword rules):** 23 ultramafic/serpentinite polygons
  (best by open ground: the Nottingham barrens body, 134 km, 20 km², 23% open, 2.7% bare); 49 basalt
  (Watchung: Preakness, Orange Mountain — "locally pillowed" — Hook Mountain; 28–62 km); 12 lake
  sediments (glacial-lake deposits incl. a "lacustrine delta", lower Hudson valley NY, ~100–135 km);
  5 wind-blown sand (barrier islands, coastal, weak); 87 glacial; 0 evaporite. Caveats: NY's map
  includes surficial deposits, NJ/PA bedrock only (glacial/lake hits stop at state lines for
  map-making reasons); keyword rules only see map text (the Triassic Lockatong lake formation was
  missed because its description lacks "lacustrine"; adding it by hand would be hand-picking); an
  early basalt rule falsely matched schists listing "metabasalt" and was restricted to unit names.

## 6. Literature checks (quick, not exhaustive)

- State Line complex: layered mafic intrusion, part of the Baltimore mafic complex; basal portion
  serpentinite with relict peridotite (USGS Geolex). Fractional crystallisation → chromite, dunite and
  peridotite cumulates → serpentinised; region was a major source of magnesite (GSA NE 2014 abstract).
  Macrostrat unit text: "Includes serpentine, steatite, and other products of alteration of
  peridotites and pyroxenites". Nottingham County Park: National Natural Landmark, ~1 sq mi serpentine
  barrens, old chromite mines, open 8 AM–dusk daily.
- Jezero link: olivine–carbonate lithology in the Jezero watershed (Brown et al. 2020, JGR Planets,
  doi:10.1029/2019JE006011), serpentinisation proposed as a mechanism; Séítah carbonates consistent
  with magnesite–siderite solid solutions (Clavé et al. 2023, JGR Planets, doi:10.1029/2022JE007463).
- Not a prominent Mars analog as far as a quick search found; established serpentinite analogs are
  elsewhere (e.g. Samail ophiolite, Oman; Coast Range/Tablelands etc.). Caveats: Mars olivine is far
  more Fe-rich; tectonic setting differs; no lake/delta; humid and vegetated.
- Mars base context: NASA HLS framework = field station + Regions of Interest within ~100 km radius;
  water feedstocks = subsurface ice or hydrated minerals (energy-intensive); NASA slides used Jezero as
  an example site. A Jezero-type region fits a **science region** (and a backup hydrated-mineral water
  source), not landing/ISRU-ice zones.
- AT&T direct-to-device satellite: not available in time (AST SpaceMobile delays to 2027); irrelevant
  since fieldwork doesn't need internet.

## 7. Field plan (Sunday)

- **Site: Nottingham County Park, West Nottingham Twp, PA** (~1¾–2 h drive). Chosen because the
  method flagged the area (GLiM G1, then state maps ranked its serpentinite body first by open ground);
  team should state this order in the presentation and log it. Goat Hill Barrens closed Oct–Jan; Rock
  Springs research-only. Backup: Watchung basalts (30–45 min; best pillow exposures in private
  quarries — don't enter).
- Safety: amphibole asbestos can occur in these serpentine rocks — no hammering, crushing, or
  collecting (collecting not allowed anyway); stay out of old mine pits; hunting season: wear blaze
  orange; adult present.
- D435 can: cm–m surface shape, local slope over 0.5–2 m, boulder sizes, a check of 3DEP lidar at the
  same spot, 3-D footage. Cannot: anything at 400 m+ scales, mineralogy, planetary validation. Plain
  D435 has **no IMU** — record camera tilt with a phone level. Bring a strong magnet (serpentinite often
  has magnetite), hand lens, scale bar. Protocol: 8 stations at fixed spacing chosen before arrival,
  GPS + photos + 30 s `rs-record` per station; process with the same plane-fit estimator at 0.5/1/2 m.
- Framing: "a G1/state-map geology site the method nominated; field data documents it and checks one
  input dataset; it doesn't validate the planetary comparison."

## 8. Rubric strategy (from the user's PDFs + local slides)

Criteria (1–5 each): Impact, Creativity, Validity, Relevance, Presentation. Relevance requires NASA
data as a core component (LOLA, MOLA–HRSC). Validity includes usability. Local slides: "videos or
live demos will take you far", public open-source repo, an AI-use paragraph on the project page and a
sentence in the talk. Suggested 8-min arc: problem (bases need different ground per zone) → method
(two pathways, NASA references, no scores, scale signature, yardstick) → global/US results → "what
about near us?" → ~1.5 min field video (local file) → why it matters (science region, serpentinisation,
astrobiology, hydrated minerals) → limits. Global 30 s demo must be faceless.

## 9. Google Earth Engine: not needed for results; optional value

Nothing so far used EE. Added value if used: (1) **click-any-point** live recomputation on the
website (strongest "nothing is hardcoded" proof; use `COPERNICUS/DEM/GLO30` averaged to 100 m, label
numbers as live GLO-30, they can differ slightly from the GLO-90 run); (2) USGS 3DEP 1 m and Sentinel-2
leaf-off imagery for the field-site area; (3) a cross-check of GLO-90 vs GLO-30 slopes. Risks: shared
150 EECU-h/month quota; restricted mode past it would kill the live tool. If access is given to an
assistant, use a dedicated service account with Earth Engine-only roles, deleted after the hackathon.

## 10. What's left (priority order)

1. Global terrain run tonight (M5): 100-tile timing test, then `caffeinate -i python3 global_run.py
   features 12`; then `compare.py`; then rerun rock-type pathway (or reuse outputs). Freeze run ID.
2. Website (Flutter) reading the JSON: reference-band strips, scale chart, coverage map, evidence
   ladder; optional EE click-any-point.
3. Field visit; D435 processing Sunday afternoon.
4. Presentation (local video + slides, everyone speaks), global 30 s faceless demo, public repo,
   references list, AI disclosure; FortiGuard classification for the site URL; submit with margin.
5. Optional: Shackleton reference redefinition/flag; Mars ice-mining reference (needs Mars ice data;
   SWIM site was down); EMIT G3; SGMC cross-check of the state-map results; sensitivity runs
   (thresholds, window size, N).

## 11. Things that are NOT verified or are my estimates — please don't promote them to facts

- Drive time to Nottingham (~1¾–2 h) and M5 runtime (1–2 h) are estimates.
- Place names attached to coordinates are my readings of the coordinates.
- "Not a prominent analog" is based on a quick search, not a literature review.
- GLiM service host and terms unconfirmed.
- All results are test runs; the frozen submission run hasn't happened.
- Earth slope noise (~0.1° at 800 m) used √2·σ/L with σ ≈ 1 m as a conservative bound.

## 12. Files

- `terrain_analog_lab_v0.3.zip`: v0.2 prototype unchanged + `engine/` + `README_v0.3.md` (commands) +
  `results_test_2026-11-14/` (JSONs and PNGs; files without `_v2`/`_v3` are superseded earlier
  versions: `geology_candidates.json` used the weak partner rule; `regional_terrain.json` lacks zones).
- `HANDOFF_2026-11-14.md` in the zip is an earlier, shorter handoff (afternoon); this one supersedes it.
- `CODE_BUNDLE.md`: all `engine/*.py` concatenated for reading without unzipping.
