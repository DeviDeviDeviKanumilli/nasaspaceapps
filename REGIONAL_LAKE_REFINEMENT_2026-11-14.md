# Regional refinement: ancient lake deposits near Plainsboro (Sat 14 Nov 2026, ~23:30 ET)

**Label:** regional refinement of the global method. Not an output of the global search.

**How the hypothesis and criteria were chosen (disclosure).** After the team asked whether New Jersey
has Mars-relevant geology the coarse global search missed, Claude proposed Newark Basin rift-lake
deposits (e.g. the Lockatong Formation) from prior geological knowledge, as an analog for the lake
sediments at Jezero (and Gale). The team also asked specifically about the Sourland Mountain area.
The rule below was written into `engine/regional_lake_search.py` before running and applied identically
to every polygon in the study area. One correction was made after the first run (see "Rule revision").

## Rule
- **Study area:** 150 km circle around Plainsboro (same as earlier regional runs): NJ and parts of PA, NY,
  DE, MD, CT.
- **Data:** USGS State Geologic Map Compilation v1.1 (polygons + the state surveys' own unit
  descriptions + lithology comments). This is a bedrock compilation; it contains no surficial
  (Quaternary) units here, so Class B is empty by construction.
- **Class A (ancient lake deposits):** description text says lacustrine / playa / "lake deposits/beds/
  sediments/sequences/cycles/mudflat", unit older than Quaternary.
- **Supporting attributes (not used for selection):** mentions of mudcracks/desiccation, evaporite or salt
  crystals, cyclic beds.
- **Field criteria, reported separately, never combined:** exposure proxy = polygon area with slope ≥ 25°
  on USGS 3DEP 1/3″ (≈20 m) plus WorldCover bare and tree shares; accessibility = area of PAD-US
  "Open access" land inside the polygon, with names; straight-line distance.
- **Ranking:** by exposure-proxy area. Field shortlist = same ranking restricted to polygons with open
  public access.

## Rule revision (disclosed)
The pre-registered keyword `lake` matched place names ("Greenwood Lake", "Peach Lake", "Halcyon Lake
Dolostone"): v1 selected 283 polygons including schists, gneisses and gabbro. v2 keeps the same intent
and excludes place names (`lacustrine | playa | lake + deposits/beds/...`). v2: 228 polygons, all from
four units: Lockatong Formation, Lockatong Formation red bed, Passaic Formation, Passaic Formation gray
bed. Both versions are in `regional_lake_search.json`.

## Results (`results_test_2026-11-14/regional_lake_search.json`, `figs/regional_lake_search.png`)
- **228 polygons, 638 km²**, all in the central New Jersey part of the Newark Basin (state map sheet
  suffix `;2`). Descriptions: Lockatong "predominantly cyclic lacustrine sequences of silty, dolomitic or
  analcime-bearing argillite"; Passaic "cyclic playa-lake-mudflat sequences"; Passaic gray bed "gray lake
  deposits". Most also mention mudcracks/desiccation and cycles.
- **Exposure is the limiting factor:** steep ground is 0.2–3% of each polygon; trees cover 47–75%; bare
  ground ≈ 0%. Visible rock will be in stream cuts, ledges and road cuts, not open landscapes.
- **Top by exposure proxy (all have open-access public land):**
  1. Lockatong Formation, ~30 km NW (rep. point 40.51 N, 74.89 W; Hunterdon County): 0.20 km² steep
     ground; open-access lands include Capoolong Creek WMA, Lockatong WMA, D&R Canal State Park.
  2. Passaic Formation, ~4.5 km W (rep. point 40.34 N, 74.81 W): 0.05 km² steep; includes Baldpate
     Mountain and others.
  3. Passaic Formation, ~20 km NW (40.46 N, 74.78 W): 0.05 km² steep; includes **Sourland Mountain Preserve**.
  Lockatong around Hopewell/Baldpate (rank 11, ~15 km) is the nearest Lockatong with public land.

## Sourland check (reported as found)
- The Sourland ridge itself is mapped as **Diabase** (an intruded igneous sill): not a lake deposit, so
  it does not qualify.
- Lake-deposit polygons flank it: 40 Class A polygons lie within 5 km of the ridge check points
  (Lockatong, Passaic, Passaic gray bed), ranks 3, 4, 9, 10, 11, 13, ... Polygons overlapping Sourland
  Mountain Preserve land: ranks 3, 18, 41, 101, 104, 117, 178.
- So Sourland **emerges as a candidate area for the lake deposits around it**, not for the ridge rock.
  Near the diabase, the Lockatong is baked to hornfels, which changes its appearance; expect that.

## Limitations (show these)
- **Text-rule dependence:** the same formations on the northern-NJ map sheet (`;5`) and in Pennsylvania
  are described without lake wording, so they were not selected, although the Newark Basin lake beds
  continue there. The result maps where the *descriptions* say "lake", not every lake bed.
- Exposure proxy is slope-based at ~20 m; it finds steep ground, not confirmed outcrop.
- PAD-US "open access" does not guarantee trails reach the outcrops.
- Analogy limits: Newark Basin lakes were Earth rift lakes ~200 million years old with life, Earth
  chemistry and burial; they share the *process* (lake sediments, drying cycles, mudcracks) with
  Jezero/Gale, not the setting, chemistry or age. Mudcracks are known from Gale crater (Curiosity).
