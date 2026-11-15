"""Phone <-> desktop BLE control protocol v1, desktop (peripheral) side.

Implements contracts/BLE_PROTOCOL_V1.md (written by the mobile team):
framing (2-byte header: counter, flags 0x01=last), 6-digit-code HMAC pairing,
MAC-wrapped inner messages with seq + id de-duplication, acks.

Transport-independent: the radio (CoreBluetooth in the Flutter macOS runner)
hands written chunks to `on_rx` and sends whatever `send_cb` is given. This
module never moves scan files; BLE is control only.

Interpretation choices where the contract is silent (sent to the mobile team):
  * HMAC key for pairing = UTF-8 bytes of the 6-digit code string
  * nonces, proofs, MACs = standard base64 with padding
  * K = raw 32-byte HMAC-SHA256 output
  * seq starts at 1 per sender per session
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import threading
import time
import uuid
from collections import deque

from . import PROTOCOL_VERSION

PAIR_WINDOW_S = 120
MAX_BAD_PROOFS = 3
SESSION_S = 3600
ACK_TIMEOUT_S = 5.0
CAPABILITIES = ["d435_capture", "scan_import"]
FLAG_LAST = 0x01


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def unb64(s: str) -> bytes:
    return base64.b64decode(s.encode("ascii"), validate=True)


def hm(key: bytes, msg: str | bytes) -> bytes:
    return hmac.new(key, msg.encode("utf-8") if isinstance(msg, str) else msg, hashlib.sha256).digest()


def pair_proof_phone(code: str, nd_b64: str, np_b64: str, phone_id: str) -> str:
    return b64(hm(code.encode("utf-8"), f"pair1|{nd_b64}|{np_b64}|{phone_id}"))


def pair_proof_desktop(code: str, nd_b64: str, np_b64: str) -> str:
    return b64(hm(code.encode("utf-8"), f"pair2|{np_b64}|{nd_b64}"))


def session_key(code: str, nd_b64: str, np_b64: str) -> bytes:
    return hm(code.encode("utf-8"), f"key|{nd_b64}|{np_b64}")


def wrap(key: bytes, inner: dict) -> dict:
    m = json.dumps(inner, separators=(",", ":"))
    return {"m": m, "mac": b64(hm(key, m))}


def chunk_message(obj: dict, counter: int, max_chunk: int) -> list[bytes]:
    """Split one JSON message into chunks of at most max_chunk bytes (= MTU - 3), each with the 2-byte header."""
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    room = max(1, max_chunk - 2)
    parts = [data[i:i + room] for i in range(0, len(data), room)] or [b""]
    return [bytes([counter & 0xFF, FLAG_LAST if i == len(parts) - 1 else 0]) + p for i, p in enumerate(parts)]


class Reassembler:
    def __init__(self):
        self.counter = None
        self.buf = bytearray()

    def feed(self, chunk: bytes) -> bytes | None:
        if len(chunk) < 2:
            self.counter, self.buf = None, bytearray()
            return None
        c, flags, payload = chunk[0], chunk[1], chunk[2:]
        if self.counter is not None and c != self.counter:
            self.buf = bytearray()       # a new counter discards the partial message
        self.counter = c
        self.buf += payload
        if flags & FLAG_LAST:
            out = bytes(self.buf)
            self.counter, self.buf = None, bytearray()
            return out
        return None


class PhoneSession:
    def __init__(self, central: str, key: bytes, phone_id: str, phone_name: str):
        self.central = central
        self.key = key
        self.phone_id = phone_id
        self.phone_name = phone_name
        self.expires = time.time() + SESSION_S
        self.last_seq_in = 0
        self.seq_out = 0
        self.seen: deque = deque(maxlen=128)
        self.replies: dict[str, dict] = {}
        self.pending: dict[str, dict] = {}     # outgoing commands awaiting ack
        self.phone_state: dict | None = None
        self.paired_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class DesktopLink:
    """Desktop side of the control protocol. `send_cb(central, chunk_bytes)` delivers one notify chunk."""

    def __init__(self, name: str, desktop_id: str, send_cb=None, controller=None, on_event=None):
        self.name = name
        self.desktop_id = desktop_id
        self.send_cb = send_cb or (lambda c, b: None)
        self.controller = controller
        self.on_event = on_event or (lambda ev: None)
        self.code: str | None = None
        self.nd: str = b64(secrets.token_bytes(16))
        self.window_until = 0.0
        self.bad_proofs = 0
        self.locked = False
        self.rx: dict[str, Reassembler] = {}
        self.sessions: dict[str, PhoneSession] = {}
        self.max_chunk: dict[str, int] = {}
        self.out_counter: dict[str, int] = {}
        self._lock = threading.RLock()

    # ---- pairing window (user pressed "Pair a phone")
    def open_pairing(self) -> dict:
        with self._lock:
            self.code = f"{secrets.randbelow(10 ** 6):06d}"
            self.nd = b64(secrets.token_bytes(16))
            self.window_until = time.time() + PAIR_WINDOW_S
            self.bad_proofs = 0
            self.locked = False
        self.on_event({"type": "pairing_opened", "expires_in_s": PAIR_WINDOW_S})
        return {"code": self.code, "expires_in_s": PAIR_WINDOW_S}

    def close_pairing(self) -> None:
        with self._lock:
            self.code = None
            self.window_until = 0.0

    def pairing_status(self) -> dict:
        with self._lock:
            open_ = self.code is not None and time.time() < self.window_until and not self.locked
            return {"open": open_, "code": self.code if open_ else None,
                    "expires_in_s": max(0, int(self.window_until - time.time())) if open_ else 0,
                    "locked": self.locked, "bad_proofs": self.bad_proofs,
                    "phones": [{"central": s.central, "phone_id": s.phone_id, "phone_name": s.phone_name,
                                "paired_utc": s.paired_utc, "expires_in_s": int(s.expires - time.time()),
                                "phone_state": s.phone_state} for s in self.sessions.values() if s.expires > time.time()]}

    def info(self) -> dict:
        return {"v": PROTOCOL_VERSION, "role": "desktop", "name": self.name, "desktop_id": self.desktop_id,
                "nonce": self.nd, "capabilities": CAPABILITIES}

    # ---- transport hooks
    def on_rx(self, central: str, chunk: bytes, max_chunk: int = 182) -> None:
        with self._lock:
            self.max_chunk[central] = max(20, int(max_chunk))
            msg = self.rx.setdefault(central, Reassembler()).feed(chunk)
        if msg is None:
            return
        try:
            obj = json.loads(msg.decode("utf-8"))
        except Exception:
            self._send_plain(central, {"v": PROTOCOL_VERSION, "type": "error", "code": "bad_json", "message": "could not parse message"})
            return
        if isinstance(obj, dict) and "m" in obj and "mac" in obj:
            self._on_wrapped(central, obj)
        elif isinstance(obj, dict) and obj.get("type") == "pair_request":
            self._on_pair_request(central, obj)
        else:
            self._send_plain(central, {"v": PROTOCOL_VERSION, "type": "error", "code": "not_paired",
                                       "message": "pair first; only pair_request is accepted unauthenticated"})

    def on_disconnect(self, central: str) -> None:
        with self._lock:
            self.rx.pop(central, None)
            s = self.sessions.get(central)
        if s:
            self.on_event({"type": "phone_disconnected", "phone_name": s.phone_name, "central": central})

    # ---- internals
    def _send_plain(self, central: str, obj: dict) -> None:
        with self._lock:
            c = self.out_counter.get(central, 0)
            self.out_counter[central] = (c + 1) & 0xFF
            mc = self.max_chunk.get(central, 182)
        for ch in chunk_message(obj, c, mc):
            self.send_cb(central, ch)

    def _on_pair_request(self, central: str, req: dict) -> None:
        with self._lock:
            now = time.time()
            if self.locked:
                reason = "locked"
            elif self.code is None or now > self.window_until:
                reason = "expired"
            else:
                reason = None
            if reason is None:
                try:
                    expected = pair_proof_phone(self.code, self.nd, str(req["nonce_phone"]), str(req["phone_id"]))
                    good = hmac.compare_digest(expected, str(req.get("proof", "")))
                except Exception:
                    good = False
                if not good:
                    self.bad_proofs += 1
                    if self.bad_proofs >= MAX_BAD_PROOFS:
                        self.locked = True
                    reason = "bad_code"
            if reason:
                self.on_event({"type": "pair_rejected", "reason": reason, "phone_name": req.get("phone_name")})
                self._send_plain(central, {"v": PROTOCOL_VERSION, "type": "pair_reject", "reason": reason})
                return
            npb = str(req["nonce_phone"])
            key = session_key(self.code, self.nd, npb)
            proof = pair_proof_desktop(self.code, self.nd, npb)
            self.sessions[central] = PhoneSession(central, key, str(req["phone_id"]), str(req.get("phone_name") or "iPhone"))
            # one pairing per code: close the window
            self.code = None
            self.window_until = 0.0
        self._send_plain(central, {"v": PROTOCOL_VERSION, "type": "pair_accept", "proof": proof, "expires_s": SESSION_S,
                                   "capabilities": CAPABILITIES})
        self.on_event({"type": "phone_paired", "phone_name": req.get("phone_name"), "central": central})

    def send(self, central: str, type_: str, **fields) -> dict:
        """Send an authenticated inner message to a paired phone. Returns the inner message."""
        with self._lock:
            s = self.sessions.get(central)
            if s is None or s.expires < time.time():
                raise PermissionError("phone not paired or session expired")
            s.seq_out += 1
            inner = {"v": PROTOCOL_VERSION, "type": type_, "id": fields.pop("id", None) or str(uuid.uuid4()), "seq": s.seq_out, **fields}
            if type_ in ("start_capture", "stop_capture", "capture_now"):
                s.pending[inner["id"]] = {"msg": inner, "sent": time.time(), "resent": False}
            key = s.key
        self._send_plain(central, wrap(key, inner))
        return inner

    def broadcast(self, type_: str, **fields) -> None:
        for c in list(self.sessions):
            try:
                self.send(c, type_, **dict(fields))
            except PermissionError:
                pass

    def tick(self) -> None:
        """Call about once a second: re-send unacknowledged commands once after 5 s, then report failure."""
        now = time.time()
        for c, s in list(self.sessions.items()):
            for mid, p in list(s.pending.items()):
                if now - p["sent"] < ACK_TIMEOUT_S:
                    continue
                if not p["resent"]:
                    p["resent"], p["sent"] = True, now
                    with self._lock:
                        s.seq_out += 1
                        msg = {**p["msg"], "seq": s.seq_out}   # same id, new seq
                    self._send_plain(c, wrap(s.key, msg))
                else:
                    s.pending.pop(mid, None)
                    self.on_event({"type": "command_failed", "ref": mid, "command": p["msg"]["type"], "phone_name": s.phone_name})

    def _on_wrapped(self, central: str, outer: dict) -> None:
        with self._lock:
            s = self.sessions.get(central)
        if s is None or s.expires < time.time():
            self._send_plain(central, {"v": PROTOCOL_VERSION, "type": "error", "code": "not_paired", "message": "session missing or expired"})
            return
        try:
            mac_ok = hmac.compare_digest(b64(hm(s.key, str(outer["m"]))), str(outer["mac"]))
        except Exception:
            mac_ok = False
        if not mac_ok:
            self.on_event({"type": "message_dropped", "reason": "bad_mac", "central": central})
            return
        try:
            inner = json.loads(outer["m"])
            seq, mid, typ = int(inner["seq"]), str(inner["id"]), str(inner["type"])
        except Exception:
            self.on_event({"type": "message_dropped", "reason": "malformed_inner", "central": central})
            return
        if mid in s.seen:
            # re-send of something already handled (same id, new seq per contract): ack again, never act twice.
            # A failed original is repeated as-is so the phone still sees the real error.
            prev = s.replies.get(mid)
            if typ in ("start_capture", "stop_capture", "capture_now"):
                extra = {k: v for k, v in (prev or {}).items() if k not in ("v", "type", "id", "seq", "ref", "ok", "error")}
                if prev is not None and not prev.get("ok"):
                    self.send(central, "ack", ref=mid, ok=False, error=prev.get("error"), **extra)
                else:
                    self.send(central, "ack", ref=mid, ok=True, error="duplicate: already handled", **extra)
            if seq > s.last_seq_in:
                s.last_seq_in = seq
            return
        if seq <= s.last_seq_in:
            self.on_event({"type": "message_dropped", "reason": "old_seq", "central": central})
            return
        s.last_seq_in = seq
        s.seen.append(mid)
        self._handle(central, s, inner)

    def _ack(self, central: str, s: PhoneSession, ref: str, ok: bool, error: str | None = None, **extra) -> None:
        reply = {"type": "ack", "ref": ref, "ok": ok, "error": error, **extra}
        s.replies[ref] = reply
        if len(s.replies) > 128:
            s.replies.pop(next(iter(s.replies)))
        self.send(central, "ack", ref=ref, ok=ok, error=error, **extra)

    def _handle(self, central: str, s: PhoneSession, m: dict) -> None:
        t = m["type"]
        ctl = self.controller
        if t == "hello":
            self.send(central, "hello", role="desktop", capabilities=CAPABILITIES)
            if ctl is not None:
                self.send(central, "capture_state", **ctl.capture_state())
        elif t in ("start_capture", "stop_capture", "capture_now"):
            target = m.get("target", "desktop")
            if t == "capture_now" or target != "desktop":
                self._ack(central, s, m["id"], False, "wrong_target")
                return
            if ctl is None:
                self._ack(central, s, m["id"], False, "no_controller")
                return
            try:
                if t == "start_capture":
                    if m.get("sensor_id") not in (None, "realsense:d435"):
                        raise ValueError(f"unknown sensor_id {m.get('sensor_id')}")
                    r = ctl.start_recording(title=m.get("title") or f"Remote capture from {s.phone_name}",
                                            session_id=m.get("session_id"), started_by=f"paired_phone:{s.phone_name}")
                    self._ack(central, s, m["id"], True, None, scan_id=r["scan_id"])
                else:
                    r = ctl.stop_recording(f"stopped_by_phone:{s.phone_name}")
                    self._ack(central, s, m["id"], True, None, scan_id=r["scan_id"])
                self.on_event({"type": "remote_command", "command": t, "phone_name": s.phone_name, "ok": True})
            except Exception as exc:
                self._ack(central, s, m["id"], False, str(exc))
                self.on_event({"type": "remote_command", "command": t, "phone_name": s.phone_name, "ok": False, "error": str(exc)})
        elif t == "ack":
            p = s.pending.pop(str(m.get("ref")), None)
            self.on_event({"type": "phone_ack", "ref": m.get("ref"), "ok": m.get("ok"), "error": m.get("error"),
                           "command": p["msg"]["type"] if p else None, "phone_name": s.phone_name})
        elif t == "capture_state":
            s.phone_state = {k: m.get(k) for k in ("state", "elapsed_ms", "frames_recorded", "tracking", "scan_id")}
            self.on_event({"type": "phone_capture_state", "phone_name": s.phone_name, **s.phone_state})
        elif t == "capture_complete":
            self.on_event({"type": "phone_capture_complete", "phone_name": s.phone_name,
                           **{k: m.get(k) for k in ("scan_id", "keyframes", "points", "bytes")},
                           "note": "transfer the scan by zip (AirDrop / Files / USB) and import it in Library"})
        elif t == "disconnect":
            with self._lock:
                self.sessions.pop(central, None)
            self.on_event({"type": "phone_disconnected", "phone_name": s.phone_name, "reason": m.get("reason")})
        elif t == "error":
            self.on_event({"type": "phone_error", "phone_name": s.phone_name, "code": m.get("code"), "message": m.get("message")})
        else:
            self.send(central, "error", code="unknown_type", message=f"unsupported type {t}", ref=m.get("id"))
