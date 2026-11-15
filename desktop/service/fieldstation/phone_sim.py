"""Phone (central) side of BLE_PROTOCOL_V1, written from the contract alone.

FOR TESTS AND REHEARSAL ONLY. It talks to DesktopLink directly (no radio), so
it proves the application protocol, not Bluetooth. The real phone
implementation is the mobile team's ble_protocol.dart.
"""
from __future__ import annotations

import json
import secrets
import uuid

from .protocol import Reassembler, b64, chunk_message, hm, pair_proof_desktop, pair_proof_phone, session_key, wrap


class PhoneSim:
    def __init__(self, link, central: str = "00000000-0000-0000-0000-00000000c0de", max_chunk: int = 182,
                 phone_name: str = "Test iPhone"):
        self.link = link
        self.central = central
        self.max_chunk = max_chunk
        self.phone_id = secrets.token_hex(8)
        self.phone_name = phone_name
        self.np = b64(secrets.token_bytes(16))
        self.key: bytes | None = None
        self.seq = 0
        self.counter = 0
        self.rx = Reassembler()
        self.inbox: list[dict] = []
        self.code = None
        self.nd = None

    # desktop -> phone transport
    def deliver(self, central: str, chunk: bytes) -> None:
        if central != self.central:
            return
        msg = self.rx.feed(chunk)
        if msg is None:
            return
        obj = json.loads(msg)
        if "m" in obj and "mac" in obj:
            if self.key is None or b64(hm(self.key, obj["m"])) != obj["mac"]:
                self.inbox.append({"type": "_bad_mac"})
                return
            obj = json.loads(obj["m"])
        self.inbox.append(obj)

    def _send(self, obj: dict) -> None:
        for ch in chunk_message(obj, self.counter, self.max_chunk):
            self.link.on_rx(self.central, ch, self.max_chunk)
        self.counter = (self.counter + 1) & 0xFF

    def read_info(self) -> dict:
        info = self.link.info()
        self.nd = info["nonce"]
        return info

    def pair(self, code: str) -> dict:
        self.read_info()
        self.code = code
        self._send({"v": 1, "type": "pair_request", "phone_id": self.phone_id, "phone_name": self.phone_name,
                    "nonce_phone": self.np, "proof": pair_proof_phone(code, self.nd, self.np, self.phone_id)})
        reply = self.inbox[-1]
        if reply.get("type") == "pair_accept":
            if reply["proof"] != pair_proof_desktop(code, self.nd, self.np):
                raise RuntimeError("desktop proof did not verify")
            self.key = session_key(code, self.nd, self.np)
        return reply

    def send(self, type_: str, msg_id: str | None = None, seq: int | None = None, **fields) -> dict:
        if seq is None:
            self.seq += 1
            seq = self.seq
        inner = {"v": 1, "type": type_, "id": msg_id or str(uuid.uuid4()), "seq": seq, **fields}
        self._send(wrap(self.key, inner))
        return inner

    def send_raw(self, obj: dict) -> None:
        self._send(obj)

    def acks_for(self, msg_id: str) -> list[dict]:
        return [m for m in self.inbox if m.get("type") == "ack" and m.get("ref") == msg_id]
