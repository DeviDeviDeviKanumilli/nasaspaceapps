"""BLE control protocol (contracts/BLE_PROTOCOL_V1.md), desktop side, against a contract-based phone simulator.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import json
import time

from fieldstation.phone_sim import PhoneSim
from fieldstation.protocol import DesktopLink, chunk_message, Reassembler, wrap

from conftest import wait_for


def make(controller=None, max_chunk=182):
    events = []
    link = DesktopLink("Field Station test", "abc123", controller=controller, on_event=events.append)
    phone = PhoneSim(link, max_chunk=max_chunk)
    link.send_cb = phone.deliver
    return link, phone, events


def test_framing_roundtrip_small_mtu():
    msg = {"v": 1, "type": "x", "pad": "y" * 500}
    chunks = chunk_message(msg, 7, 20)
    assert all(len(c) <= 20 for c in chunks) and chunks[-1][1] == 1 and all(c[0] == 7 for c in chunks)
    r = Reassembler()
    out = [r.feed(c) for c in chunks]
    assert json.loads(out[-1]) == msg and all(o is None for o in out[:-1])
    # a new counter discards a partial message
    r.feed(chunks[0])
    assert r.feed(chunk_message({"a": 1}, 8, 20)[0]) == b'{"a":1}'


def test_pairing_success_and_mutual_proof():
    link, phone, events = make(max_chunk=23)       # minimum BLE MTU: forces chunking
    code = link.open_pairing()["code"]
    reply = phone.pair(code)
    assert reply["type"] == "pair_accept" and phone.key is not None
    assert link.pairing_status()["open"] is False          # one pairing per code
    assert any(e["type"] == "phone_paired" for e in events)
    phone.send("hello", role="phone", capabilities=["arkit_lidar"])
    assert phone.inbox[-1]["type"] in ("hello", "capture_state")


def test_wrong_code_three_times_locks():
    link, phone, _ = make()
    code = link.open_pairing()["code"]
    wrong = f"{(int(code) + 1) % 10**6:06d}"
    for _ in range(3):
        assert phone.pair(wrong) == {"v": 1, "type": "pair_reject", "reason": "bad_code"}
    assert phone.pair(code)["reason"] == "locked"


def test_expired_window():
    link, phone, _ = make()
    code = link.open_pairing()["code"]
    link.window_until = time.time() - 1
    assert phone.pair(code)["reason"] == "expired"


def test_unpaired_and_forged_messages_rejected(controller):
    link, phone, events = make(controller)
    phone.send_raw({"v": 1, "type": "start_capture", "target": "desktop"})
    assert phone.inbox[-1]["code"] == "not_paired"
    code = link.open_pairing()["code"]
    phone.pair(code)
    controller.open("synthetic", "synthetic:scene-v1")
    forged = wrap(b"\x00" * 32, {"v": 1, "type": "start_capture", "id": "x", "seq": 99, "target": "desktop"})
    phone.send_raw(forged)
    assert controller.state == "streaming"
    assert any(e["type"] == "message_dropped" and e["reason"] == "bad_mac" for e in events)


def test_remote_start_stop_dedupe_and_old_seq(controller, store):
    link, phone, events = make(controller)
    phone.pair(link.open_pairing()["code"])
    controller.open("synthetic", "synthetic:scene-v1")
    m = phone.send("start_capture", target="desktop", sensor_id="realsense:d435", profile="field_static")
    ack = phone.acks_for(m["id"])[0]
    assert ack["ok"] is True
    sid = ack["scan_id"]
    assert store.manifest(sid)["operator"]["started_by"] == "paired_phone:Test iPhone"
    # re-sent with the same id (lost ack): desktop repeats the ack and does NOT start a second capture
    phone.send("start_capture", msg_id=m["id"], target="desktop", sensor_id="realsense:d435")
    acks = phone.acks_for(m["id"])
    assert len(acks) == 2 and len(store.list()) == 1
    assert acks[1]["ok"] is True and acks[1]["error"] == "duplicate: already handled" and acks[1]["scan_id"] == sid
    # an old seq is dropped
    phone.send("stop_capture", seq=1, target="desktop")
    assert any(e.get("reason") == "old_seq" for e in events)
    s = phone.send("stop_capture", target="desktop")
    assert phone.acks_for(s["id"])[0]["ok"] is True
    wait_for(lambda: store.manifest(sid)["status"] in ("complete", "incomplete"))


def test_wrong_target_and_phone_status_events(controller):
    link, phone, events = make(controller)
    phone.pair(link.open_pairing()["code"])
    m = phone.send("start_capture", target="phone", sensor_id="iphone:arkit")
    assert phone.acks_for(m["id"])[0] == {**phone.acks_for(m["id"])[0], "ok": False, "error": "wrong_target"}
    phone.send("capture_state", state="recording", elapsed_ms=1200, frames_recorded=10, tracking="normal", scan_id="s")
    assert link.pairing_status()["phones"][0]["phone_state"]["state"] == "recording"
    phone.send("capture_complete", scan_id="s", keyframes=10, points=1000, bytes=12345)
    assert any(e["type"] == "phone_capture_complete" and "zip" in e["note"] for e in events)


def test_desktop_command_to_phone_resend_then_fail():
    link, phone, events = make()
    phone.pair(link.open_pairing()["code"])
    sent = link.send(phone.central, "start_capture", target="phone", sensor_id="iphone:arkit", profile="default")
    assert phone.inbox[-1]["id"] == sent["id"]
    s = link.sessions[phone.central]
    s.pending[sent["id"]]["sent"] -= 6
    link.tick()                                            # re-sent once, same id
    assert [m.get("id") for m in phone.inbox].count(sent["id"]) == 2
    s.pending[sent["id"]]["sent"] -= 6
    link.tick()
    assert any(e["type"] == "command_failed" and e["ref"] == sent["id"] for e in events)
    # an ack clears a pending command
    sent2 = link.send(phone.central, "stop_capture", target="phone")
    phone.send("ack", ref=sent2["id"], ok=True)
    assert sent2["id"] not in s.pending


def test_mobile_team_vectors():
    """contracts/BLE_TEST_VECTORS.json, generated by the mobile team (their Dart tests assert the same values)."""
    from pathlib import Path
    from fieldstation.protocol import b64, hm, pair_proof_desktop, pair_proof_phone, session_key
    v = json.loads((Path(__file__).resolve().parents[3] / "contracts" / "BLE_TEST_VECTORS.json").read_text())
    assert pair_proof_phone(v["code"], v["nonce_desktop"], v["nonce_phone"], v["phone_id"]) == v["phone_proof"]
    assert pair_proof_desktop(v["code"], v["nonce_desktop"], v["nonce_phone"]) == v["desktop_proof"]
    k = session_key(v["code"], v["nonce_desktop"], v["nonce_phone"])
    assert b64(k) == v["session_key_b64"] and k.hex() == v["session_key_hex"]
    assert b64(hm(k, v["example_inner"])) == v["example_mac"]
    wire = json.loads(v["example_wire"])
    assert wire["m"] == v["example_inner"] and wire["mac"] == v["example_mac"]


def test_desktop_accepts_mobile_vector_pairing():
    """Drive DesktopLink with the vector's code and nonces: it must accept the phone's proof and answer with the desktop proof."""
    from pathlib import Path
    from fieldstation.protocol import chunk_message
    v = json.loads((Path(__file__).resolve().parents[3] / "contracts" / "BLE_TEST_VECTORS.json").read_text())
    link, phone, _ = make()
    link.open_pairing()
    link.code, link.nd = v["code"], v["nonce_desktop"]
    req = {"v": 1, "type": "pair_request", "phone_id": v["phone_id"], "phone_name": "vector phone",
           "nonce_phone": v["nonce_phone"], "proof": v["phone_proof"]}
    for ch in chunk_message(req, 0, 182):
        link.on_rx(phone.central, ch, 182)
    assert phone.inbox[-1]["type"] == "pair_accept" and phone.inbox[-1]["proof"] == v["desktop_proof"]
