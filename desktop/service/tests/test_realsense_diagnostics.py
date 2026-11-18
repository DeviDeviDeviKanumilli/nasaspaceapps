"""RealSense discovery explains *why* there is no camera. No hardware needed: the SDK and USB listing are faked."""
import os
import types

import pytest

from fieldstation.adapters import realsense as r
from fieldstation.adapters.base import AdapterError


@pytest.fixture
def no_sdk_devices(monkeypatch):
    fake = types.SimpleNamespace(context=lambda: types.SimpleNamespace(query_devices=lambda: []))
    monkeypatch.setattr(r, "rs", fake)


def test_nothing_on_usb_is_an_empty_list(no_sdk_devices, monkeypatch):
    monkeypatch.setattr(r, "usb_seen", lambda: [])
    assert r.RealSenseAdapter().discover() == []


def test_on_usb_but_not_openable_points_to_d435_sh(no_sdk_devices, monkeypatch):
    monkeypatch.setattr(r, "usb_seen", lambda: [{"product_id": "0b07", "link_bps": 5_000_000_000, "name": "D435"}])
    monkeypatch.setattr(os, "geteuid", lambda: 501)
    with pytest.raises(AdapterError, match="d435.sh"):
        r.RealSenseAdapter().discover()


def test_recovery_mode_is_named(no_sdk_devices, monkeypatch):
    monkeypatch.setattr(r, "usb_seen", lambda: [{"product_id": "0adb", "link_bps": 480_000_000, "name": "DFU"}])
    with pytest.raises(AdapterError, match="RECOVERY"):
        r.RealSenseAdapter().discover()


class _PowerStateFails:
    """What pyrealsense2-macosx 2.56.5 does as a normal user on macOS 26 with a D435 attached: the device list has one
    entry, and touching it raises RuntimeError('failed to set power state')."""
    def __iter__(self):
        raise RuntimeError("failed to set power state")


def test_power_state_error_becomes_the_sudo_advice(monkeypatch):
    monkeypatch.setattr(r, "rs", types.SimpleNamespace(context=lambda: types.SimpleNamespace(query_devices=_PowerStateFails)))
    monkeypatch.setattr(r, "usb_seen", lambda: [{"product_id": "0b07", "link_bps": 480_000_000, "name": "D435"}])
    monkeypatch.setattr(os, "geteuid", lambda: 501)
    with pytest.raises(AdapterError, match=r"d435.sh.*failed to set power state"):
        r.RealSenseAdapter().discover()


def test_usb2_link_recommends_the_fallback_profile(monkeypatch):
    info = {"name": "Intel RealSense D435", "serial": "123", "firmware": "5.16", "usb": "2.1", "line": "D400"}
    ci = types.SimpleNamespace(name="name", serial_number="serial", firmware_version="firmware",
                               usb_type_descriptor="usb", product_line="line")
    dev = types.SimpleNamespace(supports=lambda k: True, get_info=lambda k: info[k])
    monkeypatch.setattr(r, "rs", types.SimpleNamespace(camera_info=ci, context=lambda: types.SimpleNamespace(query_devices=lambda: [dev])))
    (d,) = r.RealSenseAdapter().discover()
    assert d["recommended_profile"] == "usb2_fallback" and "USB 2.1" in d["warning"]
