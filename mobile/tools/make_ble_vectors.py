"""Writes contracts/BLE_TEST_VECTORS.json with Python's hmac/hashlib (independent of the Dart code).
Run: python3 mobile/tools/make_ble_vectors.py   (from the repo root)"""
import base64, hashlib, hmac, json, os

def h(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

code = "482913"
nd = base64.b64encode(bytes(range(0, 16))).decode()
np_ = base64.b64encode(bytes(range(16, 32))).decode()
phone_id = "3f2b8c1e-7a4d-4e5f-9b6a-0c1d2e3f4a5b"
key = h(code.encode(), f"key|{nd}|{np_}")
inner = json.dumps({"v": 1, "type": "start_capture", "target": "phone", "id": "11111111-2222-4333-8444-555555555555", "seq": 1},
                   separators=(",", ":"))
out = {
    "note": "HMAC-SHA256; key for proofs = UTF-8 bytes of the code; nonces and outputs are standard base64 with padding",
    "code": code, "nonce_desktop": nd, "nonce_phone": np_, "phone_id": phone_id,
    "phone_proof": base64.b64encode(h(code.encode(), f"pair1|{nd}|{np_}|{phone_id}")).decode(),
    "desktop_proof": base64.b64encode(h(code.encode(), f"pair2|{np_}|{nd}")).decode(),
    "session_key_b64": base64.b64encode(key).decode(),
    "session_key_hex": key.hex(),
    "example_inner": inner,
    "example_mac": base64.b64encode(h(key, inner)).decode(),
    "example_wire": json.dumps({"m": inner, "mac": base64.b64encode(h(key, inner)).decode()}),
}
p = os.path.join(os.path.dirname(__file__), "..", "..", "contracts", "BLE_TEST_VECTORS.json")
with open(p, "w") as f:
    json.dump(out, f, indent=1)
print(json.dumps(out, indent=1))
