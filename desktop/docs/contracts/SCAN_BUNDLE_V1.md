# Scan bundle v1 (shared by the iPhone app and the desktop workstation)

Status: written 2026-11-15 by the mobile side. The iPhone app writes exactly this. The desktop app should
read it, and write the same `scan.json` envelope for D435 sessions (with its own `origin` and `capture` values).
Change it only by bumping `schema_version` and saying so here.

A scan is one folder, `scan-<scan_id>/`, and may be shipped as a zip of that folder.

```
scan-<scan_id>/
  scan.json                 envelope (below). Written last; its file list carries SHA-256 for every other file.
  keyframes.jsonl           one JSON object per keyframe (raw evidence: pose, intrinsics, depth stats, trigger)
  keyframes/kf_00001.jpg    RGB from ARFrame.capturedImage, sensor-native orientation + EXIF orientation tag, no GPS in EXIF
  keyframes/kf_00001.f32    ARKit sceneDepth, float32 little-endian, metres, row-major, width x height from keyframes.jsonl
  keyframes/kf_00001.u8     ARKit confidence (0 low, 1 medium, 2 high), uint8, same grid as the depth
  photos/ph_00001.jpg       optional full-resolution photo (ARSession.captureHighResolutionFrame) with its own pose/intrinsics
  point_cloud_fused.ply     DERIVED: voxel-averaged points from all keyframes' depth (recipe in scan.json processing)
  mesh_arkit.ply            DERIVED by ARKit: scene-reconstruction mesh, world frame, faces + ARKit surface class
  thumbnail.jpg             small preview, never the only output
  log.jsonl                 capture events (tracking changes, interruptions, auto-stops, warnings)
  catalog_draft.json        only if the user prepared a contribution; never implies upload or publication
```

Raw versus derived: `keyframes/*` are the closest thing to raw data that Apple's public API gives (ARKit's
processed depth estimate, not LiDAR returns). The fused cloud and the mesh are derived and must never be called raw.
A device without LiDAR writes keyframes with RGB and pose only (`capture.depth_type = "none"`).

## Coordinates and units

- Everything in metres.
- `arkit_session_world`: right-handed, +Y up along measured gravity (ARKit `worldAlignment = .gravity`), origin and
  heading = where the phone was when the session started. Local only: not geodetic, and it can drift.
- Camera frame (ARKit): +X right, +Y up, −Z forward, for the sensor-native landscape image. Pixel (u right, v down).
  Back-projection used everywhere: `Z = d`, `x = (u − cx)·Z/fx`, `y = −(v − cy)·Z/fy`, `z = −Z`, then
  `p_world = camera_to_world · [x, y, z, 1]`.
- Intrinsics are stored for the RGB image size they belong to. Depth intrinsics = RGB intrinsics × (depth_w / image_w).
  Depth pixel (i, j) centre maps to image pixel `((i + 0.5)·s − 0.5, (j + 0.5)·s − 0.5)`, `s = image_w / depth_w`.
- 4×4 matrices are stored column-major as 16 numbers (as `simd_float4x4` columns).
- Latitude/longitude (WGS84) only if the user turned location on for that scan; stored in `scan.json` only, never in
  image EXIF.

## `scan.json`

```json
{
  "schema_version": "1.0",
  "scan_id": "uuid-v4",
  "session_id": "uuid-v4",
  "origin": "iphone_arkit_lidar | iphone_arkit_camera | realsense_d435 | ...",
  "device": {"manufacturer": "Apple", "model": "iPhone 17 Pro", "model_identifier": "iPhone18,1", "os_version": "26.1"},
  "app": {"name": "Field Scan", "version": "0.1.0", "pipeline_version": "fs-1.0"},
  "captured_at_utc": {"start": "...Z", "end": "...Z"},
  "capture": {
    "depth_type": "sceneDepth | none", "depth_units": "m", "smoothed_depth_used": false,
    "confidence_present": true, "mesh_present": true, "tracking_poses_present": true,
    "keyframes": 120, "photos": 40, "trigger": {"mode": "movement", "move_m": 0.1, "turn_deg": 10, "...": "..."},
    "rig_mode": false
  },
  "coordinate_frame": {"name": "arkit_session_world", "units": "m", "handedness": "right", "up": "+Y gravity", "...": "..."},
  "location": {"sharing": "hidden | coarse | exact", "collected": false, "latitude": null, "longitude": null, "uncertainty_m": null},
  "field_site_id": null, "candidate_id": null, "candidate_run_id": null,
  "observation": {"title": "", "feature_type": "rock_face | boulder | boulder_field | outcrop | ground | other",
                  "notes": "", "claims": [{"text": "", "kind": "observed | interpreted | user_reported"}]},
  "quality": {"...": "measured counts and fractions only; see below"},
  "measurements": [],
  "files": [{"path": "point_cloud_fused.ply", "role": "derived_point_cloud", "mime": "application/x-ply",
             "bytes": 0, "sha256": "...", "lineage": "fused from keyframes/*.f32 (see processing)"}],
  "processing": {"pipeline_version": "fs-1.0", "operations": [{"op": "voxel_fuse", "params": {}}]},
  "publication": {"status": "local_private", "license": null, "consent_obtained": false},
  "limitations": ["ARKit estimated geometry; not mineral identification", "..."]
}
```

`origin` for a D435 session: `realsense_d435`; `coordinate_frame.name`: `camera_optical_m` or whatever the desktop
defines, documented the same way. `quality` contains only counted or measured values (valid-depth fraction,
confidence-level fractions, keyframe count, tracking-limited time, mesh size, points). No invented accuracy figure.

## Measurement record (`measurements[]`)

```json
{"id": "uuid", "label": "boulder A, upper face", "name": "plane_fit_roughness",
 "value": 0.0042, "unit": "m", "status": "measured",
 "method": "total least squares plane (PCA) on fused points within radius_m of centre; RMS of orthogonal residuals",
 "source_artifact": "point_cloud_fused.ply", "frame": "arkit_session_world",
 "roi": {"kind": "sphere", "center": [0, 0, 0], "radius_m": 0.15, "n_points": 1800},
 "extra": {"tilt_from_horizontal_deg": 61.2, "residual_p95_m": 0.009},
 "uncertainty": {"method": "none from a single scan; compare repeat scans with the same label", "n": 1},
 "validity": ["partial view", "voxel size 0.01 m smooths sub-centimetre relief", "..."],
 "created_utc": "...Z"}
```

Names in use: `distance` (two picked points), `plane_fit_roughness`, `plane_tilt_from_horizontal`
(gravity from ARKit; trusted only while tracking was normal), `extent_vertical`, `extent_horizontal_major`,
`extent_horizontal_minor`, `protrusion_above_plane`.

### Agreed with the desktop (Field Station), 2026-11-15

- Top-level `status`: `recording | processing | complete | incomplete | imported`, plus `status_reason`,
  `is_real_sensor`, `replay_of`, `platform`, `operator`. The phone writes `complete`, or `incomplete` for a capture
  recovered after the app was closed mid-scan.
- `origin` may also be `replay` or `synthetic_fixture` (clearly labelled non-live sources; `is_real_sensor: false`).
- `capture.frames_recorded`; D435 sessions also `capture.depth_scale_m`.
- `files[]` also carry `kind` (`raw` | `derived`) and `coordinate_frame`.
- D435 frame: `camera_optical_m` (+X right, +Y down, +Z forward, metres, origin at the depth imager). D435 bundles use
  `calibration.json`, `frames.jsonl`, `frames/depth_NNNNN.png` (z16 × `depth_scale_m`), `frames/color_NNNNN.png`,
  `point_cloud_raw.ply` (role `raw_point_cloud`, one frame), `point_cloud_filtered.ply` (role `derived_point_cloud`),
  `metrics.json`.
- Extra measurement names for sensors without gravity: `plane_tilt_from_optical_axis`, `extent_in_plane_major`,
  `extent_in_plane_minor`, `median_range`. A D435 scan emits `plane_tilt_from_horizontal` with status `not_measured`.
- ROI kinds: `sphere`, `points` (phone), `pixel_rect` (`rect_px` = [u0, v0, u1, v1] in the depth image, desktop),
  `all_points`.
- PLY readers must read vertex properties by name: the phone's fused cloud has `confidence` (uchar) and `samples` (ushort)
  after the colour.

## `catalog_draft.json` (CatalogEntry, local only)

`status`: `draft_local` → (`uploading` → `private_cloud_draft` → `pending_review` → `published` | `rejected` | `removed`).
Only `draft_local` exists in this build: there is no catalog service yet. Uploading never equals publishing.
