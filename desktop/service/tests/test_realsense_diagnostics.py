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
