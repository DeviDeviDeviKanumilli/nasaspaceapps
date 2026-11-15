"""Regenerate the SYNTHETIC example bundle in examples/ (clearly labelled; not a sensor measurement).

    .venv/bin/python tools/make_example.py
Writes a full bundle to examples/SYNTHETIC_example_bundle/ (gitignored: large) and copies its small JSON
files (scan.json, calibration.json, metrics.json) to examples/SYNTHETIC_example_json/ for reference.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fieldstation.bundle import ScanStore  # noqa: E402
from fieldstation.capture import CaptureController  # noqa: E402

ex = Path(__file__).resolve().parents[1] / "examples"
work = ex / "SYNTHETIC_example_bundle"
shutil.rmtree(work, ignore_errors=True)
st = ScanStore(work / "scans")
c = CaptureController(st, use_process=False, fixtures=True)
c.open("synthetic", "synthetic:scene-v1", "field_static")
r = c.start_recording(frames=10, title="SYNTHETIC example: board + 0.30x0.20x0.15 m box + 0.12 m sphere cap", feature_type="other")
while st.manifest(r["scan_id"])["status"] not in ("complete", "incomplete") or c.state != "streaming":
    time.sleep(0.1)
c.close()
sid = r["scan_id"]
d = st.dir_of(sid)
out = ex / "SYNTHETIC_example_json"
shutil.rmtree(out, ignore_errors=True)
out.mkdir(parents=True)
for f in ("scan.json", "calibration.json", "metrics.json"):
    shutil.copyfile(d / f, out / f)
z = st.export_zip(sid)
print(json.dumps({"scan_id": sid, "bundle": str(d), "zip": str(z), "json_copies": str(out)}, indent=2))
