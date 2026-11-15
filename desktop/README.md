# Field Station: desktop sensor capture and analysis

The **desktop surface** of the Vancomycin NASA Space Apps 2026 project. It is a field-instrument
workstation: it acquires depth and colour from an Intel RealSense D435, writes reproducible scan bundles,
computes local geometric measurements with units and limitations, imports iPhone LiDAR scans, and pairs
with the phone over Bluetooth for capture control.

**What it is not.** It has no planetary analog discovery, no terrain or geology scoring, and no candidate
ranking. That lives only on the website. A scan can carry a website `candidate_id` / `field_site_id` as an
opaque reference and nothing more. A test (`tests/test_server.py::test_scope_no_analog_discovery_in_desktop`)
fails if the analog engine is ever imported here.

Current state, with what is real versus simulated: **[STATUS.md](STATUS.md)**. Read it before demoing.

## Architecture

```
┌──────────────── Flutter macOS app (desktop/app) ─────────────────┐
│ Devices · Capture · Viewer (Dart point-cloud renderer) · Analysis │
│ Library · Pairing · About                                         │
│   └─ Swift CoreBluetooth peripheral (macos/Runner/MainFlutter-    │
│      Window.swift): radio only, passes bytes to/from Dart         │
└───────────────┬──────────────────────────────────────────────────┘
                │ HTTP + WebSocket on 127.0.0.1, per-launch token
┌───────────────▼──────── Python service (desktop/service) ────────┐
│ server.py      local API (loopback only, token, Host check)       │
│ capture.py     sensor worker in its own PROCESS (USB failure      │
│                cannot crash the UI); recorder; preview            │
│ adapters/      SensorAdapter boundary: realsense · replay ·       │
│                synthetic (fixtures only)                          │
│ pointcloud.py  raw + filtered clouds, colour registration         │
│ metrics.py     plane-fit roughness, tilt, extents, protrusion,    │
│                distance, capture quality, repeatability           │
│ bundle.py      scan bundles, hashes, recovery, export/import      │
│ protocol.py    BLE control protocol (pairing, MACs, acks)         │
└───────────────────────────────────────────────────────────────────┘
```

Why there is a Python service behind the Flutter app: the only RealSense driver that installs on this
Apple Silicon Mac is the `pyrealsense2-macosx` wheel (librealsense 2.56.5). Running it in a separate
process is also what HANDOFF 02 asks for, so that a USB fault can't take the UI down. The UI imports no
vendor SDK; new sensors plug in under `service/fieldstation/adapters/`.

## Setup (once, needs internet)

```bash
cd desktop/service
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13 -m venv .venv   # arm64 Python 3.13
.venv/bin/pip install -r requirements.txt          # exact versions in requirements.lock.txt
cd ../app && ~/development/flutter/bin/flutter build macos --debug
```

On Windows (PowerShell), the same steps with the Windows wheel (`pyrealsense2`, see `requirements-windows.txt`):

```powershell
cd desktop\service
py -3.13 -m venv .venv
.venv\Scripts\pip install -r requirements-windows.txt
cd ..\app; flutter build windows --debug
.\build\windows\x64\runner\Debug\field_station.exe     # the app finds desktop\service and starts it
```

Scans live in `%LOCALAPPDATA%\FieldStation` on Windows. Phone pairing over Bluetooth needs the macOS build;
on Windows, move phone scans as .zip files and import them in Library.

After that, everything works offline: no network calls, and the viewer is pure Dart.

## Run

```bash
desktop/run.sh                 # builds if needed, launches the app; the app starts the service itself
desktop/run.sh --fixtures      # also offers the SYNTHETIC test scene (for rehearsal without a camera)
```

Rehearsal helpers for the app (these only choose the opening view): `FIELDSTATION_UI_SECTION=devices|capture|viewer|analysis|library|pairing|about`,
`FIELDSTATION_UI_SCAN=<scan id>`. To attach the app to a service that is already running:
`FIELDSTATION_URL=http://127.0.0.1:8765 FIELDSTATION_TOKEN=devtoken`.

To run the service on its own (for development, or to drive it with curl):

```bash
cd desktop/service
.venv/bin/python -m fieldstation.server --port 8765 --token devtoken [--fixtures] [--home DIR]
# prints {"event":"ready","port":8765,"token":"devtoken",...}
curl -H 'Authorization: Bearer devtoken' http://127.0.0.1:8765/api/health
```

Headless fallback (same code paths, no GUI). Useful if the UI misbehaves in the field:

```bash
cd desktop/service
.venv/bin/python -m fieldstation.cli devices                                   # list RealSense devices
.venv/bin/python -m fieldstation.cli capture --device realsense:<serial> --frames 30 --title "Boulder A" --feature boulder
.venv/bin/python -m fieldstation.cli roughness <scan_id> --rect 380 200 470 280
.venv/bin/python -m fieldstation.cli repeat <id1> <id2> <id3> --rect 380 200 470 280
.venv/bin/python -m fieldstation.cli export <scan_id>
```

Data lives in `~/Library/Application Support/FieldStation/` (`scans/`, `exports/`). Override it with
`FIELDSTATION_HOME`.

## Hardware gate: do this first with the real camera

```bash
cd desktop/service && .venv/bin/python tools/d435_smoke.py
```

| Exit | Meaning |
|---|---|
| 0 | REAL depth acquired; the JSON log, one raw depth PNG and one colour PNG are written |
| 2 | SDK missing |
| 3 | No device enumerated |
| 4 | Streaming failed |
| 5 | Frames arrived but depth was empty |

Use a USB 3 **data** cable. If the camera shows in *System Information › USB* but not in the tool, record
that, try another port or cable, and as a last resort try `sudo` and note it in the log. If it can't be made
to work, demo with **Replay** of a previously recorded real scan, labelled as replay. Never use a fabricated
capture.

## Tests

```bash
cd desktop/service && .venv/bin/python -m pytest -q
cd desktop/app && ~/development/flutter/bin/flutter test
```

The service tests cover:
- projection matching librealsense's own functions (all supported distortion models, extrinsics convention);
- an exact plane;
- noisy and outlier plane fits;
- box height and length against analytic ground truth;
- metric scale of saved bundles;
- SHA-256 of every file;
- raw read-only files;
- crash recovery;
- export → import round trip;
- duplicate and tampered zips, and path traversal;
- iPhone bundle import with gravity-referenced tilt;
- unplug mid-recording;
- cancel;
- the fixtures gate;
- process isolation and replay provenance;
- the full BLE protocol against a contract-based phone simulator (pairing, lockout, expiry, forged MAC, old seq, duplicate ids, acks/resend);
- the HTTP API end to end (auth, host check, analyses, repeatability, export).

## Scan bundle

The format is shared with the iPhone app. The contract, written by the mobile team, is
[../contracts/SCAN_BUNDLE_V1.md](../contracts/SCAN_BUNDLE_V1.md) at the repository root (the only copy).
The desktop specifics are in [docs/DESKTOP_DATA.md](docs/DESKTOP_DATA.md).

```
scan-<scan_id>/
  scan.json                 envelope; final version lists SHA-256 of every other file
  calibration.json          RAW  depth/colour intrinsics, depth→colour extrinsics, depth scale, device
  frames.jsonl              RAW  per frame: sensor timestamps (+domain), frame numbers, wall-clock UTC, hashes
  frames/depth_NNNNN.png    RAW  16-bit z16 sensor units (× depth_scale_m = metres), 0 = no data   (read-only)
  frames/color_NNNNN.png    RAW  native colour stream                                             (read-only)
  point_cloud_raw.ply       DERIVED: one raw frame back-projected; only depth==0 removed
  point_cloud_filtered.ply  DERIVED: temporal median, range clip, flying-pixel removal (+ optional voxel/outlier)
  depth_filtered.png        DERIVED filtered depth image (same units)
  thumbnail.jpg  metrics.json  log.jsonl  [catalog_draft.json]
```

Coordinate frame `camera_optical_m`: metres, +X right, +Y down, +Z forward, right-handed, with the origin at
the depth imager. PLY headers repeat the units, frame, origin and scan id. Synthetic and replay PLYs say
`NOT A LIVE SENSOR CAPTURE` in the header.

## Measurements (all in `metrics.json` and `scan.json › measurements[]`)

| name | what | caveat shown with it |
|---|---|---|
| `plane_fit_roughness` | RMS of orthogonal residuals from a total-least-squares plane in the ROI, plus `baseline_m` | Depends on baseline. Flagged `at_noise_floor` when below 2× Intel's D400 noise model at that range. Per-frame spread is precision, not accuracy |
| `plane_tilt_from_optical_axis` | Angle of that plane to the camera axis | Relative to the camera, **not** horizontal |
| `plane_tilt_from_horizontal` | Only for frames with measured gravity (iPhone `arkit_session_world`) | For the D435 it is always `not_measured` (no IMU) |
| `extent_in_plane_major/minor` | Visible patch extent | Visible part only |
| `protrusion_above_plane` | p95 height of object points above a robust plane fitted to a user-chosen reference ROI; footprint | Occluded parts aren't measured. Any rover-clearance comparison is a team-defined illustration |
| `distance` | Between two picked points (5×5 median depth each) | Edge picks mix surfaces |
| `median_range` | Distance from the sensor | |
| Repeatability | Same ROI applied to ≥2 scans of a session → mean/std/CV | Empirical spread, not ground-truth accuracy |

Nothing here identifies rock type or mineralogy, and nothing compares to the 400–3200 m planetary
descriptors.

## Phone link

Bluetooth LE carries **control only**. Per the mobile contract ([../contracts/BLE_PROTOCOL_V1.md](../contracts/BLE_PROTOCOL_V1.md)):
- The desktop is the GATT peripheral and advertises service `2ED62242-…`.
- Pairing uses a 6-digit code shown on the desktop, proven with HMAC (the code is never sent).
- Messages are HMAC-signed with `seq` and `id` de-duplication.
- The phone can start or stop D435 capture, and the desktop can start or stop phone capture.

Scans move by zip (AirDrop / Files / USB): *Library › Import*. Imports verify every SHA-256, reject
duplicates, tampering and path traversal, and keep the phone's provenance.

**Phone ↔ desktop interop test.** `mobile/test/interop_field_station_test.dart` starts this service (with the
synthetic camera) and drives it with the phone's own Dart code: pairing at the minimum BLE MTU, commands and acks
both ways, duplicate and forged messages, and zips made exactly as the phone's Export button makes them
(LiDAR-shaped, synthetic and crash-recovered scans). Run it with `cd mobile && flutter test test/interop_field_station_test.dart`
(it skips itself if `desktop/service/.venv` is missing). The radio is not part of it: CoreBluetooth on both
sides is replaced by the same entry points the radios use.

## 60-second offline demo

See [docs/DEMO.md](docs/DEMO.md).
