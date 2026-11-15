# Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fieldstation.adapters.synthetic import SyntheticAdapter  # noqa: E402
from fieldstation.bundle import ScanStore  # noqa: E402
from fieldstation.capture import CaptureController  # noqa: E402


@pytest.fixture
def store(tmp_path):
    return ScanStore(tmp_path / "home" / "scans")


@pytest.fixture
def controller(store):
    c = CaptureController(store, use_process=False, fixtures=True)
    yield c
    c.close()


def wait_for(pred, timeout=30.0, step=0.05):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        v = pred()
        if v:
            return v
        time.sleep(step)
    raise AssertionError("timed out")


def record_synthetic(controller, frames=8, **kw):
    if controller.state != "streaming":
        controller.open("synthetic", "synthetic:scene-v1", "field_static")
    r = controller.start_recording(frames=frames, **kw)
    sid = r["scan_id"]
    wait_for(lambda: controller.store.manifest(sid)["status"] in ("complete", "incomplete") and controller.state == "streaming")
    return sid


@pytest.fixture
def synthetic_scan(controller):
    return record_synthetic(controller, frames=8, title="fixture")


@pytest.fixture
def scene():
    return SyntheticAdapter().scene
