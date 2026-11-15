# Field Station desktop: status (updated continuously)

Branch `desktop`, worktree `~/nasaspaceapps-desktop`. Host used for everything below:
**MacBook Air (Apple M4, 16 GB), macOS 26.6.2**. Note that HANDOFF 01 says the team laptop is an M5; this was
built and tested on an M4.

Labels: **REAL** = verified with real hardware or data. **TESTED** = automated tests pass on this Mac.
**SIMULATED** = verified only against a simulator or fixture. **BUILT, UNTESTED** = code exists, not
exercised. **PLANNED** = not built.

## Hardware gate (HANDOFF 02 §2)

| Check | State | Evidence |
|---|---|---|
| librealsense on this Mac | `pyrealsense2-macosx` 2.56.5 imports (arm64, Python 3.13) | `service/requirements.lock.txt` |
| D435 enumerated / real depth frame | **NOT YET: no camera was attached** (2026-11-15 02:40 ET; `tools/d435_smoke.py` exit 3, "no RealSense device enumerated") | log in `~/Library/Application Support/FieldStation/hardware_smoke/` once run on the real camera |

Until the smoke test returns exit 0 with the real camera, **no live D435 capture may be claimed**. The
fallbacks are Replay of a real recording (labelled REPLAY), and the SYNTHETIC scene for rehearsal only
(labelled everywhere).

## Feature status

| Area | State | Notes |
|---|---|---|
| Sensor adapter boundary (`SensorAdapter`, typed `Frame`/`Calibration`) | TESTED | realsense / replay / synthetic |
| RealSense adapter (streams, intrinsics, extrinsics, depth scale, baseline, options, timestamps) | BUILT, UNTESTED on hardware | Discovery runs in a child process and reports errors verbatim |
| Sensor in a separate process; unplug mid-recording → `incomplete`, earlier scans untouched | TESTED (with a simulated unplug) | `test_capture.py` |
| Projection / colour registration | TESTED vs librealsense's own functions | float32-level agreement |
| Raw + filtered point clouds, binary PLY with units and provenance | TESTED | Metre scale checked against an analytic box |
| Roughness / tilt / extents / protrusion / distance / repeatability | TESTED on analytic fixtures | Box height within 1 cm, length within 1 cm |
| Noise-floor flag (Intel D400 RMS model) | TESTED | Flat board → `at_noise_floor` |
| Bundle: hashes, read-only raw, atomic writes, crash recovery | TESTED | |
| Export zip / import zip (iPhone or desktop) with SHA verification | TESTED with a contract-shaped fixture | Not yet with a real iPhone bundle |
| Local catalog draft (no upload; there is no catalog service) | TESTED | `draft_local` only |
| Local API (loopback, token, Host check) | TESTED | |
| Headless CLI (`python -m fieldstation.cli`) | TESTED manually (devices, capture via the worker process, roughness) | Field fallback if the GUI fails |
| BLE protocol (pairing, MAC, seq/id, acks, resend) | TESTED against the mobile team's `BLE_TEST_VECTORS.json` (byte-identical proofs, key, MAC) + SIMULATED end-to-end with `phone_sim.py` | Not yet against the real phone app |
| BLE radio (Swift CoreBluetooth peripheral in the Flutter runner) | BUILT, UNTESTED | Needs a phone; first run triggers the macOS Bluetooth permission prompt |
| Flutter macOS UI (Devices, Capture, Viewer, Analysis, Library, Pairing, About) | TESTED on screen with the SYNTHETIC scene | `flutter analyze` clean, 9/9 `flutter test`, `flutter build macos` OK. Driven in the app: open device → live preview (26.7 fps) → record → 3D viewer (132k of 397k points, orbit, back-to-front sort) → sphere-ROI roughness. Analysis rectangle/protrusion/distance and export checked through the same API calls (box height 0.152 m vs 0.150 m true), not by dragging in the app |
| UI paths never exercised | BUILT, UNTESTED | Import file picker, Reveal in Finder, edit notes, reprocess, catalog-draft form, phone-refusal error card (no phone yet), Mesh mode in the viewer |
| App self-starts the Python service and stops it on quit | TESTED | Window 1430x840, title "Field Station" |
| Bounded grid mesh (`mesh_grid.ply`) + GLB (`mesh_grid.glb`) | TESTED (structure, indices, frame conversion) | Only neighbouring measured pixels are joined; no hole filling; labelled DERIVED. GLB loads in trimesh (99k vertices, 197k faces, vertex colours) |
| Multi-view registration / TSDF / fusion with ARKit | PLANNED (P2) | Not implied anywhere in the UI |
| Wi-Fi bulk transfer | Not in this build (the mobile contract reserves `transfer_offer`) | Zip via AirDrop/Files/USB instead |

## Blockers / needs from the team

1. **Plug the D435 into this Mac** with a USB 3 data cable and run `tools/d435_smoke.py`. Then record one
   real scan of a flat surface and one of an object with known dimensions (ruler), per HANDOFF 02 §9.
2. A real iPhone scan zip from the mobile app, to test the import path end to end.
3. A phone build of the mobile app, to test BLE pairing for real.

## Changelog

- 2026-11-15 02:15 ET: worktree `desktop` created from `main` (fe10c0d).
- 02:20: Python 3.13 arm64 venv; pyrealsense2-macosx 2.56.5 imports; three.js briefly vendored, then removed (the UI is Flutter).
- 02:25: the user asked for the UI in Flutter + Dart. Restructured into `app/` (Flutter) and `service/` (Python sensor/analysis).
- 02:30: adopted the mobile team's SCAN_BUNDLE_V1 / BLE_PROTOCOL_V1 contracts (folder `scan-<id>/scan.json`,
  measurement record fields, GATT UUIDs, HMAC pairing). Replied with the desktop additions.
- 02:40: service core done; 32 tests pass; hardware smoke test run (no camera attached, exit 3).
- 02:50: grid mesh + GLB export added to processing; frame PNGs use fast compression (~8 ms/frame); 33 tests pass.
  Docs: README, docs/DESKTOP_DATA.md, docs/DEMO.md, contract snapshot in docs/contracts/.
- 02:55: headless CLI added (capture/roughness/repeat/export/import); GLB checked with trimesh.
- 03:00: mobile team confirmed all six BLE encoding choices and published test vectors; desktop matches them byte-for-byte
  (`test_mobile_team_vectors`, `test_desktop_accepts_mobile_vector_pairing`). The mobile app now writes the desktop's
  envelope additions. PLY reader confirmed to read the phone's extra vertex properties by name. 36 tests pass.
- 03:05: contract change from mobile: a re-sent command keeps its id with a NEW seq; the desktop now re-acks it with ok=true, error "duplicate: already handled" (a failed original is repeated as failed) and never runs it twice. Contracts re-copied.
- 03:10: re-copied contracts after mobile wrote the duplicate-ack rule into BLE_PROTOCOL_V1.md (both sides now behave identically).
- 03:30: Flutter UI finished (built by a sub-agent, reviewed here from screenshots); runner fixed to open at 1430x840 titled
  "Field Station"; app self-launch verified (service starts with the app, gone after quit). Known cosmetic: moiré on the
  synthetic checkerboard at 2.5 px point size when seen head-on.
