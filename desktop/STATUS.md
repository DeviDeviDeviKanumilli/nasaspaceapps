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
| D435 enumerated / real depth frame | **PASS WITH SUDO** (2026-11-15 08:26 ET): Intel RealSense D435, serial 832112072809, firmware 5.11.1.100, **USB 2.1** link. `desktop/d435.sh`: as the normal user exit 3 (`failed to set power state`); with sudo exit 0, `usb2_fallback` 640x480, 30 frames at 14.97 fps measured, mean valid depth 0.327, median 1.08–1.83 m, fx 384.9 px, depth scale 1 mm. Field Station must run its service as root on this Mac (`desktop/d435.sh run`); live capture there TESTED (scans 800a7322, c8c21460 COMPLETE; reopen 8/8). Full-resolution profiles: UNTESTED (need a USB 3 link) | `hardware_smoke_20261115T132628Z.json` + depth/colour PNG (SHA-256 in the log) in `~/Library/Application Support/FieldStation/hardware_smoke/`; the colour PNG may show people: do not publish it |

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
| Export zip / import zip (iPhone or desktop) with SHA verification | TESTED with zips made by the phone app's own code (`mobile/test/interop_field_station_test.dart`: LiDAR-shaped, synthetic and crash-recovered scans; duplicate and tampered zips refused; roughness and gravity tilt measured after import) | Not yet with a zip from a real iPhone capture |
| Local catalog draft (no upload; there is no catalog service) | TESTED | `draft_local` only. A draft the phone made is read correctly and its fields (location precision, people/property answers) are kept when edited here; licences are SPDX ids like the phone's |
| Local API (loopback, token, Host check) | TESTED | |
| Headless CLI (`python -m fieldstation.cli`) | TESTED manually (devices, capture via the worker process, roughness) | Field fallback if the GUI fails |
| BLE protocol (pairing, MAC, seq/id, acks, resend) | TESTED against the mobile team's `BLE_TEST_VECTORS.json` (byte-identical proofs, key, MAC), and against the phone app's own Dart protocol code through the service's HTTP/WebSocket path (`mobile/test/interop_field_station_test.dart`, minimum MTU) | Radio not involved: never over the air with a real phone |
| BLE radio (Swift CoreBluetooth peripheral in the Flutter runner) | TESTED over the air, 2026-11-15 | iPhone 17 Pro + MacBook Air M4: pairing, Mac→phone start/stop/keyframe, phone state, remote start opening the phone's scanner, sessions 12 h. Auto-reconnect after a dropped link is unit-tested (new Bluetooth identity, wrong key refused) but **not yet over the air** |
| Flutter macOS UI (Devices, Capture, Viewer, Analysis, Library, Pairing, About) | TESTED on screen with the SYNTHETIC scene | `flutter analyze` clean, 9/9 `flutter test`, `flutter build macos` OK. Driven in the app: open device → live preview (26.7 fps) → record → 3D viewer (132k of 397k points, orbit, back-to-front sort) → sphere-ROI roughness. Analysis rectangle/protrusion/distance and export checked through the same API calls (box height 0.152 m vs 0.150 m true), not by dragging in the app |
| UI paths never exercised | BUILT, UNTESTED | Import file picker (macOS osascript / Windows dialog), Show folder / Open in Finder or Explorer, edit notes, reprocess, catalog-draft form, phone-refusal error card (no phone yet), Mesh mode in the viewer |
| App self-starts the Python service and stops it on quit | TESTED | Window 1430x840, title "Field Station" |
| Bounded grid mesh (`mesh_grid.ply`) + GLB (`mesh_grid.glb`) | TESTED (structure, indices, frame conversion) | Only neighbouring measured pixels are joined; no hole filling; labelled DERIVED. GLB loads in trimesh (99k vertices, 197k faces, vertex colours) |
| Redesigned UI (light survey-plate style, viridis depth figures with colour bars, booktabs result tables) | TESTED on Windows 11 with the SYNTHETIC scene. **macOS build not re-run since the redesign** | `flutter analyze` clean, 9/9 `flutter test`, 37/37 service tests, `flutter build windows --debug` OK, every screen checked on screen (Capture only in Colour mode). Run `flutter build macos` and click through on the Mac before demoing |
| Windows build (runner, service from `.venv\Scripts\python.exe`, data in `%LOCALAPPDATA%\FieldStation`, service watches the app's process with `--parent-pid` and exits when it is gone) | TESTED on Windows with SYNTHETIC: app opened from Explorer starts its own service, service gone 5 s after force-killing the app, no console window. D435 on Windows: UNTESTED | `service/requirements-windows.txt` (`pyrealsense2` instead of `pyrealsense2-macosx`) |
| Phone pairing on Windows | Not available by design | The Phone screen says so; scans still move by zip import |
| BLE protocol through the app's own path (`POST /api/ble/rx` in, `ble_tx` WebSocket events out) | SIMULATED end-to-end, 10/10 checks | `phone_sim.py` driven over HTTP + WebSocket against a running service: pairing, wrong code refused, phone→desktop start/stop acked, duplicate re-acked, desktop→phone command with valid MAC, phone ack recorded, unpaired sender refused. No radio, no real phone |
| Depth display colour map | Changed from a jet-like map to viridis; pixels with no depth are white (were black) | Display only: raw and filtered depth PNGs are unchanged. `thumbnail.jpg` of scans recorded earlier keeps the old map until reprocessed |
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
- 06:00–06:50: live tests with the real iPhone 17 Pro.
  - iPhone scans copy into Library over the USB cable automatically (`usb_phone.py`, `usb_sync.py`; needs Xcode's
    devicectl). Measured: about 2–3.5 s per scan after stop, every SHA-256 verified (4 real scans, up to 116 files / 88 MB).
  - Rig use (phone mounted, run from the Mac): start acked in 0.3 s, stop saved, scan in Library ~2 s later, phone
    re-armed for the next scan; tested twice in a row. **Failed once**: after ~2 min idle the phone stopped answering
    (most likely the screen auto-locked, which suspends the app). Fixed by making the phone app the only owner of
    keep-awake (the native code no longer clears it after each recording) and re-asserting it every 10 s; **re-test pending**.
  - Also fixed live: a remote scan's title carried over to the next scan; no answer to the Mac if the phone's camera
    failed to start; a reconnecting phone showed the pairing form.
  - Pairing screen is now **Phone**: rig control panel (state + timer, Start/Stop with confirmation spinner, next scan
    name, cable status, last scan with Open), connection details folded away.
- 06:55: D435 preparation (camera not attached yet). `desktop/d435.sh` (check / watch / run): USB link speed from
  macOS, the hardware gate, automatic sudo retry and a root service launcher for Macs where librealsense needs root.
  Discovery now says when the camera is on USB but cannot be opened, or is in firmware recovery. Checked here without a
  camera only (exit 3, clear message; USB parser checked against the iPhone); **never run with a D435**.
- 08:20: **D435 attached** (first time). USB 2 link (480 Mb/s). As the normal user: 1 device listed, opening it raises
  `failed to set power state`, and librealsense then **segfaults** when Python frees its objects (smoke test exit 139, so
  d435.sh never offered the sudo retry; service discovery timed out after 15 s with no reason). Fixed: the smoke test and
  the discovery child keep the SDK objects alive and leave with `os._exit` (smoke now exits 3 with the error text;
  discovery returns "needs root: run desktop/d435.sh"); d435.sh also retries with sudo on any crash; on a USB 2 link
  discovery recommends `usb2_fallback` and the app opens with it, the smoke test picks it by default. Real depth: not yet.
- 08:26: **hardware gate passed with sudo** (user ran desktop/d435.sh, typed the password): real depth, 30 frames,
  14.97 fps, valid fraction 0.33 (lower half of the frame empty: nearer than the ~0.2 m minimum range, e.g. the desk).
  Live capture in the app through `desktop/d435.sh run`: next.
- 08:35: `d435.sh run` (the root launcher) dry-run end to end with a stand-in sudo that runs as the user: service up,
  health OK, app opened and connected, quit → service stopped, ownership handed back. Found and fixed: the clean-up ran
  after `run_app` returned, lost its `local` variables under `set -u` and skipped pkill/chown (a real root run would have
  left root-owned scans); sudo could expire before clean-up (now kept alive); the app was started as a bare binary, so
  Bluetooth permission would be asked for Terminal (now `open -n -W`); every run rebuilt the app (the .app folder's
  timestamp never changes; now compared with its binary, also in run.sh). Camera link still USB 2 with a second cable
  and the other port (480 Mb/s both). Root service with the real camera: not yet run.
- 08:38–08:52: **first live D435 run in Field Station (root service via d435.sh run).** First open streamed, then
  "no frames within 3000 ms"; every reopen then crashed the camera worker (SIGSEGV; macOS crash reports read):
  (a) `libusb_init` failing inside librealsense's 100 ms USB polling thread / `pipeline.start` → NULL context →
  crash in `libusb_get_device_list`; (b) crash in libusb `darwin_reenumerate_device` while releasing the camera.
  Cause: as root, libusb takes the camera from macOS and gives it back by re-enumerating it on USB at every
  release, so any second touch (a reopen, or the Devices screen probing while streaming) resets the camera under
  the stream. Fixes: each camera process holds one libusb context for its lifetime (no more (a): 0 init crashes
  after it); `pipeline.start` retries "failed to set power state" (macOS UVCAssistant briefly holding the colour
  camera); first frame may take 10 s; the service never probes an open RealSense (reports it instead); opens wait
  3 s after a release and retry up to 3 times on power-state / already-opened / crash; a crashed open worker is
  reported in < 1 s instead of a 20 s timeout. **Measured with the libusb fix (worker side, live):** open → 15.0 fps
  steady for 45 s; real scan `800a7322` saved COMPLETE (USB 2.1, usb2_fallback, 15 frames, mean valid depth 0.347,
  102,944 points; title "D435 setup test (desk)", not a field observation); 5 close/reopen cycles: 3 streamed,
  1 crash on release (b), 1 "already opened" right after it. The retry/wait logic (service side) needs a service
  restart to load: re-test after `d435.sh run` again.
- 08:55–09:08 (still the 08:38 service; only camera-process code reloads): crash dialogs fixed: camera processes
  (worker, discovery probe, smoke test) install libc `_exit` as their SIGSEGV/SIGBUS handler, so a libusb crash while
  releasing the camera ends the process with exit 11, no macOS dialog (verified: synthetic segfault on a non-Python
  thread → exit 11, no crash report; 12 live close/reopen cycles → 0 crash reports). Tried and REVERTED: exiting
  without releasing the camera (next open streamed no frames). Found: after a close, a reopen often "starts" but no
  frames arrive, and the open after that fails "already opened" / "power state". Added: open() waits up to 8 s for
  the first frame set and, if none, hardware-resets the camera and fails retryably (service waits 8 s, retries);
  open attempts get 30 s each. **Not yet verified live**: the camera is now wedged at USB level ("UVC device is already
  opened" with no process holding it) and needs a physical replug; then restart d435.sh run and re-test.
- 09:06–09:16, **after replug + restart (service with all fixes):** 5 reopen cycles with release-on-close: 3/5
  streamed (after retries, 5–38 s), 1 driver crash (exit 11, no dialog, reported in < 1 s), 1 no-frames → camera reset.
  Changed close on macOS to **hardware-reset the camera instead of releasing it** (it reboots into the fresh-plug
  state) and open to wait for it to drop off USB and come back (ioreg, no libusb). **8/8 reopen cycles streamed**
  (6 in 8 s, 2 after an automatic retry in 26 s / 37 s), 0 crash reports. Devices-screen scan while streaming ×3:
  stream unaffected (15.0 fps), open camera reported, not probed. Real scan `c8c21460` after the cycles: COMPLETE,
  15 frames, valid depth 0.678, 34,657 points (title "D435 setup test 2 (desk)", not a field observation).
  Still UNTESTED: USB 3 / full-resolution profiles (no USB 3 cable worked), the first open after quitting the app
  mid-stream (camera not reset then; the retries and no-frames reset are meant to cover it).

