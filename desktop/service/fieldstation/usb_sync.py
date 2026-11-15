"""Automatic import of the iPhone's scans over the USB cable (on by default).

While an iPhone with Field Scan is plugged into this Mac, every finished scan on it is copied over and imported
(same checks as any import: every listed SHA-256 verified, nothing overwritten). It checks every few seconds,
and at once when the paired phone reports `capture_complete` over Bluetooth, so a scan appears here seconds
after Stop. A scan folder without scan.json is still recording and is left alone until it has one.

The phone must be unlocked and have trusted this Mac ("Trust This Computer"): that is the consent to copy.
Turn it off in Library or with FIELDSTATION_USB_AUTO=0.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import os
import shutil
import threading
import time
import uuid
from pathlib import Path

from . import usb_phone
from .adapters.base import utc_now
from .bundle import BundleError, DuplicateScan
from .schema import ENVELOPE

POLL_S = 4.0


class UsbAutoSync:
    def __init__(self, store, home: Path, emit, enabled: bool | None = None):
        self.store, self.home, self.emit = store, Path(home), emit
        self.enabled = (os.environ.get("FIELDSTATION_USB_AUTO", "1") != "0") if enabled is None else enabled
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.failed: dict[str, str] = {}          # scan_id -> error; not retried until the next capture_complete
        self.state = {"enabled": self.enabled, "available": None, "reason": None, "devices": [], "busy": None,
                      "last_check_utc": None, "last_import": None, "last_error": None, "imported_count": 0}
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="usb-auto-sync", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    def set_enabled(self, on: bool) -> dict:
        self.enabled = bool(on)
        self._set(enabled=self.enabled)
        if on:
            self.kick(retry_failed=True)
        return self.status()

    def kick(self, retry_failed: bool = False) -> None:
        if retry_failed:
            self.failed.clear()
        self._wake.set()

    def status(self) -> dict:
        with self._lock:
            return dict(self.state, failed=[{"scan_id": k, "error": v} for k, v in self.failed.items()])

    def _set(self, **kw) -> None:
        """Update the state; tell the app only when something other than the poll time changed."""
        with self._lock:
            before = {k: v for k, v in self.state.items() if k != "last_check_utc"}
            self.state.update(kw)
            changed = before != {k: v for k, v in self.state.items() if k != "last_check_utc"}
        if changed:
            self.emit("usb_sync", **self.status())

    def _run(self) -> None:
        av = usb_phone.availability()
        self._set(available=av["available"], reason=av["reason"])
        if not av["available"]:
            return
        while not self._stop.is_set():
            if self.enabled:
                try:
                    self.sync_once()
                except Exception as exc:          # never let the loop die; show the error instead
                    self._set(last_error=f"{type(exc).__name__}: {exc}"[:300], busy=None)
            self._wake.wait(POLL_S)
            self._wake.clear()

    def sync_once(self) -> list[dict]:
        devs = [d for d in usb_phone.devices() if d.get("transport") == "wired"]
        self._set(devices=devs, last_check_utc=utc_now())
        done = []
        for dev in devs:
            try:
                ids = usb_phone.list_scan_ids(dev["device_id"])
            except usb_phone.UsbPhoneError as exc:
                self._set(last_error=f"{dev.get('name')}: {exc}"[:300])
                continue
            for sid in ids:
                if (self.store.root / f"scan-{sid}" / ENVELOPE).exists() or sid in self.failed or not self.enabled:
                    continue
                if usb_phone.read_scan_json(dev["device_id"], sid) is None:
                    continue                      # still recording (or not saved yet)
                done.append(self._import(dev, sid))
        self._set(busy=None)
        return done

    def _import(self, dev: dict, sid: str) -> dict:
        self._set(busy={"scan_id": sid, "device": dev.get("name"), "stage": "copying"})
        work = self.home / "usb_import_tmp" / str(uuid.uuid4())
        work.mkdir(parents=True)
        t0 = time.monotonic()
        try:
            folder = usb_phone.pull_scan(dev["device_id"], sid, work)
            self._set(busy={"scan_id": sid, "device": dev.get("name"), "stage": "verifying"})
            man = self.store.import_dir(folder, source_name=f"{dev.get('name') or 'iPhone'} over USB (automatic)")
            res = {"scan_id": sid, "ok": True, "origin": man.get("origin"), "title": (man.get("observation") or {}).get("title"),
                   "seconds": round(time.monotonic() - t0, 1), "utc": utc_now(), "device": dev.get("name")}
            with self._lock:
                self.state["imported_count"] += 1
            self._set(last_import=res, last_error=None)
            self.emit("scan_imported", scan_id=sid, origin=man.get("origin"), via="usb_auto", title=res["title"])
            return res
        except DuplicateScan:
            return {"scan_id": sid, "ok": True, "duplicate": True}
        except (usb_phone.UsbPhoneError, BundleError, ValueError, OSError) as exc:
            self.failed[sid] = str(exc)[:300]
            self._set(last_error=f"scan {sid[:8]}: {exc}"[:300])
            self.emit("usb_import_failed", scan_id=sid, error=str(exc)[:300])
            return {"scan_id": sid, "ok": False, "error": str(exc)}
        finally:
            shutil.rmtree(work, ignore_errors=True)
