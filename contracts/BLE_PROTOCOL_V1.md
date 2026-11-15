# Phone ↔ desktop Bluetooth LE control protocol v1

Status: written 2026-11-15 by the mobile side. The phone side (central) is implemented in
`mobile/lib/core/ble_protocol.dart` (message framing, pairing proofs, message MACs; unit-tested) and
`mobile/lib/core/ble_link.dart` (CoreBluetooth via flutter_blue_plus). The desktop side is `desktop/service/fieldstation/protocol.py`
behind the Swift peripheral in `desktop/app/macos/Runner/MainFlutterWindow.swift`. The phone's protocol code has been run
against the desktop service by `mobile/test/interop_field_station_test.dart` with the radio replaced; **the two have
not yet talked over the air.**

BLE carries small control messages only. Scans move by zip export (AirDrop / Files / USB) in this build;
`transfer_offer` is reserved for a later local Wi-Fi transfer and is not implemented.

## Roles and GATT

Desktop = peripheral (advertises), phone = central (scans, connects). Foreground use only on both sides.

| Item | UUID | Properties |
|---|---|---|
| Service | `2ED62242-2267-41EC-BA7D-A321B67A1B8A` | advertised |
| `info` | `9BC2CC53-AFB3-4C24-AEBC-912AF3962D9B` | read: UTF-8 JSON `{"v":1,"role":"desktop","name":"...","desktop_id":"...","nonce":"<b64 16 bytes>","capabilities":[...]}` |
| `rx` (phone → desktop) | `2C4DE982-D089-429A-9945-5FF10A4935A3` | write with response |
| `tx` (desktop → phone) | `00A3B417-650E-4ABE-8F9C-5332D2E0A07A` | notify |

The desktop generates a new `nonce` and a new 6-digit pairing code each time the user presses "Pair a phone",
shows the code on screen, and lets the window expire after 120 s or 3 wrong proofs. Because the nonce changes with
every press, the phone re-reads `info` just before it sends `pair_request`.

## Framing

A message is UTF-8 JSON, split into chunks of at most (MTU − 3) bytes. Each chunk = 2-byte header + payload:
byte 0 = message counter (mod 256), byte 1 = flags (`0x01` = last chunk). The receiver concatenates payloads with
the same counter until a chunk with the last flag arrives. A gap or a new counter discards the partial message.

## Pairing

Inputs: desktop nonce `Nd` (from `info`), pairing code `C` (typed on the phone), phone nonce `Np` (16 random bytes),
`phone_id` (random, stable per install). HMAC = HMAC-SHA256, strings joined with `|`, nonces in base64.

1. phone → `{"v":1,"type":"pair_request","phone_id":"…","phone_name":"…","nonce_phone":"<Np>","proof":"b64(HMAC(C, 'pair1|Nd|Np|phone_id'))"}`
2. desktop checks the proof (constant-time), then → `{"v":1,"type":"pair_accept","proof":"b64(HMAC(C, 'pair2|Np|Nd'))","expires_s":3600,"capabilities":[…]}`
   or `{"v":1,"type":"pair_reject","reason":"bad_code|expired|locked"}`.
3. The phone checks the desktop's proof. Both derive the session key `K = HMAC(C, 'key|Nd|Np')`.

After pairing every message is wrapped: `{"m":"<inner JSON as a string>","mac":"b64(HMAC(K, utf8(m)))"}`.
The inner message has `v`, `type`, `id` (uuid), `seq` (strictly increasing per sender). The receiver drops
messages with a bad MAC, an old `seq`, or an expired session. Re-sent messages keep their `id` but get a new `seq`; a receiver
that has already seen the `id` sends the `ack` again and does not act on the command a second time. The repeated ack
carries the original outcome: `ok: true, error: "duplicate: already handled"` (plus `scan_id` if the original had one)
when the command succeeded, or `ok: false` with the original error when it failed. A duplicate still advances the
receiver's last seen `seq`. Both sides implement this (phone: `ble_link.dart`; desktop: Field Station, confirmed
2026-11-15).

Encoding (agreed with the desktop): the HMAC key for the proofs is the UTF-8 bytes of the 6-digit code string; nonces,
proofs and MACs are standard base64 with padding; `K` is the raw 32-byte HMAC output; `seq` starts at 1 per sender per
session; the desktop advertises the local name `Field Station <host>` (the phone filters by service UUID). Test vectors:
`BLE_TEST_VECTORS.json` (made with Python's `hmac` by `mobile/tools/make_ble_vectors.py`).

Known weakness: someone who records the pairing exchange over the air can try all 10^6 codes offline and recover
`K`. Fine for a park demo; a QR code with a 128-bit secret would fix it and fits the same formulas.

## Messages (inner)

| type | direction | fields |
|---|---|---|
| `hello` | both | `role`, `capabilities` (`arkit_lidar`, `arkit_camera`, `d435_capture`, `scan_import`) |
| `start_capture` | both | `target` (`phone` or `desktop`), `sensor_id` (`iphone:arkit`, `realsense:d435`), `profile` |
| `stop_capture` | both | `target` |
| `capture_now` | desktop → phone | one keyframe/photo now |
| `capture_state` | both (about every 1 s while recording) | `state` (`idle`, `recording`, `paused`, `saving`, `error`), `elapsed_ms`, `frames_recorded`, `tracking`, `scan_id` |
| `capture_complete` | both | `scan_id`, `keyframes`, `points`, `bytes` |
| `ack` | both | `ref` (id acknowledged), `ok`, `error` |
| `error` | both | `code`, `message`, `ref` |
| `disconnect` | both | `reason` |

Every command gets an `ack` within 5 s or is re-sent once with the same `id`, then reported as failed.
The phone obeys `start_capture` / `stop_capture` / `capture_now` only when the user has turned on
"Let the paired Mac control capture" (on by default in rig mode).
