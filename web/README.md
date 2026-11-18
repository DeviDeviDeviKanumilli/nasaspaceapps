# Data for the website

`app_bundle.json`: the file the website (`../website/`, React + CesiumJS) reads (schema 1.0; see ../SCHEMA.md).
- `candidates`: global terrain results (1,464,296 windows; 19,295 of 19,433 1° tiles processed, 138 missing; no tiles south of 60°S), plus the rock-type records.
- `geology_v2`: process-aware geology results. `featured[0]` is the Sourland / Lockatong validation (PASS)
  with the full Mars-vs-Earth property comparison. Parse with ../app/geology_v2.dart.

Sourland is a geology result, not a terrain result: its 1-degree tile (N40 W075) is almost entirely forest,
cropland and built-up land, so the terrain engine masks it, by design.
