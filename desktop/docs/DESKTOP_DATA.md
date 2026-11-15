# Desktop data details (on top of SCAN_BUNDLE_V1)

The shared envelope and the measurement-record fields are defined by the mobile team in
[contracts/SCAN_BUNDLE_V1.md](contracts/SCAN_BUNDLE_V1.md). The desktop writes exactly those field names.
This page lists only what the desktop adds or fixes for D435 sessions. These additions were sent to the
mobile session on 2026-11-15.

## Envelope values for desktop scans

| Field | Desktop value |
|---|---|
| `origin` | `realsense_d435` (live camera), `replay` (re-recorded from a saved scan), `synthetic_fixture` (ray-cast test scene) |
| `is_real_sensor` | `true` only for `realsense_d435` |
| `replay_of` | `{scan_id, origin}` of the source when `origin = replay` |
| `status` / `status_reason` | `recording` → `processing` → `complete`, or `incomplete` (device lost, cancel, crash recovery), or `imported` |
| `capture.modality` | `active_ir_stereo_depth` |
| `capture.depth_type` | `stereo_z16`; `depth_scale_m` from the device; `frames_requested`, `frames_recorded`, `frames_skipped_between_recorded` (gaps in sensor frame numbers) |
| `capture.gravity_reference_present` | `false` (the D435 has no IMU) |
| `coordinate_frame` | `{"name":"camera_optical_m","units":"m","axes":"+X right, +Y down, +Z forward (out of the lens)","handedness":"right","origin":"optical centre of the depth imager"}` |
| `location` | always `sharing: hidden`, `collected: false` (no GPS on the desktop; never added automatically) |
| `device` | model, firmware, USB type, `serial_sha256_8` (the serial itself appears only in calibration.json) |
| `operator.started_by` | `desktop_user` or `paired_phone:<name>` |
| `files[]` | shared fields plus `kind` (`raw` / `derived`) and `coordinate_frame` |
| `desktop_import` | added to imported envelopes: time, number of SHA-256-verified files, source zip name |

## Measurement names added by the desktop

`plane_tilt_from_optical_axis`, `extent_in_plane_major`, `extent_in_plane_minor`, `median_range`.
D435 scans always carry `plane_tilt_from_horizontal` with `status: "not_measured"`.

ROI kinds: `sphere` (shared), `pixel_rect` (`rect_px = [u0, v0, u1, v1]` in depth-image pixels, end-exclusive)
and `points` (distance). The `status` value `at_noise_floor` means the plane-fit residual is under 2× the
expected sensor noise. Intel's model is `rms = z² · 0.08 / (fx · baseline)`, a typical figure and not
measured for this unit.

For imported iPhone scans (`arkit_session_world`, +Y = gravity up), the desktop analyses
`point_cloud_fused.ply` with sphere ROIs and does compute `plane_tilt_from_horizontal`. The validity note
says gravity comes from ARKit tracking.

## calibration.json

```json
{
  "schema_version": "1.0",
  "depth_scale_m": 0.001,
  "depth_intrinsics":  {"width":848,"height":480,"fx":..,"fy":..,"ppx":..,"ppy":..,"model":"brown_conrady","coeffs":[5]},
  "color_intrinsics":  {...},
  "depth_to_color_extrinsics": {"rotation_row_major":[[..],[..],[..]],"translation_m":[..]},
  "depth_fps": 30, "color_fps": 30, "depth_format":"z16", "color_format":"rgb8",
  "alignment": "unaligned_native_streams",
  "stereo_baseline_m": 0.050, "baseline_source": "device_option_stereo_baseline | nominal_D435_spec_50mm",
  "device": {"name","serial","firmware","usb_type","product_line","sdk"},
  "sensor_options": {"emitter_enabled","laser_power","enable_auto_exposure","exposure","gain","visual_preset","depth_units"},
  "source": "sdk | replay | synthetic"
}
```

Note that the extrinsics rotation is stored **row-major** (`p_color = R · p_depth + t`); librealsense's own
array is column-major, and the conversion is tested against `rs2_transform_point_to_point`. Pixel
convention: pixel centres at integer coordinates, as in librealsense's `rs2_deproject_pixel_to_point`. The
iPhone contract uses `+0.5` centres, so each bundle states its own convention.

## Processing recipe (scan.json › processing)

1. `raw_point_cloud`: middle recorded frame, every pixel with depth > 0, no other filtering.
2. `temporal_median` over all frames (a pixel needs ≥50 % valid samples).
3. `range_clip` 0.2–6.0 m.
4. `flying_pixel_removal`: drop a pixel if a 4-neighbour differs by more than max(1 cm, 3 % of z).
5. `statistical_outlier_removal`: **off** unless requested.
6. `voxel_downsample`: **off** unless requested.
7. `color_registration`: project into the colour camera with the recorded extrinsics; nearest pixel;
   z-buffer occlusion test. Points without valid colour are grey with `color_valid = 0` in the PLY.

Every parameter is stored, reprocessing never touches raw files, and each run is appended to
`processing.runs`.
