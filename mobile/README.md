# Field Scan (iPhone LiDAR scanning app)

Flutter + Dart app with a native Swift ARKit module, for NASA Space Apps 2026 (team Vancomycin). It records
LiDAR depth, camera poses and photos of rock surfaces, takes keyframes and photos **automatically** (handheld or
hands-free on the FieldKit rig), builds a metric point cloud, measures local geometry, and prepares opt-in catalog
contributions. It does **not** find or rank planetary analog sites; that is the website's job.

Shared formats with the desktop app (Field Station): `../contracts/SCAN_BUNDLE_V1.md`, `../contracts/BLE_PROTOCOL_V1.md`,
`../contracts/BLE_TEST_VECTORS.json`.

## Status (2026-11-15)

| Part | State |
|---|---|
| Native ARKit capture (depth, confidence, poses, mesh, full-res photos, auto triggers, fusion, PLY export) | **Builds for device; never run on a phone.** No LiDAR iPhone has been connected to this Mac yet |
| Geometry in Swift (back-projection, pose transform, EXIF orientation, voxel grid) | Tested on the Mac: `tools/test_scanmath.sh`, 16 checks pass |
| Dart: PLY, plane fit / roughness / tilt / extents, scan.json, library, crash recovery, BLE framing + pairing + MACs | 17 unit tests pass (`flutter test`), BLE crypto checked against Python-generated vectors |
| UI (scan setup, capture + rig mode, 3D viewer, measuring, library, repeat-scan comparison, contribution, explore, connect, settings) | End-to-end UI test passes on the iPhone 17 Pro **simulator** (`integration_test/app_test.dart`, 12 screenshots): synthetic scans, orbit, distance and surface measurements saved to scan.json, SHA-256 check, contribution draft, repeat-scan compare, crash recovery, Bluetooth-unavailable and no-ARKit error paths. The simulator has no camera, LiDAR, ARKit or Bluetooth, so live capture and pairing still need a real phone |
| Bundle verifier for the Mac (`tools/verify_scan.py`) | Self-test passes on a synthetic bundle (cube on a floor, recovered to < 1 mm) |
| Bluetooth link to Field Station | Phone side written and unit-tested at protocol level. The desktop (`../desktop`) passes the same test vectors, and `test/interop_field_station_test.dart` runs this app's protocol and export code against the real desktop service (pairing, commands both ways, acks, duplicates, forged MACs, zip import). The radio is replaced in that test: **the two have never talked over the air** |
| Wi-Fi bulk transfer | Not built. Scans move by Export → AirDrop / Files (works offline) |
| Public catalog upload / browse | Not built (no backend). Contributions are saved as local drafts only; Explore says so |

No real scan has been taken with this app yet. Everything above that says "tested" was tested on synthetic data.

**Hardware note:** the iPhones paired with this Mac are an iPhone 17 (`iPhone18,3`), a 14 and a 13: **none has
LiDAR**. On those the app records photos with ARKit poses only (no depth, no point cloud). The LiDAR features need the
team's iPhone 17 Pro (`iPhone18,1`) or another Pro model.

## Hands-free photos on the FieldKit rig

The rig holds the phone landscape behind the laptop lid, screen toward the lid and cameras outward, so nobody can see or
touch the screen while walking. Rig mode is built for that:

1. Pick **FieldKit rig (hands-free)** on the Scan tab (or switch on *Rig mode* with any preset), open the scanner, press Start.
2. A 5-second spoken countdown gives time to clamp the phone. Then it records by itself: a keyframe every 0.5 m walked or
   15° turned, or every 3 s when standing still, each with a full-resolution photo and its ARKit pose.
3. The screen goes black (brightness 5 %) and ignores touches. It ticks on every keyframe and speaks:
   "Recording", "Tracking limited. Move slower.", "25 frames". Hold anywhere for 2 s to unlock the controls for 10 s.
4. Shots wait (up to 2 s) until the estimated rotational blur is under 2.5 px, and never fire while ARKit tracking is limited.
5. If the paired Mac allows it, it can start, stop and trigger keyframes over Bluetooth (setting: *Let the paired Mac control capture*).
6. Auto-stop on 900 keyframes, 30 minutes, < 800 MB free storage, critical temperature or < 5 % battery.

Images are stored in the camera's native orientation with an EXIF orientation tag computed from gravity, so they display
upright however the phone is mounted (landscape either way, upside down, portrait). The tag only changes how a viewer
rotates the image; the pixels and intrinsics are unchanged.

Other presets: *Handheld scan* (keyframe every 10 cm or 10°), *Fixed interval* (1 s), *Manual shutter*.

## What a scan contains

See `../contracts/SCAN_BUNDLE_V1.md`. In short: `keyframes/` (RGB JPEG, float32 depth in metres, uint8 confidence,
pose and intrinsics in `keyframes.jsonl`): the raw evidence. `photos/` (full-resolution, posed). `point_cloud_fused.ply`
(derived: 1 cm voxel average of unsmoothed sceneDepth, confidence ≥ medium, 0.15–4 m, ≥ 2 samples; colour, max
confidence and sample count per point). `mesh_arkit.ply` (ARKit's mesh, latest revision per anchor, with ARKit's surface
classes, which describe rooms and are not geology). `scan.json` with SHA-256 for every file, quality counts, processing
recipe and limitations. Location is collected only if switched on for that scan and is never written into image EXIF.

## Measurements (scan detail screen)

- **Distance** between two tapped points: use it on a ruler or known object to check scale.
- **Surface**: tap to centre a sphere (3–100 cm). The app fits a total-least-squares plane to the fused points inside it
  and reports RMS orthogonal residual (roughness), 95th-percentile residual, tilt from horizontal (ARKit gravity),
  highest point above the plane toward the camera side, in-plane extent, and points used. Optional robust refit drops
  points beyond 3× RMS.
- **Extents** of the whole cloud: vertical along gravity and the two horizontal principal axes (1 % trimmed).
- Saved measurements carry method, ROI, frame, validity notes and "uncertainty: none from a single scan".
  **Library → compare** groups measurements with the same label across scans (n, mean, SD, range) for the 3-repeat protocol.

No accuracy percentage, no "Mars match", no rock or mineral identification.

## Look and feel

Light theme in `lib/ui/style.dart`: one set of colours, 20 px side margins, 20 px card corners and 56 px buttons with 18 px corners on every screen.
Type is Nunito Sans, bundled in `assets/fonts` so it renders offline (SIL Open Font License, licence file alongside).
Rock drawings live in `lib/ui/rocks.dart`. The rock character appears only on empty and status screens: no ARKit, empty Library, Explore, rig countdown, locked rig, saving and errors.
First launch shows a two-page intro (`lib/screens/intro_screen.dart`): what the app does, then what stays private. It is remembered in `settings.json` (`introSeen`) and can be replayed from Settings → Show intro again.
Feature-type pickers and Library placeholders use plain rock shapes. The 3D viewer, measurements and capture overlays stay plain.

## Build and run

Flutter is at `~/development/flutter/bin` (not on PATH).

```sh
cd mobile
~/development/flutter/bin/flutter pub get
~/development/flutter/bin/flutter test                 # 17 Dart unit tests
tools/test_scanmath.sh                                 # Swift geometry checks on the Mac
python3 tools/verify_scan.py --selftest                # bundle verifier self-test (numpy, scipy)
~/development/flutter/bin/flutter build ios --no-codesign --release   # compiles for device
```

On a phone: plug in the iPhone 17 Pro, unlock it, turn on Developer Mode, open `ios/Runner.xcworkspace` in Xcode once to
pick a signing team (Runner → Signing & Capabilities), then `flutter run --release`. iOS 16 or later.

Simulator (no ARKit, so the Scan tab shows "not available"): the Library and viewer work. Full UI test with screenshots:

```sh
FS_SHOTS=build/screenshots ~/development/flutter/bin/flutter drive \
  --driver=test_driver/integration_test.dart --target=integration_test/app_test.dart -d <simulator id>
```

 In debug builds,
`--dart-define=FS_START=detail` opens a SYNTHETIC fixture scan; Settings → *Add a SYNTHETIC test scan* does the same
(always labelled as a fixture).

## On the Mac: checking a scan

```sh
python3 tools/verify_scan.py ~/Downloads/scan-<id>.zip
```

It checks every SHA-256, re-projects the raw keyframe depth with the contract's conventions into
`point_cloud_from_keyframes.ply` (this also recovers a scan whose fused cloud was never written), and reports the
nearest-neighbour distance to the phone's fused cloud. Matching surfaces should agree to about a voxel; decimetres mean a
convention bug. Open either PLY in MeshLab or CloudCompare and check a known length.

## Field demo script (Sourland, offline, about 60 s)

1. Airplane mode on. Scan tab → name "Boulder A", feature *Boulder*, preset *Handheld scan* → Open scanner.
2. Start, walk slowly around the visible face of a textured boulder at 1–2 m (do not climb). Watch tracking stay normal and
   points climb. Stop & save.
3. Scan detail: orbit the cloud (camera path shown in blue). **Distance**: tap both ends of a ruler or trekking pole laid on
   the rock and compare. **Surface**: tap the boulder face, 15 cm radius, read roughness (mm) and tilt (°). Save with label
   "Boulder A face".
4. Repeat the scan twice more and save the same label; Library → compare shows the spread.
5. Export → AirDrop the zip to the Mac; `python3 tools/verify_scan.py` there.
6. Say what it cannot do: geometry only, partial view, ARKit's processed depth, metres-scale, not a planetary match.

For the rig: preset *FieldKit rig*, Start, clamp the phone during the countdown, walk; listen for ticks.

## Layout

```
ios/Runner/FieldScanner.swift   ARKit session, auto triggers, keyframe/photo writing, fusion, mesh export, cues, preview view
ios/Runner/ScanMath.swift       pure geometry (tested on the Mac)
lib/core/                       scanner channel, scan.json + library, PLY, geometry, BLE protocol + link, fixture
lib/screens/                    scan setup, capture (rig mode), scan detail (viewer + measuring), library + compare,
                                contribute, explore, connect, settings
lib/widgets/cloud_viewer.dart   z-buffered software point viewer with picking and scale bar
tools/                          test_scanmath.sh, verify_scan.py, make_ble_vectors.py
test/core_test.dart             unit tests
```

## Known limits

- Fusion assumes ARKit tracking stays consistent; drift smears the cloud. Keyframes are kept so it can be redone on the Mac.
- The fused cloud is capped at 1.5 M voxels (handheld) and reports when the cap is reached.
- Blur is a rotation-only estimate (angular speed × exposure × focal length); translation and rolling shutter are ignored.
- Spoken prompts use the playback audio session (heard with the silent switch on); the keyframe tick is a system sound and is silent when the ring switch is off.
- One fix is taken for location at the start of a scan (if enabled), not a track.
- The BLE pairing code is 6 digits: someone recording the pairing exchange could brute-force it offline. Acceptable for a park demo; a QR secret would fix it.
- `flutter_blue_plus` is used under its nonprofit/educational licence tier (student team, non-commercial).

AI disclosure: this app was drafted with AI assistance (Claude, Anthropic) at the team's request; the team reviews, runs and tests it.

## Sharing a contribution

There is no catalog service yet. On "Prepare contribution", after both consent boxes are ticked:

- **Save draft on this phone** writes `catalog_draft.json` and uploads nothing.
- **Share contribution package** opens the iOS share sheet (AirDrop, Files, Messages, Mail) with a zip built by `lib/core/contribution_package.dart`. It contains only what the form lists as public:
  - the point cloud and mesh
  - `scan_public.json`: location hidden, rounded to 0.1° or exact, as chosen; no session id; no field site id when the location is hidden; notes only if "Include my field notes" is on
  - photos only when no people or private property are visible, with any GPS-bearing EXIF, XMP and IPTC blocks removed
  - `contribution.json` with licence and consent
  - `README.txt`

  The private scan folder, raw poses, depth files and device identifiers are never included. Unit tests are in `test/contribution_package_test.dart`.

## Installing on an iPhone

Plug the phone in once, and trust the Mac. Sign Xcode in to your Apple ID (Settings → Accounts), then set your team in Runner → Signing & Capabilities.
Turn on Developer Mode on the phone (Settings → Privacy & Security). Then run:

    flutter build ios --release
    xcrun devicectl device install app --device <id from `xcrun devicectl list devices`> build/ios/iphoneos/Runner.app

On the first launch, trust the developer on the phone: Settings → General → VPN & Device Management.
A free (Personal Team) install stops opening after 7 days; reinstall it the same way.
