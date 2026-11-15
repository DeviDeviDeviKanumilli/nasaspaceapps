// Cross-language interop: the phone's real Dart protocol and export code against the real Field Station
// desktop service (Python, ../desktop/service), started as a subprocess with its SYNTHETIC test camera.
//
// What this covers: BLE framing, pairing proofs, session MACs, seq/id de-duplication, commands and acks in both
// directions, and scan zips made exactly the way the phone's Export button makes them, imported by the desktop.
// What it does not cover: the radio. CoreBluetooth on either side is replaced by direct calls to the same entry
// points the radios use (POST /api/ble/rx in, "ble_tx" events out). Over-the-air use is still untested.
//
// Skipped automatically when the desktop service's Python environment is missing
// (set FIELDSTATION_PYTHON to use another interpreter).
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:field_scan/core/ble_protocol.dart';
import 'package:field_scan/core/fixture.dart';
import 'package:field_scan/core/ply.dart';
import 'package:field_scan/core/scan_record.dart';
import 'package:flutter_test/flutter_test.dart';

final _serviceDir = Directory('../desktop/service').absolute;
final _python = Platform.environment['FIELDSTATION_PYTHON'] ?? '${_serviceDir.path}/.venv/bin/python';
final String? _skip = File(_python).existsSync() ? null : 'desktop service venv not found at $_python';

/// The desktop service, driven through the same HTTP/WebSocket API the Field Station app uses.
class Desk {
  late Process proc;
  late int port;
  final String token = 'interop-${DateTime.now().microsecondsSinceEpoch}';
  late WebSocket ws;
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> seen = [];
  final _client = HttpClient();
  final List<String> stderrLines = [];

  Future<void> start(Directory home) async {
    proc = await Process.start(_python, ['-m', 'fieldstation.server', '--port', '0', '--token', token, '--fixtures', '--home', home.path],
        workingDirectory: _serviceDir.path);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(stderrLines.add);
    final ready = Completer<int>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      try {
        final o = jsonDecode(l);
        if (o is Map && o['event'] == 'ready' && !ready.isCompleted) ready.complete((o['port'] as num).toInt());
      } catch (_) {}
    });
    port = await ready.future.timeout(const Duration(seconds: 60), onTimeout: () => throw StateError('service did not start: ${stderrLines.join('\n')}'));
    ws = await WebSocket.connect('ws://127.0.0.1:$port/ws/events?token=$token');
    ws.listen((m) {
      final o = jsonDecode(m as String) as Map<String, dynamic>;
      seen.add(o);
      events.add(o);
    });
  }

  Future<dynamic> call(String method, String path, [Object? body]) async {
    final rq = await _client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    rq.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      rq.headers.contentType = ContentType.json;
      rq.write(jsonEncode(body));
    }
    final rs = await rq.close();
    final text = await rs.transform(utf8.decoder).join();
    if (rs.statusCode >= 400) throw HttpException('${rs.statusCode} $path: $text');
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<Map<String, dynamic>> waitEvent(bool Function(Map<String, dynamic>) test, {int seconds = 30}) {
    for (final e in seen) {
      if (test(e)) return Future.value(e);
    }
    return events.stream.firstWhere(test).timeout(Duration(seconds: seconds));
  }

  Future<void> stop() async {
    try {
      await ws.close();
    } catch (_) {}
    _client.close(force: true);
    proc.kill(ProcessSignal.sigterm);
    await proc.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}

/// The phone side, built only from the app's own protocol code (ble_protocol.dart). The radio is replaced by
/// POSTs to /api/ble/rx (what the Mac's CoreBluetooth bridge does with each write) and the service's ble_tx
/// events (what the bridge turns into notifications).
class Phone {
  final Desk desk;
  final String central;
  final int mtu;
  final _framer = Framer();
  final _deframer = Deframer();
  final String phoneId = newId();
  SecureChannel? chan;
  final inbox = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> got = [];
  final List<String> dropped = [];

  Phone(this.desk, this.central, this.mtu) {
    desk.events.stream.where((e) => e['type'] == 'ble_tx' && e['central'] == central).listen((e) {
      final msg = _deframer.add(base64.decode(e['data_b64'] as String));
      if (msg == null) return;
      Map<String, dynamic>? m;
      try {
        m = chan == null ? jsonDecode(msg) as Map<String, dynamic> : chan!.unwrap(msg);
      } on SecurityException catch (x) {
        dropped.add(x.message);
      }
      if (m != null) {
        got.add(m);
        inbox.add(m);
      }
    });
  }

  Future<void> sendRaw(String s) async {
    for (final c in _framer.split(s, mtu)) {
      expect(c.length, lessThanOrEqualTo(mtu - 3));
      await desk.call('POST', '/api/ble/rx', {'central': central, 'data_b64': base64.encode(c), 'max_chunk': mtu - 3});
    }
  }

  Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic>) test, {int seconds = 30}) {
    for (final m in got) {
      if (test(m)) return Future.value(m);
    }
    return inbox.stream.firstWhere(test).timeout(Duration(seconds: seconds));
  }

  Future<String> send(Map<String, dynamic> inner) async {
    inner['id'] ??= newId();
    await sendRaw(chan!.wrap(inner));
    return inner['id'] as String;
  }
}

Future<File> zipLikeTheApp(ScanRecord r, Directory out) async {
  // Same call as ScanDetailScreen._export().
  final path = '${out.path}/scan-${r.id}.zip';
  await ZipFileEncoder().zipDirectory(r.dir, filename: path, level: 1);
  return File(path);
}

void main() {
  late Directory tmp;
  final desk = Desk();

  setUpAll(() async {
    if (_skip != null) return;
    tmp = Directory.systemTemp.createTempSync('fs-interop-');
    await desk.start(Directory('${tmp.path}/desk')..createSync());
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await desk.stop();
    tmp.deleteSync(recursive: true);
  });

  test('BLE: phone pairs with the desktop and both sides run commands (minimum MTU, so every message is chunked)', () async {
    // The desktop user presses "Pair a phone"; the phone reads the info characteristic.
    final code = (await desk.call('POST', '/api/ble/pairing/open'))['code'] as String;
    final infoResp = await desk.call('GET', '/api/ble/info') as Map<String, dynamic>;
    final info = jsonDecode(utf8.decode(base64.decode(infoResp['info_b64'] as String))) as Map<String, dynamic>;
    expect(info['v'], 1);
    expect(info['role'], 'desktop');
    expect(base64.decode(info['nonce'] as String).length, 16);
    expect(info['capabilities'], containsAll(['d435_capture', 'scan_import']));
    expect('${info['name']}', startsWith('Field Station'));

    final phone = Phone(desk, 'central-A', 23);
    final nd = info['nonce'] as String, np = Pairing.newNonce();

    // A wrong code is refused and does not use up the window.
    final wrong = ((int.parse(code) + 1) % 1000000).toString().padLeft(6, '0');
    await phone.sendRaw(jsonEncode({'v': 1, 'type': 'pair_request', 'phone_id': phone.phoneId, 'phone_name': 'interop', 'nonce_phone': np,
      'proof': Pairing.phoneProof(wrong, nd, np, phone.phoneId)}));
    expect((await phone.next((m) => m['type'] == 'pair_reject'))['reason'], 'bad_code');
    phone.got.clear();

    await phone.sendRaw(jsonEncode({'v': 1, 'type': 'pair_request', 'phone_id': phone.phoneId, 'phone_name': 'interop iPhone', 'nonce_phone': np,
      'proof': Pairing.phoneProof(code, nd, np, phone.phoneId)}));
    final acc = await phone.next((m) => m['type'] == 'pair_accept');
    expect(constantTimeEquals(Pairing.desktopProof(code, np, nd), '${acc['proof']}'), isTrue, reason: 'desktop proof must verify on the phone');
    expect(acc['expires_s'], greaterThan(0));
    phone.chan = SecureChannel(Pairing.sessionKey(code, nd, np));
    await desk.waitEvent((e) => e['type'] == 'phone_paired' && e['phone_name'] == 'interop iPhone');

    // hello, as BleLink sends right after pairing.
    await phone.send({'type': 'hello', 'role': 'phone', 'capabilities': ['arkit_lidar', 'arkit_camera']});
    final hello = await phone.next((m) => m['type'] == 'hello');
    expect(hello['role'], 'desktop');

    // Phone -> desktop: start a D435 capture (the connect screen's button). The open device is the SYNTHETIC scene.
    await desk.call('POST', '/api/device/open', {'adapter_id': 'synthetic', 'device_id': 'synthetic:scene-v1', 'profile': 'field_static'});
    for (var i = 0; i < 100 && (await desk.call('GET', '/api/status'))['state'] != 'streaming'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final startCmd = {'type': 'start_capture', 'target': 'desktop', 'sensor_id': 'realsense:d435', 'profile': 'field_static'};
    final id = await phone.send(Map.of(startCmd));
    final ack = await phone.next((m) => m['type'] == 'ack' && m['ref'] == id);
    expect(ack['ok'], isTrue, reason: '${ack['error']}');
    final scanId = ack['scan_id'] as String;
    expect(scanId, isNotEmpty);
    final rec = await phone.next((m) => m['type'] == 'capture_state' && m['state'] == 'recording');
    expect(rec['scan_id'], scanId);
    final done = await phone.next((m) => m['type'] == 'capture_complete', seconds: 90);
    expect(done['scan_id'], scanId);

    // The phone's retry rule: re-send with the same id and a fresh seq. The desktop re-acks, does not record again.
    final before = ((await desk.call('GET', '/api/scans'))['scans'] as List).length;
    phone.got.removeWhere((m) => m['type'] == 'ack');
    await phone.send({...startCmd, 'id': id});
    final dup = await phone.next((m) => m['type'] == 'ack' && m['ref'] == id);
    expect(dup['ok'], isTrue);
    expect(dup['error'], 'duplicate: already handled');
    expect(dup['scan_id'], scanId);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(((await desk.call('GET', '/api/scans'))['scans'] as List).length, before);
    expect((await desk.call('GET', '/api/status'))['state'], isNot('recording'));

    // A forged message (wrong key) is dropped by the desktop.
    final forged = SecureChannel(List<int>.filled(32, 7)).wrap({'type': 'start_capture', 'target': 'desktop', 'id': newId()});
    await phone.sendRaw(forged);
    await desk.waitEvent((e) => e['type'] == 'message_dropped' && e['reason'] == 'bad_mac');

    // Desktop -> phone: the Mac asks the phone to record; the phone refuses because remote control is off
    // (capture_screen.dart's answer), and the desktop surfaces that error verbatim.
    await desk.call('POST', '/api/ble/send', {'central': 'central-A', 'type': 'start_capture'});
    final cmd = await phone.next((m) => m['type'] == 'start_capture');
    expect(cmd['target'], 'phone');
    expect(cmd['sensor_id'], 'iphone:arkit');
    await phone.send({'type': 'ack', 'ref': cmd['id'], 'ok': false, 'error': 'remote control is off on the phone'});
    final pa = await desk.waitEvent((e) => e['type'] == 'phone_ack' && e['ref'] == cmd['id']);
    expect(pa['ok'], isFalse);
    expect(pa['error'], 'remote control is off on the phone');
    expect(pa['command'], 'start_capture');

    // Phone capture progress reaches the desktop (capture_screen.dart sends these about once a second).
    await phone.send({'type': 'capture_state', 'target': 'phone', 'state': 'recording', 'elapsed_ms': 1200, 'frames_recorded': 4, 'tracking': 'normal', 'scan_id': newId()});
    final ps = await desk.waitEvent((e) => e['type'] == 'phone_capture_state');
    expect(ps['frames_recorded'], 4);
    expect(ps['tracking'], 'normal');

    expect(phone.dropped, isEmpty, reason: 'the phone rejected desktop messages: ${phone.dropped}');
  }, skip: _skip);

  test('Scan zips exported by the phone import on the desktop with every SHA-256 verified, and measure there', () async {
    final lib = ScanLibrary(Directory('${tmp.path}/phone')..createSync());

    // 1) A LiDAR scan as the app records it: envelope from buildEnvelope(), fused PLY with confidence, as the
    //    native side hashes it. The geometry is a 1 m flat patch tilted 20 degrees about X (y-up world).
    final id = newId();
    final dir = lib.newScanDir(id)..createSync(recursive: true);
    final xyz = <double>[], rgb = <int>[], conf = <int>[];
    const t = 20 * math.pi / 180;
    for (var i = 0; i < 100; i++) {
      for (var j = 0; j < 100; j++) {
        final x = -0.5 + i / 99, d = -0.5 + j / 99;
        xyz.addAll([x, d * math.sin(t), -1.5 + d * math.cos(t)]);
        rgb.addAll([120, 110, 100]);
        conf.add(2);
      }
    }
    final ply = writePly(PointCloud(Float32List.fromList(xyz), rgb: Uint8List.fromList(rgb), confidence: Uint8List.fromList(conf)),
        comments: ['interop test geometry, not a real scan']);
    File('${dir.path}/point_cloud_fused.ply').writeAsBytesSync(ply);
    final summary = {
      'scanId': id, 'depth': true, 'mesh': false, 'modelIdentifier': 'iPhone18,1', 'osVersion': '26.1',
      'startUTC': utcNow(), 'endUTC': utcNow(), 'keyframes': 0, 'photos': 0, 'points': 10000, 'stopReason': 'user',
      'files': [
        {'path': 'point_cloud_fused.ply', 'bytes': ply.length, 'sha256': sha256.convert(ply).toString(), 'role': 'derived_point_cloud',
          'mime': 'application/x-ply', 'lineage': 'interop test'}
      ],
    };
    final env = buildEnvelope(summary, ScanSetup(title: 'interop tilted patch', featureType: 'rock_face', candidateId: 'cand-123'), sessionId: newId());
    final r = ScanRecord(dir, env);
    await r.save('interop: saved');
    // The phone also leaves a catalog draft in the folder (contribute screen); it is not listed in files[].
    File('${dir.path}/catalog_draft.json').writeAsStringSync(jsonEncode({'status': 'draft_local'}));
    expect(await verifyFiles(r), isEmpty);

    final zip = await zipLikeTheApp(r, tmp);
    final imp = await desk.call('POST', '/api/import', {'path': zip.path}) as Map<String, dynamic>;
    expect(imp['scan_id'], id);
    expect(imp['origin'], 'iphone_arkit_lidar');
    final man = (await desk.call('GET', '/api/scans/$id'))['manifest'] as Map<String, dynamic>;
    expect(man['candidate_id'], 'cand-123', reason: 'the website reference survives as an opaque id');
    expect(man['coordinate_frame']['name'], 'arkit_session_world');

    // Roughness + tilt on the imported cloud: the desktop must use the phone's gravity (+Y up).
    final an = await desk.call('POST', '/api/scans/$id/analyze', {
      'kind': 'roughness', 'label': 'interop', 'roi': {'kind': 'sphere', 'center': [0.0, 0.0, -1.5], 'radius_m': 0.4}
    }) as Map<String, dynamic>;
    final ms = {for (final m in (an['measurements'] as List).cast<Map<String, dynamic>>()) m['name']: m};
    expect(ms['plane_fit_roughness']!['value'] as num, lessThan(0.001));
    expect(ms['plane_tilt_from_horizontal']!['status'], 'measured');
    expect((ms['plane_tilt_from_horizontal']!['value'] as num).toDouble(), closeTo(20.0, 0.5));

    // Importing the same zip again is refused as a duplicate (nothing is overwritten).
    await expectLater(desk.call('POST', '/api/import', {'path': zip.path}), throwsA(predicate((e) => '$e'.contains('409'))));

    // A tampered zip is refused.
    final bad = ScanRecord(lib.newScanDir(newId())..createSync(), Map<String, dynamic>.from(jsonDecode(jsonEncode(env)) as Map));
    bad.json['scan_id'] = bad.dir.path.split('scan-').last;
    File('${bad.dir.path}/point_cloud_fused.ply').writeAsBytesSync([...ply]..[ply.length - 1] ^= 1);
    await bad.save('interop: tampered');
    final badZip = await zipLikeTheApp(bad, tmp);
    await expectLater(desk.call('POST', '/api/import', {'path': badZip.path}), throwsA(predicate((e) => '$e'.contains('checksum mismatch'))));

    // 2) The app's own SYNTHETIC fixture scan.
    final syn = await writeSyntheticScan(lib);
    final synImp = await desk.call('POST', '/api/import', {'path': (await zipLikeTheApp(syn, tmp)).path}) as Map<String, dynamic>;
    expect(synImp['origin'], 'synthetic_fixture');

    // 3) A scan the phone recovered after the app was killed mid-capture (ScanLibrary.list() writes its envelope).
    final rid = newId();
    final rdir = lib.newScanDir(rid)..createSync();
    File('${rdir.path}/keyframes.jsonl').writeAsStringSync('{"type":"keyframe","index":0}\n');
    Directory('${rdir.path}/keyframes').createSync();
    File('${rdir.path}/keyframes/rgb_00000.jpg').writeAsBytesSync(List<int>.generate(64, (i) => i));
    final recovered = (await lib.list()).firstWhere((s) => s.id == rid);
    expect(recovered.status, 'incomplete');
    final recImp = await desk.call('POST', '/api/import', {'path': (await zipLikeTheApp(recovered, tmp)).path}) as Map<String, dynamic>;
    expect(recImp['scan_id'], rid);
    expect(recImp['status'], 'incomplete');
  }, skip: _skip);
}
