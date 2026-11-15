import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:field_scan/core/contribution_package.dart';
import 'package:field_scan/core/scan_record.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> scanJson() => {
      'scan_id': '0123456789abcdef',
      'session_id': 'outing-1',
      'device': {'manufacturer': 'Apple', 'model': 'iPhone 17 Pro'},
      'location': {'sharing': 'hidden', 'collected': true, 'latitude': 40.43219, 'longitude': -74.71234, 'uncertainty_m': 5.0},
      'field_site_id': 'SOURLAND-03',
      'observation': {'title': 'Boulder A', 'feature_type': 'boulder', 'notes': 'met Sam at the gate'},
      'files': [
        {'path': 'point_cloud_fused.ply'},
        {'path': 'photos/ph_00001.jpg'},
        {'path': 'keyframes.jsonl'},
      ],
    };

ContributionOptions opts({String loc = 'hidden', bool photos = false, bool notes = false}) =>
    ContributionOptions(locationPrecision: loc, includePhotos: photos, includeNotes: notes, license: 'CC-BY-4.0', attribution: 'Team V');

/// Minimal JPEG: SOI, one APP1 segment, SOS marker, two data bytes, EOI.
Uint8List jpegWith(List<int> app1Payload) {
  final len = app1Payload.length + 2;
  return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, len >> 8, len & 0xFF, ...app1Payload, 0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]);
}

/// "Exif\0\0" + little-endian TIFF header + IFD0 with one entry of [tag].
List<int> exifWithTag(int tag) => [
      ...'Exif'.codeUnits, 0, 0, //
      0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // II*, IFD0 at 8
      0x01, 0x00, // one entry
      tag & 0xFF, tag >> 8, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, // next IFD
    ];

void main() {
  test('hidden location: no coordinates, no site id, no session id, no notes', () {
    final j = publicScanJson(scanJson(), opts(), {'point_cloud_fused.ply'});
    expect(j['location'], {'sharing': 'hidden'});
    expect(j.containsKey('field_site_id'), isFalse);
    expect(j.containsKey('session_id'), isFalse);
    expect((j['observation'] as Map).containsKey('notes'), isFalse);
    expect([for (final f in j['files'] as List) f['path']], ['point_cloud_fused.ply']);
    expect(jsonEncode(j).contains('40.432'), isFalse);
  });

  test('coarse location is rounded to 0.1 degree; notes only when chosen', () {
    final j = publicScanJson(scanJson(), opts(loc: 'coarse', notes: true), {});
    expect(j['location']['latitude'], 40.4);
    expect(j['location']['longitude'], -74.7);
    expect(j['observation']['notes'], 'met Sam at the gate');
    expect(jsonEncode(j).contains('40.43219'), isFalse);
  });

  test('JPEG: EXIF with GPS removed, EXIF without GPS kept, XMP removed', () {
    final gps = jpegWith(exifWithTag(0x8825));
    final orient = jpegWith(exifWithTag(0x0112));
    final xmp = jpegWith([...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0, ...'<x:xmpmeta/>'.codeUnits]);
    final cleanGps = stripJpegLocation(gps);
    expect(cleanGps.sublist(0, 4), [0xFF, 0xD8, 0xFF, 0xDA]);
    expect(cleanGps.sublist(cleanGps.length - 4), [0x11, 0x22, 0xFF, 0xD9]);
    expect(stripJpegLocation(orient), orient);
    expect(stripJpegLocation(xmp).sublist(0, 4), [0xFF, 0xD8, 0xFF, 0xDA]);
  });

  test('package holds only the public parts', () async {
    final tmp = Directory.systemTemp.createTempSync('fs_pkg');
    final scan = Directory('${tmp.path}/scan')..createSync();
    File('${scan.path}/point_cloud_fused.ply').writeAsStringSync('ply\n');
    File('${scan.path}/keyframes.jsonl').writeAsStringSync('{}\n');
    File('${scan.path}/scan.json').writeAsStringSync('{}');
    Directory('${scan.path}/photos').createSync();
    File('${scan.path}/photos/ph_00001.jpg').writeAsBytesSync(jpegWith(exifWithTag(0x8825)));
    final r = ScanRecord(scan, scanJson());

    Future<Map<String, List<int>>> entries(ContributionOptions o) async {
      final zip = await buildContributionPackage(r, o, {'license': o.license}, tmp);
      return {for (final f in ZipDecoder().decodeBytes(zip.readAsBytesSync())) f.name: f.content as List<int>};
    }

    final noPhotos = await entries(opts());
    expect(noPhotos.keys.toSet(), {'point_cloud_fused.ply', 'scan_public.json', 'contribution.json', 'README.txt'});
    expect(utf8.decode(noPhotos['scan_public.json']!).contains('40.43219'), isFalse);

    final withPhotos = await entries(opts(photos: true));
    expect(withPhotos.keys, contains('photos/ph_00001.jpg'));
    expect(withPhotos['photos/ph_00001.jpg']!.sublist(0, 4), [0xFF, 0xD8, 0xFF, 0xDA]); // GPS EXIF stripped
    tmp.deleteSync(recursive: true);
  });
}
