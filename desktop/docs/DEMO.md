# Field Station: 60-second offline demo (desktop)

Before the demo, turn Wi-Fi off. Nothing in the app needs the network.

## A. With the real D435 (only after `tools/d435_smoke.py` has returned exit 0 on this Mac)

| t | Do | Say |
|---|---|---|
| 0–8 s | `desktop/run.sh` (Windows: `field_station.exe`), then **Devices**: the camera list fills in by itself (*Scan again* after plugging in). Profile *Field static* at the top › **Open** on the D435 row | "The desktop is the field instrument. It talks to the depth camera over USB 3; the camera runs in its own process so a cable fault can't crash the app." |
| 8–18 s | **Capture**: toggle Colour/Depth, point at the boulder face, watch valid-depth % and range | "Live quality is measured, not decorative: valid-depth fraction and range right now." |
| 18–28 s | Title "Boulder A, upper face", feature *boulder* › **Record 30 frames** (~1 s) | "A stationary capture: 30 raw frames kept untouched, plus calibration." |
| 28–40 s | **Viewer**: orbit the cloud, Raw vs Filtered | "Metric point cloud in metres. Only what the camera saw: no invented back side." |
| 40–52 s | **Analysis**: tool *Roughness*, drag a rectangle on the face › **Measure roughness** | "Plane-fit roughness X mm over a Y cm baseline. Tilt is relative to the camera, because the D435 has no gravity sensor. If roughness is near the sensor's noise floor, the app says so." |
| 52–60 s | **Library** › select the scan › **Export .zip** | "Everything exports as a bundle with hashes: raw frames, calibration, clouds, measurements, limitations. It links to a website site ID, but analog discovery stays on the website." |

## B. Without the camera (rehearsal or fallback)

- **Replay** (preferred fallback): *Devices › Replay a saved scan* › **Open** on the row. Only use replay of a real
  earlier recording. The app shows a REPLAY banner, and the new scan is stamped `origin: replay` with
  `replay_of`.
- **Synthetic** (rehearsal only, never in judging as a field result): `desktop/run.sh --fixtures` (or turn on
  *About › Test sources*) › *Synthetic test scene* › **Open**. A banner reads "SYNTHETIC TEST SCENE — not a sensor measurement".

## C. Phone link (if both apps are on hand; macOS build only)

**Pairing** › *Pair a phone* shows a 6-digit code. On the phone, pick "Field Station <Mac>" and type the
code. From the phone: start D435 capture. Scans travel by AirDrop/Files as zip › *Library › Import*.
Imported scans keep "iPhone ARKit" provenance.

## What not to say

- That the scan "validates" a Moon or Mars match, or anything at the 400–3200 m scale.
- Anything about rock type or mineralogy, or that the boulder is Lockatong (Sourland's boulders are mostly diabase).
- An accuracy figure. We have repeatability across captures and a published noise model, not ground-truth accuracy.
