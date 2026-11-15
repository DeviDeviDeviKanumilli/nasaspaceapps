// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:field_station/service/models.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List encodeCloud(List<List<double>> xyz, List<List<int>> rgb) {
  final n = xyz.length;
  final bd = ByteData(4 + n * 12 + n * 3);
  bd.setUint32(0, n, Endian.little);
  for (int i = 0; i < n; i++) {
    for (int k = 0; k < 3; k++) {
      bd.setFloat32(4 + (i * 3 + k) * 4, xyz[i][k], Endian.little);
      bd.setUint8(4 + n * 12 + i * 3 + k, rgb[i][k]);
    }
  }
  return bd.buffer.asUint8List();
}

void main() {
  test('cloud.bin parses counts, coordinates, colours and headers', () {
    final bytes = encodeCloud([
      [0.1, -0.2, 1.5],
      [1.0, 2.0, 3.0],
    ], [
      [255, 0, 10],
      [1, 2, 3],
    ]);
    final c = CloudData.parse(bytes, {'x-points-total': '1000', 'x-frame': 'camera_optical_m', 'x-source-file': 'point_cloud_filtered.ply'});
    expect(c.count, 2);
    expect(c.xyz[0], closeTo(0.1, 1e-6));
    expect(c.xyz[1], closeTo(-0.2, 1e-6));
    expect(c.xyz[5], closeTo(3.0, 1e-6));
    expect(c.rgb.sublist(0, 3), [255, 0, 10]);
    expect(c.total, 1000);
    expect(c.frame, 'camera_optical_m');
  });

  test('cloud.bin rejects truncated payloads', () {
    final bytes = encodeCloud([
      [0, 0, 1],
    ], [
      [0, 0, 0],
    ]);
    expect(() => CloudData.parse(Uint8List.sublistView(bytes, 0, bytes.length - 2)), throwsFormatException);
  });

  test('scan.json sample parses measurements with units and honesty origin', () {
    final man = jsonDecode(File('test/fixtures/scan.json').readAsStringSync()) as Map<String, dynamic>;
    expect(originKind(man['origin'] as String), OriginKind.synthetic);
    expect(originBadge(man['origin'] as String), 'SYNTHETIC');
    final ms = Measurement.listFrom(man['measurements']);
    final rough = ms.firstWhere((m) => m.name == 'plane_fit_roughness');
    expect(rough.unit, 'm');
    expect(rough.roi['kind'], 'pixel_rect');
    expect(rough.displayValue, endsWith('mm'));
    final slope = ms.firstWhere((m) => m.name == 'plane_tilt_from_horizontal');
    expect(slope.status, 'not_measured');
    expect(slope.displayValue, '—');
  });

  test('formatting keeps units', () {
    expect(formatValue(0.00466, 'm'), '4.66 mm');
    expect(formatValue(1.2345, 'm'), '1.234 m');
    expect(formatValue(30.7, 'deg'), '30.70°');
    expect(formatValue([0.5, 0.25], 'm'), '0.500 m × 0.250 m');
    expect(formatValue(null, 'm'), '—');
  });
}
