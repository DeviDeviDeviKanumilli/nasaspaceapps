"""Copy scans off the iPhone app (Field Scan) over the USB cable, using Apple's `devicectl` (part of Xcode).

Nothing here talks to the phone app itself: devicectl reads the app's Documents folder, which the app shares
(UIFileSharingEnabled). Each scan folder is copied to a temporary folder and imported with ScanStore.import_dir,
so the same checks as a zip import apply (every listed SHA-256 verified, no overwrite).

macOS only, and only with Xcode installed (Xcode Command Line Tools alone do not include devicectl). Without it,
the same folders can be dragged out of Finder (iPhone > Files > Field Scan > scans) and imported as folders.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PHONE_BUNDLE_ID = "org.vancomycin.fieldScan"
SCANS_DIR = "Documents/scans"
_SCAN_RE = re.compile(r"scan-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")


class UsbPhoneError(RuntimeError):
    pass


def _user_prefix() -> list[str]:
    """When the service runs as root (needed for the D435 on some Macs: desktop/d435.sh run), run devicectl as the
    user who started it: the iPhone's pairing/trust lives in that user's account, not root's."""
    user = os.environ.get("SUDO_USER")
    if hasattr(os, "geteuid") and os.geteuid() == 0 and user and user != "root":
        return ["sudo", "-n", "-u", user]
    return []


def availability() -> dict:
    """Whether USB import can work on this computer, and why not if it can't."""
    if sys.platform != "darwin":
        return {"available": False, "reason": "USB import from the iPhone needs macOS (Apple's devicectl). Use AirDrop or Files, then Import."}
    if not shutil.which("xcrun"):
        return {"available": False, "reason": "xcrun not found: install Xcode to import over USB, or use AirDrop / Finder."}
    r = subprocess.run([*_user_prefix(), "xcrun", "-f", "devicectl"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"available": False, "reason": "devicectl not found: it ships with Xcode (not the Command Line Tools alone). "
                                              "Install Xcode, or drag the scan folder out of Finder (iPhone > Files > Field Scan)."}
    return {"available": True, "reason": None}


def _devicectl(args: list[str], timeout: float = 120) -> dict:
    prefix = _user_prefix()
    with tempfile.TemporaryDirectory(prefix="fs-devicectl-") as td:
        out = Path(td) / "out.json"
        if prefix:
            # devicectl runs as the user: let it write its JSON and copied files into our (root-owned) temp folders
            for d in [Path(td)] + [Path(args[i + 1]).parent for i, a in enumerate(args) if a == "--destination" and i + 1 < len(args)]:
                try:
                    os.chmod(d, 0o777)
                except OSError:
                    pass
        try:
            r = subprocess.run([*prefix, "xcrun", "devicectl", *args, "--json-output", str(out), "--quiet"],
                               capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise UsbPhoneError(f"devicectl timed out after {timeout:.0f} s")
        data = json.loads(out.read_text()) if out.exists() else {}
        if r.returncode != 0:
            err = (data.get("error") or {}).get("userInfo", {}).get("NSLocalizedDescription", {})
            msg = err.get("string") if isinstance(err, dict) else None
            raise UsbPhoneError((msg or r.stderr.strip() or r.stdout.strip() or f"devicectl exit {r.returncode}")[:400])
        return data


def devices() -> list[dict]:
    """iPhones connected to this Mac right now (USB first)."""
    out = []
    for d in (_devicectl(["list", "devices"], timeout=30).get("result") or {}).get("devices", []):
        hw, cp, dp = d.get("hardwareProperties") or {}, d.get("connectionProperties") or {}, d.get("deviceProperties") or {}
        if hw.get("platform") != "iOS" or cp.get("tunnelState") != "connected":
            continue
        out.append({"device_id": d.get("identifier"), "name": dp.get("name"), "model": hw.get("marketingName"),
                    "transport": cp.get("transportType"), "os_version": dp.get("osVersionNumber")})
    out.sort(key=lambda x: x["transport"] != "wired")
    return out


def _copy_from(device_id: str, source: str, dest: Path, timeout: float) -> None:
    _devicectl(["device", "copy", "from", "--device", device_id, "--domain-type", "appDataContainer",
                "--domain-identifier", PHONE_BUNDLE_ID, "--source", source, "--destination", str(dest)], timeout=timeout)


def _scan_ids_in(obj) -> set[str]:
    found: set[str] = set()
    if isinstance(obj, dict):
        for v in obj.values():
            found |= _scan_ids_in(v)
    elif isinstance(obj, list):
        for v in obj:
            found |= _scan_ids_in(v)
    elif isinstance(obj, str):
        found |= set(_SCAN_RE.findall(obj))
    return found


def list_scan_ids(device_id: str) -> list[str]:
    """Scan folder ids in the phone app (cheap: one directory listing)."""
    try:
        data = _devicectl(["device", "info", "files", "--device", device_id, "--domain-type", "appDataContainer",
                           "--domain-identifier", PHONE_BUNDLE_ID, "--subdirectory", SCANS_DIR, "--no-recurse"], timeout=60)
    except UsbPhoneError as exc:
        if "not installed" in str(exc).lower() or "no such" in str(exc).lower():
            raise UsbPhoneError(f"Field Scan is not installed on this phone, or has no scans yet ({exc})")
        raise
    return sorted(_scan_ids_in(data.get("result") or data))


def read_scan_json(device_id: str, scan_id: str) -> dict | None:
    """The phone's scan.json for one scan, or None while it does not exist yet (the phone writes it last,
    when a capture is saved; a folder without it is still recording)."""
    uuid.UUID(scan_id)
    with tempfile.TemporaryDirectory(prefix="fs-scanjson-") as td:
        try:
            _copy_from(device_id, f"{SCANS_DIR}/scan-{scan_id}/scan.json", Path(td) / "scan.json", timeout=60)
        except UsbPhoneError:
            return None
        try:
            return json.loads((Path(td) / "scan.json").read_text())
        except (ValueError, OSError):
            return None


def list_scans(device_id: str) -> list[dict]:
    """Scans in the phone app, with title/status/size read from each scan.json (newest first)."""
    ids = list_scan_ids(device_id)

    def meta(sid: str) -> dict:
        row = {"scan_id": sid, "title": None, "origin": None, "status": None, "started_utc": None, "keyframes": None,
               "points": None, "error": None}
        with tempfile.TemporaryDirectory(prefix="fs-scanjson-") as td:
            try:
                _copy_from(device_id, f"{SCANS_DIR}/scan-{sid}/scan.json", Path(td) / "scan.json", timeout=60)
                m = json.loads((Path(td) / "scan.json").read_text())
                row.update(title=(m.get("observation") or {}).get("title") or None, origin=m.get("origin"), status=m.get("status"),
                           started_utc=(m.get("captured_at_utc") or {}).get("start") if isinstance(m.get("captured_at_utc"), dict) else None,
                           keyframes=(m.get("capture") or {}).get("keyframes"), points=(m.get("quality") or {}).get("fused_points"),
                           bytes=sum(int(f.get("bytes") or 0) for f in m.get("files") or []))
            except (UsbPhoneError, ValueError, OSError) as exc:
                row["error"] = f"scan.json not readable: {exc}"[:200]
        return row

    with ThreadPoolExecutor(max_workers=4) as ex:
        rows = list(ex.map(meta, ids))
    rows.sort(key=lambda r: r.get("started_utc") or "", reverse=True)
    return rows


def pull_scan(device_id: str, scan_id: str, work_dir: Path) -> Path:
    """Copy one scan folder off the phone into work_dir; returns the local folder."""
    uuid.UUID(scan_id)  # only well-formed ids reach devicectl
    dest = Path(work_dir) / f"scan-{scan_id}"
    _copy_from(device_id, f"{SCANS_DIR}/scan-{scan_id}", dest, timeout=900)
    if not (dest / "scan.json").is_file():
        # some devicectl versions place the folder inside the destination
        inner = dest / f"scan-{scan_id}"
        if (inner / "scan.json").is_file():
            return inner
        raise UsbPhoneError(f"copied scan-{scan_id} but found no scan.json in it")
    return dest
