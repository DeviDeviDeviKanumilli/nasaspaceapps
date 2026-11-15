"""Scan bundles on disk (contracts/SCAN_BUNDLE_V1.md).

    scan-<scan_id>/
      scan.json                 envelope; rewritten atomically; final version lists SHA-256 of every other file
      calibration.json          raw: intrinsics, extrinsics, depth scale, device
      frames.jsonl              raw: one line per recorded frame (timestamps, frame numbers, file names, hashes)
      frames/depth_00000.png    raw: 16-bit z16 sensor units (x depth_scale_m = metres), 0 = no data
      frames/color_00000.png    raw: RGB from the colour sensor (native stream, not aligned)
      point_cloud_raw.ply       DERIVED from one raw frame with no filtering (role raw_point_cloud)
      point_cloud_filtered.ply  DERIVED: temporal median + range clip + flying-pixel removal (+ options)
      depth_filtered.png        DERIVED: the filtered depth image (same units as raw)
      thumbnail.jpg             DERIVED preview; never the only output
      metrics.json              DERIVED: capture quality + measurements + analyses
      log.jsonl                 capture / device / processing events
      catalog_draft.json        optional local CatalogEntry draft (never uploaded by this app)

Raw files are made read-only once written. Reprocessing replaces derived files
only. A bundle left in "recording"/"processing" by a crash is marked
"incomplete" on the next start, never silently "complete".
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import threading
import uuid
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

from . import PIPELINE_VERSION, SCHEMA_VERSION
from .adapters.base import Calibration, Frame, utc_now
from .camera_model import FRAME_CONVENTION
from .metrics import capture_quality, roi_points_from_pixels, roughness_analysis
from .ply import make_vertices, read_ply, rgb_of, write_ply, xyz_of
from .mesh import grid_mesh, write_glb, write_mesh_ply
from .pointcloud import FILTER_DEFAULTS, build_filtered_cloud, build_raw_cloud, register_color
from .schema import ENVELOPE, ORIGIN_LIMITATIONS, file_entry, new_manifest, sha256_file, validate_manifest

MAX_IMPORT_BYTES = 4 * 1024 ** 3
MAX_IMPORT_FILES = 20000


class BundleError(RuntimeError):
    pass


class DuplicateScan(BundleError):
    pass


def atomic_write_json(path: Path, obj) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2, default=_json_default)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _json_default(o):
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    raise TypeError(type(o))


def _make_readonly(p: Path) -> None:
    os.chmod(p, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)


def _save_png_atomic(path: Path, arr: np.ndarray) -> None:
    tmp = path.with_name(path.name + ".tmp.png")
    if arr.dtype == np.uint16:
        Image.fromarray(np.ascontiguousarray(arr, dtype="<u2")).save(tmp, format="PNG", compress_level=1)
    else:
        Image.fromarray(arr).save(tmp, format="PNG", compress_level=1)
    os.replace(tmp, path)


def load_depth_png(path: Path) -> np.ndarray:
    return np.array(Image.open(path), dtype=np.uint16)


def depth_colormap(depth_m: np.ndarray, zmin: float = 0.2, zmax: float = 4.0) -> np.ndarray:
    """Perceptual-ish near=warm far=cool map; invalid = black. Display only."""
    t = np.clip((depth_m - zmin) / (zmax - zmin), 0, 1)
    r = np.clip(1.5 - np.abs(4 * t - 1), 0, 1)
    g = np.clip(1.5 - np.abs(4 * t - 2), 0, 1)
    b = np.clip(1.5 - np.abs(4 * t - 3), 0, 1)
    rgb = (np.stack([r, g, b], -1) * 255).astype(np.uint8)
    rgb[depth_m <= 0] = 0
    return rgb


class ScanWriter:
    """Writes one scan bundle while a capture runs. Thread-safe for one producer."""

    def __init__(self, store: "ScanStore", manifest: dict, calib: Calibration):
        self.store = store
        self.m = manifest
        self.calib = calib
        self.dir = store.root / f"scan-{manifest['scan_id']}"
        self.dir.mkdir(parents=True, exist_ok=False)
        (self.dir / "frames").mkdir()
        self.n = 0
        self.last_frame_number = None
        self.dropped = 0
        self._lock = threading.Lock()
        self.m["capture"]["depth_scale_m"] = calib.depth_scale_m
        self.m["capture"]["color_present"] = calib.color is not None
        atomic_write_json(self.dir / "calibration.json", {"schema_version": SCHEMA_VERSION, **calib.to_dict()})
        _make_readonly(self.dir / "calibration.json")
        self.save_manifest()
        self.log("capture_started", profile=manifest["capture"]["profile"], device=calib.device, origin=manifest["origin"])

    def save_manifest(self) -> None:
        atomic_write_json(self.dir / ENVELOPE, self.m)

    def log(self, event: str, **data) -> None:
        with open(self.dir / "log.jsonl", "a") as f:
            f.write(json.dumps({"t_utc": utc_now(), "event": event, **data}, default=_json_default) + "\n")

    def write_frame(self, fr: Frame) -> None:
        with self._lock:
            i = self.n
            rec = {"i": i, "adapter_index": fr.index, "wall_utc": fr.wall_utc, "timestamp_domain": fr.timestamp_domain,
                   "depth_timestamp_ms": fr.depth_timestamp_ms, "color_timestamp_ms": fr.color_timestamp_ms,
                   "depth_frame_number": fr.depth_frame_number, "color_frame_number": fr.color_frame_number}
            if fr.depth is None:
                raise BundleError("frame without depth")
            dname = f"depth_{i:05d}.png"
            _save_png_atomic(self.dir / "frames" / dname, fr.depth)
            _make_readonly(self.dir / "frames" / dname)
            rec["depth_file"] = dname
            rec["depth_sha256"] = sha256_file(self.dir / "frames" / dname)
            if fr.color is not None:
                cname = f"color_{i:05d}.png"
                _save_png_atomic(self.dir / "frames" / cname, fr.color)
                _make_readonly(self.dir / "frames" / cname)
                rec["color_file"] = cname
                rec["color_sha256"] = sha256_file(self.dir / "frames" / cname)
            if fr.depth_frame_number is not None and self.last_frame_number is not None:
                gap = fr.depth_frame_number - self.last_frame_number - 1
                if gap > 0:
                    self.dropped += gap
                    rec["frames_skipped_before"] = gap
            self.last_frame_number = fr.depth_frame_number
            with open(self.dir / "frames.jsonl", "a") as f:
                f.write(json.dumps(rec) + "\n")
            self.n += 1
            self.m["capture"]["frames_recorded"] = self.n
            self.m["capture"]["frames_skipped_between_recorded"] = self.dropped
            if self.n % 10 == 0:
                self.save_manifest()   # keeps the on-disk count current for crash recovery

    def finish(self, reason: str, ok: bool) -> None:
        """Called when recording stops. ok=False (device lost, error) leaves the scan 'incomplete'."""
        self.m["captured_at_utc"]["end"] = utc_now()
        self.m["status"] = "processing" if ok else "incomplete"
        self.m["status_reason"] = reason
        self.save_manifest()
        self.log("capture_stopped", reason=reason, ok=ok, frames=self.n, skipped=self.dropped)


class ScanStore:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.exports = self.root.parent / "exports"
        self.exports.mkdir(exist_ok=True)
        self.recovered = self.recover()

    # ---- lookup -------------------------------------------------------------
    def dir_of(self, scan_id: str) -> Path:
        uuid.UUID(scan_id)  # raises ValueError for anything that is not a UUID (no path tricks)
        d = self.root / f"scan-{scan_id}"
        if not (d / ENVELOPE).exists():
            raise KeyError(scan_id)
        return d

    def manifest(self, scan_id: str) -> dict:
        return json.loads((self.dir_of(scan_id) / ENVELOPE).read_text())

    def list(self) -> list[dict]:
        out = []
        for m in self.root.glob(f"scan-*/{ENVELOPE}"):
            try:
                man = json.loads(m.read_text())
            except Exception:
                out.append({"scan_id": m.parent.name[5:], "status": "unreadable", "error": "scan.json could not be parsed"})
                continue
            obs = man.get("observation") or {}
            out.append({
                "scan_id": man["scan_id"], "session_id": man.get("session_id"), "origin": man.get("origin"),
                "is_real_sensor": man.get("is_real_sensor"), "status": man.get("status"), "status_reason": man.get("status_reason"),
                "title": obs.get("title"), "feature_type": obs.get("feature_type"),
                "captured_at_utc": (man.get("captured_at_utc") or {}).get("start") if isinstance(man.get("captured_at_utc"), dict) else man.get("captured_at_utc"),
                "frames": (man.get("capture") or {}).get("frames_recorded") or (man.get("capture") or {}).get("keyframes"),
                "device_model": (man.get("device") or {}).get("model"), "field_site_id": man.get("field_site_id"),
                "publication_status": (man.get("publication") or {}).get("status"),
                "has_thumbnail": (m.parent / "thumbnail.jpg").exists(),
                "measurement_count": len(man.get("measurements") or []),
            })
        out.sort(key=lambda r: r.get("captured_at_utc") or "", reverse=True)
        return out

    def recover(self) -> list[str]:
        fixed = []
        for m in self.root.glob(f"scan-*/{ENVELOPE}"):
            try:
                man = json.loads(m.read_text())
            except Exception:
                continue
            if man.get("status") in ("recording", "processing"):
                man["status"] = "incomplete"
                man["status_reason"] = f"app stopped while the scan was {man['status']}; recovered at next start"
                atomic_write_json(m, man)   # reason is in status_reason; log.jsonl is not touched (its hash may be listed)
                fixed.append(man["scan_id"])
            for tmp in m.parent.rglob("*.tmp*"):
                tmp.unlink(missing_ok=True)
        return fixed

    def new_writer(self, calib: Calibration, **manifest_kwargs) -> ScanWriter:
        m = new_manifest(captured_at_utc=utc_now(), **manifest_kwargs)
        return ScanWriter(self, m, calib)

    def save_manifest(self, scan_id: str, man: dict) -> None:
        atomic_write_json(self.dir_of(scan_id) / ENVELOPE, man)

    # ---- processing ------------------------------------------------------------
    def process(self, scan_id: str, params: dict | None = None) -> dict:
        """(Re)build all derived artifacts of a recorded scan from its raw frames."""
        d = self.dir_of(scan_id)
        man = self.manifest(scan_id)
        if man.get("origin") in ("iphone_arkit_lidar", "iphone_arkit_camera", "unknown_import"):
            raise BundleError("imported scans are analysed from their own files; there are no raw D435 frames to process")
        prev_status = man["status"]
        calib = Calibration.from_dict(json.loads((d / "calibration.json").read_text()))
        recs = [json.loads(l) for l in (d / "frames.jsonl").read_text().splitlines() if l.strip()] if (d / "frames.jsonl").exists() else []
        if not recs:
            man["status"] = "incomplete"
            man["status_reason"] = (man.get("status_reason") or "") + "; no frames recorded"
            self.save_manifest(scan_id, man)
            raise BundleError("no frames recorded")
        p = {**FILTER_DEFAULTS, **(params or {})}
        stack = np.stack([load_depth_png(d / "frames" / r["depth_file"]) for r in recs])
        mid = len(recs) // 2
        color = None
        if recs[mid].get("color_file"):
            color = np.array(Image.open(d / "frames" / recs[mid]["color_file"]).convert("RGB"))
        raw = build_raw_cloud(stack[mid], calib.depth_scale_m, calib.depth, color, calib.color, calib.depth_to_color, p)
        filt = build_filtered_cloud(stack, calib.depth_scale_m, calib.depth, color, calib.color, calib.depth_to_color, p)
        origin = man["origin"]
        base_comments = [f"schema {SCHEMA_VERSION}", "units m", "frame camera_optical_m (+X right, +Y down, +Z forward, right-handed)",
                         f"scan_id {scan_id}", f"origin {origin}", f"pipeline {PIPELINE_VERSION}"]
        if origin != "realsense_d435":
            base_comments.append("NOT A LIVE SENSOR CAPTURE: " + " ".join(ORIGIN_LIMITATIONS.get(origin, [origin])))
        write_ply(d / "point_cloud_raw.ply",
                  make_vertices(raw["points"], raw["rgb"], color_valid=raw["color_valid"].astype(np.uint8)),
                  base_comments + [f"kind raw_single_frame frame_index {mid} (only depth==0 removed; no filtering)"])
        write_ply(d / "point_cloud_filtered.ply",
                  make_vertices(filt["points"], filt["rgb"], color_valid=filt["color_valid"].astype(np.uint8),
                                n_valid_frames=filt["n_valid_frames"].astype(np.uint8)),
                  base_comments + [f"kind filtered from {len(recs)} frames; see scan.json processing"])
        # bounded grid mesh (derived): only neighbouring measured pixels with consistent depth are joined
        gm = grid_mesh(filt["depth_filtered_m"], calib.depth, step=2, rel_jump=p["flying_pixel_rel_jump"], abs_m=p["flying_pixel_abs_m"])
        if color is not None and calib.color is not None and calib.depth_to_color is not None:
            gm["rgb"], _ = register_color(gm["points"], calib.color, calib.depth_to_color, color,
                                          p["color_occlusion_tol_rel"], p["color_occlusion_tol_abs_m"])
        write_mesh_ply(d / "mesh_grid.ply", gm["points"], gm["rgb"], gm["faces"],
                       base_comments + ["kind DERIVED grid mesh from depth_filtered.png; neighbouring measured pixels only; no hole filling"])
        write_glb(d / "mesh_grid.glb", gm["points"], gm["rgb"], gm["faces"],
                  {"scan_id": scan_id, "origin": origin, "kind": "derived grid mesh; no hole filling", **gm["params"]})
        filt["operations"].append({"op": "grid_mesh", **gm["params"], "vertices": int(len(gm["points"])), "faces": int(len(gm["faces"]))})
        filt_raw_units = np.round(filt["depth_filtered_m"] / calib.depth_scale_m).astype(np.uint16)
        _save_png_atomic(d / "depth_filtered.png", filt_raw_units)
        # thumbnail: colour | filtered depth
        dm = depth_colormap(filt["depth_filtered_m"])
        tiles = [Image.fromarray(dm)]
        if color is not None:
            tiles.insert(0, Image.fromarray(color).resize((dm.shape[1], dm.shape[0])))
        th = Image.new("RGB", (sum(t.width for t in tiles), dm.shape[0]))
        x = 0
        for t in tiles:
            th.paste(t, (x, 0))
            x += t.width
        th.thumbnail((640, 240))
        th.save(d / "thumbnail.jpg.tmp.jpg", quality=85)
        os.replace(d / "thumbnail.jpg.tmp.jpg", d / "thumbnail.jpg")
        # default analysis: central 50 % of the filtered depth image
        h, w = filt["depth_filtered_m"].shape
        rect = [w // 4, h // 4, 3 * w // 4, 3 * h // 4]
        roi = {"kind": "pixel_rect", "rect_px": rect, "label": "default: central 50% of depth image"}
        pts, _ = roi_points_from_pixels(filt["depth_filtered_m"], rect, calib.depth)
        per_frame = []
        for k in range(len(recs)):
            pk, _ = roi_points_from_pixels(stack[k].astype(np.float64) * calib.depth_scale_m, rect, calib.depth)
            if len(pk) >= 50:
                from .metrics import plane_fit
                per_frame.append(plane_fit(pk)["rms_orthogonal_m"])
        noise = {"fx_px": calib.depth.fx, "baseline_m": calib.stereo_baseline_m} if calib.stereo_baseline_m else None
        default = roughness_analysis(pts, roi, per_frame_rms=per_frame, noise_model=noise, source_artifact="depth_filtered.png",
                                     label=roi["label"])
        quality = capture_quality(stack, calib.depth_scale_m, filt)
        quality.update({"raw_point_cloud_points": int(len(raw["points"])), "filtered_point_cloud_points": int(len(filt["points"])),
                        "frames_skipped_between_recorded": man["capture"].get("frames_skipped_between_recorded", 0)})
        old_metrics = {}
        if (d / "metrics.json").exists():
            old_metrics = json.loads((d / "metrics.json").read_text())
        metrics = {
            "schema_version": SCHEMA_VERSION, "scan_id": scan_id, "source": origin, "coordinate_frame": "camera_optical_m",
            "pipeline_version": PIPELINE_VERSION, "computed_utc": utc_now(),
            "capture_quality": quality,
            "default_analysis": {"roi": roi, "status": default["status"], "plane": default.get("plane"),
                                 "measurements": default["measurements"]},
            "analyses": old_metrics.get("analyses", []),
            "gravity_referenced_slope": {"status": "not_measured", "reason": "no_measured_world_up"},
            "uncertainty": {"method": "repeat_acquisition", "n": len(self.session_scans(man["session_id"])),
                            "note": "compare scans in the same session (Library > Repeatability)"},
            "raw_capture_preserved": True, "model_scope": "visible_sensors_only",
        }
        atomic_write_json(d / "metrics.json", metrics)
        ops = filt["operations"]
        man["processing"]["operations"] = [{"op": "raw_point_cloud", "frame_index": mid, "params": {"removed": "depth==0 only"}}] + ops
        man["processing"]["params"] = p
        man["processing"]["runs"].append({"t_utc": utc_now(), "params": p, "pipeline_version": PIPELINE_VERSION})
        man["quality"] = quality
        man["measurements"] = default["measurements"] + [m for a in metrics["analyses"] for m in a.get("measurements", [])]
        man["status"] = "complete" if prev_status in ("processing", "complete") else prev_status
        with open(d / "log.jsonl", "a") as f:   # log first: the file list below hashes the final log
            f.write(json.dumps({"t_utc": utc_now(), "event": "processed", "params": p, "status": man["status"]}, default=_json_default) + "\n")
        self._refresh_files(d, man)
        self.save_manifest(scan_id, man)
        return man

    def _refresh_files(self, d: Path, man: dict) -> None:
        frame = "camera_optical_m"
        files = []
        roles = [("calibration.json", "calibration", "raw", "", None), ("frames.jsonl", "frame_index", "raw", "", None),
                 ("point_cloud_raw.ply", "raw_point_cloud", "derived", "one raw frame back-projected; depth==0 removed only", frame),
                 ("point_cloud_filtered.ply", "derived_point_cloud", "derived", "all frames; see processing.operations", frame),
                 ("mesh_grid.ply", "derived_mesh", "derived", "grid mesh from depth_filtered.png; no hole filling", frame),
                 ("mesh_grid.glb", "derived_mesh_preview", "derived", "same mesh as glTF binary for viewing (frame converted to glTF +Y up)", "gltf_from_camera_optical_m"),
                 ("depth_filtered.png", "derived_depth", "derived", "temporal median + range clip + flying-pixel removal", None),
                 ("thumbnail.jpg", "thumbnail", "derived", "colour + filtered depth preview", None),
                 ("metrics.json", "analysis", "derived", "capture quality and measurements", None),
                 ("log.jsonl", "log", "raw", "", None), ("catalog_draft.json", "catalog_draft", "derived", "local draft only", None)]
        for rel, role, kind, lineage, fr in roles:
            if (d / rel).exists():
                files.append(file_entry(d, rel, role, kind, lineage, fr))
        for p in sorted((d / "frames").glob("*.png")):
            role = "raw_depth" if p.name.startswith("depth_") else "raw_color"
            files.append(file_entry(d, f"frames/{p.name}", role, "raw", "", None))
        man["files"] = files

    def session_scans(self, session_id: str) -> list[dict]:
        return [s for s in self.list() if s.get("session_id") == session_id]

    def add_analysis(self, scan_id: str, analysis: dict) -> dict:
        d = self.dir_of(scan_id)
        man = self.manifest(scan_id)
        mp = d / "metrics.json"
        metrics = json.loads(mp.read_text()) if mp.exists() else {"schema_version": SCHEMA_VERSION, "scan_id": scan_id, "analyses": []}
        analysis = {"analysis_id": str(uuid.uuid4()), "created_utc": utc_now(), **analysis}
        metrics.setdefault("analyses", []).append(analysis)
        atomic_write_json(mp, metrics)
        man["measurements"] = list(man.get("measurements") or []) + analysis.get("measurements", [])
        if man.get("origin") not in ("iphone_arkit_lidar", "iphone_arkit_camera", "unknown_import"):
            self._refresh_files(d, man)
        else:
            self._refresh_import_files(d, man)
        self.save_manifest(scan_id, man)
        return analysis

    # ---- export / import ------------------------------------------------------------
    def export_zip(self, scan_id: str) -> Path:
        d = self.dir_of(scan_id)
        out = self.exports / f"scan-{scan_id}.zip"
        tmp = out.with_suffix(".zip.tmp")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(d.rglob("*")):
                if p.is_file() and ".tmp" not in p.name:
                    z.write(p, f"scan-{scan_id}/{p.relative_to(d)}")
        os.replace(tmp, out)
        return out

    def import_zip(self, zip_path: Path) -> dict:
        """Import a scan bundle zip (from the iPhone app or another desktop). Verifies every listed SHA-256."""
        with zipfile.ZipFile(zip_path) as z:
            infos = [i for i in z.infolist() if not i.is_dir()]
            if len(infos) > MAX_IMPORT_FILES or sum(i.file_size for i in infos) > MAX_IMPORT_BYTES:
                raise BundleError("bundle too large")
            for i in infos:
                parts = Path(i.filename).parts
                if i.filename.startswith("/") or ".." in parts or "\\" in i.filename:
                    raise BundleError(f"unsafe path in zip: {i.filename!r}")
            env = [i for i in infos if Path(i.filename).name == ENVELOPE]
            if len(env) != 1:
                raise BundleError(f"zip must contain exactly one {ENVELOPE}")
            prefix = str(Path(env[0].filename).parent)
            prefix = "" if prefix == "." else prefix + "/"
            man = json.loads(z.read(env[0]))
            errs = validate_manifest(man)
            if errs:
                raise BundleError("invalid scan.json: " + "; ".join(errs))
            sid = man["scan_id"]
            dest = self.root / f"scan-{sid}"
            if dest.exists():
                mine = json.loads((dest / ENVELOPE).read_text())
                same = {f["path"]: f["sha256"] for f in mine.get("files", [])} == {f["path"]: f["sha256"] for f in man["files"]}
                raise DuplicateScan(f"scan {sid} already exists" + (" (identical content: already imported)" if same else " with DIFFERENT content: not overwritten"))
            staging = self.root / f".import-{uuid.uuid4()}"
            staging.mkdir()
            try:
                for i in infos:
                    if not i.filename.startswith(prefix):
                        continue
                    rel = i.filename[len(prefix):]
                    target = staging / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(i) as src, open(target, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                bad = []
                for f in man["files"]:
                    p = staging / f["path"]
                    if not p.exists():
                        bad.append(f"missing {f['path']}")
                    elif sha256_file(p) != f["sha256"]:
                        bad.append(f"checksum mismatch {f['path']}")
                if bad:
                    raise BundleError("bundle failed verification: " + "; ".join(bad[:10]))
                os.replace(staging, dest)
            except Exception:
                shutil.rmtree(staging, ignore_errors=True)
                raise
        # imported envelopes keep their own status; we only note it was imported
        man["desktop_import"] = {"imported_utc": utc_now(), "verified_sha256_files": len(man["files"]), "source_zip": zip_path.name}
        man["status"] = man.get("status") or "imported"
        atomic_write_json(dest / ENVELOPE, man)
        return man

    def import_ply(self, ply_path: Path, title: str = "", declared_origin: str = "unknown_import") -> dict:
        """A bare PLY with no envelope: kept, but provenance is flagged as unverified."""
        verts, comments = read_ply(ply_path)
        m = new_manifest(origin="unknown_import", is_real_sensor=False, device={"name": None}, profile=None, frames_requested=None,
                         title=title or ply_path.stem, captured_at_utc=None)
        m["status"] = "imported"
        m["status_reason"] = "bare PLY without a provenance envelope"
        m["coordinate_frame"] = {"name": "unknown", "units": "m (assumed)", "note": "PLY header comments: " + " | ".join(comments)[:500]}
        m["capture"].update({"depth_type": None, "depth_units": None, "modality": "unknown"})
        d = self.root / f"scan-{m['scan_id']}"
        d.mkdir()
        shutil.copyfile(ply_path, d / "point_cloud_imported.ply")
        self._refresh_import_files(d, m)
        atomic_write_json(d / ENVELOPE, m)
        return m

    def _refresh_import_files(self, d: Path, man: dict) -> None:
        known = {f["path"]: f for f in man.get("files", [])}
        for rel in ("metrics.json", "point_cloud_imported.ply", "catalog_draft.json"):
            if (d / rel).exists():
                role = {"metrics.json": "analysis", "point_cloud_imported.ply": "imported_point_cloud", "catalog_draft.json": "catalog_draft"}[rel]
                known[rel] = file_entry(d, rel, role, "derived" if rel != "point_cloud_imported.ply" else "raw", "desktop", None)
        man["files"] = list(known.values())

    def cloud_file(self, scan_id: str, kind: str = "filtered") -> Path:
        """Pick the point cloud to show/analyse for a scan, whatever produced it."""
        d = self.dir_of(scan_id)
        candidates = {"filtered": ["point_cloud_filtered.ply", "point_cloud_fused.ply", "point_cloud_imported.ply"],
                      "raw": ["point_cloud_raw.ply", "point_cloud_fused.ply", "point_cloud_imported.ply"],
                      "mesh": ["mesh_grid.ply", "mesh_arkit.ply"]}[kind]
        for c in candidates:
            if (d / c).exists():
                return d / c
        raise KeyError(f"no {kind} point cloud in scan {scan_id}")

    def write_catalog_draft(self, scan_id: str, fields: dict) -> dict:
        """Local CatalogEntry draft. Never uploads; there is no catalog service in this build."""
        d = self.dir_of(scan_id)
        man = self.manifest(scan_id)
        draft = {
            "schema_version": SCHEMA_VERSION, "catalog_entry_id": str(uuid.uuid4()), "scan_id": scan_id,
            "status": "draft_local", "visibility": "private",
            "title": fields.get("title") or (man.get("observation") or {}).get("title"),
            "license": fields.get("license"), "attribution": fields.get("attribution"),
            "author_approval": bool(fields.get("author_approval")), "consent_obtained": bool(fields.get("consent_obtained")),
            "people_or_private_property_visible": fields.get("people_or_private_property_visible"),
            "location_precision": "hidden", "tags": fields.get("tags", []),
            "quality_label": "unreviewed_user_contribution",
            "public_files": fields.get("public_files", ["point_cloud_filtered.ply", "thumbnail.jpg", "metrics.json", "scan.json"]),
            "notes": "Local draft only. Upload/publication requires a catalog service, which this build does not have.",
            "created_utc": utc_now(), "revision_history": [{"t_utc": utc_now(), "change": "created"}],
        }
        atomic_write_json(d / "catalog_draft.json", draft)
        man["publication"]["license"] = draft["license"]
        man["publication"]["consent_obtained"] = draft["consent_obtained"]
        man["publication"]["catalog_entry_id"] = draft["catalog_entry_id"]
        man["publication"]["status"] = "draft_local"
        if man.get("origin") in ("iphone_arkit_lidar", "iphone_arkit_camera", "unknown_import"):
            self._refresh_import_files(d, man)
        else:
            self._refresh_files(d, man)
        self.save_manifest(scan_id, man)
        return draft

    def update_observation(self, scan_id: str, fields: dict) -> dict:
        man = self.manifest(scan_id)
        obs = man.setdefault("observation", {})
        for k in ("title", "notes", "feature_type"):
            if k in fields:
                obs[k] = fields[k]
        for k in ("field_site_id", "candidate_id", "candidate_run_id"):
            if k in fields:
                man[k] = fields[k] or None
        if "claims" in fields:
            obs["claims"] = [{"text": str(c.get("text", "")), "kind": c.get("kind") if c.get("kind") in ("observed", "interpreted", "user_reported") else "user_reported"}
                             for c in fields["claims"]]
        self.save_manifest(scan_id, man)
        return man


def default_home() -> Path:
    env = os.environ.get("FIELDSTATION_HOME")
    if env:
        return Path(env)
    return Path.home() / "Library" / "Application Support" / "FieldStation"
