"""Capture lifecycle: repeat captures, unplug mid-recording, cancel, fixtures gate, process isolation.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json

import pytest

from fieldstation import capture as capture_mod
from fieldstation.adapters import AdapterError, DeviceLost
from fieldstation.adapters.synthetic import SyntheticAdapter
from fieldstation.capture import CaptureController

from conftest import record_synthetic, wait_for


class UnpluggedAfter(SyntheticAdapter):
    """Synthetic scene that 'loses the USB device' after k frames."""
    origin = "synthetic_fixture"

    def __init__(self, k):
        super().__init__()
        self.k = k

    def read_frame(self, timeout_ms):
        if self._i >= self.k:
            raise DeviceLost("simulated unplug")
        return super().read_frame(timeout_ms)


def test_repeat_captures_share_session(controller, store):
    a = record_synthetic(controller, frames=4)
    sess = store.manifest(a)["session_id"]
    b = record_synthetic(controller, frames=4, session_id=sess)
    assert a != b and store.manifest(b)["session_id"] == sess
    assert len(store.session_scans(sess)) == 2


def test_unplug_mid_recording_leaves_incomplete_scan_and_prior_scans_intact(controller, store, monkeypatch):
    good = record_synthetic(controller, frames=4)
    good_files = store.manifest(good)["files"]
    controller.close()
    monkeypatch.setattr(capture_mod, "make_adapter", lambda aid, root=None: UnpluggedAfter(k=40))
    controller.open("synthetic", "synthetic:scene-v1")
    r = controller.start_recording(frames=200)
    wait_for(lambda: controller.state == "error")
    m = wait_for(lambda: (lambda m: m if m["status"] == "incomplete" else None)(store.manifest(r["scan_id"])))
    assert "device_lost" in m["status_reason"]
    assert controller.error["kind"] == "device_lost"
    assert store.manifest(good)["files"] == good_files and store.manifest(good)["status"] == "complete"
    # the partial capture is still processed (frames are real evidence) but never promoted to complete
    wait_for(lambda: (store.dir_of(r["scan_id"]) / "metrics.json").exists())
    assert store.manifest(r["scan_id"])["status"] == "incomplete"


def test_cancel_marks_incomplete(controller, store):
    controller.open("synthetic", "synthetic:scene-v1")
    r = controller.start_recording(frames=300)
    wait_for(lambda: controller.writer is not None and controller.writer.n >= 2)
    controller.cancel_recording()
    wait_for(lambda: controller.state == "streaming")
    assert store.manifest(r["scan_id"])["status"] == "incomplete"


def test_cannot_record_without_sensor_and_fixtures_gate(store):
    c = CaptureController(store, use_process=False, fixtures=False)
    with pytest.raises(AdapterError):
        c.start_recording()
    with pytest.raises(AdapterError, match="fixtures are disabled"):
        c.open("synthetic", "synthetic:scene-v1")
    assert c.discover("synthetic")["devices"] == []


def test_worker_process_isolation_and_replay(store):
    """Real code path: sensor in a spawned process. Record synthetic, then replay that scan."""
    c = CaptureController(store, use_process=True, fixtures=True)
    try:
        sid = record_synthetic(c, frames=3)
        c.close()
        devs = c.discover("replay")["devices"]
        assert any(d["device_id"] == f"replay:{sid}" for d in devs)
        c.open("replay", f"replay:{sid}")
        r = c.start_recording(frames=3)
        wait_for(lambda: store.manifest(r["scan_id"])["status"] == "complete")
        m = store.manifest(r["scan_id"])
        assert m["origin"] == "replay" and m["replay_of"]["scan_id"] == sid and m["is_real_sensor"] is False
        assert any("REPLAY" in x for x in m["limitations"])
    finally:
        c.close()


def test_realsense_discovery_reports_honestly(store):
    """No camera attached in CI: discovery must return an empty list or an explicit error, never a fake device."""
    c = CaptureController(store, use_process=True)
    r = c.discover("realsense")
    assert isinstance(r["devices"], list)
    for d in r["devices"]:
        assert d["is_real_sensor"] is True and d["serial"]
