import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:field_scan/core/ble_protocol.dart';
import 'package:field_scan/core/fixture.dart';
import 'package:field_scan/core/geometry.dart';
import 'package:field_scan/core/ply.dart';
import 'package:field_scan/core/scan_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// Points on a plane through [c] with normal [n], with Gaussian noise [sigma] along the normal.
Float32List planePoints(Vec3 c, Vec3 n, double sigma, {int count = 4000, double half = 0.3, int seed = 1}) {
  final r = math.Random(seed);
  final nn = n.unit;
  final a = (nn.x.abs() < 0.9 ? const Vec3(1, 0, 0) : const Vec3(0, 1, 0));
  // u = a - (a.n)n, v = n x u
  final u = (a - nn * a.dot(nn)).unit;
  final v = Vec3(nn.y * u.z - nn.z * u.y, nn.z * u.x - nn.x * u.z, nn.x * u.y - nn.y * u.x);
  final out = Float32List(count * 3);
  for (int i = 0; i < count; i++) {
    final s = (r.nextDouble() * 2 - 1) * half, t = (r.nextDouble() * 2 - 1) * half;
    final g = math.sqrt(-2 * math.log(math.max(1e-12, r.nextDouble()))) * math.cos(2 * math.pi * r.nextDouble());
    final p = c + u * s + v * t + nn * (g * sigma);
    out[i * 3] = p.x;
    out[i * 3 + 1] = p.y;
    out[i * 3 + 2] = p.z;
  }
  return out;
}

void main() {
  group('geometry', () {
    test('eigen decomposition of a diagonal and a rotated matrix', () {
      final (ev, _) = symEig3([
        [3.0, 0, 0],
        [0, 1.0, 0],
        [0, 0, 2.0]
      ]);
      expect(ev[0], closeTo(1, 1e-12));
      expect(ev[2], closeTo(3, 1e-12));
      final (ev2, vec2) = symEig3([
        [2.0, 1.0, 0],
        [1.0, 2.0, 0],
        [0, 0, 5.0]
      ]);
      expect(ev2, [closeTo(1, 1e-9), closeTo(3, 1e-9), closeTo(5, 1e-9)]);
      expect(vec2[0].x.abs(), closeTo(math.sqrt(0.5), 1e-9));
    });

    test('plane fit recovers tilt and noise of a synthetic plane', () {
      for (final tilt in [0.0, 30.0, 61.0, 90.0]) {
        final rad = tilt * math.pi / 180;
        final n = Vec3(math.sin(rad), math.cos(rad), 0);
        final xyz = planePoints(const Vec3(1, 0.5, -2), n, 0.003, seed: tilt.round());
        final f = fitPlane(xyz, List.generate(xyz.length ~/ 3, (i) => i))!;
        expect(f.tiltFromHorizontalDeg, closeTo(tilt, 0.3), reason: 'tilt $tilt');
        expect(f.rmsResidual, closeTo(0.003, 0.0003), reason: 'noise at tilt $tilt');
        expect(f.normal.dot(n).abs(), closeTo(1, 1e-3));
      }
    });

    test('noise-free plane gives ~zero roughness; robust fit drops gross outliers', () {
      final xyz = planePoints(const Vec3(0, 0, 0), const Vec3(0, 1, 0), 0.0);
      final f = fitPlane(xyz, List.generate(xyz.length ~/ 3, (i) => i))!;
      expect(f.rmsResidual, lessThan(1e-6));
      // add 20 outliers 10 cm off the plane
      final withOut = Float32List(xyz.length + 60)..setRange(0, xyz.length, xyz);
      for (int i = 0; i < 20; i++) {
        withOut[xyz.length + i * 3] = 0.01 * i;
        withOut[xyz.length + i * 3 + 1] = 0.10;
        withOut[xyz.length + i * 3 + 2] = 0.0;
      }
      final idx = List.generate(withOut.length ~/ 3, (i) => i);
      final plain = fitPlane(withOut, idx)!;
      final robust = fitPlane(withOut, idx, robust: true)!;
      expect(plain.rmsResidual, greaterThan(0.005));
      expect(robust.rejected, 20);
      expect(robust.rmsResidual, lessThan(1e-5));
    });

    test('normal points toward the observer', () {
      final xyz = planePoints(const Vec3(0, 0, 0), const Vec3(0, 0, 1), 0.001);
      final idx = List.generate(xyz.length ~/ 3, (i) => i);
      expect(fitPlane(xyz, idx, towards: const Vec3(0, 0, 5))!.normal.z, greaterThan(0.99));
      expect(fitPlane(xyz, idx, towards: const Vec3(0, 0, -5))!.normal.z, lessThan(-0.99));
    });

    test('too few points returns null', () {
      expect(fitPlane(Float32List(9), [0, 1, 2]), isNull);
    });

    test('sphere selection and extents', () {
      final xyz = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0.5]);
      expect(pointsInSphere(xyz, const Vec3(0, 0, 0), 0.6), [0, 3]);
      // box 0.8 x 0.3 rotated 30 deg in the horizontal plane, 0.25 tall
      final pts = <double>[];
      const a = 30 * math.pi / 180;
      for (double s = -0.4; s <= 0.4001; s += 0.02) {
        for (double t = -0.15; t <= 0.1501; t += 0.02) {
          for (final y in [0.0, 0.25]) {
            pts.addAll([s * math.cos(a) - t * math.sin(a), y, s * math.sin(a) + t * math.cos(a)]);
          }
        }
      }
      final e = extents(Float32List.fromList(pts), List.generate(pts.length ~/ 3, (i) => i));
      expect(e.vertical, closeTo(0.25, 1e-6));
      expect(e.horizontalMajor, closeTo(0.8, 0.01));
      expect(e.horizontalMinor, closeTo(0.28, 0.025)); // grid step 0.02 from -0.15 stops at 0.13/0.15
    });

    test('summary stats', () {
      final s = SummaryStats.of([1, 2, 3, 4])!;
      expect(s.mean, 2.5);
      expect(s.sd, closeTo(1.290994, 1e-6));
    });
  });

  group('ply', () {
    test('binary round trip with colour and confidence', () {
      final pc = PointCloud(Float32List.fromList([0, 1, 2, -1.5, 0.25, 3]), rgb: Uint8List.fromList([1, 2, 3, 250, 251, 252]), confidence: Uint8List.fromList([2, 0]));
      final back = parsePly(writePly(pc, comments: ['hello']));
      expect(back.length, 2);
      expect(back.xyz, pc.xyz);
      expect(back.rgb, pc.rgb);
      expect(back.confidence, pc.confidence);
      expect(back.comments, ['hello']);
    });

    test('reads the native layout (x y z rgb confidence ushort samples)', () {
      const header = 'ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\n'
          'property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar confidence\nproperty ushort samples\nend_header\n';
      final b = BytesBuilder()..add(utf8.encode(header));
      for (final v in [
        [0.5, -0.25, 1.0, 10, 20, 30, 2, 7],
        [1.0, 2.0, 3.0, 40, 50, 60, 1, 300]
      ]) {
        final bd = ByteData(18);
        bd.setFloat32(0, v[0].toDouble(), Endian.little);
        bd.setFloat32(4, v[1].toDouble(), Endian.little);
        bd.setFloat32(8, v[2].toDouble(), Endian.little);
        bd.setUint8(12, v[3].toInt());
        bd.setUint8(13, v[4].toInt());
        bd.setUint8(14, v[5].toInt());
        bd.setUint8(15, v[6].toInt());
        bd.setUint16(16, v[7].toInt(), Endian.little);
        b.add(bd.buffer.asUint8List());
      }
      final pc = parsePly(b.toBytes());
      expect(pc.xyz, [0.5, -0.25, 1.0, 1.0, 2.0, 3.0]);
      expect(pc.rgb, [10, 20, 30, 40, 50, 60]);
      expect(pc.confidence, [2, 1]);
    });

    test('mesh with faces and classification, and ascii', () {
      const header = 'ply\nformat binary_little_endian 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\n'
          'element face 1\nproperty list uchar uint vertex_indices\nproperty uchar classification\nend_header\n';
      final b = BytesBuilder()..add(utf8.encode(header));
      final v = ByteData(36);
      for (int i = 0; i < 9; i++) {
        v.setFloat32(i * 4, i.toDouble(), Endian.little);
      }
      b.add(v.buffer.asUint8List());
      final f = ByteData(14)
        ..setUint8(0, 3)
        ..setUint32(1, 0, Endian.little)
        ..setUint32(5, 1, Endian.little)
        ..setUint32(9, 2, Endian.little)
        ..setUint8(13, 2);
      b.add(f.buffer.asUint8List());
      final m = parsePly(b.toBytes());
      expect(m.faces, [0, 1, 2]);
      final a = parsePly(Uint8List.fromList(utf8.encode('ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n4 5 6\n')));
      expect(a.xyz, [1, 2, 3, 4, 5, 6]);
    });

    test('decimation keeps a deterministic stride', () {
      final pc = PointCloud(Float32List.fromList(List.generate(300, (i) => i.toDouble())));
      final d = parsePly(writePly(pc), maxPoints: 25);
      expect(d.length, 25);
      expect(d.xyz.sublist(0, 6), [0, 1, 2, 12, 13, 14]);
    });
  });

  group('ble protocol', () {
    final vec = jsonDecode(File('../contracts/BLE_TEST_VECTORS.json').readAsStringSync()) as Map<String, dynamic>;

    test('matches the Python-generated vectors', () {
      expect(Pairing.phoneProof(vec['code'], vec['nonce_desktop'], vec['nonce_phone'], vec['phone_id']), vec['phone_proof']);
      expect(Pairing.desktopProof(vec['code'], vec['nonce_phone'], vec['nonce_desktop']), vec['desktop_proof']);
      final k = Pairing.sessionKey(vec['code'], vec['nonce_desktop'], vec['nonce_phone']);
      expect(base64.encode(k), vec['session_key_b64']);
      final ch = SecureChannel(k);
      final m = ch.unwrap(vec['example_wire'] as String)!;
      expect(m['type'], 'start_capture');
      expect(base64.encode(Hmac(sha256, k).convert(utf8.encode(vec['example_inner'])).bytes), vec['example_mac']);
    });

    test('wrap/unwrap, tamper, replay and duplicate id', () {
      final k = List<int>.generate(32, (i) => i);
      final a = SecureChannel(k), b = SecureChannel(k);
      final w1 = a.wrap({'type': 'capture_now'});
      final w2 = a.wrap({'type': 'stop_capture', 'target': 'phone'});
      expect(b.unwrap(w1)!['type'], 'capture_now');
      expect(b.unwrap(w2)!['seq'], 2);
      // a re-send keeps its id but carries a new seq: flagged as duplicate (re-ack, do not act again)
      final m1 = jsonDecode(jsonDecode(w1)['m'] as String) as Map<String, dynamic>;
      final resend = a.wrap(Map.of(m1)..remove('seq'));
      expect(b.unwrap(resend)!['_duplicate'], true);
      // the identical wire message again is a replay (old seq)
      expect(() => b.unwrap(w1), throwsA(isA<SecurityException>()));
      final o = jsonDecode(a.wrap({'type': 'capture_now'})) as Map<String, dynamic>;
      o['m'] = (o['m'] as String).replaceAll('capture_now', 'stop_capture');
      expect(() => b.unwrap(jsonEncode(o)), throwsA(isA<SecurityException>()));
      expect(() => SecureChannel(List.filled(32, 9)).unwrap(a.wrap({'type': 'x'})), throwsA(isA<SecurityException>()));
      // replay with an older seq but a new id
      final c = SecureChannel(k);
      final old = c.wrap({'type': 'a'});
      final newer = c.wrap({'type': 'b'});
      final d = SecureChannel(k);
      d.unwrap(newer);
      expect(() => d.unwrap(old), throwsA(isA<SecurityException>()));
    });

    test('framing splits by MTU and reassembles', () {
      final msg = jsonEncode({'type': 'capture_state', 'pad': 'x' * 700, 'unicode': 'Ångström 🌑'});
      final f = Framer();
      final chunks = f.split(msg, 23);
      expect(chunks.length, greaterThan(30));
      expect(chunks.every((c) => c.length <= 20), isTrue);
      final d = Deframer();
      String? out;
      for (final c in chunks) {
        out = d.add(c) ?? out;
      }
      expect(out, msg);
      // a second message uses the next counter
      expect(f.split('{}', 185).single[0], 1);
    });
  });

  group('scan record', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fs_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('envelope from a native summary has the contract fields', () {
      final env = buildEnvelope({
        'scanId': 'abc',
        'startUTC': '2026-11-15T15:00:00Z',
        'endUTC': '2026-11-15T15:01:00Z',
        'keyframes': 12,
        'photos': 3,
        'depth': true,
        'mesh': true,
        'meshVertices': 100,
        'modelIdentifier': 'iPhone18,1',
        'osVersion': '26.1',
        'fuse': {'enabled': true, 'voxel_m': 0.01},
        'files': [
          {'path': 'point_cloud_fused.ply', 'role': 'derived_point_cloud', 'bytes': 1, 'sha256': 'x'},
          {'path': 'keyframes/kf_00001.f32', 'role': 'keyframe_depth', 'bytes': 1, 'sha256': 'y'},
        ],
      }, ScanSetup(title: 'Boulder A'), sessionId: 's1');
      expect(env['schema_version'], '1.0');
      expect(env['origin'], 'iphone_arkit_lidar');
      expect(env['device']['model'], 'iPhone 17 Pro');
      expect(env['coordinate_frame']['name'], 'arkit_session_world');
      expect(env['publication']['status'], 'local_private');
      expect(env['location']['sharing'], 'hidden');
      expect(env['location']['latitude'], isNull);
      expect((env['files'] as List)[0]['kind'], 'derived');
      expect((env['files'] as List)[1]['kind'], 'raw');
      expect((env['limitations'] as List).any((l) => '$l'.contains('mineralogy')), isTrue);
      final cam = buildEnvelope({'scanId': 'b', 'depth': false, 'modelIdentifier': 'iPhone18,3'}, ScanSetup(), sessionId: 's');
      expect(cam['origin'], 'iphone_arkit_camera');
      expect(cam['device']['model'], 'iPhone 17');
    });

    test('library recovers a crashed capture as incomplete and verifies hashes', () async {
      final lib = ScanLibrary(tmp);
      final d = lib.newScanDir('crash1')..createSync(recursive: true);
      File('${d.path}/keyframes.jsonl').writeAsStringSync('{"type":"keyframe","index":1}\n{"type":"keyframe","index":2}\n');
      final list = await lib.list();
      expect(list.single.status, 'incomplete');
      expect(list.single.json['capture']['keyframes'], 2);
      expect(await verifyFiles(list.single), isEmpty);
      File('${d.path}/keyframes.jsonl').writeAsStringSync('tampered');
      expect(await verifyFiles(list.single), isNotEmpty);
    });

    test('synthetic fixture: measurements recover the generated geometry', () async {
      final r = await writeSyntheticScan(ScanLibrary(tmp));
      expect(r.json['origin'], 'synthetic_fixture');
      expect(r.json['is_real_sensor'], false);
      expect(await verifyFiles(r), isEmpty);
      final pc = parsePly(r.file('point_cloud_fused.ply').readAsBytesSync());
      // ground patch away from the boulder
      final ground = fitPlane(pc.xyz, pointsInSphere(pc.xyz, const Vec3(0.75, 0, 0.75), 0.15))!;
      expect(ground.tiltFromHorizontalDeg, lessThan(1.0));
      expect(ground.rmsResidual, closeTo(0.002, 0.0004));
      final e = extents(pc.xyz, List.generate(pc.length, (i) => i));
      // untrimmed range includes the noise tails at both ends (about +-4 sigma of 2 mm)
      expect(e.vertical, greaterThan(0.30));
      expect(e.vertical, lessThan(0.30 + 8 * 0.002 + 1e-3));
    });
  });
}
