# Geology engine geo-2.0 (process-aware regional refinement)

Drafted with AI assistance (Claude, Anthropic), disclosed per the Space Apps AI policy. This builds on `regional_lake_search.py`. It does not replace it. The terrain engine, the global run, `app_bundle.json` (schema 1.0) and GLiM global screening are unchanged.

## 1. What the algorithm computes

For every geological map polygon in a study circle, which is clipped to the circle (Newark basin: 150 km around Princeton; held-out: Hartford basin, 110 km around Hartford):

1. **Evidence profile per map unit** (`geo_v2.evidence_profile`). Every entry records its source.
   - **Lithology** comes from USGS SGMC *structured* lithology (`TOTAL_LITH` and `LITH_RANK`, major or minor). It is not taken from free text.
   - **Environment, emplacement, structure, mineral and alteration** come from a controlled vocabulary on the unit description, with a negation guard. Map-text mineral names are tagged "mapped mention", not measured mineralogy.
   - **Macrostrat corroboration, constrained by place and age.** A Macrostrat unit is used only if its column lies within 150 km of the map unit and its age overlaps the map unit's age (±10 Ma, from period names in SGMC). Same-name units elsewhere are rejected, and the reason is stored. Even when matched, Macrostrat only *corroborates*. A property that only Macrostrat lists goes into `macrostrat_only`, is shown, and never satisfies a core property or a contradiction. Entries marked "inferred" are database defaults and are not used as evidence. A disagreement with the state map is recorded as a conflict.
   - **Rock names that are intrusive by definition** (diabase, dolerite, gabbro, sill, dike) are read from the unit **name**. This catches SGMC coding errors such as Palisade Diabase, which SGMC stores as "Volcanic – Basalt". Descriptions are not used for this, because lava flows are often described as "grading to gabbro in the interior".
   - **Map scale** comes from the source reference and gives the positional uncertainty of contacts.
2. **Measured spatial context** for each polygon (STRtree, EPSG:5070; `make_context`). A "lava neighbour" must be volcanic **and** not identified as an intrusion, so Palisade Diabase (coded basalt) is not one:
   - shared boundary length with lava-flow units and with mapped lake units;
   - share of the polygon's area within 500 m of an intrusive contact (a caution for heat-altered mudstone);
   - whether it lies within 10 km of a mapped lake unit.
3. **Lacustrine inference from sedimentology plus basin context** (`infer_lacustrine`). This is the part that goes beyond keywords. A unit with no lake wording is inferred lacustrine (labelled "inferred", never "recorded") only if all of these hold:
   - fine clastic rock is a **major** lithology;
   - no major carbonate (this excludes tidal-flat dolomites, which also have mudcracks);
   - no marine evidence;
   - at least **2 independent** indicators from {desiccation cracks, cyclic bedding, dark/black laminated mudrock, evaporite (text or structured lithology), aquatic fossils};
   - a continental basin context: it borders lava flows or a mapped lake unit, or lies within 10 km of one.
4. **Property-by-property comparison with a planetary reference** (`compare`). Every reference property carries:
   - a role: core, supporting, contradiction, caution, or earth_only;
   - a Mars evidence type: observed or interpreted;
   - peer-reviewed citations.

   A polygon qualifies only if it meets every core property and has no core contradiction. There is no score, no percentage, and no generated text. Candidates are ordered by the number of supporting properties recorded, then by area.
5. **Four separate field layers**, kept apart:
   - geology (above);
   - exposure: steep ground ≥25° on the 3DEP ~20 m DEM, a proxy for outcrop and not confirmed rock;
   - access: steep ground inside PAD-US "Open access" land;
   - D435: only "steep public ground exists", plus the three largest such patches. What cannot be judged remotely is listed.

Planetary references (`geo_v2.PLANETARY`):

| Reference | Core | Contradiction | Supporting (observed / interpreted on Mars) |
|---|---|---|---|
| MARS-LAKE (Gale, Jezero) | fine clastic; lacustrine | marine | desiccation cracks (Stein 2018), cyclic/laminated bedding (Grotzinger 2015; Rapin 2023), clay (Vaniman 2014), Ca-sulfate (Nachon 2014), igneous neighbour (Farley 2022; Mangold 2021) |
| MARS-SERP (Jezero: Séítah and Máaz kept apart) | olivine-rich ultramafic (Séítah, observed; Liu 2022, Beyssac 2023) | — | olivine (Séítah, observed); Mg-Fe carbonate at low abundance (Séítah, observed; Clavé 2023); Fe-serpentine (**Máaz**, observed; Tosca 2025); serpentinization (Máaz, interpreted; Tosca 2025). H₂ production (Máaz) is **inferred**, not measured, and not compared. Fe- vs Mg-serpentine is listed as not comparable (Tutolo & Tosca 2023) |
| MARS-LAVA (InSight/Jezero floor) | mafic volcanic; extrusive | intrusive | lake neighbour (Mangold 2021). Pillows are tagged **earth_only** and are not counted as Mars support |

## 2. What was executed (14–15 Nov)

Commands (from `engine/`):
```
python3 regional_geology_v2.py SGMC.gdb geology_v2_nj.json                                   # Newark, 150 km, 251 s
python3 regional_geology_v2.py SGMC.gdb geology_v2_hartford.json 41.75 -72.65 110 hartford 15  # held-out, 61 s
python3 tests_geology_v2.py geology_v2_nj.json        # 39 unit checks + 5 output checks, all pass
python3 tests_geology_v2.py geology_v2_hartford.json  # all pass
python3 export_app_json.py MANIFEST TERRAIN GEOLOGY CROSS app_bundle.json STATE --geo2 geology_v2_nj.json:"study area" --geo2 geology_v2_hartford.json:"held-out test"
dart run ../app/geology_v2_check.dart app_bundle.json  # parses the bundle with the app's model
```

### Controls: Newark basin
Labels come from published formation descriptions and were used only for evaluation. Results are by named unit.

| Reference | geo-2.0 | Old rule |
|---|---|---|
| MARS-LAKE (5 lake units vs 13 non-lake units: marine Coastal Plain, Martinsburg turbidites, fluvial Stockton, diabase, basalt) | precision 1.0, recall 1.0 | keyword "lake": 0.67 / 0.40 (Shark River false positive); lake regex: 1.0 / 0.40 |
| MARS-LAVA (2 basalts vs Diabase, Palisade Diabase, Lockatong, serpentinite) | 1.0 / 1.0 | GLiM-style "basic volcanic or plutonic": 0.50 / 1.0 (both diabases selected) |
| MARS-SERP (4 serpentinite/ultramafic units vs 4) | 1.0 / 1.0 | 1.0 / 1.0 (these controls do not discriminate; see the limitations) |

- Towaco, Feltville and Boonton have no lake wording in their descriptions. They are recovered only by the inference, from microlaminated black mudstone, cycles, mudcracks and gypsum/halite pseudomorphs, inside the lava-bounded basin.
- One map-sheet unit is still missed: Pennsylvania's Lockatong (PATRl;3). Its PA description has dark argillite but no mudcracks or cycles, so it shows 1 indicator and needs 2. This is a data limitation, and it is reported rather than tuned away.

### Held-out test: Hartford basin (CT/MA)
Map-unit labels were fixed before the engine was run there. The Connecticut descriptions of East Berlin and Shuttle Meadow do not use the word "lake".

| Run | MARS-LAKE (7 lake units vs 12 others) | MARS-LAVA (6 basalts vs 3 dolerite/diabase + 2 others) |
|---|---|---|
| First run, rules frozen | precision 1.0, recall 0.71 | 1.0 / 1.0 |
| After one bug fix (below) | 1.0 / 1.0 | 1.0 / 1.0 |
| After the review fixes (15 Nov, section 4) | 1.0 / 0.86 | 1.0 / 1.0 |
| Old rules, same labels | keyword: 0.86 / 0.86 (a conglomerate facies selected) | GLiM-style: 0.67 / 1.0 (Buttress, West Rock and MA diabase selected) |

The two first-run misses (Mount Toby, Sugarloaf) exposed a real bug: Macrostrat's "non-marine" matched the MARINE contradiction. Fixing it is post-hoc for Hartford, so the Hartford MARS-LAKE result after the fix is no longer a clean held-out number. The frozen-rules number (0.71 recall) is the honest held-out figure.

### Sourland validation
The Sourland Conservancy geology-hike guide describes Lockatong argillite with fossil mudcracks in the preserve. The check uses the PAD-US preserve polygon, not guessed points. Result: **PASS**. Lockatong polygons NJTRl;2 overlap the preserve, with supporting desiccation, cyclic, laminated and clay evidence. 24% and 100% of their area lies within 500 m of a diabase contact, which is flagged as a caution (heat-altered mudstone). Sourland is not used as an input and is not hardcoded anywhere.

### Candidate counts in the Newark study area (map units / polygons)
- **MARS-LAKE: 12 / 293.** Lockatong, Passaic, Passaic gray beds, Towaco, Feltville, Boonton. Passaic red mudstone is the weakest inference.
- **MARS-SERP: 7 / 149.** PA/MD State Line, NY, NJ and DE serpentinites/ultramafics. Includes NYOopx;3 "Olivine pyroxenite", because SGMC's structured lithology codes it olivine-rich. This is borderline.
- **MARS-LAVA: 6 / 19.** Orange Mountain, Preakness, Hook Mountain, Jonestown.

### One end-to-end planetary → Earth comparison (Lockatong NJTRl;2, Sourland)
| Property | Mars (type, source) | Earth record |
|---|---|---|
| Fine clastic (core) | observed, Grotzinger 2014/2015 | SGMC structured lithology, corroborated by Macrostrat |
| Lacustrine (core) | interpreted, Grotzinger 2015; Mangold 2021 | SGMC description; Macrostrat's "inferred marine" default recorded as a conflict |
| Marine (contradiction) | — | none recorded |
| Desiccation cracks | observed, Stein 2018 | SGMC description |
| Cyclic / laminated | observed, Grotzinger 2015; Rapin 2023 | SGMC description |
| Clay | observed, Vaniman 2014 | mapped mention |
| Contact heating (caution) | not reported at Gale/Jezero lake beds | 24–100% within 500 m of diabase |

## 3. Corrections made during this work (design-time disclosure)
- **Newark iteration 1 → 2.** Allentown Dolomite (marine tidal flat, minor shale, mudcracks) was selected. The fix requires mudrock to be major and excludes major carbonate. "Olivine pyroxenite" had been upgraded from text alone; the fix: no upgrade when the unit name is pyroxenite or hornblendite. These rules were changed after seeing the Newark controls, so the **Newark numbers are training-set numbers**.
- **Control label error.** NJJps;5 is a siltstone interbed carrying the Preakness Basalt name. It was removed from the positives, with the reason stored in `label_fixes`. No rule was changed for it.
- **Reproducibility.** The old-rule comparison used whichever map sheet came first in a set, which is nondeterministic. It now uses all sheets, sorted.
- **Bugs found by the unit tests, not by the region runs:** "deposited in a lake" was not matched; pillows had been counted as Mars support with no Mars source.

## 4. Review corrections (15 Nov)
Each correction has a regression test in `tests_geology_v2.py`: 39 unit checks plus 5 output checks, all passing.

1. **Intrusions are no longer lava neighbours.** `is_lava_unit` requires volcanic lithology and no intrusive identification. The new toy-map test (mudstone next to Palisade Diabase versus mudstone next to Orange Mountain Basalt) fails under the old rule. The Newark and Hartford outputs did not change: no lake candidate's lava-neighbour flag had come only from a diabase.
2. **Macrostrat is constrained and cannot establish core properties** (see §1). Effect: Connecticut's Shuttle Meadow (CTJsm;0) had qualified only because Macrostrat called it lacustrine. Its CT description gives one lake indicator (thin lamination), so it is now **missed**. Hartford MARS-LAKE recall goes from 1.0 to 0.86 with no false positives. Newark is unchanged.
3. **MARS-SERP is corrected.** The serpentinization evidence (Tosca 2025) is from **Máaz**. The olivine cumulate and its carbonate are **Séítah**. Each property now has a `site`, and the reference has a `site_note`: an Earth serpentinite combines the Séítah rock type with the Máaz process, and no single Mars site in these sources shows both. Serpentinization is now "interpreted", H₂ production "inferred" and not compared, and the serpentine mineral "observed". Candidate lists are unchanged; only the evidence labels changed.
4. **App.** `export_app_json.py --geo2 ...` adds the optional `geology_v2` block (SCHEMA.md). All existing fields are identical to an export without the flag. `app/geology_v2.dart` passes `dart analyze` and parses the real bundle; `dart run app/geology_v2_check.dart` prints the Sourland/Lockatong case. A bundle without the block parses to null. `app/geology_v2_widgets.dart` (Material widgets: featured case, unit card, comparison row) was **not compiled**, because no Flutter SDK is available here.

The frozen Hartford result is kept unchanged in `geology_v2_hartford_frozen_run.json` (lake 1.0/0.71, lava 1.0/1.0). The control labels were not edited.

## 5. What remains unimplemented
- **No spectra.** CRISM/OMEGA ↔ ASTER/EMIT comparison is not built. Mineral evidence is map text only.
- **No outcrop-scale evidence.** Grain size, bed thickness and structures at a site are not measured. The FieldKit (D435 and iPhone LiDAR) recorded its first field scans at Sourland Mountain on 2026-11-15; outcrop-scale measurements from scans are the next step.
- **Global generalization is partial.** geo-2.0 needs SGMC-style structured unit descriptions, which exist for the USA only. Outside the USA the engine is still GLiM classes (unchanged). Macrostrat map units could carry it further, but that is not done.
- MARS-SERP controls do not discriminate (old and new rules both score 1.0). A gabbro/pyroxenite negative set exists only as unit tests.
- **Thresholds are not tuned:** ≥2 lake indicators, 10 km basin radius, 500 m contact distance and 25° steepness are fixed by judgement. Sensitivity has not been run for geo-2.0.
- **Nottingham** (a candidate field site considered before the trip; the team went to Sourland Mountain) lies on the Pennsylvania State Line ultramafic unit (PAPZu;0), which qualifies as MARS-SERP. The access layer, however, found no ≥25° ground on the ~20 m DEM inside Nottingham County Park. For that polygon it lists Goat Hill Serpentine Barrens and Octorara Creek Acquisition instead. Small outcrops below 20 m resolution would not show up; that is unverified. No field observation has been made yet.
- The Flutter widgets have not been compiled or placed in the team app. The data model is tested with Dart 3.14.
