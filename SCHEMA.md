# App data schema v1.0 (`app_bundle.json`)

One file, produced by `engine/export_app_json.py` from the run outputs. The Flutter app should read only
this file (plus images it references). Every sentence-like field is built from fixed templates or the
fixed outcome vocabulary below — never generated prose.

```text
schema_version            "1.0"
outcome_vocabulary        ["inside middle half", "inside 10-90% range", "outside range", "not measured", "not comparable"]
run                       provenance of the terrain run
  manifest_describe_as    exact coverage statement to show (e.g. "partial: 19295 of 19433 tiles ...")
  created_utc, tiles (by status), windows (evaluated / excluded), software, parameters, datasets,
  known_coverage_limits   list of strings (show on the coverage screen)
geology_run               thresholds {G1_min_mapped, G2_min_exposed, G4_min_partner, min_mapped_land}, emit status, source
references[]              one per planetary reference
  id                      M-CR | M-SR | M-DG | M-MA | MZ-FLAT | MZ-STEEP | R-JZ | R-IS | R-AE
  body                    Moon | Mars
  ref_type                "site box (...)" | "zone (team-defined terrain context)" | "process (rock-type pathway only)"
  description, exploration_purpose
  baselines_m, grid_m
  slope_bands_deg         {baseline: {p10, p25, p50, p75, p90}}   -> reference-band strips
  connectivity_curve      {threshold_deg: share}                 -> diagnostic only, not traversability
  yardstick               {kind, p90 or median/p90, caveat}       -> "closer than X" statements
  not_comparable          list of properties Earth cannot reproduce for this body
  warnings                e.g. Shackleton heterogeneity
candidates[]
  id                      T-<ref>-NNN (terrain) | G-<ref>-NNN (rock type)
  pathway                 "terrain" | "rock type"
  reference, rank_rule, position {lat, lon}
  footprint               terrain: 10 km square, local azimuthal-equidistant, 5 km step
                          rock type: 0.1 deg x 0.1/cos(lat) deg box (~11.1 km), half-box step
  terrain only:
    pareto_front, distances {worst_scale_slope_W1_deg, worst_scale_log10_roughness_W1,
                             connectivity_distance, by_baseline_deg}
    inside_yardstick      true | false | null
    properties[]          {property, unit, value, reference_band, outcome}
    land_cover            {valid_fraction, bare_fraction, snow_ice_fraction}
  rock type only:
    tier                  G1 | G2 | G4      (G3 spectral: "not evaluated")
    evidence_ladder       {G1_mapped, G2_exposed, G3_spectral, G4_colocated_partner}
    values                {mapped_target_fraction, exposed_target_fraction, exposed_target_area_km2, partner_fraction}
  cross_pathway           the OTHER pathway's measurement with its own footprint, or {"status": "not measured ..."}
  evidence                {supporting[], contradicting[], unmeasured[], not_comparable[]}   (fixed strings)
coverage                  {tile: window count or skip reason}  -> coverage map
regional_state_geology    output of state_geology_targets.py (Plainsboro 150 km), or null
limitations               fixed list shown on an "About the method" screen
```

Display rules: show distances in their own units; never sum them or turn them into percentages; show
"not measured" explicitly; show `manifest_describe_as` verbatim wherever the word "global" would appear.

## Optional block `geology_v2` (added 15 Nov; `schema_version` stays "1.0")

This block appears only when the bundle is exported with `--geo2`:
```
python3 export_app_json.py MANIFEST TERRAIN GEOLOGY CROSS OUT [STATE] --geo2 geology_v2_nj.json:"study area" --geo2 geology_v2_hartford.json:"held-out test"
```
Every other field is byte-for-byte what the exporter writes without the flag, so a consumer that ignores unknown keys is unaffected. Dart model: `app/geology_v2.dart`, where `GeologyV2Block.fromBundle(json)` returns null when the block is absent. Widgets: `app/geology_v2_widgets.dart` (not compiled here).

```
geology_v2.block_version   "geo-2.0-app-1"
regions[]       {id, role ("study area" | "held-out test"), centre, radius_km, created, n_polygons, n_units, datasets}
references[]    {id, name, site_note, locations[], not_comparable[],
                 properties[] {code, role, role_label, mars_site, evidence_type (observed|interpreted|inferred|not_applicable), statement, citations[]}}
featured[]      independent validations only (currently: Lockatong in Sourland Mountain Preserve)
                {id, region, reference, title, outcome, unit_name, unit_link, preserve_area_km2, polygon_area_km2,
                 share_within_500m_of_intrusive_contact, units_mapped_in_preserve[], conflicts[], note, comparison[]}
units[]         one card per (region, reference, map unit)
                {id, region, reference, unit_name, unit_link, state, unit_age, polygons, area_km2, nearest_distance_km, nearest_point,
                 how_core_was_established[], supporting_recorded[], supporting_total, conflicts[], spatial_context,
                 macrostrat {name_matches, accepted, rejected[]}, map_source, steep_ground_km2, public_steep_ground_km2,
                 public_lands_with_steep_ground[], look_here[], exposure_note, comparison[], not_comparable[], unmeasured[]}
comparison[]    {property, role, role_label, mars_site, mars_evidence_type, mars_statement, citations[],
                 earth_status, earth_source, earth_text}
controls[]      {region, reference, method, precision, recall, false_positives[], missed[]}
citations       {key: full reference}
limitations[]   strings
```
Display rules: put `role_label` and `mars_evidence_type` next to every property. Show `earth_status` verbatim; "inferred" means derived from sedimentology plus basin context. Never show a score or a match percentage, because none exists. `supporting_recorded` of `supporting_total` is a count, not a score.
