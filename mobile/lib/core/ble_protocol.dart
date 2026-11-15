// Field Scan <-> Field Station BLE control protocol v1 (contracts/BLE_PROTOCOL_V1.md). Pure Dart, no Bluetooth
// calls: framing, pairing proofs, session key and message MACs. Test vectors: contracts/BLE_TEST_VECTORS.json.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const bleServiceUuid = '2ED62242-2267-41EC-BA7D-A321B67A1B8A';
const bleInfoUuid = '9BC2CC53-AFB3-4C24-AEBC-912AF3962D9B';
const bleRxUuid = '2C4DE982-D089-429A-9945-5FF10A4935A3'; // phone -> desktop (write)
const bleTxUuid = '00A3B417-650E-4ABE-8F9C-5332D2E0A07A'; // desktop -> phone (notify)

List<int> _hmac(List<int> key, String msg) => Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

String b64(List<int> b) => base64.encode(b);

/// Pairing proofs. Key = UTF-8 bytes of the 6-digit code; nonces are standard base64 strings as sent.
class Pairing {
  static String phoneProof(String code, String nonceDesktop, String noncePhone, String phoneId) =>
      b64(_hmac(utf8.encode(code), 'pair1|$nonceDesktop|$noncePhone|$phoneId'));

  static String desktopProof(String code, String noncePhone, String nonceDesktop) =>
      b64(_hmac(utf8.encode(code), 'pair2|$noncePhone|$nonceDesktop'));

  /// 32-byte session key K.
  static List<int> sessionKey(String code, String nonceDesktop, String noncePhone) =>
      _hmac(utf8.encode(code), 'key|$nonceDesktop|$noncePhone');

  static String newNonce([Random? r]) {
    final rnd = r ?? Random.secure();
    return b64(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }
}

bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  if (x.length != y.length) return false;
  int d = 0;
  for (int i = 0; i < x.length; i++) {
    d |= x[i] ^ y[i];
  }
  return d == 0;
}

/// Wraps and checks messages after pairing.
class SecureChannel {
  final List<int> key;
  int _sendSeq = 0;
  int _lastRecvSeq = 0;
  final Set<String> _seenIds = {};
  SecureChannel(this.key);

  /// Adds v/seq (and id if missing) to [inner] and returns the wire JSON string.
  String wrap(Map<String, dynamic> inner) {
    final m = Map<String, dynamic>.from(inner);
    m['v'] = 1;
    m['seq'] = ++_sendSeq;
    m['id'] ??= newId();
    final s = jsonEncode(m);
    return jsonEncode({'m': s, 'mac': b64(_hmac(key, s))});
  }

  /// Returns the inner message, or throws [SecurityException] for a bad MAC / replay. A re-send of an id
  /// already seen comes back with `_duplicate: true`: re-acknowledge it, but do not act on it again.
  Map<String, dynamic>? unwrap(String wire) {
    final o = jsonDecode(wire) as Map<String, dynamic>;
    final s = o['m'] as String?;
    final mac = o['mac'] as String?;
    if (s == null || mac == null) throw SecurityException('unauthenticated message');
    if (!constantTimeEquals(b64(_hmac(key, s)), mac)) throw SecurityException('bad MAC');
    final m = jsonDecode(s) as Map<String, dynamic>;
    final seq = (m['seq'] as num?)?.toInt() ?? 0;
    final id = m['id'] as String? ?? '';
    if (seq <= _lastRecvSeq) throw SecurityException('replayed or out-of-order seq $seq');
    _lastRecvSeq = seq;
    if (_seenIds.contains(id)) return m..['_duplicate'] = true;
    _seenIds.add(id);
    if (_seenIds.length > 500) _seenIds.remove(_seenIds.first);
    return m;
  }
}

class SecurityException implements Exception {
  final String message;
  SecurityException(this.message);
  @override
  String toString() => 'SecurityException: $message';
}

String newId([Random? r]) {
  final rnd = r ?? Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// 2-byte header framing: [counter mod 256, flags (0x01 = last)] + payload.
class Framer {
  int _counter = 0;
  List<Uint8List> split(String message, int mtu) {
    final data = utf8.encode(message);
    final room = max(1, mtu - 3 - 2);
    final c = _counter;
    _counter = (_counter + 1) & 0xFF;
    final out = <Uint8List>[];
    for (int off = 0; off < data.length || out.isEmpty; off += room) {
      final end = min(data.length, off + room);
      final last = end >= data.length;
      out.add(Uint8List.fromList([c, last ? 1 : 0, ...data.sublist(off, end)]));
      if (last) break;
    }
    return out;
  }
}

class Deframer {
  int? _counter;
  final _buf = BytesBuilder();

  /// Feed one chunk; returns a complete message when the last chunk arrives.
  String? add(List<int> chunk) {
    if (chunk.length < 2) return null;
    final c = chunk[0], last = (chunk[1] & 1) == 1;
    if (_counter != c) {
      _buf.clear();
      _counter = c;
    }
    _buf.add(chunk.sublist(2));
    if (!last) return null;
    _counter = null;
    return utf8.decode(_buf.takeBytes());
  }
}
