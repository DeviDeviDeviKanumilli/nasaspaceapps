# Field Station desktop: status (updated continuously)

Merged into `main` (PR #2, 2026-11-15); the shared contracts are in `/contracts` at the repository root.
Host used for everything below:
**MacBook Air (Apple M4, 16 GB), macOS 26.6.2**. Note that HANDOFF 01 says the team laptop is an M5; this was
built and tested on an M4.

Labels: **REAL** = verified with real hardware or data. **TESTED** = automated tests pass on this Mac.
**SIMULATED** = verified only against a simulator or fixture. **BUILT, UNTESTED** = code exists, not
exercised. **PLANNED** = not built.

## Hardware gate (HANDOFF 02 §2)

| Check | State | Evidence |
|---|---|---|
| librealsense on this Mac | `pyrealsense2-macosx` 2.56.5 imports (arm64, Python 3.13) | `service/requirements.lock.txt` |
| D435 enumerated / real depth frame | **REAL: tested live in the field at Sourland Mountain, 2026-11-15.** Depth and colour streams both worked and the team recorded a field scan. (Earlier, 2026-11-15 02:40 ET, before the camera was attached: `tools/d435_smoke.py` exit 3, "no RealSense device enumerated".) | Team field test on 2026-11-15 |

The D435 has now been used live with real hardware (Sourland Mountain, 2026-11-15). Replay of a real
recording (labelled REPLAY) and the SYNTHETIC scene (rehearsal only, labelled everywhere) remain available
as fallbacks.

## Feature status

| Area | State | Notes |
|---|---|---|
| Sensor adapter boundary (`SensorAdapter`, typed `Frame`/`Calibration`) | TESTED | realsense / replay / synthetic |
| RealSense adapter (streams, intrinsics, extrinsics, depth scale, baseline, options, timestamps) | REAL (field-tested on the D435 at Sourland Mountain, 2026-11-15: depth and colour streams worked, field scan recorded) | Discovery runs in a child process and reports errors verbatim |
| Sensor in a separate process; unplug mid-recording → `incomplete`, earlier scans untouched | TESTED (with a simulated unplug) | `test_capture.py` |
| Projection / colour registration | TESTED vs librealsense's own functions | float32-level agreement |
| Raw + filtered point clouds, binary PLY with units and provenance | TESTED | Metre scale checked against an analytic box |
| Roughness / tilt / extents / protrusion / distance / repeatability | TESTED on analytic fixtures | Box height within 1 cm, length within 1 cm |
| Noise-floor flag (Intel D400 RMS model) | TESTED | Flat board → `at_noise_floor` |
| Bundle: hashes, read-only raw, atomic writes, crash recovery | TESTED | |
| Export zip / import zip (iPhone or desktop) with SHA verification | TESTED with zips made by the phone app's own code (`mobile/test/interop_field_station_test.dart`: LiDAR-shaped, synthetic and crash-recovered scans; duplicate and tampered zips refused; roughness and gravity tilt measured after import) | Not yet with a zip from a real iPhone capture |
| Local catalog draft (no upload; there is no catalog service) | TESTED | `draft_local` only. A draft the phone made is read correctly and its fields (location precision, people/property answers) are kept when edited here; licences are SPDX ids like the phone's |
| Local API (loopback, token, Host check) | TESTED | |
| Headless CLI (`python -m fieldstation.cli`) | TESTED manually (devices, capture via the worker process, roughness) | Field fallback if the GUI fails |
| BLE protocol (pairing, MAC, seq/id, acks, resend) | TESTED against the mobile team's `BLE_TEST_VECTORS.json` (byte-identical proofs, key, MAC), and against the phone app's own Dart protocol code through the service's HTTP/WebSocket path (`mobile/test/interop_field_station_test.dart`, minimum MTU) | Radio not involved: never over the air with a real phone |
| BLE radio (Swift CoreBluetooth peripheral in the Flutter runner) | BUILT, UNTESTED | Needs a phone; first run triggers the macOS Bluetooth permission prompt |
| Flutter macOS UI (Devices, Capture, Viewer, Analysis, Library, Pairing, About) | TESTED on screen with the SYNTHETIC scene | `flutter analyze` clean, 9/9 `flutter test`, `flutter build macos` OK. Driven in the app: open device → live preview (26.7 fps) → record → 3D viewer (132k of 397k points, orbit, back-to-front sort) → sphere-ROI roughness. Analysis rectangle/protrusion/distance and export checked through the same API calls (box height 0.152 m vs 0.150 m true), not by dragging in the app |
| Desktop app with the real D435 | REAL: field-tested at Sourland Mountain, 2026-11-15 | The desktop UI ran on the computer with the D435 attached. Live depth and colour worked, and a scan was recorded and shown to the local judges |
| App self-starts the Python service and stops it on quit | TESTED | Window 1430x840, title "Field Station" |
| Bounded grid mesh (`mesh_grid.ply`) + GLB (`mesh_grid.glb`) | TESTED (structure, indices, frame conversion) | Only neighbouring measured pixels are joined; no hole filling; labelled DERIVED. GLB loads in trimesh (99k vertices, 197k faces, vertex colours) |
| Redesigned UI (light survey-plate style, viridis depth figures with colour bars, booktabs result tables) | TESTED on Windows 11 with the SYNTHETIC scene. **macOS build not re-run since the redesign** | `flutter analyze` clean, 9/9 `flutter test`, 37/37 service tests, `flutter build windows --debug` OK, every screen checked on screen (Capture only in Colour mode). Run `flutter build macos` and click through on the Mac before demoing |
| Windows build (runner, service from `.venv\Scripts\python.exe`, data in `%LOCALAPPDATA%\FieldStation`, service watches the app's process with `--parent-pid` and exits when it is gone) | TESTED on Windows with SYNTHETIC: app opened from Explorer starts its own service, service gone 5 s after force-killing the app, no console window. D435 on Windows: UNTESTED | `service/requirements-windows.txt` (`pyrealsense2` instead of `pyrealsense2-macosx`) |
| Phone pairing on Windows | Not available by design | The Pairing screen says so; scans still move by zip import |
| BLE protocol through the app's own path (`POST /api/ble/rx` in, `ble_tx` WebSocket events out) | SIMULATED end-to-end, 10/10 checks | `phone_sim.py` driven over HTTP + WebSocket against a running service: pairing, wrong code refused, phone→desktop start/stop acked, duplicate re-acked, desktop→phone command with valid MAC, phone ack recorded, unpaired sender refused. No radio, no real phone |
| Depth display colour map | Changed from a jet-like map to viridis; pixels with no depth are white (were black) | Display only: raw and filtered depth PNGs are unchanged. `thumbnail.jpg` of scans recorded earlier keeps the old map until reprocessed |
| Multi-view registration / TSDF / fusion with ARKit | PLANNED (P2) | Not implied anywhere in the UI |
| Wi-Fi bulk transfer | Not in this build (the mobile contract reserves `transfer_offer`) | Zip via AirDrop/Files/USB instead |

## Blockers / needs from the team

1. ~~Plug the D435 into this Mac and record a real scan.~~ Done: the D435 was used live at Sourland Mountain on
   2026-11-15 (depth and colour worked; a field scan was recorded).
2. A real iPhone scan zip from the mobile app, to test the import path end to end.
3. A phone build of the mobile app, to test BLE pairing for real.

## Changelog

- 2026-11-17: status updated from the team's report of the Sourland Mountain field test on 2026-11-15. The D435
  ran live in the field with depth and colour streams working, and a field scan was recorded. The hardware gate, the desktop UI with the D435
  and RealSense adapter are now marked REAL. Only documentation changed in this update.
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
- 04:55: UI redesign + Windows support (commit 6249c86), built and tested on a Windows 11 PC, not on the Mac. Viridis depth
  figures with colour bars (`GET /api/scans/{id}/depth_figure.png`), Public Sans font bundled (OFL), Windows runner and launcher,
  `--exit-with-stdin` so the service never outlives the app. 37 service tests, 9 flutter tests.
- 05:30: audit of that commit (own checks + an independent code review). Fixed:
  - Windows: the app's own service quit about 1 s after start whenever Devices scanned for cameras (stdin EOF seen while
    the app was running). `--exit-with-stdin` replaced by `--parent-pid` (the service waits on the app's process handle).
  - Camera release on stop: the sensor worker is now closed in the server's lifespan shutdown. Before, SIGTERM from the
    app (macOS) made uvicorn re-raise the signal and skip `finally: ctl.close()`, which could leave the worker holding the D435.
  - Analysis kept the previous scan's depth range and valid-pixel % when the next scan's figure failed or was loading.
  - Analysis offered `thumbnail.jpg` as a "colour frame" when a scan had none; now only a recorded colour frame is offered.
  - Wording: colour bars say depth z (along the camera axis), not range; Capture says Live / Replayed / Synthetic frames;
    Viewer says distance from the session origin for iPhone scans; replay sources are named "replay of ...".
  - Layout: replay table buttons clipped when a replay was open; footer could overflow with a long scan title.
  - File picker: Windows paths with non-ASCII characters came back garbled (now UTF-8); macOS filter again includes
    `public.zip-archive`.
  - Bluetooth channel is no longer touched on non-macOS builds. BLE protocol re-checked end to end through the
    HTTP/WebSocket path the Dart bridge uses (10/10). Still no radio test (needs the Mac and a phone).
  - Team rule "disclose AI use in every script": AI-assistance header added to all desktop source files.
  - DEMO.md button names updated to the new UI. 39 service tests (2 new: parent watch, shutdown releases the sensor), 9 flutter tests.
- 2026-11-15 ~06:00 ET, after the merge into `main` (integration check across desktop, mobile, contracts and web):
  - New `mobile/test/interop_field_station_test.dart`: the phone's real Dart code against this service (started as a subprocess
    with the synthetic camera). Pairing at MTU 23 with a wrong code first, hello, phone→desktop D435 start acked with a
    scan id and followed by capture_state/capture_complete, duplicate re-acked without a second recording, forged MAC
    dropped, desktop→phone command refused by the phone with its error shown verbatim, phone capture_state received;
    zips made with the phone's Export call import with every SHA-256 verified. 2/2 pass.
  - Fixed: a scan the phone recovers after a crash was refused on import (`missing coordinate_frame`). The desktop now
    imports it with an explicit `unknown` frame; the phone now writes the frame for recovered scans too.
  - Fixed: desktop catalog-draft form misread phone drafts (consent/author unticked, licence blank) and saving would have
    replaced the phone's location and people/property answers. It now reads both shapes and keeps the phone's fields.
  - Fixed: written BLE chunks were forwarded to the service as concurrent HTTP requests, so a multi-chunk message could
    arrive out of order. They are now forwarded one at a time (as notifications already were).
  - Fixed (phone): the phone re-reads the desktop nonce before pairing, so pressing "Pair a phone" again on the Mac
    no longer looks like a wrong code.
  - `desktop/docs/contracts/` removed; `/contracts` at the repository root is the only copy, and the desktop tests read it there.
