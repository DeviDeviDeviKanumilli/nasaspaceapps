"""Scan envelope (manifest.json) shared with the iPhone app and the catalog.

Field names follow the common versioned scan envelope shared with the iPhone app (see /contracts);
desktop-only additions are listed in schema/scan_envelope.v1.schema.json.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import hashlib
import platform
import uuid
from pathlib import Path

from . import APP_NAME, APP_VERSION, PIPELINE_VERSION, SCHEMA_VERSION
from .camera_model import FRAME_CONVENTION

FEATURE_TYPES = ["rock_face", "boulder", "boulder_field", "outcrop", "ground", "other"]
ORIGINS = {"realsense_d435", "replay", "synthetic_fixture", "iphone_arkit_lidar", "iphone_arkit_camera", "unknown_import"}
STATUSES = {"recording", "processing", "complete", "incomplete", "imported"}
ENVELOPE = "scan.json"        # contracts/SCAN_BUNDLE_V1.md

MIME = {".json": "application/json", ".jsonl": "application/x-ndjson", ".ply": "application/x-ply",
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".glb": "model/gltf-binary",
        ".usdz": "model/vnd.usdz+zip", ".zip": "application/zip", ".txt": "text/plain", ".obj": "model/obj"}

BASE_LIMITATIONS = [
    "Geometry only: no mineral, chemical or rock-type identification.",
    "Single viewpoint: hidden surfaces (backs, undersides) are not measured and are not shown as measured.",
    "Close-range scale (centimetres to metres); not comparable with the 400-3200 m terrain descriptors used for planetary analog discovery.",
    "No gravity reference (the D435 has no IMU): plane angles are relative to the camera, not to horizontal.",
    "This scan is a field observation, not a validated planetary analog match.",
]

ORIGIN_LIMITATIONS = {
    "synthetic_fixture": ["SYNTHETIC: rendered test scene with simulated noise. Not a sensor measurement of anything real."],
    "replay": ["REPLAY: re-recorded from a previously saved scan; not a new observation."],
    "iphone_arkit_lidar": ["ARKit processed depth/mesh (not raw LiDAR returns); session-local world frame; tracking drift possible."],
    "iphone_arkit_camera": ["ARKit camera poses and RGB only; no depth sensor data."],
    "unknown_import": ["Imported file without a provenance manifest: sensor, units and frame are as stated by the importer, unverified."],
}


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(chunk):
            h.update(b)
    return h.hexdigest()


def file_entry(root: Path, rel: str, role: str, kind: str, lineage: str = "", frame: str | None = None) -> dict:
    """files[] record per SCAN_BUNDLE_V1 (path, role, mime, bytes, sha256, lineage) plus kind=raw|derived and frame."""
    p = root / rel
    return {"path": rel, "role": role, "kind": kind, "mime": MIME.get(p.suffix.lower(), "application/octet-stream"),
            "bytes": p.stat().st_size, "sha256": sha256_file(p), "lineage": lineage, "coordinate_frame": frame}


def platform_info() -> dict:
    return {"os": f"macOS {platform.mac_ver()[0]}" if platform.system() == "Darwin" else platform.platform(),
            "machine": platform.machine(), "app": f"{APP_NAME} {APP_VERSION}", "python": platform.python_version()}


def new_manifest(*, origin: str, is_real_sensor: bool, device: dict, profile: str | None, frames_requested: int | None,
                 title: str = "", feature_type: str = "other", notes: str = "", session_id: str | None = None,
                 field_site_id: str | None = None, candidate_id: str | None = None, candidate_run_id: str | None = None,
                 started_by: str = "desktop_user", replay_of: dict | None = None, captured_at_utc: str | None = None) -> dict:
    """scan.json envelope per contracts/SCAN_BUNDLE_V1.md. Desktop-only additions: status, status_reason,
    is_real_sensor, replay_of, platform, operator, frames_recorded, reference_note."""
    if origin not in ORIGINS:
        raise ValueError(f"unknown origin {origin}")
    if feature_type not in FEATURE_TYPES:
        feature_type = "other"
    sid = str(uuid.uuid4())
    plat = platform_info()
    return {
        "schema_version": SCHEMA_VERSION,
        "scan_id": sid,
        "session_id": session_id or str(uuid.uuid4()),
        "origin": origin,
        "is_real_sensor": bool(is_real_sensor),
        "replay_of": replay_of,
        "status": "recording", "status_reason": None,
        "device": {"manufacturer": "Intel" if origin == "realsense_d435" else device.get("manufacturer"),
                   "model": device.get("name"), "firmware": device.get("firmware"), "usb_type": device.get("usb_type"),
                   "serial_sha256_8": hashlib.sha256(str(device["serial"]).encode()).hexdigest()[:8] if device.get("serial") else None,
                   "host_os": plat["os"], "host_machine": plat["machine"]},
        "app": {"name": APP_NAME, "version": APP_VERSION, "pipeline_version": PIPELINE_VERSION},
        "platform": plat,
        "captured_at_utc": {"start": captured_at_utc, "end": None},
        "capture": {"modality": {"realsense_d435": "active_ir_stereo_depth", "replay": "replay", "synthetic_fixture": "synthetic_raycast"}.get(origin, origin),
                    "depth_type": "stereo_z16", "depth_units": "m", "depth_scale_m": None, "smoothed_depth_used": False,
                    "profile": profile, "frames_requested": frames_requested, "frames_recorded": 0,
                    "color_present": None, "confidence_present": False, "mesh_present": False, "tracking_poses_present": False,
                    "gravity_reference_present": False, "rig_mode": False},
        "coordinate_frame": dict(FRAME_CONVENTION),
        "location": {"sharing": "hidden", "collected": False, "latitude": None, "longitude": None, "uncertainty_m": None,
                     "note": "the desktop has no GPS; location is never added automatically"},
        "field_site_id": field_site_id, "candidate_id": candidate_id, "candidate_run_id": candidate_run_id,
        "reference_note": "field_site_id / candidate_id are opaque references to the website; no analog scoring happens on the desktop",
        "observation": {"title": title, "feature_type": feature_type, "notes": notes, "claims": [],
                        "feature_type_note": "user annotation, not an automatic classification"},
        "quality": {},
        "measurements": [],
        "files": [],
        "processing": {"pipeline_version": PIPELINE_VERSION, "operations": [], "runs": []},
        "publication": {"status": "local_private", "license": None, "consent_obtained": False},
        "operator": {"started_by": started_by},
        "limitations": list(BASE_LIMITATIONS) + ORIGIN_LIMITATIONS.get(origin, []),
    }


REQUIRED_KEYS = ["schema_version", "scan_id", "origin", "files", "publication", "limitations"]
# coordinate_frame is expected (contracts/SCAN_BUNDLE_V1.md) but not required: the phone's envelope for a scan it
# recovered after a crash had none. Imports without one get an explicit "unknown" frame (see bundle.import_zip),
# so nothing downstream assumes a frame, e.g. no tilt from horizontal is reported.


def validate_manifest(m: dict) -> list[str]:
    """Minimal structural validation for imports. Returns a list of problems (empty = ok)."""
    errs = []
    for k in REQUIRED_KEYS:
        if k not in m:
            errs.append(f"missing {k}")
    if errs:
        return errs
    if str(m["schema_version"]).split(".")[0] != SCHEMA_VERSION.split(".")[0]:
        errs.append(f"unsupported schema_version {m['schema_version']}")
    try:
        uuid.UUID(str(m["scan_id"]))
    except ValueError:
        errs.append("scan_id is not a UUID")
    if m["origin"] not in ORIGINS:
        errs.append(f"unknown origin {m['origin']!r}")
    if not isinstance(m["files"], list):
        errs.append("files must be a list")
    else:
        for f in m["files"]:
            p = str(f.get("path", ""))
            if not p or p.startswith("/") or ".." in Path(p).parts:
                errs.append(f"unsafe file path {p!r}")
            if not isinstance(f.get("sha256"), str) or len(f["sha256"]) != 64:
                errs.append(f"file {p!r} has no sha256")
    pub = m.get("publication") or {}
    if pub.get("status") not in (None, "local_private", "draft_local", "uploading", "private_cloud_draft", "pending_review", "published", "rejected", "removed"):
        errs.append("unknown publication status")
    return errs
